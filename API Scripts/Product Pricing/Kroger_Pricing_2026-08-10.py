"""
Pull per-store pricing for known Kroger products into a pandas DataFrame.

Kroger's Products API returns price data on the SAME /v1/products endpoint
used for the catalog pull — it just needs filter.locationId added, since
price is inherently per-store, not national. To avoid re-crawling the
catalog by search term, this queries by the productIds already known from
the catalog pull, batched via filter.productId. Product IDs are read
directly from the latest kroger_product_catalog_*.csv already sitting in
S3 (not a local file) — S3 is this project's source of truth for raw
pulls, and there's no guarantee a local copy exists on whatever machine
runs this script.

Live-tested 2026-08-10 against real data:
  - filter.productId accepts a comma-separated batch — Kroger enforces a
    hard server-side cap of 50 ids/call (HTTP 400, code PRODUCT-2018,
    "Field 'productId' must not exceed 50 items").
  - The response for each product includes an "items" array with
    per-store price/inventory/fulfillment data once filter.locationId is set.

locationId values come from Product Location/Kroger_Location_*.py's
output. LOCATION_IDS below is seeded with one real, live-verified Atlanta
store (01100695, "Kroger - Ponce") — replace/expand after running the
Locations script for your actual target store list.

Output is intentionally close to raw: only productId/locationId/
collected_at are pulled out as real columns (needed as join/partition
keys), and the full, untouched API response for each product+location
combination is preserved as a JSON string in raw_data. No field
selection or reshaping (e.g. picking regular vs. promo price, a specific
item variant) is applied — that's left to dbt downstream.

NOTE (cost-effectiveness, see .claude/instructions.md): this script and
Kroger_Inventory_*.py both call this exact same endpoint independently,
and now that both land the identical raw response verbatim, they produce
literally the same raw_data content, just uploaded under different
filenames — running both back-to-back doubles the API calls for
duplicate data. Kept as two separate scripts per the requested folder
structure (Product Pricing/ vs Product Inventory/); worth considering a
single shared script if you find yourself running both together.

Output uploads to S3 (grocerydbtprojectrawdata/kroger/), same bucket/prefix
convention as the product catalog script.
"""

import base64
import io
import json
import logging
import os
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import boto3
import pandas as pd
import requests
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
load_dotenv(PROJECT_ROOT / ".env")

TOKEN_URL = "https://api.kroger.com/v1/connect/oauth2/token"
PRODUCTS_URL = "https://api.kroger.com/v1/products"

BATCH_SIZE = 50  # server-enforced max for filter.productId
DAILY_CALL_BUDGET = 10_000

MAX_WORKERS = 8
MAX_REQUESTS_PER_SECOND = 8

S3_BUCKET = "grocerydbtprojectrawdata"
S3_PREFIX = "kroger/"

# Seed with a real, live-verified Atlanta store. Replace/expand with real
# locationIds from Product Location/Kroger_Location_*.py's output.
LOCATION_IDS: list[str] = ["01100695"]


