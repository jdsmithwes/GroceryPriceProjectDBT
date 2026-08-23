# Aldi Publix Scripts (grocery_ingest)

Scoped to this folder — applies when working under `API Scripts/Aldi Publix
Scripts/`. For the rest of the GroceryPriceProject repo (Kroger/Walmart
scripts, dbt project, Snowflake conventions), see `.claude/instructions.md`
at the repo root.

Integrated from a standalone `grocery_ingest` repo (2026-08-23) — origin
history wasn't preserved, just the reviewed files. Everything below predates
that integration except where noted.

Personal grocery price-comparison pipeline. Scrapes store-scoped pricing,
lands raw NDJSON locally *and* uploads to `s3://grocerydbtprojectrawdata/`,
matching the root project's S3-as-source-of-truth convention (see D11).
Normalizes in dbt (Snowflake) — not written yet, see root project's
`DBT Transformations/grocery_price_project/`.

**Active adapters:** ALDI (endpoint shape verified), Publix (unverified).
**Deferred:** Lidl, Ingles (circular-only), Piggly Wiggly (franchise co-op).

@README.md
@DECISIONS.md

## Current state — read before proposing work

**Nothing has run against a live endpoint.** Everything is verified against
mocked payloads plus one open-source ALDI reference. Tested-and-green here does
not mean confirmed-against-production. The next real step is always: probe
first, then trust.

Blocking unknowns, in order:

1. ALDI `STORE_URL` is a guess — adapter falls back to hardcoded service point
   `479-022` so the pipeline runs end to end.
2. Every value in `PUBLIX_CONFIG` is a hypothesis.
3. The `serviceType` value that returns shelf pricing is unconfirmed
   (`"instore"` is a guess).

## Invariants — do not break these

These look like overengineering until you know what they defend against. Each
one maps to a decision record; read it before changing the behavior.

- **`price_surface` stays in `observation_key`** (D1). Removing it makes shelf
  and Instacart-marked-up prices for one SKU hash identically, and the second
  write silently wins. This was a real bug, not a hypothetical.
- **Never adjust a price to back out a markup** (D5). Instacart's margin varies
  per item; any correction factor is wrong invisibly. Label the surface,
  filter downstream. Quarantine beats correction.
- **403 aborts the retailer; do not retry or evade it** (D3). If a site
  refuses, find an official feed or drop the source.
- **`raw` payload is always preserved** (D2). You cannot re-scrape yesterday.
- **Adapters stay dumb** (D2). Unit parsing, fuzzy matching, and basket logic
  belong in dbt where they are testable.

## Conventions

- **Python 3.10+** required (`dataclass(slots=True)`). `httpx` async,
  stdlib elsewhere. No scraping frameworks.
- ALDI's paths are hardcoded because verified; Publix's live in
  `PUBLIX_CONFIG` because they are not. Do not "clean this up" into one style —
  the asymmetry is the point (D4).
- New retailer = new `RetailerAdapter` subclass in `adapters.py`, declaring
  its `tier` and its `PriceSurface`.

## Commands

Run from inside `API Scripts/Aldi Publix Scripts/`:

```bash
python adapters.py probe publix --zip 30080     # dump raw payload + key inventory
python adapters.py calibrate --zip 30080        # measure surface price spread
python ingest.py --retailers aldi --zips 30080  # full ALDI sweep, ~6 min, uploads to S3 as it goes
python ingest.py --retailers aldi --zips 30080 --no-s3-upload  # local-only, e.g. while still probing
```

## Picking up

When asked to "pick up with Publix and ALDI": read `DECISIONS.md` open threads
plus the README "Picking up from here" list, check whether anything under
`data/` shows a prior live run, and start at the first unresolved step rather
than assuming earlier ones are done.
