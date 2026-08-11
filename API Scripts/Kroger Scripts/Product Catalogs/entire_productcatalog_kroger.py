"""
Pull as much of the Kroger product catalog as possible into a pandas DataFrame.

Kroger's Products API has no bulk "list everything" endpoint: each call to
/v1/products requires a search term, brand, or product ID filter, and every
unique filter combination is capped at 250 results (start + limit <= 250).
This script works around that by looping over a list of search terms,
paginating each one to the cap, and de-duplicating on productId.

Requests are fanned out with a bounded thread pool since this workload is
I/O-bound (waiting on Kroger's servers, not local CPU). Pagination proceeds
in rounds: all active terms fetch page N concurrently, then any term whose
page came back short drops out before round N+1. This keeps total API calls
identical to a sequential run (no calls wasted probing pages that don't
exist) while cutting wall-clock time by roughly MAX_WORKERS.

No locationId is used, so results are catalog metadata only (no per-store
price/availability) — that can be layered on separately with a locationId
once you know which store(s) you care about.

Output is written directly to S3 (no local file), as a new timestamped key
per run so nothing is overwritten between pulls.
"""

import base64
import io
import logging
import os
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
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

PAGE_LIMIT = 50           # max results per page allowed by the API
MAX_START = 200           # max filter.start allowed (200 + 50 = 250 results/term cap)
DAILY_CALL_BUDGET = 10_000  # Kroger's documented rate limit

MAX_WORKERS = 10            # concurrent in-flight requests
MAX_REQUESTS_PER_SECOND = 8  # conservative pace to stay well clear of throttling

S3_BUCKET = "grocerydbtprojectrawdata"
S3_PREFIX = "kroger/"

# Search terms to iterate over. Kroger has no category-listing endpoint, so
# broad grocery terms are used as a stand-in for "browse everything". Expand
# this list to improve catalog coverage.
SEARCH_TERMS = [
    "milk", "bread", "eggs", "cheese", "chicken", "beef", "pork", "seafood",
    "fruit", "vegetables", "cereal", "snacks", "soda", "juice", "water",
    "coffee", "tea", "pasta", "rice", "beans", "soup", "frozen", "ice cream",
    "yogurt", "butter", "bakery", "deli", "paper towels", "cleaning",
    "laundry", "shampoo", "soap", "toothpaste", "diapers", "baby food",
    "pet food", "candy", "chips", "crackers", "condiments", "sauce",
    "spices", "baking", "canned goods", "dairy", "produce", "beverages",
    "wine", "beer", "energy drink", "granola bar",
]


class KrogerAuth:
    """Thread-safe token cache. Only one thread refreshes at a time; the
    rest reuse the cached token once it lands."""

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


def fetch_products_page(
    auth: KrogerAuth, rate_limiter: RateLimiter, term: str, start: int
) -> list[dict]:
    """Fetch a single page of results, retrying on 429/5xx with backoff."""
    max_retries = 3
    for attempt in range(max_retries):
        rate_limiter.acquire()
        response = requests.get(
            PRODUCTS_URL,
            headers={"Authorization": f"Bearer {auth.get_token()}"},
            params={
                "filter.term": term,
                "filter.limit": PAGE_LIMIT,
                "filter.start": start,
            },
            timeout=30,
        )

        if response.status_code == 200:
            return response.json().get("data", [])

        if response.status_code in (429, 500, 502, 503, 504):
            wait = 2 ** attempt
            logger.warning(
                "term=%r start=%s got HTTP %s, retrying in %ss (attempt %s/%s)",
                term, start, response.status_code, wait, attempt + 1, max_retries,
            )
            time.sleep(wait)
            continue

        response.raise_for_status()

    logger.error("term=%r start=%s failed after %s retries, skipping", term, start, max_retries)
    return []


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


def collect_catalog(auth: KrogerAuth, terms: list[str]) -> pd.DataFrame:
    rate_limiter = RateLimiter(MAX_REQUESTS_PER_SECOND)
    budget = CallBudget(DAILY_CALL_BUDGET)
    rows: dict[str, dict] = {}  # keyed by productId to de-dupe

    active_terms = list(terms)
    start = 0

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        while active_terms and start <= MAX_START:
            schedulable = [t for t in active_terms if budget.try_consume()]
            if not schedulable:
                logger.warning("Reached daily call budget (%s), stopping early", DAILY_CALL_BUDGET)
                break

            logger.info(
                "Round start=%s: %s active terms (unique products so far: %s, calls so far: %s)",
                start, len(schedulable), len(rows), budget.count,
            )

            futures = {
                executor.submit(fetch_products_page, auth, rate_limiter, term, start): term
                for term in schedulable
            }

            next_active_terms = []
            for future, term in futures.items():
                products = future.result()

                for product in products:
                    row = flatten_product(product)
                    product_id = row["productId"]
                    if product_id:
                        rows[product_id] = row

                if len(products) == PAGE_LIMIT:
                    next_active_terms.append(term)  # may have more pages

            active_terms = next_active_terms
            start += PAGE_LIMIT

    logger.info("Finished. Total API calls: %s, unique products: %s", budget.count, len(rows))
    return pd.DataFrame(rows.values())


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
    df = collect_catalog(auth, SEARCH_TERMS)

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    key = f"{S3_PREFIX}kroger_product_catalog_{timestamp}.csv"
    upload_df_to_s3(df, S3_BUCKET, key)

    return df


if __name__ == "__main__":
    main()
