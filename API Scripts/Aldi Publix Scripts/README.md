# grocery_ingest

Store-scoped grocery price ingestion. Currently: **ALDI** (verified) and
**Publix** (needs endpoint confirmation).

## Layout

| File | Role |
|---|---|
| `ingest.py` | Transport + models + orchestration. `PoliteClient`, `TokenBucket`, `PriceObservation`, `NDJSONSink`. No retailer logic. |
| `adapters.py` | Retailer implementations, the `probe`/`calibrate` CLIs, and `PUBLIX_CONFIG`. |
| `DECISIONS.md` | Why the code looks the way it does. Read before changing anything that seems overcomplicated. |

## Setup

Requires **Python 3.10+**.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Run order

**1. Probe first — do not skip this for Publix.**

```bash
python adapters.py probe aldi   --zip 30080
python adapters.py probe publix --zip 30080 --term milk
```

Writes raw payloads to `data/probe/` and prints a flattened key inventory.
Diff that inventory against the `fields` maps in `PUBLIX_CONFIG` and correct
any path that doesn't match. Every value in `PUBLIX_CONFIG` is a hypothesis.

**2. Then ingest.**

```bash
python ingest.py --retailers aldi --zips 30080
python ingest.py --retailers publix --zips 30080 \
  --categories milk eggs bread "chicken breast" bananas
```

Output lands as NDJSON at `data/raw/dt=YYYY-MM-DD/retailer=X/surface=Y/store_Z.ndjson`
— one JSON object per line, ready for a Snowflake VARIANT stage load.

Each store's file is also uploaded to `s3://grocerydbtprojectrawdata/<retailer>/dt=.../surface=.../store_Z.ndjson`
as soon as that store finishes (not batched to the end of the run — see D11),
matching this project's S3-as-source-of-truth convention for Kroger/Walmart.
Pass `--no-s3-upload` to `ingest.py` to keep a run fully local (e.g. while
still probing/calibrating and not yet ready to land anything durably).

## What's settled

- **ALDI store id is `merchantReference`** (format `NNN-NNN`, e.g. `479-022`).
  Different value → different prices. Verified endpoint shape against
  github.com/stiles/aldi (MIT).
- **ALDI full sweep beats keyword search.** ~7,800 SKUs / 48 per page = 163
  requests, ~6 min at 0.5 req/s. Gives assortment + delisting signal free.
- **Prices are integer cents** in `prices[0].grossAmount`. `formattedPrice`
  is the fallback only — string parsing breaks on `"2/$5.00"` and `"$1.29/lb"`.
- **Grain is `(retailer, store_id, sku, day)`**, hashed into
  `observation_key` for idempotent re-runs.

## Open questions

1. **ALDI store discovery is unverified.** `STORE_URL` is a guess; the adapter
   falls back to a hardcoded service point so the pipeline still runs. Probe
   the store selector on new.aldi.us to find the real path.
2. **All of Publix is unverified.** See run order step 1.
3. **Publix + Instacart — now handled, still needs your confirmation.**
   See "Price surfaces" below. The adapter detects and quarantines marketplace
   pricing, but you still need to confirm the right `serviceType` value via
   the probe.
4. **No UPC from ALDI.** ~90% private label, so there's often no UPC to match
   on at all. Cross-retailer joins need fuzzy name+size matching — this is the
   real work of the dbt layer, not an afterthought.

## Price surfaces

The same SKU at the same store on the same day has **different prices on
different fulfillment surfaces**. Publix delivery/curbside is Instacart-powered
and marked up per item; in-store/pickup is shelf price. Both return well-formed
JSON, so mixing them does not look like an error — it looks like Publix got
expensive.

**We label prices. We never adjust them.** Instacart's margin varies by item
and by retailer agreement, so any correction factor is wrong in a way that is
invisible in the output.

How it works:

- `PriceSurface` is part of the record **and part of `observation_key`**.
  Without that, shelf and marked-up prices for one SKU collide on the same key
  and whichever lands second silently wins.
- `serviceType` is pinned in the request, then `SurfaceDetector` verifies the
  response — the request is asked, not trusted.
- Mismatches are **quarantined, not dropped**: they land under
  `surface=thirdparty` / `surface=unknown` with `is_comparable=false`, and
  detection evidence in `raw._surface_evidence`. In strict mode (default) they
  are not emitted at all.
- ALDI declares `PriceSurface.PICKUP` explicitly so it can never be silently
  compared against a marked-up Publix row.

Measure the real gap before you trust either feed:

```bash
python adapters.py calibrate --zip 30080 --service-types instore delivery
```

Read the **spread**, not the average. Wide spread = per-item markup = no
correction is valid, surface separation is the only sound approach. Expect
that outcome.

**Downstream invariant:** every basket-comparison model must filter
`is_comparable = true`. Enforce it as a dbt test, not a convention.

## Conduct

`PoliteClient` checks robots.txt, honors `Crawl-delay`, rate limits per host,
and treats **403 as final** — it aborts that retailer rather than retrying.
That behavior is deliberate; don't soften it. If a site refuses, find an
official feed or drop the source. Check each retailer's ToS before running
this on a schedule.

## Picking up from here

Nothing has been run against live endpoints yet — everything below is verified
only against mocked payloads and one open-source reference. In order:

1. **Probe ALDI.** Only store discovery is unverified; the catalog path is
   known good. Find the real service-point lookup, then drop the `479-022`
   fallback in `AldiAdapter.discover_stores`.
2. **Probe Publix.** Fix every path in `PUBLIX_CONFIG` against the real
   payload. Assume all of it is wrong until proven otherwise.
3. **Calibrate surfaces.** Confirm which `serviceType` returns shelf pricing,
   and measure the delivery-vs-instore spread. This gates whether any Publix
   number is trustworthy.
4. **First real run.** ALDI full sweep (~6 min) + a five-item Publix basket.
   Check the `surface=` partitions before believing anything.
5. **Then the dbt layer** — unit parsing (`"8.25 oz"` → value + uom), fuzzy
   ALDI↔Publix matching (no shared UPC, see D5/open threads), and a
   comparable-basket model gated on `is_comparable = true`.

Design rationale for all of the above is in `DECISIONS.md`, keyed D1–D10.
