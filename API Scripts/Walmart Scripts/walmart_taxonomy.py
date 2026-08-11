"""
Pull Walmart's full category taxonomy (Departments > Categories >
Sub-categories) into a flat pandas DataFrame, via:

    GET https://developer.api.walmart.com/api-proxy/service/affil/product/v2/taxonomy

This is a single unpaginated call, so it reuses the signed-request auth,
retry, and S3-upload logic from entire_productcatalog_walmart.py rather
than duplicating it.

The point of this script: entire_productcatalog_walmart.py's CATALOG_FILTERS
needs real Walmart category ids to scope pulls to Food/Grocery instead of
filtering client-side by keyword. This script surfaces the ids to use —
run it, check the logged "grocery/food keyword matches" section (or the
uploaded CSV) for the right department id(s), then set those as
`{"category": "<id>"}` entries in CATALOG_FILTERS over there.
"""

import logging
from datetime import datetime, timezone

import pandas as pd

from entire_productcatalog_walmart import (
    API_HOST,
    PROJECT_ROOT,
    RateLimiter,
    S3_BUCKET,
    WalmartAuth,
    fetch_page,
    upload_df_to_s3,
)
import os

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

TAXONOMY_PATH = "/api-proxy/service/affil/product/v2/taxonomy"
MAX_REQUESTS_PER_SECOND = 8

S3_PREFIX = "walmart/"

# Keywords used only to surface likely Food/Grocery matches for you to
# review after the pull — not used to filter what's saved.
GROCERY_KEYWORDS = [
    "food", "grocery", "grocer", "beverage", "snack", "dairy", "produce",
    "meat", "seafood", "bakery", "pantry", "candy", "condiment",
]


def flatten_categories(categories: list[dict], rows: list[dict] | None = None) -> list[dict]:
    if rows is None:
        rows = []

    for category in categories:
        category_id = category.get("id")
        depth = category_id.count("_") + 1 if category_id else None
        parent_id = "_".join(category_id.split("_")[:-1]) if category_id and "_" in category_id else None

        rows.append({
            "id": category_id,
            "name": category.get("name"),
            "path": category.get("path"),
            "depth": depth,
            "parent_id": parent_id,
        })

        children = category.get("children") or []
        if children:
            flatten_categories(children, rows)

    return rows


def fetch_taxonomy(auth: WalmartAuth) -> dict:
    rate_limiter = RateLimiter(MAX_REQUESTS_PER_SECOND)
    url = f"{API_HOST}{TAXONOMY_PATH}"
    return fetch_page(auth, rate_limiter, url)


def main() -> pd.DataFrame:
    consumer_id = os.environ["WALMART_CONSUMER_ID"]
    key_path = PROJECT_ROOT / os.environ["WALMART_KEY_PATH"]

    auth = WalmartAuth(consumer_id, key_path)
    payload = fetch_taxonomy(auth)
    categories = payload.get("categories") or []

    rows = flatten_categories(categories)
    df = pd.DataFrame(rows)
    logger.info("Fetched %s total categories/sub-categories", len(df))

    if not df.empty:
        keyword_pattern = "|".join(GROCERY_KEYWORDS)
        matches = df[df["name"].str.lower().str.contains(keyword_pattern, na=False)]
        logger.info("%s categories match grocery/food keywords:", len(matches))
        for _, row in matches.iterrows():
            logger.info("  id=%s name=%r path=%r depth=%s", row["id"], row["name"], row["path"], row["depth"])

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    key = f"{S3_PREFIX}walmart_taxonomy_{timestamp}.csv"
    upload_df_to_s3(df, S3_BUCKET, key)

    return df


if __name__ == "__main__":
    main()
