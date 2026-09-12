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

locationId values are loaded dynamically from the latest
kroger_locations_*.csv in S3 (Product Location/Kroger_Location_*.py's
output) — covers every known store, not a hardcoded subset.

Output is intentionally close to raw: only productId/locationId/
collected_at are pulled out as real columns (needed as join/partition
keys), and the full, untouched API response for each product+location
combination is preserved as a JSON string in raw_data. No field
selection or reshaping (e.g. picking regular vs. promo price, a specific
item variant) is applied — that's left to dbt downstream.

Cost/scale note: full coverage (~11K products x ~81 stores, batched 50
products/call) is ~18K calls — well over Kroger's documented 10K/day
budget, so one run can't finish it. Progress is checkpointed to S3
(a location is marked complete only once every batch for it has been
submitted within budget) so re-running this script on a later day picks
up where it left off instead of re-covering the same stores. To force a
full re-pull later (e.g. to refresh stale prices), delete the checkpoint
object at s3://<bucket>/kroger/_checkpoints/kroger_pricing_completed_locations.json.

As of 2026-08-14, Kroger_Inventory_*.py is retired — this script's
response already carries stockLevel/fulfillment data alongside price
(see stg_json_kroger_product_snapshot_items.sql), so running both against
the same store just doubles calls for duplicate data.

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
from requests.adapters import HTTPAdapter

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
load_dotenv(PROJECT_ROOT / ".env")

TOKEN_URL = "https://api.kroger.com/v1/connect/oauth2/token"
PRODUCTS_URL = "https://api.kroger.com/v1/products"

BATCH_SIZE = 50  # server-enforced max for filter.productId
DAILY_CALL_BUDGET = 10_000
REQUEST_TIMEOUT = (10, 45)  # (connect, read) seconds — read gets extra slack under load

MAX_WORKERS = 8
MAX_REQUESTS_PER_SECOND = 8

S3_BUCKET = "grocerydbtprojectrawdata"
S3_PREFIX = "kroger/"
S3_CHECKPOINT_KEY = f"{S3_PREFIX}_checkpoints/kroger_pricing_completed_locations.json"


def build_session(pool_size: int = MAX_WORKERS) -> requests.Session:
    """Shared session with a connection pool sized to the thread pool, so
    concurrent requests reuse TCP/TLS connections instead of each thread
    paying a fresh handshake — cheaper and less prone to read timeouts
    under load."""
    session = requests.Session()
    adapter = HTTPAdapter(pool_connections=pool_size, pool_maxsize=pool_size)
    session.mount("https://", adapter)
    return session


