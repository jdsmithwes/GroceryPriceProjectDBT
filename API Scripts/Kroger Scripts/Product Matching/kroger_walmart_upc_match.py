"""Find Walmart grocery items that Kroger also carries by looking up Walmart UPCs in Kroger's Products API.

Kroger's productId is the UPC without its check digit, zero-padded to 13 digits, so each Walmart
UPC-A converts straight to a Kroger productId (no search needed). Candidates are read from Snowflake
via the connector; matches are written in entire_productcatalog_kroger.py's CSV shape so the catalog
Snowpipe loads them into GROCERY_RAW_KROGER.KROGER_PRODUCT_CATALOG.
"""

import argparse
import base64
import io
import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path

import boto3
import pandas as pd
import requests
import snowflake.connector
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
load_dotenv(PROJECT_ROOT / ".env")

TOKEN_URL = "https://api.kroger.com/v1/connect/oauth2/token"
PRODUCTS_URL = "https://api.kroger.com/v1/products"

BATCH_SIZE = 50  # server-enforced max for filter.productId
REQUEST_TIMEOUT = (10, 45)
SECONDS_BETWEEN_CALLS = 0.5
DEFAULT_MAX_CALLS = 40

S3_BUCKET = "grocerydbtprojectrawdata"
# Must stay out of top-level kroger/: the pricing script treats the latest top-level
# kroger_product_catalog_* file as its entire product list.
S3_MATCH_PREFIX = "kroger/upc_match/"
S3_ATTEMPTED_KEY = f"{S3_MATCH_PREFIX}_checkpoints/attempted_product_ids.json"

CANDIDATES_SQL = """
with walmart_upcs as (
    select distinct w.UPC
    from GROCERYDBTPROJECT.GROCERY_STAGING_WALMART.DBT_STG_WALMART_PRODUCT_CATALOG w
    join GROCERYDBTPROJECT.GROCERY_INTERMEDIATE_COMMON.DBT_INT_RETAILER_PRODUCT_CATEGORIES c
        on c.RETAILER = 'walmart'
        and c.PRODUCT_ID = w.ITEM_ID
        and c.CROSSWALK_STATUS = 'mapped'
    where regexp_like(w.UPC, '^[0-9]{12}$')
)
select distinct lpad(left(UPC, 11), 13, '0') as KROGER_PRODUCT_ID
from walmart_upcs
where lpad(left(UPC, 11), 13, '0') not in (
    select "productId"
    from GROCERYDBTPROJECT.GROCERY_RAW_KROGER.KROGER_PRODUCT_CATALOG
    where "productId" is not null
)
order by 1
"""


def load_candidates() -> list[str]:
    connection_name = os.getenv("SNOWFLAKE_CONNECTION_NAME", "default")
    with snowflake.connector.connect(connection_name=connection_name) as conn:
        return [row[0] for row in conn.cursor().execute(CANDIDATES_SQL)]


def load_attempted(s3) -> set[str]:
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=S3_ATTEMPTED_KEY)
    except s3.exceptions.NoSuchKey:
        return set()
    return set(json.loads(obj["Body"].read()))


