#!/usr/bin/env python3
"""Ingest Publix product pricing by running an Apify scraper actor and
writing normalized records to a local raw CSV (staged for later load into
Snowflake alongside Kroger/Walmart data).

Publix has no public pricing API, so this goes through a paid third-party
scraper on Apify (e.g. rigelbytes/publix-scraper). The actor's exact input
and output field names can change — verify them against the actor's page
under your Apify account, and adjust FIELD_ALIASES/run_input below if
needed. This script is defensive about unknown field names so a mismatch
degrades to nulls rather than a crash.

Usage:
    python scripts/ingest_publix_prices.py --zip-code 33301 --max-items 500
    python scripts/ingest_publix_prices.py --store-id 1234 --search "milk" --search "eggs"
"""

import argparse
import csv
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests
from dotenv import load_dotenv

load_dotenv()

APIFY_API_TOKEN = os.environ.get("APIFY_API_TOKEN")
APIFY_ACTOR_ID_DEFAULT = os.environ.get("APIFY_PUBLIX_ACTOR_ID", "rigelbytes~publix-scraper")
APIFY_RUN_URL_TEMPLATE = "https://api.apify.com/v2/acts/{actor_id}/run-sync-get-dataset-items"

RAW_DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "raw" / "publix"

# Common field names seen across grocery scraper actors. First match wins.
FIELD_ALIASES = {
    "product_id": ["productId", "sku", "id", "itemId"],
    "upc": ["upc", "gtin", "barcode"],
    "name": ["name", "title", "productName"],
    "brand": ["brand", "brandName"],
    "regular_price": ["regularPrice", "listPrice", "price", "originalPrice"],
    "promo_price": ["promoPrice", "salePrice", "discountedPrice", "specialPrice"],
    "unit_price": ["unitPrice", "pricePerUnit"],
    "in_stock": ["inStock", "available", "stock"],
    "store_id": ["storeId", "store"],
    "category": ["category", "department"],
    "url": ["url", "productUrl"],
}

OUTPUT_COLUMNS = list(FIELD_ALIASES.keys()) + ["source", "collected_at", "raw"]


def _first_present(record: dict, keys: list) -> object:
    for key in keys:
        if key in record and record[key] not in (None, ""):
            return record[key]
    return None


def normalize_record(raw: dict, source: str, collected_at: str) -> dict:
    normalized = {field: _first_present(raw, aliases) for field, aliases in FIELD_ALIASES.items()}
    normalized["source"] = source
    normalized["collected_at"] = collected_at
    normalized["raw"] = json.dumps(raw, default=str)
    return normalized


def run_actor(actor_id: str, run_input: dict) -> list:
    if not APIFY_API_TOKEN:
        raise RuntimeError("APIFY_API_TOKEN is not set. Copy .env.example to .env and fill it in.")
    url = APIFY_RUN_URL_TEMPLATE.format(actor_id=actor_id)
    response = requests.post(url, params={"token": APIFY_API_TOKEN}, json=run_input, timeout=300)
    response.raise_for_status()
    return response.json()


def write_csv(records: list, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()
        writer.writerows(records)


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingest Publix pricing data via an Apify scraper actor.")
    parser.add_argument("--store-id", help="Publix store number to scrape (actor-specific field).")
    parser.add_argument("--zip-code", help="Zip code to scope results to a local store.")
    parser.add_argument("--search", action="append", default=None, help="Search term/category to scrape. Repeatable.")
    parser.add_argument("--max-items", type=int, default=500, help="Max products to pull in this run.")
    parser.add_argument("--actor-id", default=APIFY_ACTOR_ID_DEFAULT, help="Apify actor ID (owner~name).")
    args = parser.parse_args()

    run_input = {"maxItems": args.max_items}
    if args.store_id:
        run_input["storeId"] = args.store_id
    if args.zip_code:
        run_input["zipCode"] = args.zip_code
    if args.search:
        run_input["searchTerms"] = args.search

    print(f"Running Apify actor '{args.actor_id}' with input: {run_input}")
    try:
        items = run_actor(args.actor_id, run_input)
    except requests.HTTPError as exc:
        print(f"Apify run failed: {exc}", file=sys.stderr)
        sys.exit(1)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

    if not items:
        print("No items returned. Verify run_input matches the actor's actual input schema on Apify.")
        sys.exit(0)

    collected_at = datetime.now(timezone.utc).isoformat()
    records = [normalize_record(item, source="publix_apify", collected_at=collected_at) for item in items]

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    out_path = RAW_DATA_DIR / f"publix_prices_{timestamp}.csv"
    write_csv(records, out_path)

    print(f"Wrote {len(records)} Publix product records to {out_path}")


if __name__ == "__main__":
    main()
