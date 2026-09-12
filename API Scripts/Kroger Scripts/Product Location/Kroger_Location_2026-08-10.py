"""
Pull Kroger store locations (locationId, address, geolocation, departments)
into a pandas DataFrame, organized by US region for easy expansion.

Endpoint (live-tested 2026-08-10): GET https://api.kroger.com/v1/locations
Params: filter.zipCode.near, filter.radiusInMiles, filter.limit, filter.start
(pagination convention matches the Products API).

REGIONS below is the extension point: start broad (one zip + a wide radius),
then add more search points to a region — or whole new regions — for finer
coverage without touching any other code. Currently seeded with just Metro
Atlanta per initial scope.

locationId values discovered here feed the LOCATION_IDS list in the Pricing
and Inventory scripts (Product Pricing/, Product Inventory/) — pricing and
inventory are inherently per-store, so those scripts can't run meaningfully
without at least one real locationId from this script's output.

Output is intentionally close to raw: only locationId/region/collected_at
are pulled out as real columns (needed as join/partition keys), and the
full, untouched API response for each location is preserved as a JSON
string in raw_data. No field selection, joining, or reshaping is applied —
that's left to dbt downstream.

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

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
load_dotenv(PROJECT_ROOT / ".env")

TOKEN_URL = "https://api.kroger.com/v1/connect/oauth2/token"
LOCATIONS_URL = "https://api.kroger.com/v1/locations"

PAGE_LIMIT = 200          # Locations API page size; unlike Products (max 50),
                           # this endpoint has not been confirmed to cap here —
                           # kept conservative and paginated defensively either way.
MAX_PAGES_PER_SEARCH_POINT = 5
DAILY_CALL_BUDGET = 10_000

MAX_WORKERS = 8
MAX_REQUESTS_PER_SECOND = 8

S3_BUCKET = "grocerydbtprojectrawdata"
S3_PREFIX = "kroger/"

# Extension point: add more search points to widen coverage within a region,
# or add new regions entirely. Each search point is one Locations API call
# (plus pagination) — keep this list only as large as actually needed, per
# the project's cost-effectiveness guideline (.claude/instructions.md).
REGIONS: dict[str, list[dict]] = {
    "Metro Atlanta": [
        {"zip_code": "30303", "radius_miles": 25},  # downtown Atlanta, wide radius
        # Add more points here for finer coverage of outer suburbs, e.g.:
        # {"zip_code": "30009", "radius_miles": 15},  # Alpharetta (north metro)
        # {"zip_code": "30135", "radius_miles": 15},  # Douglasville (west metro)
    ],
    # Add more regions here as the project expands, e.g.:
    # "Metro Chicago": [{"zip_code": "60601", "radius_miles": 25}],
}


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


def fetch_locations_page(
    auth: KrogerAuth, rate_limiter: RateLimiter, zip_code: str, radius_miles: int, start: int
) -> list[dict]:
    max_retries = 3
    for attempt in range(max_retries):
        rate_limiter.acquire()
        response = requests.get(
            LOCATIONS_URL,
            headers={"Authorization": f"Bearer {auth.get_token()}"},
            params={
                "filter.zipCode.near": zip_code,
                "filter.radiusInMiles": radius_miles,
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
                "zip=%s start=%s got HTTP %s, retrying in %ss (attempt %s/%s)",
                zip_code, start, response.status_code, wait, attempt + 1, max_retries,
            )
            time.sleep(wait)
            continue

        response.raise_for_status()

    logger.error("zip=%s start=%s failed after %s retries, skipping", zip_code, start, max_retries)
    return []


def flatten_location(location: dict, region: str) -> dict:
    # No field selection/reshaping here by design — dbt owns parsing and
    # joins downstream (see .claude/instructions.md and project direction).
    # locationId/region/collected_at are pulled out only because they're
    # needed as join/partition keys; raw_data is the untouched API object.
    return {
        "locationId": location.get("locationId"),
        "region": region,
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "raw_data": json.dumps(location),
    }


def walk_search_point(
    auth: KrogerAuth, rate_limiter: RateLimiter, budget: CallBudget, region: str, search_point: dict
) -> list[dict]:
    zip_code = search_point["zip_code"]
    radius_miles = search_point["radius_miles"]
    rows = []
    start = 0

    for _ in range(MAX_PAGES_PER_SEARCH_POINT):
        if not budget.try_consume():
            logger.warning("Reached daily call budget (%s), stopping early", budget.limit)
            break

        locations = fetch_locations_page(auth, rate_limiter, zip_code, radius_miles, start)
        if not locations:
            break

        for location in locations:
            rows.append(flatten_location(location, region))

        if len(locations) < PAGE_LIMIT:
            break  # last page for this search point

        start += PAGE_LIMIT

    logger.info("region=%r zip=%s: found %s locations", region, zip_code, len(rows))
    return rows


def collect_locations(auth: KrogerAuth) -> pd.DataFrame:
    rate_limiter = RateLimiter(MAX_REQUESTS_PER_SECOND)
    budget = CallBudget(DAILY_CALL_BUDGET)

    search_jobs = [
        (region, search_point)
        for region, search_points in REGIONS.items()
        for search_point in search_points
    ]

    rows: dict[str, dict] = {}  # keyed by locationId to de-dupe overlapping search points
    with ThreadPoolExecutor(max_workers=min(MAX_WORKERS, len(search_jobs))) as executor:
        futures = {
            executor.submit(walk_search_point, auth, rate_limiter, budget, region, sp): (region, sp)
            for region, sp in search_jobs
        }
        for future in as_completed(futures):
            for row in future.result():
                location_id = row["locationId"]
                if location_id:
                    rows[location_id] = row

    logger.info("Finished. Total API calls: %s, unique locations: %s", budget.count, len(rows))
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
    df = collect_locations(auth)

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    key = f"{S3_PREFIX}kroger_locations_{timestamp}.csv"
    upload_df_to_s3(df, S3_BUCKET, key)

    return df


if __name__ == "__main__":
    main()
