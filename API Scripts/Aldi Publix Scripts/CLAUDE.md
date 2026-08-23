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

**Active adapters:** ALDI (API host confirmed broken 2026-08-23, see D12 — not currently functional), Publix (unverified, never attempted live).
**Deferred:** Lidl, Ingles (circular-only), Piggly Wiggly (franchise co-op).

@README.md
@DECISIONS.md

## Current state — read before proposing work

**`api.aldi.us` — every URL in `AldiAdapter` (`CATALOG_URL`, `STORE_URL`,
`PRODUCT_URL`) — does not resolve. Confirmed 2026-08-23, root-caused, not
a network/Fargate issue.** Two live attempts against it both failed
identically with `httpx.ConnectError: [Errno -5] No address associated
with hostname`. Verified independently via `dig`/`curl` from a completely
different network (not the Fargate task) — the domain simply has no DNS
record right now, from anywhere. For comparison, `new.aldi.us` (the real
customer-facing site, already referenced in `EXTRA_HEADERS`' `origin`/
`referer`) resolves fine and is Akamai-fronted. The open-source reference
this adapter's endpoint shape was built from (`github.com/stiles/aldi`,
per `DECISIONS.md` D4) has almost certainly drifted — Aldi likely moved
their API to a different host since that reference was written. **ALDI is
not merely "unverified" anymore — it's confirmed broken as currently
coded.** Fixing it means finding the real current API host (likely by
inspecting network requests on `new.aldi.us` in a browser) and updating
`CATALOG_URL`/`STORE_URL`/`PRODUCT_URL` accordingly — not a retry, not an
infrastructure fix. **Publix** has never touched a live endpoint at all —
the "probe first, then trust" rule fully applies there, and it stays
excluded from the scheduled pipeline until it does.

Blocking unknowns, in order:

1. **`api.aldi.us` needs to be replaced with Aldi's real current API
   host** (see above) — this now blocks everything else about ALDI, not
   just store discovery.
2. ALDI `STORE_URL` is a guess on top of the above — even once the host is
   fixed, the store-selector endpoint itself is still unconfirmed; the
   hardcoded `479-022` fallback exists so the pipeline degrades gracefully
   rather than hard-failing, but it was never meant to be the permanent
   answer.
3. Every value in `PUBLIX_CONFIG` is a hypothesis.
4. The `serviceType` value that returns shelf pricing is unconfirmed
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
- ALDI's paths are hardcoded (Publix's live in `PUBLIX_CONFIG` instead) — but
  don't read "hardcoded" as "verified" anymore, see D12: the hardcoded host
  itself is confirmed wrong. Do not "clean this up" into one style once it's
  fixed — the asymmetry (hardcoded vs. config-driven) was always about how
  much confidence exists per source, not about which one currently works
  (D4).
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
