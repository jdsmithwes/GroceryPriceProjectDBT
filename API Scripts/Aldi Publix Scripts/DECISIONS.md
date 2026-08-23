# Design decisions

Why the code looks the way it does. Read this before changing something that
seems overcomplicated — most of it is defending against a specific failure that
is invisible in the output.

Status key: **settled** (don't relitigate without new evidence) ·
**provisional** (needs live verification) · **deferred** (deliberately not done)

---

## D1 — Grain is `(retailer, store_id, sku, price_surface, day)`

**Status:** settled

**Context.** The obvious grain is `(retailer, sku, day)`. It's wrong twice.
Prices are store-scoped, so a record without `store_id` can't be compared to
anything. And the same SKU at the same store on the same day genuinely has
different prices on different fulfillment surfaces.

**Decision.** Both `store_id` and `price_surface` are in the grain, and both
are hashed into `observation_key`.

**Consequence.** Store resolution has to happen before product fetching — it's
step one of every adapter, not a lookup bolted on later.

**This was a real bug.** The first version omitted `price_surface` from the
key. Shelf price and Instacart-marked-up price for one SKU hashed identically,
so on any run touching both, whichever landed second silently overwrote the
other. Nothing errored. The data was just quietly wrong.

---

## D2 — Land raw NDJSON, normalize in dbt

**Status:** settled

**Decision.** Adapters emit a thin normalized record *plus* the untouched
source payload in `raw`. Output is newline-delimited JSON partitioned
`dt=/retailer=/surface=`.

**Why.** You cannot re-scrape yesterday. Any field you discard at ingest time
is gone permanently, whereas anything you keep can be reinterpreted later. NDJSON
maps directly onto a Snowflake VARIANT stage load, and a partial file from a
crashed run is still parseable up to the last newline.

**Consequence.** Unit parsing, fuzzy product matching, and basket construction
all belong downstream where they're testable and re-runnable — not in the
scraper.

---

## D3 — Politeness lives in the transport layer, and 403 is terminal

**Status:** settled

**Decision.** `PoliteClient` checks robots.txt, honors `Crawl-delay`, rate
limits per host via token bucket, retries 5xx with backoff and jitter, respects
`Retry-After` on 429 — and raises `BlockedError` on 403/401, which aborts that
retailer for the run.

**Why terminal.** A 403 is the site saying no. Retrying past it, rotating
identity, or otherwise working around it turns a personal price-comparison
project into a ToS problem and gets the IP burned. If a source refuses, find an
official feed or drop the source.

**Do not soften this.** It's a deliberate constraint, not a rough edge.

---

## D4 — ALDI hardcoded, Publix config-driven

**Status:** ALDI **revoked as of 2026-08-23 — see D12** · Publix provisional

**Context.** I know very different amounts about the two.

ALDI's shape is **verified** against a working open-source collector
(`github.com/stiles/aldi`, MIT). Publix's is **unverified** — no working
reference exists publicly.

**Decision.** ALDI's paths and field names are hardcoded because they're known
good. Publix's live in `PUBLIX_CONFIG` with fallback candidate lists per field,
resolved through `pathget`/`first_present`.

**Why.** Guessing field names in code and letting you discover the guesses were
wrong at 2am is the worse option. When Publix moves a field, you edit a dict.

**Every value in `PUBLIX_CONFIG` is a hypothesis** until the probe confirms it.

---

## D5 — Label the price surface; never correct the markup

**Status:** settled

**Context.** Publix delivery/curbside is Instacart-powered and marked up over
shelf price. Both surfaces return well-formed JSON with plausible numbers, so a
mix-up doesn't look like an error — it looks like Publix got expensive. Against
ALDI (read at pickup pricing) that shows up as a real-looking competitive gap
that's pure artifact.

**Decision.** Four layers, in order:

1. Pin `serviceType` in the request — ask for one surface.
2. `SurfaceDetector` verifies the *response*. The request is asked, not trusted.
3. Mismatches are **quarantined, not dropped** — they land under
   `surface=thirdparty` / `surface=unknown` with `is_comparable=false` and
   detection evidence in `raw._surface_evidence`. Strict mode (default) doesn't
   emit them at all.
4. Prices are never adjusted.

**Why no markup estimator.** Instacart's margin varies by item and by retailer
agreement. Any correction factor is wrong in a way that's invisible in the
output — the numbers still look like money. Labeling is falsifiable;
correcting is not.

**Verify rather than trust this reasoning:** `python adapters.py calibrate`
runs one basket through both surfaces and reports the *spread* of per-item
ratios. Wide spread ⇒ per-item markup ⇒ no correction is valid. Expect that.

**Downstream invariant:** every basket model filters `is_comparable = true`.
Make it a dbt test — a filter someone forgets to apply is the same bug in a
different hat.

---

## D6 — ALDI: full catalog sweep, not keyword search

**Status:** settled

**Numbers.** ~7,800 SKUs ÷ 48 per page = 163 requests ≈ 6 min at 0.5 req/s.
(Confirmed: `maxPage` came back as exactly 163.)

**Decision.** Sweep everything; ignore the `categories` argument. Category
comes back on each row (`categoryName` / `mainCategoryName`), so filter in dbt.

**Why.** Cheaper than N keyword queries *and* it gives assortment and delisting
signal for free — you learn what stopped being carried, which keyword search
can never tell you.

**Publix is the opposite** — no cheap full sweep, so it's driven by a keyword
basket. Keep that basket small and stable or week-over-week comparisons stop
being apples-to-apples.

---

## D7 — Parse integer cents, not formatted strings

**Status:** settled

**Decision.** Prefer `prices[0].grossAmount` (integer cents, Spryker
convention) over `formattedPrice`.

**Why.** `"$2.75"` parses fine right up until you meet `"2/$5.00"` or
`"$1.29/lb"`. The string fallback stays for older payloads, but the integer
path is primary.

---

## D8 — Hydrate only unseen SKUs

**Status:** settled

**Context.** ALDI's detail endpoint is one request per SKU: ~7,800 requests
≈ 4.5 hours at polite rates. Running that daily is absurd.

**Decision.** `SkuCache` tracks hydrated SKUs; only new ones get detail calls.

**Why it's safe.** Descriptive fields (description, origin, warnings, image)
are near-static. Only price moves — and price is already in the catalog
response. Day two drops to ~2 minutes.

---

## D9 — Guard against page-1 re-serving

**Status:** settled

**Context.** Many retail search APIs ignore an out-of-range page parameter and
re-serve page 1 rather than returning empty.

**Decision.** Track the SKU set per page; stop when a page repeats the previous
one.

**Why.** Without it the loop never terminates and writes duplicates forever.
Cheap insurance against a failure that looks like a hang.

---

## D10 — Deferred retailers

**Status:** deferred

| Retailer | Reason |
|---|---|
| Lidl | Circular-only. No browsable priced catalog; ~200 promo rows/week, not shelf prices. |
| Ingles | Circular-only. Online shopping is outsourced; the durable public artifact is the weekly digital circular. |
| Piggly Wiggly | Franchise co-op, not a chain. Owners run different platforms (Freshop, Rosie, ECRS, plain WordPress) with different prices, SKUs, and URL schemes. Model as N sub-adapters keyed by detected platform — a structurally different problem. |

**Consequence for the model.** When Lidl/Ingles land, missing SKUs mean
"not in this week's circular," **not** "delisted." Don't let the delisting
logic from D6 treat them the same way.

---

## D11 — Upload to S3 per store, not batched to end of run

**Status:** settled

**Context.** Integrated into the GroceryPriceProject git repo (2026-08-23),
whose Kroger scripts write straight to `s3://grocerydbtprojectrawdata/` —
"S3 is this project's source of truth" for raw pulls. NDJSONSink originally
only wrote local files.

**Decision.** `NDJSONSink.upload_new_to_s3()` uploads each store's completed
file(s) to S3 immediately after that store finishes (success, handled error,
or a `BlockedError` abort), not once at the very end of `run()`. Local layout
stays `dt=/retailer=/surface=/store_N.ndjson`; the S3 key reorders to put
retailer first (`<retailer>/dt=.../surface=.../store_N.ndjson`), matching the
`kroger/`, `walmart/` top-level prefixes already in the bucket.

**Why per-store, not batched.** This project already has a real incident to
point to: the Kroger pricing script originally deferred all persistence
(checkpoint + S3 upload) to the end of the whole run. A crash partway through
meant every already-completed store's data — and every API call spent getting
it — was lost, because nothing had actually been written anywhere durable
yet. Fixed there by persisting per-location as each one completes; same fix
applied here from the start rather than waiting to hit the same bug twice.

**Consequence.** `ingest_retailer`/`run` now thread an `uploaded: set[Path]`
through the whole run so a file already pushed to S3 is never re-uploaded on
a later store/retailer in the same process. `--no-s3-upload` on `ingest.py`
skips this entirely for local-only exploration.

---

## D12 — `api.aldi.us` does not resolve; D4's "ALDI verified" is revoked

**Status:** confirmed broken, unfixed

**Context.** First two live attempts against `AldiAdapter`
(2026-08-23, via `Orchestration/`'s Fargate pipeline — see that folder's
README) both failed identically: `httpx.ConnectError: [Errno -5] No
address associated with hostname` on `api.aldi.us`. Not a fluke, not
Fargate-specific — verified independently with `dig`/`curl` from an
unrelated network: the hostname has no DNS record at all, from anywhere,
right now. `new.aldi.us` (the real customer site, already referenced in
`EXTRA_HEADERS`) resolves fine and is Akamai-fronted.

**Decision (forced by evidence, not chosen).** D4's claim that "ALDI's
shape is verified" no longer holds. The open-source reference this was
built from (`github.com/stiles/aldi`) has almost certainly drifted since
it was written — Aldi likely migrated their API to a different host.
`CATALOG_URL`, `STORE_URL`, and `PRODUCT_URL` in `AldiAdapter` all need
the real current host substituted in before ALDI can produce a single
row. This is not a retry-and-it-works situation (confirmed via two
independent attempts) and not an infrastructure problem (confirmed via
independent DNS lookup outside the affected environment).

**Why this matters beyond just "one broken URL."** Every other ALDI
design decision in this file (D1 grain, D6 full-sweep-not-search, D7
integer-cents parsing, D8 SkuCache) is reasoning about the *shape* of
data ALDI returns — none of it can be re-verified until a reachable host
is found, because zero real ALDI data has ever actually been collected
by this codebase. Treat every "ALDI settled" status elsewhere in this
file as **provisional pending a working host**, not actually settled.

**Next step.** Find Aldi's real current API host — most direct path is
inspecting Network tab requests while browsing `new.aldi.us` in a
browser (the same technique `adapters.py probe` automates for Publix,
just manually this time since there's no known correct URL yet to probe
against). Do not guess a replacement host and hardcode it without
confirming — that's exactly the "plausible guess that silently returns
wrong data" failure mode `.claude/commands/pickup.md` explicitly warns
against.

---

## Open threads

1. **`api.aldi.us` doesn't resolve — find the real host (see D12).** This
   now blocks everything else about ALDI; nothing below it can be
   attempted meaningfully until this is fixed.
2. **ALDI store discovery is unverified**, independent of D12. `STORE_URL`
   is a guess; the adapter falls back to a hardcoded service point
   (`479-022`) so the pipeline degrades gracefully rather than hard-
   failing. Probe the store selector on new.aldi.us for the real path
   once a working API host exists to probe.
3. **All Publix endpoints unverified.** Run the probe, fix `PUBLIX_CONFIG`.
4. **Confirm the right `serviceType` value** for shelf pricing. `"instore"` is
   a guess.
5. **ALDI exposes no UPC.** ~90% private label, so there's often no UPC to
   match on at all. Cross-retailer joins need fuzzy name + size matching. This
   is the real work of the dbt layer, not an afterthought — and it's the next
   piece to build, once ALDI can actually produce data at all.