class KrogerAuth:
    def __init__(self, client_id: str, client_secret: str, session: requests.Session):
        self.client_id = client_id
        self.client_secret = client_secret
        self.session = session
        self._access_token = None
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def get_token(self) -> str:
        with self._lock:
            if self._access_token and time.time() < self._expires_at - 30:
                return self._access_token

            credentials = f"{self.client_id}:{self.client_secret}".encode("utf-8")
            encoded_credentials = base64.b64encode(credentials).decode("utf-8")

            response = self.session.post(
                TOKEN_URL,
                headers={
                    "Authorization": f"Basic {encoded_credentials}",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                data={"grant_type": "client_credentials", "scope": "product.compact"},
                timeout=REQUEST_TIMEOUT,
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


def load_known_location_ids(bucket: str, prefix: str) -> list[str]:
    s3 = boto3.client("s3")
    response = s3.list_objects_v2(Bucket=bucket, Prefix=f"{prefix}kroger_locations_")
    keys = [obj["Key"] for obj in response.get("Contents", []) if obj["Key"].endswith(".csv")]
    if not keys:
        raise FileNotFoundError(f"No kroger_locations_*.csv found under s3://{bucket}/{prefix}")

    latest_key = max(keys)  # filenames embed an ISO8601 timestamp, so lexicographic max = most recent
    logger.info("Loading known location IDs from s3://%s/%s", bucket, latest_key)

    obj = s3.get_object(Bucket=bucket, Key=latest_key)
    # dtype=str: locationIds have meaningful leading zeros, same gotcha as productId.
    df = pd.read_csv(io.BytesIO(obj["Body"].read()), dtype=str)
    return df["locationId"].dropna().unique().tolist()


def load_completed_locations(bucket: str, key: str) -> set[str]:
    s3 = boto3.client("s3")
    try:
        obj = s3.get_object(Bucket=bucket, Key=key)
    except s3.exceptions.NoSuchKey:
        return set()
    return set(json.loads(obj["Body"].read()))


def save_completed_locations(bucket: str, key: str, completed: set[str]) -> None:
    s3 = boto3.client("s3")
    s3.put_object(Bucket=bucket, Key=key, Body=json.dumps(sorted(completed)))


def fetch_pricing_batch(
    session: requests.Session, auth: KrogerAuth, rate_limiter: RateLimiter,
    product_ids: list[str], location_id: str
) -> list[dict]:
    """Fetch one batch, retrying on 429/5xx and network errors (timeouts,
    connection resets) with backoff."""
    max_retries = 3
    for attempt in range(max_retries):
        rate_limiter.acquire()
        try:
            response = session.get(
                PRODUCTS_URL,
                headers={"Authorization": f"Bearer {auth.get_token()}"},
                params={
                    "filter.productId": ",".join(product_ids),
                    "filter.locationId": location_id,
                },
                timeout=REQUEST_TIMEOUT,
            )
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as exc:
            wait = 2 ** attempt
            logger.warning(
                "location=%s batch of %s network error (%s), retrying in %ss (attempt %s/%s)",
                location_id, len(product_ids), exc, wait, attempt + 1, max_retries,
            )
            time.sleep(wait)
            continue

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


def upload_df_to_s3(df: pd.DataFrame, bucket: str, key: str) -> None:
    buffer = io.StringIO()
    df.to_csv(buffer, index=False)

    s3 = boto3.client("s3")
    s3.put_object(Bucket=bucket, Key=key, Body=buffer.getvalue())
    logger.info("Uploaded %s rows to s3://%s/%s", len(df), bucket, key)


def collect_pricing(
    session: requests.Session, auth: KrogerAuth, bucket: str, prefix: str, checkpoint_key: str,
    product_ids: list[str], location_ids: list[str], completed: set[str],
) -> tuple[int, int]:
    """Processes locations one at a time (all of a location's batches
    concurrently, via the shared thread pool). Each location's data is
    uploaded to S3 as its own small file, and the checkpoint is saved,
    IMMEDIATELY after that location finishes — not batched up for one big
    upload at the end of the whole run. Two reasons: (1) it bounds memory
    to one location's worth (~150-200MB) instead of accumulating every
    location's raw JSON in RAM for the whole run, and (2) it makes
    progress durable — if this process dies partway through (crash, a
    single bad location, laptop sleep), everything already completed is
    already safely in S3/checkpointed, and only the one in-flight location
    is lost. A single failing batch is logged and skipped rather than
    crashing the whole run — one bad store (e.g. a stale/invalid
    locationId returning 404) shouldn't take down 80 good ones. Rate
    limiting caps total throughput regardless of the per-location
    ordering, so none of this costs real wall-clock time vs. one flat
    interleaved job queue."""
    rate_limiter = RateLimiter(MAX_REQUESTS_PER_SECOND)
    budget = CallBudget(DAILY_CALL_BUDGET)
    batches = chunked(product_ids, BATCH_SIZE)

    logger.info(
        "%s products across %s remaining locations -> up to %s batch calls this run (budget %s)",
        len(product_ids), len(location_ids), len(location_ids) * len(batches), DAILY_CALL_BUDGET,
    )

    total_rows = 0
    locations_completed_this_run = 0

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        for location_id in location_ids:
            futures = []
            budget_exhausted = False
            for batch in batches:
                if not budget.try_consume():
                    budget_exhausted = True
                    break
                futures.append(executor.submit(fetch_pricing_batch, session, auth, rate_limiter, batch, location_id))

            location_rows: list[dict] = []
            for future in as_completed(futures):
                try:
                    products = future.result()
                except Exception:
                    logger.exception(
                        "location=%s a batch failed unexpectedly (not a retryable status), skipping it",
                        location_id,
                    )
                    continue
                for product in products:
                    location_rows.append(flatten_pricing(product, location_id))

            if budget_exhausted:
                logger.warning(
                    "Reached daily call budget (%s) partway through location=%s — stopping, "
                    "this location will be retried in full next run", budget.limit, location_id,
                )
                break

            if location_rows:
                timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
                key = f"{prefix}kroger_pricing_{timestamp}_{location_id}.csv"
                upload_df_to_s3(pd.DataFrame(location_rows), bucket, key)
                total_rows += len(location_rows)

            completed.add(location_id)
            save_completed_locations(bucket, checkpoint_key, completed)
            locations_completed_this_run += 1
            logger.info(
                "Completed location=%s (%s/%s locations done this run, %s calls so far)",
                location_id, locations_completed_this_run, len(location_ids), budget.count,
            )

    logger.info(
        "Finished. Total API calls: %s, price rows collected: %s, locations completed: %s/%s",
        budget.count, total_rows, locations_completed_this_run, len(location_ids),
    )
    return total_rows, locations_completed_this_run


def delete_checkpoint(bucket: str, key: str) -> None:
    # S3 DeleteObject is idempotent — succeeds even if the key never existed
    # (e.g. the very first run), so no NoSuchKey handling needed here unlike
    # load_completed_locations' read path.
    s3 = boto3.client("s3")
    s3.delete_object(Bucket=bucket, Key=key)
    logger.info("Deleted checkpoint s3://%s/%s — this run starts a full sweep", bucket, key)


def main(reset_checkpoint: bool = False) -> None:
    client_id = os.environ["KROGER_CLIENT_ID"]
    client_secret = os.environ["KROGER_CLIENT_SECRET"]

    if reset_checkpoint:
        delete_checkpoint(S3_BUCKET, S3_CHECKPOINT_KEY)

    session = build_session()
    auth = KrogerAuth(client_id, client_secret, session)
    product_ids = load_known_product_ids(S3_BUCKET, S3_PREFIX)
    all_location_ids = load_known_location_ids(S3_BUCKET, S3_PREFIX)

    completed = load_completed_locations(S3_BUCKET, S3_CHECKPOINT_KEY)
    remaining_location_ids = [loc for loc in all_location_ids if loc not in completed]

    if not remaining_location_ids:
        logger.info(
            "All %s known locations already have pricing data per checkpoint — nothing to do. "
            "Delete s3://%s/%s to force a full re-pull.",
            len(all_location_ids), S3_BUCKET, S3_CHECKPOINT_KEY,
        )
        return

    logger.info(
        "%s/%s locations already completed (checkpoint) — %s remaining",
        len(completed), len(all_location_ids), len(remaining_location_ids),
    )

    total_rows, locations_done = collect_pricing(
        session, auth, S3_BUCKET, S3_PREFIX, S3_CHECKPOINT_KEY,
        product_ids, remaining_location_ids, completed,
    )
    logger.info(
        "Run complete: %s new price rows across %s newly completed locations (checkpoint: %s/%s total)",
        total_rows, locations_done, len(completed), len(all_location_ids),
    )


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="Kroger pricing collection")
    ap.add_argument(
        "--reset-checkpoint", action="store_true",
        help="Delete the S3 checkpoint before running, forcing a full re-pull of "
             "every known location instead of skipping ones already marked "
             "complete. For the weekly scheduled refresh (see "
             "Snowflake Scripts/../orchestration docs) — not for routine local "
             "runs, where you almost always want to resume, not restart.",
    )
    args = ap.parse_args()
    main(reset_checkpoint=args.reset_checkpoint)
