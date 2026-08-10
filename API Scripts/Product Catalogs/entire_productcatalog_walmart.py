"""
Pull the grocery/food portion of Walmart's product catalog into a pandas
DataFrame, using the Affiliate API's paginated items feed:

    GET https://developer.api.walmart.com/api-proxy/service/affil/product/v2/paginated/items

Every request must carry 4 signed headers (WM_CONSUMER.ID,
WM_CONSUMER.INTIMESTAMP, WM_SEC.KEY_VERSION, WM_SEC.AUTH_SIGNATURE). The
signature is RSA-SHA256 over "consumerId\nintimestamp\nkeyVersion\n" using
the private key at WALMART_KEY_PATH, and expires 180 seconds after it's
generated — so it's regenerated fresh on every single request rather than
cached like the Kroger OAuth token. See .claude/instructions.md for the
full signing spec as documented by Walmart.

Pagination: the response carries a "nextPage" field — a full relative URL
(with its own query string, including category/count) to hit verbatim for
the next page. That makes pagination within one category/brand filter
strictly sequential (you can't know page 2's URL until page 1 responds).
The independent unit of work is therefore a *filter* (a category or brand),
not a page — so CATALOG_FILTERS holds a list of filter dicts, and each
filter's full paginated walk runs in its own thread, concurrently, the same
way Kroger's independent search terms did.

Server-side category scoping needs a real category id from Walmart's
Taxonomy API (separate endpoint, not yet reviewed) — CATALOG_FILTERS
defaults to a single unfiltered walk until real Food/Grocery category ids
are added. In the meantime, GROCERY_KEYWORDS filters items client-side by
matching against the real "categoryPath" field (e.g.
"Food/Snacks/Chips"), confirmed from Walmart's sample response.

WALMART_KEY_PATH (credentials/walmart/WM_IO_private_key.pem) does not
exist on disk yet, so this hasn't been tested against the live API —
only the signing algorithm and the pagination/parsing logic (against a
mocked response matching Walmart's documented schema) have been verified.
"""

import base64
import io
import logging
import os
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

import boto3
import pandas as pd
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
load_dotenv(PROJECT_ROOT / ".env")

API_HOST = "https://developer.api.walmart.com"
CATALOG_PATH = "/api-proxy/service/affil/product/v2/paginated/items"
KEY_VERSION = "1"

PAGE_SIZE = 200            # "count" param; max not confirmed, lower this if the API errors
MAX_PAGES_PER_FILTER = 500  # safety valve against a runaway/looping walk, not an expected ceiling

DAILY_CALL_BUDGET = 10_000
MAX_WORKERS = 10
MAX_REQUESTS_PER_SECOND = 8

S3_BUCKET = "grocerydbtprojectrawdata"
S3_PREFIX = "walmart/"

# One walk per filter, run concurrently. TODO: once real Food/Grocery
# category ids are pulled from Walmart's Taxonomy API, replace the single
# unfiltered entry below with one entry per category id, e.g.
# [{"category": "976759"}, {"category": "976760"}] — each runs as its own
# concurrent, fully-paginated walk instead of relying on client-side
# keyword filtering.
CATALOG_FILTERS: list[dict] = [{}]

# Client-side safety net: keep only items whose categoryPath matches one of
# these, since server-side category scoping isn't wired up yet (see
# CATALOG_FILTERS above). categoryPath is a real field confirmed from
# Walmart's documented sample response, e.g. "Food/Snacks/Chips".
GROCERY_KEYWORDS = [
    "food", "grocery", "grocer", "snack", "beverage", "drink", "pantry",
    "dairy", "produce", "meat", "seafood", "bakery", "frozen", "candy",
    "condiment", "spice", "cereal", "breakfast",
]


