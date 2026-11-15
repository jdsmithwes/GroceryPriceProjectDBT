"""
Add seasonal products (Thanksgiving turkeys, holiday hams, ...) to the set of
Kroger products the weekly pricing sweep prices.

Why this exists: Kroger_Pricing_*.py prices only the products in the latest
top-level kroger_product_catalog_*.csv (last crawled 2026-08-14) plus the
kroger/upc_match/ files. Products that only appear seasonally were never in
that crawl, so they were never priced — in mid-November 2026 the data held
1 whole turkey at Kroger. This script searches Kroger for a season's terms
and writes the matches, in the catalog script's CSV shape, to

    s3://grocerydbtprojectrawdata/kroger/seasonal/kroger_product_catalog_seasonal_<season>_<ts>.csv

Two things then happen on their own:
  - the catalog Snowpipe (PATTERN '.*kroger_product_catalog_.*[.]csv') loads
    them into GROCERY_RAW_KROGER.KROGER_PRODUCT_CATALOG, and
  - Kroger_Pricing_*.py prices every product in kroger/seasonal/ files written
    in the last SEASONAL_MAX_AGE_DAYS (60), so seasonal items stop being
    priced after the holiday without anyone removing them.

Never write these files to top-level kroger/: the pricing script treats the
latest top-level kroger_product_catalog_* file as its whole product list, so a
small seasonal file there would shrink the weekly sweep to just these items.

Runs automatically every Friday inside the weekly pipeline (friday_full,
Orchestration/entrypoint.sh) with --season auto, which picks the season from
the date (season_for_date below) and exits quietly outside every window. To
run by hand from the repo root:

    python3 "API Scripts/Kroger Scripts/Product Catalogs/kroger_seasonal_watchlist.py" --season thanksgiving
    python3 ... --season auto --dry-run     # search + log, no upload

Cost: one Kroger API call per term per page (PAGES_PER_TERM pages of 50) —
about 50 calls for Thanksgiving, against the 10,000/day budget. Pricing the
matches adds roughly (products / 50) calls per store to each weekly sweep.

Reuses entire_productcatalog_kroger.py's auth, page fetch, and row flattening
so the CSV shape is identical. It deliberately does NOT reuse collect_catalog():
that function checkpoints to the full crawl's resume file, which this script
must never overwrite.
"""

import argparse
import io
import logging
from datetime import date, datetime, timedelta, timezone

import boto3
import pandas as pd
from dateutil.easter import easter

from entire_productcatalog_kroger import (
    MAX_REQUESTS_PER_SECOND,
    S3_BUCKET,
    KrogerAuth,
    RateLimiter,
    build_session,
    fetch_products_page,
    flatten_product,
)
import os

logger = logging.getLogger(__name__)

S3_SEASONAL_PREFIX = "kroger/seasonal/"
PAGES_PER_TERM = 2  # 100 results per term: specific terms put the relevant items first
PAGE_LIMIT = 50

# Specific phrases, not single words: "turkey" alone returns deli meat and cat
# food ahead of whole birds. Edit freely; add a season by adding a key.
SEASONAL_TERMS = {
    "thanksgiving": [
        "whole turkey", "frozen whole turkey", "fresh whole turkey", "turkey breast",
        "bone in turkey breast", "turkey legs", "turkey wings", "turkey roast",
        "spiral ham", "bone in ham", "honey ham", "cranberry sauce", "stuffing mix",
        "turkey gravy", "gravy mix", "pumpkin pie filling", "canned pumpkin",
        "pie crust", "frozen pie crust", "sweet potatoes", "canned yams",
        "dinner rolls", "french fried onions", "cream of mushroom soup",
        "evaporated milk", "heavy whipping cream", "whipped topping", "pecan halves",
        "marshmallows", "fresh cranberries",
    ],
    "christmas": [
        "spiral ham", "bone in ham", "prime rib", "beef tenderloin", "standing rib roast",
        "whole turkey", "eggnog", "candy canes", "gingerbread", "sugar cookie dough",
        "baking chocolate chips", "pie crust", "dinner rolls", "cranberry sauce",
    ],
    "easter": [
        "spiral ham", "bone in ham", "lamb leg", "easter candy", "jelly beans",
        "chocolate eggs", "deviled egg", "dinner rolls", "hot cross buns",
    ],
    "july4": [
        "hot dogs", "hamburger patties", "hamburger buns", "hot dog buns", "bratwurst",
        "corn on the cob", "watermelon", "potato salad", "coleslaw", "baked beans",
        "charcoal", "paper plates",
    ],
}