def get_token(session: requests.Session) -> str:
    credentials = f"{os.environ['KROGER_CLIENT_ID']}:{os.environ['KROGER_CLIENT_SECRET']}".encode("utf-8")
    response = session.post(
        TOKEN_URL,
        headers={
            "Authorization": f"Basic {base64.b64encode(credentials).decode('utf-8')}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        data={"grant_type": "client_credentials", "scope": "product.compact"},
        timeout=REQUEST_TIMEOUT,
    )
    response.raise_for_status()
    return response.json()["access_token"]


def fetch_batch(session: requests.Session, token: str, product_ids: list[str]) -> list[dict] | None:
    """Returns None when the batch still fails after retries, so it isn't marked attempted."""
    max_retries = 3
    for attempt in range(max_retries):
        try:
            response = session.get(
                PRODUCTS_URL,
                headers={"Authorization": f"Bearer {token}"},
                params={"filter.productId": ",".join(product_ids)},
                timeout=REQUEST_TIMEOUT,
            )
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as exc:
            logger.warning("Network error (%s), retrying (attempt %s/%s)", exc, attempt + 1, max_retries)
            time.sleep(2 ** attempt)
            continue

        if response.status_code == 200:
            return response.json().get("data", [])
        if response.status_code in (429, 500, 502, 503, 504):
            logger.warning("HTTP %s, retrying (attempt %s/%s)", response.status_code, attempt + 1, max_retries)
            time.sleep(2 ** attempt)
            continue
        response.raise_for_status()

    logger.error("Batch of %s failed after %s retries, will retry next run", len(product_ids), max_retries)
    return None


def flatten_product(product: dict) -> dict:
    items = product.get("items") or [{}]
    first_item = items[0]
    images = product.get("images") or []
    front_image = next(
        (img for img in images if img.get("perspective") == "front"),
        images[0] if images else {},
    )
    front_image_url = next(
        (size.get("url") for size in front_image.get("sizes", []) if size.get("size") == "medium"),
        None,
    )
    return {
        "productId": product.get("productId"),
        "upc": product.get("upc"),
        "brand": product.get("brand"),
        "description": product.get("description"),
        "categories": ", ".join(product.get("categories", [])),
        "countryOrigin": product.get("countryOrigin"),
        "temperature": (product.get("temperature") or {}).get("indicator"),
        "size": first_item.get("size"),
        "soldBy": first_item.get("soldBy"),
        "image_url": front_image_url,
        "collected_at": datetime.now(timezone.utc).isoformat(),
    }


def main(dry_run: bool, max_calls: int) -> None:
    s3 = boto3.client("s3")
    candidates = load_candidates()
    attempted = load_attempted(s3)
    remaining = [c for c in candidates if c not in attempted]
    batches = [remaining[i:i + BATCH_SIZE] for i in range(0, len(remaining), BATCH_SIZE)][:max_calls]

    logger.info(
        "%s Walmart UPCs not in Kroger's catalog, %s already attempted, %s to try in %s Kroger calls",
        len(candidates), len(candidates) - len(remaining), sum(map(len, batches)), len(batches),
    )
    if dry_run or not batches:
        return

    session = requests.Session()
    token = get_token(session)
    rows: dict[str, dict] = {}
    newly_attempted: set[str] = set()

    for number, batch in enumerate(batches, start=1):
        products = fetch_batch(session, token, batch)
        if products is not None:
            for product in products:
                row = flatten_product(product)
                if row["productId"]:
                    rows[row["productId"]] = row
            newly_attempted.update(batch)
        logger.info("Call %s/%s: %s matches so far", number, len(batches), len(rows))
        time.sleep(SECONDS_BETWEEN_CALLS)

    if rows:
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
        key = f"{S3_MATCH_PREFIX}kroger_product_catalog_upc_match_{timestamp}.csv"
        buffer = io.StringIO()
        pd.DataFrame(rows.values()).to_csv(buffer, index=False)
        s3.put_object(Bucket=S3_BUCKET, Key=key, Body=buffer.getvalue())
        logger.info("Uploaded %s matched products to s3://%s/%s", len(rows), S3_BUCKET, key)

    s3.put_object(
        Bucket=S3_BUCKET, Key=S3_ATTEMPTED_KEY, Body=json.dumps(sorted(attempted | newly_attempted)),
    )
    logger.info(
        "Done: %s of %s looked-up Walmart UPCs are carried by Kroger", len(rows), len(newly_attempted),
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Show the plan without calling Kroger.")
    parser.add_argument("--max-calls", type=int, default=DEFAULT_MAX_CALLS, help="Cap on Kroger API calls.")
    args = parser.parse_args()
    main(dry_run=args.dry_run, max_calls=args.max_calls)