class KrogerAuth:
    def __init__(self, client_id: str, client_secret: str):
        self.client_id = client_id
        self.client_secret = client_secret
        self._access_token = None
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def get_token(self) -> str:
        with self._lock:
            if self._access_token and time.time() < self._expires_at - 30:
                return self._access_token

            credentials = f"{self.client_id}:{self.client_secret}".encode("utf-8")
            encoded_credentials = base64.b64encode(credentials).decode("utf-8")

            response = requests.post(
                TOKEN_URL,
                headers={
                    "Authorization": f"Basic {encoded_credentials}",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                data={"grant_type": "client_credentials", "scope": "product.compact"},
                timeout=30,
            )
            response.raise_for_status()
            payload = response.json()

            self._access_token = payload["access_token"]
            self._expires_at = time.time() + payload.get("expires_in", 1800)
            return self._access_token


class RateLimiter:
    def __init__(self, max_per_second: int):
        self.max_per_second = max_per_second
        self._lock = threading.Lock()
        self._call_times: deque[float] = deque()

    def acquire(self) -> None:
        while True:
            with self._lock:
                now = time.monotonic()
                while self._call_times and now - self._call_times[0] >= 1.0:
                    self._call_times.popleft()

                if len(self._call_times) < self.max_per_second:
                    self._call_times.append(now)
                    return

                sleep_for = 1.0 - (now - self._call_times[0])

            time.sleep(max(sleep_for, 0.01))


class CallBudget:
    def __init__(self, limit: int):
        self.limit = limit
        self._count = 0
        self._lock = threading.Lock()

    def try_consume(self) -> bool:
        with self._lock:
            if self._count >= self.limit:
                return False
            self._count += 1
            return True

    @property
    def count(self) -> int:
        with self._lock:
            return self._count


def load_known_product_ids(bucket: str, prefix: str) -> list[str]:
    s3 = boto3.client("s3")
    response = s3.list_objects_v2(Bucket=bucket, Prefix=f"{prefix}kroger_product_catalog_")
    keys = [obj["Key"] for obj in response.get("Contents", []) if obj["Key"].endswith(".csv")]
    if not keys:
        raise FileNotFoundError(f"No kroger_product_catalog_*.csv found under s3://{bucket}/{prefix}")

    latest_key = max(keys)  # filenames embed an ISO8601 timestamp, so lexicographic max = most recent
    logger.info("Loading known product IDs from s3://%s/%s", bucket, latest_key)

    obj = s3.get_object(Bucket=bucket, Key=latest_key)
    # dtype=str is required: Kroger productIds have meaningful leading
    # zeros (e.g. "0001111041700") that pandas silently strips if it
    # infers the column as numeric.
    df = pd.read_csv(io.BytesIO(obj["Body"].read()), dtype=str)
    return df["productId"].dropna().unique().tolist()


def chunked(items: list[str], size: int) -> list[list[str]]:
    return [items[i:i + size] for i in range(0, len(items), size)]


def fetch_pricing_batch(
    auth: KrogerAuth, rate_limiter: RateLimiter, product_ids: list[str], location_id: str
) -> list[dict]:
    max_retries = 3
    for attempt in range(max_retries):
        rate_limiter.acquire()
        response = requests.get(
            PRODUCTS_URL,
            headers={"Authorization": f"Bearer {auth.get_token()}"},
            params={
                "filter.productId": ",".join(product_ids),
                "filter.locationId": location_id,
            },
            timeout=30,
        )

        if response.status_code == 200:
            return response.json().get("data", [])

        if response.status_code in (429, 500, 502, 503, 504):
            wait = 2 ** attempt
            logger.warning(
                "location=%s batch of %s got HTTP %s, retrying in %ss (attempt %s/%s)",
                location_id, len(product_ids), response.status_code, wait, attempt + 1, max_retries,
            )
            time.sleep(wait)
            continue

        response.raise_for_status()

    logger.error(
        "location=%s batch of %s failed after %s retries, skipping",
        location_id, len(product_ids), max_retries,
    )
    return []


def flatten_pricing(product: dict, location_id: str) -> dict:
    # No field selection/reshaping here by design — dbt owns parsing and
    # joins downstream. productId/locationId/collected_at are pulled out
    # only because they're needed as join/partition keys; raw_data is the
    # untouched API object exactly as returned for this location query.
    return {
        "productId": product.get("productId"),
        "locationId": location_id,
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "raw_data": json.dumps(product),
    }


def collect_pricing(auth: KrogerAuth, product_ids: list[str], location_ids: list[str]) -> pd.DataFrame:
    rate_limiter = RateLimiter(MAX_REQUESTS_PER_SECOND)
    budget = CallBudget(DAILY_CALL_BUDGET)
    batches = chunked(product_ids, BATCH_SIZE)

    jobs = [(batch, location_id) for location_id in location_ids for batch in batches]
    logger.info(
        "%s products across %s locations -> %s batch calls planned",
        len(product_ids), len(location_ids), len(jobs),
    )

    rows: list[dict] = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {}
        for batch, location_id in jobs:
            if not budget.try_consume():
                logger.warning("Reached daily call budget (%s), stopping submission", budget.limit)
                break
            futures[executor.submit(fetch_pricing_batch, auth, rate_limiter, batch, location_id)] = location_id

        for future in as_completed(futures):
            location_id = futures[future]
            for product in future.result():
                rows.append(flatten_pricing(product, location_id))

    logger.info("Finished. Total API calls: %s, price rows collected: %s", budget.count, len(rows))
    return pd.DataFrame(rows)


def upload_df_to_s3(df: pd.DataFrame, bucket: str, key: str) -> None:
    buffer = io.StringIO()
    df.to_csv(buffer, index=False)

    s3 = boto3.client("s3")
    s3.put_object(Bucket=bucket, Key=key, Body=buffer.getvalue())
    logger.info("Uploaded %s rows to s3://%s/%s", len(df), bucket, key)


def main() -> pd.DataFrame:
    client_id = os.environ["KROGER_CLIENT_ID"]
    client_secret = os.environ["KROGER_CLIENT_SECRET"]

    auth = KrogerAuth(client_id, client_secret)
    product_ids = load_known_product_ids(S3_BUCKET, S3_PREFIX)
    df = collect_pricing(auth, product_ids, LOCATION_IDS)

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    key = f"{S3_PREFIX}kroger_pricing_{timestamp}.csv"
    upload_df_to_s3(df, S3_BUCKET, key)

    return df


if __name__ == "__main__":
    main()