def thanksgiving_day(year: int) -> date:
    """Fourth Thursday of November."""
    first = date(year, 11, 1)
    first_thursday = first + timedelta(days=(3 - first.weekday()) % 7)
    return first_thursday + timedelta(weeks=3)


def season_for_date(today: date) -> str | None:
    """The season whose shopping window contains today, else None. Windows
    open a few weeks ahead so the weekly sweep has prices before the holiday:
    Thanksgiving Oct 20 -> Thanksgiving day; Christmas the day after ->
    Dec 24; Easter five weeks before -> Easter Sunday; July 4th Jun 13 -> Jul 4."""
    year = today.year
    thanksgiving = thanksgiving_day(year)
    if date(year, 10, 20) <= today <= thanksgiving:
        return "thanksgiving"
    if thanksgiving < today <= date(year, 12, 24):
        return "christmas"
    easter_day = easter(year)
    if easter_day - timedelta(days=35) <= today <= easter_day:
        return "easter"
    if date(year, 6, 13) <= today <= date(year, 7, 4):
        return "july4"
    return None


def search_terms(terms: list[str]) -> tuple[pd.DataFrame, int]:
    session = build_session()
    auth = KrogerAuth(os.environ["KROGER_CLIENT_ID"], os.environ["KROGER_CLIENT_SECRET"], session)
    rate_limiter = RateLimiter(MAX_REQUESTS_PER_SECOND)

    rows: dict[str, dict] = {}  # keyed by productId to de-dupe across terms
    calls = 0
    for term in terms:
        for page in range(PAGES_PER_TERM):
            products = fetch_products_page(session, auth, rate_limiter, term, page * PAGE_LIMIT)
            calls += 1
            new = 0
            for product in products:
                try:
                    row = flatten_product(product)
                except Exception:
                    logger.exception("Failed to parse product, skipping: %r", product)
                    continue
                if row["productId"] and row["productId"] not in rows:
                    rows[row["productId"]] = row
                    new += 1
            logger.info("term=%r page=%s: %s results, %s new", term, page, len(products), new)
            if len(products) < PAGE_LIMIT:
                break

    return pd.DataFrame(rows.values()), calls


def main(season: str, dry_run: bool) -> None:
    if season == "auto":
        season = season_for_date(datetime.now(timezone.utc).date())
        if season is None:
            logger.info("No seasonal shopping window open today; nothing to do")
            return
        logger.info("Auto-selected season: %s", season)
    terms = SEASONAL_TERMS[season]
    df, calls = search_terms(terms)
    logger.info("season=%s: %s terms, %s API calls, %s unique products", season, len(terms), calls, len(df))

    if df.empty:
        logger.warning("No products found; nothing to upload")
        return
    if dry_run:
        logger.info("Dry run — not uploading. Sample:\n%s", df[["productId", "description", "size"]].head(15).to_string())
        return

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    key = f"{S3_SEASONAL_PREFIX}kroger_product_catalog_seasonal_{season}_{timestamp}.csv"
    buffer = io.StringIO()
    df.to_csv(buffer, index=False)
    boto3.client("s3").put_object(Bucket=S3_BUCKET, Key=key, Body=buffer.getvalue())
    logger.info("Uploaded %s rows to s3://%s/%s", len(df), S3_BUCKET, key)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--season", required=True, choices=["auto", *sorted(SEASONAL_TERMS)],
                        help="a season, or 'auto' to pick from today's date")
    parser.add_argument("--dry-run", action="store_true", help="search and log, don't upload")
    args = parser.parse_args()
    main(args.season, args.dry_run)