class WalmartAuth:
    """Generates the 4 signed headers Walmart's Affiliate API requires on
    every request. Unlike Kroger's bearer token, this signature has a
    180-second TTL, so it's regenerated per-request rather than cached."""

    def __init__(self, consumer_id: str, private_key_path: Path, key_version: str = KEY_VERSION):
        self.consumer_id = consumer_id
        self.key_version = key_version
        with open(private_key_path, "rb") as f:
            self._private_key = serialization.load_pem_private_key(f.read(), password=None)

    def build_headers(self) -> dict[str, str]:
        intimestamp = str(int(time.time() * 1000))

        # Canonicalization per Walmart's docs: sort header names
        # alphabetically, concatenate "value\n" for each in that order.
        fields = {
            "WM_CONSUMER.ID": self.consumer_id,
            "WM_CONSUMER.INTIMESTAMP": intimestamp,
            "WM_SEC.KEY_VERSION": self.key_version,
        }
        string_to_sign = "".join(f"{fields[k]}\n" for k in sorted(fields))

        signature_bytes = self._private_key.sign(
            string_to_sign.encode("utf-8"),
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
        signature = base64.b64encode(signature_bytes).decode("utf-8")

        return {
            "WM_CONSUMER.ID": self.consumer_id,
            "WM_CONSUMER.INTIMESTAMP": intimestamp,
            "WM_SEC.KEY_VERSION": self.key_version,
            "WM_SEC.AUTH_SIGNATURE": signature,
            "Accept": "application/json",
        }


class RateLimiter:
    """Sliding-window limiter shared across worker threads, so the pool as a
    whole never exceeds N requests/second regardless of MAX_WORKERS."""

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
    """Thread-safe counter that stops new work once the daily call limit is
    within reach, so a burst of in-flight requests can't blow past it."""

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


def fetch_page(auth: WalmartAuth, rate_limiter: RateLimiter, url: str) -> dict:
    """Fetch a single, already-fully-composed page URL, retrying on
    429/5xx with backoff."""
    max_retries = 3
    for attempt in range(max_retries):
        rate_limiter.acquire()
        response = requests.get(url, headers=auth.build_headers(), timeout=30)

        if response.status_code == 200:
            return response.json()

        if response.status_code in (429, 500, 502, 503, 504):
            wait = 2 ** attempt
            logger.warning(
                "GET %s got HTTP %s, retrying in %ss (attempt %s/%s)",
                url, response.status_code, wait, attempt + 1, max_retries,
            )
            time.sleep(wait)
            continue

        response.raise_for_status()

    logger.error("GET %s failed after %s retries, stopping this walk", url, max_retries)
    return {}


def is_grocery_item(item: dict) -> bool:
    haystack = " ".join(
        str(item.get(field, ""))
        for field in ("categoryPath", "name", "longDescription")
    ).lower()
    return any(keyword in haystack for keyword in GROCERY_KEYWORDS)


def flatten_product(item: dict) -> dict:
    return {
        "itemId": item.get("itemId"),
        "parentItemId": item.get("parentItemId"),
        "upc": item.get("upc"),
        "name": item.get("name"),
        "brandName": item.get("brandName"),
        "categoryPath": item.get("categoryPath"),
        "categoryNode": item.get("categoryNode"),
        "msrp": item.get("msrp"),
        "salePrice": item.get("salePrice"),
        "longDescription": item.get("longDescription"),
        "stock": item.get("stock"),
        "marketplace": item.get("marketplace"),
        "sellerInfo": item.get("sellerInfo"),
        "customerRating": item.get("customerRating"),
        "numReviews": item.get("numReviews"),
        "clearance": item.get("clearance"),
        "mediumImage": item.get("mediumImage"),
        "productTrackingUrl": item.get("productTrackingUrl"),
        "collected_at": datetime.now(timezone.utc).isoformat(),
    }


def walk_filter(
    auth: WalmartAuth, rate_limiter: RateLimiter, budget: CallBudget, filter_params: dict
) -> list[dict]:
    """Sequentially page through one category/brand filter end-to-end,
    following each response's "nextPage" URL verbatim, and return the
    grocery-matching rows found."""
    query = urlencode({"count": PAGE_SIZE, **filter_params})
    url = f"{API_HOST}{CATALOG_PATH}?{query}"
    rows = []

    for _ in range(MAX_PAGES_PER_FILTER):
        if not budget.try_consume():
            logger.warning(
                "filter=%r reached daily call budget (%s), stopping early",
                filter_params, budget.limit,
            )
            break

        payload = fetch_page(auth, rate_limiter, url)
        items = payload.get("items") or []
        if not items:
            break

        for item in items:
            if is_grocery_item(item):
                rows.append(flatten_product(item))

        logger.info(
            "filter=%r page fetched: %s items, %s grocery so far this filter, calls so far: %s",
            filter_params, len(items), len(rows), budget.count,
        )

        next_page = payload.get("nextPage")
        if not next_page:
            break
        url = f"{API_HOST}{next_page}"

    return rows


def collect_catalog(auth: WalmartAuth, filters: list[dict]) -> pd.DataFrame:
    rate_limiter = RateLimiter(MAX_REQUESTS_PER_SECOND)
    budget = CallBudget(DAILY_CALL_BUDGET)
    rows: dict[str, dict] = {}

    with ThreadPoolExecutor(max_workers=min(MAX_WORKERS, len(filters))) as executor:
        futures = {
            executor.submit(walk_filter, auth, rate_limiter, budget, f): f for f in filters
        }
        for future in as_completed(futures):
            for row in future.result():
                item_id = row["itemId"]
                if item_id:
                    rows[item_id] = row

    logger.info("Finished. Total API calls: %s, unique grocery products: %s", budget.count, len(rows))
    return pd.DataFrame(rows.values())


def upload_df_to_s3(df: pd.DataFrame, bucket: str, key: str) -> None:
    buffer = io.StringIO()
    df.to_csv(buffer, index=False)

    s3 = boto3.client("s3")
    s3.put_object(Bucket=bucket, Key=key, Body=buffer.getvalue())
    logger.info("Uploaded %s rows to s3://%s/%s", len(df), bucket, key)


def main() -> pd.DataFrame:
    consumer_id = os.environ["WALMART_CONSUMER_ID"]
    key_path = PROJECT_ROOT / os.environ["WALMART_KEY_PATH"]

    auth = WalmartAuth(consumer_id, key_path)
    df = collect_catalog(auth, CATALOG_FILTERS)

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    key = f"{S3_PREFIX}walmart_grocery_catalog_{timestamp}.csv"
    upload_df_to_s3(df, S3_BUCKET, key)

    return df


if __name__ == "__main__":
    main()
