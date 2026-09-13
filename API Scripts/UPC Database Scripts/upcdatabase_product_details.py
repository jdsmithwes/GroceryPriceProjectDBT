"""Look up product details on upcdatabase.org for UPCs carried by both Kroger and Walmart.

Candidates come from GROCERY_INTERMEDIATE_COMMON.DBT_INT_RETAILER_COMMON_UPCS (by LOOKUP_PRIORITY) via
the Snowflake connector. Raw responses land in s3://grocerydbtprojectrawdata/upc/ for Snowpipe. The free
plan allows 100 lookups/day, so a run stops near the quota and the next run resumes where it left off.
"""

import argparse
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

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
load_dotenv(PROJECT_ROOT / ".env")

API_URL = "https://api.upcdatabase.org/product/{barcode}"
REQUEST_TIMEOUT = (10, 30)
DEFAULT_TARGET_FOUND = 100
DEFAULT_QUOTA_RESERVE = 3
DEFAULT_SECONDS_BETWEEN_CALLS = 1.5
FLUSH_EVERY = 10

S3_BUCKET = "grocerydbtprojectrawdata"
S3_PREFIX = "upc/"
S3_CHECKPOINT_KEY = f"{S3_PREFIX}_checkpoints/upcdatabase_lookup_status.json"
FINAL_STATUSES = ("found", "not_found")

CANDIDATES_SQL = """
select UPC_A, KROGER_PRODUCT_ID, WALMART_ITEM_ID
from GROCERYDBTPROJECT.GROCERY_INTERMEDIATE_COMMON.DBT_INT_RETAILER_COMMON_UPCS
order by LOOKUP_PRIORITY
"""

LOADED_SQL = """
select UPC, max_by(LOOKUP_STATUS, COLLECTED_AT)
from GROCERYDBTPROJECT.GROCERY_RAW_UPC.UPCDATABASE_PRODUCT_DETAILS
where LOOKUP_STATUS in ('found', 'not_found')
group by UPC
"""


def load_from_snowflake() -> tuple[list[tuple[str, str, str]], dict[str, str]]:
    connection_name = os.getenv("SNOWFLAKE_CONNECTION_NAME", "default")
    with snowflake.connector.connect(connection_name=connection_name) as conn:
        cursor = conn.cursor()
        candidates = [tuple(row) for row in cursor.execute(CANDIDATES_SQL)]
        loaded = dict(cursor.execute(LOADED_SQL).fetchall())
    return candidates, loaded


def load_checkpoint(s3) -> dict[str, str]:
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=S3_CHECKPOINT_KEY)
    except s3.exceptions.NoSuchKey:
        return {}
    return json.loads(obj["Body"].read())


def lookup(session: requests.Session, api_key: str, barcode: str) -> requests.Response | None:
    max_retries = 3
    for attempt in range(max_retries):
        try:
            response = session.get(
                API_URL.format(barcode=barcode),
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=REQUEST_TIMEOUT,
            )
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as exc:
            logger.warning("upc=%s network error (%s), retrying (attempt %s/%s)", barcode, exc, attempt + 1, max_retries)
            time.sleep(2 ** attempt)
            continue
        if response.status_code in (500, 502, 503, 504):
            logger.warning("upc=%s HTTP %s, retrying (attempt %s/%s)", barcode, response.status_code, attempt + 1, max_retries)
            time.sleep(2 ** attempt)
            continue
        return response
    return None


def classify(response: requests.Response) -> str:
    if response.status_code == 200:
        try:
            body = response.json()
        except ValueError:
            return "error"
        return "found" if body.get("success", True) else "not_found"
    if response.status_code == 404:
        return "not_found"
    if response.status_code == 429:
        return "rate_limited"
    if response.status_code in (401, 403):
        return "auth_failed"
    return "error"


def flush(s3, rows: list[dict], checkpoint: dict[str, str]) -> None:
    if not rows:
        return
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%S%fZ")
    key = f"{S3_PREFIX}upcdatabase_product_details_{timestamp}.csv"
    buffer = io.StringIO()
    pd.DataFrame(rows).to_csv(buffer, index=False)
    s3.put_object(Bucket=S3_BUCKET, Key=key, Body=buffer.getvalue())
    s3.put_object(Bucket=S3_BUCKET, Key=S3_CHECKPOINT_KEY, Body=json.dumps(checkpoint, sort_keys=True))
    logger.info("Uploaded %s lookups to s3://%s/%s", len(rows), S3_BUCKET, key)
    rows.clear()


