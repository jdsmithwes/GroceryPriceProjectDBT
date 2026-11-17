"""
log_merged_prs.py — record merged GitHub pull requests in GROCERY_OPS.OPS_CHANGELOG
so the Sunday weekly report can say what was implemented.

    python3 Agent/ops/log_merged_prs.py              # last 14 days, prod schema
    python3 Agent/ops/log_merged_prs.py --days 90    # backfill
    python3 Agent/ops/log_merged_prs.py --schema GROCERY_DEV_OPS --dry-run

Uses the `gh` CLI (already authenticated) and the owner's `snow` default
connection. Idempotent: SP_LOG_CHANGE merges on (source='github_pr', ref=PR#).
Run it after merging to main (the deploy session usually does).
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone

import snowflake.connector

AREA_RULES = [  # first match wins; keyword -> area
    ("guest", "guest"), ("login", "guest"), ("reminder", "guest"),
    ("deals", "product"), ("streamlit", "product"), ("app:", "product"), ("agent:", "product"),
    ("improvement", "improvement"), ("cost", "cost"), ("budget", "cost"),
    ("ops", "ops"), ("sensor", "ops"), ("alert", "ops"), ("control plane", "ops"), ("watcher", "ops"), ("supervisor", "ops"),
    ("ingest", "ingestion"), ("schedule", "ingestion"), ("pipe", "ingestion"),
    ("dbt", "quality"), ("model", "quality"), ("test", "quality"), ("freshness", "quality"),
    ("doc", "docs"), ("readme", "docs"), ("hygiene", "docs"),
]


def area_for(title: str) -> str:
    t = title.lower()
    for kw, area in AREA_RULES:
        if kw in t:
            return area
    return "ops"


def lit(s) -> str:
    return "NULL" if s is None else "'" + str(s).replace("'", "''") + "'"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--schema", default="GROCERY_OPS")
    ap.add_argument("--repo", default="jdsmithwes/GroceryPriceProjectDBT")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--connection", default=None)
    args = ap.parse_args()

    out = subprocess.run(["gh", "pr", "list", "--repo", args.repo, "--state", "merged", "--limit", "100",
                          "--json", "number,title,body,mergedAt,url"], capture_output=True, text=True, check=True).stdout
    since = datetime.now(timezone.utc) - timedelta(days=args.days)
    prs = [p for p in json.loads(out) if p.get("mergedAt") and datetime.fromisoformat(p["mergedAt"].replace("Z", "+00:00")) >= since]
    prs.sort(key=lambda p: p["mergedAt"])
    print(f"{len(prs)} merged PR(s) in the last {args.days} days")
    for p in prs:
        print(f"  #{p['number']:<3} {p['mergedAt'][:10]}  [{area_for(p['title']):<11}] {p['title'][:90]}")
    if args.dry_run or not prs:
        return 0

    conn = snowflake.connector.connect(**({"connection_name": args.connection} if args.connection else {}))
    cur = conn.cursor()
    for p in prs:
        detail = (p.get("body") or "").replace("🤖 Generated with [Claude Code](https://claude.com/claude-code)", "").strip()[:3000]
        cur.execute(f"CALL GROCERYDBTPROJECT.{args.schema}.SP_LOG_CHANGE({lit(area_for(p['title']))}, {lit(p['title'][:300])}, {lit(detail)}, 'github_pr', {lit(str(p['number']))}, {lit(p['mergedAt'])}::TIMESTAMP_TZ)")
    conn.close()
    print(f"recorded {len(prs)} change(s) in GROCERYDBTPROJECT.{args.schema}.OPS_CHANGELOG")
    return 0


if __name__ == "__main__":
    sys.exit(main())