def main(dry_run: bool, target_found: int, max_calls: int | None, quota_reserve: int, delay: float) -> None:
    s3 = boto3.client("s3")
    candidates, loaded = load_from_snowflake()
    statuses = {**loaded, **load_checkpoint(s3)}
    found = sum(1 for status in statuses.values() if status == "found")
    pending = [c for c in candidates if c[0] not in statuses]
    still_needed = max(target_found - found, 0)

    logger.info(
        "%s common UPCs; %s already found, %s not in upcdatabase; %s pending; need %s more to reach %s",
        len(candidates), found, sum(1 for s in statuses.values() if s == "not_found"),
        len(pending), still_needed, target_found,
    )
    if len(candidates) < target_found:
        logger.warning("Only %s common UPCs exist — run kroger_walmart_upc_match.py to find more", len(candidates))
    if dry_run:
        for upc, kroger_id, walmart_id in pending[:still_needed]:
            logger.info("would look up upc=%s (kroger=%s, walmart=%s)", upc, kroger_id, walmart_id)
        return
    if still_needed == 0:
        return

    api_key = os.environ.get("UPC_DATABASE_API_KEY")
    if not api_key:
        raise SystemExit("UPC_DATABASE_API_KEY is not set — add it to .env")

    session = requests.Session()
    rows: list[dict] = []
    calls = found_this_run = 0

    for upc, kroger_id, walmart_id in pending:
        if found_this_run >= still_needed or (max_calls is not None and calls >= max_calls):
            break

        response = lookup(session, api_key, upc)
        calls += 1
        if response is None:
            logger.error("upc=%s failed after retries, will retry next run", upc)
            continue

        status = classify(response)
        remaining = response.headers.get("APILimit-Lookups")
        logger.info("upc=%s status=%s lookups_remaining=%s", upc, status, remaining)

        if status == "auth_failed":
            flush(s3, rows, statuses)
            raise SystemExit(f"upcdatabase.org rejected the API key (HTTP {response.status_code})")
        if status == "rate_limited":
            logger.warning("Daily lookup quota reached; resets at %s", response.headers.get("APILimit-Reset"))
            break

        rows.append({
            "upc": upc,
            "kroger_product_id": kroger_id,
            "walmart_item_id": walmart_id,
            "lookup_status": status,
            "http_status": response.status_code,
            "api_lookups_remaining": remaining,
            "collected_at": datetime.now(timezone.utc).isoformat(),
            "raw_data": response.text,
        })
        if status in FINAL_STATUSES:
            statuses[upc] = status
        if status == "found":
            found_this_run += 1
        if len(rows) >= FLUSH_EVERY:
            flush(s3, rows, statuses)

        if remaining is not None and remaining.isdigit() and int(remaining) <= quota_reserve:
            logger.warning(
                "%s lookups left (reserve %s); stopping until reset at %s",
                remaining, quota_reserve, response.headers.get("APILimit-Reset"),
            )
            break
        time.sleep(delay)

    flush(s3, rows, statuses)
    logger.info(
        "Run complete: %s calls, %s found this run, %s of %s found overall",
        calls, found_this_run, found + found_this_run, target_found,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="List the UPCs a run would look up, without API calls.")
    parser.add_argument("--target", type=int, default=DEFAULT_TARGET_FOUND, help="Total products with details to reach.")
    parser.add_argument("--max-calls", type=int, default=None, help="Cap API calls this run (e.g. 1 for a smoke test).")
    parser.add_argument("--quota-reserve", type=int, default=DEFAULT_QUOTA_RESERVE, help="Stop when this many lookups remain.")
    parser.add_argument("--delay", type=float, default=DEFAULT_SECONDS_BETWEEN_CALLS, help="Seconds between calls.")
    args = parser.parse_args()
    main(args.dry_run, args.target, args.max_calls, args.quota_reserve, args.delay)
