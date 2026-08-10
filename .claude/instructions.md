# GroceryPriceProject (SalePredictor) — Context

**Owner**: Jamaal Smith (jdsmith1906@gmail.com), SmoothData · **Last Updated**: 2026-08-10

**Goal**: collect grocery pricing/inventory/location data from Kroger and Walmart, land it in Snowflake via event-driven Snowpipe, transform with dbt, forecast sale timing. Full architecture + diagram: **`Project Architecture.md`** (repo root) — read that first for the big picture; this file is operational detail and hard-won gotchas.

**Status**: Phase 1 done. Phase 2/3 (Snowflake + Kroger ingestion) working end-to-end. Walmart blocked (portal bug, see below). dbt not started.

---

## Engineering Guidelines

**Cost-effectiveness**: any script driving compute (API polling, concurrent pulls, warehouses/pipes, scheduled jobs) should minimize resource usage — avoid redundant API calls across scripts pulling overlapping data, right-size warehouse compute (auto-suspend, smallest size), batch/dedupe over brute-force re-pulls.

**Raw-landing convention**: ingestion scripts do NOT transform/flatten/join API data. Pull out only join/partition keys as real columns (`productId`, `locationId`, `collected_at`); everything else is preserved as untouched JSON text in `raw_data`. All parsing/joining/business logic belongs in dbt, not Python or the landing tables.

**Where the detail lives**: each script's docstring has live-tested endpoint/field/gotcha specifics — check the source before re-deriving anything:
- `API Scripts/Product Catalogs/entire_productcatalog_kroger.py`, `entire_productcatalog_walmart.py`, `walmart_taxonomy.py`
- `API Scripts/Product Location/`, `Product Pricing/`, `Product Inventory/` — one Kroger script each
- `snowflake scripts/Kroger Raw Data/*.sql` — one pipeline file per source, naming convention `%source%_ingestion_pipeline.sql`

---

## Credentials & Blockers

**Kroger** — fully working, live-tested throughout. OAuth2 client credentials in `.env` (`KROGER_CLIENT_ID`/`SECRET`), scope `product.compact`. 10,000 calls/day (pipelines built so far use a few hundred each). No bulk catalog endpoint — scripts crawl by search term or batch by known `productId` (max 50/call, server-enforced). Gotcha: `productId`/`upc` have meaningful leading zeros — always `pd.read_csv(..., dtype=str)`.

**Walmart** — BLOCKED. App only has a Stage Consumer ID; no Prod Consumer ID. The portal's "Upload Public Key" dialog (Environment Type = Production) spins and silently closes with no error, reproduced identically in Safari and Chrome — likely needs Walmart dev support. Private key lives outside the repo at `/Users/jamaalsmith/credentials/walmart/WM_IO_private_key.pem` (`.env`'s `WALMART_KEY_PATH` points there); confirmed it pairs with `WM_IO_public_key.pem`. Signing algorithm/endpoint/pagination all self-verified and ready — only Prod access is missing.

**AWS** — bucket `grocerydbtprojectrawdata`, account `573509103721`, region `us-east-1`. IAM user `jdsmithwes` can fully manage S3 (uploads, bucket notifications) but **cannot touch IAM** (`AccessDenied` on create/update policy/role, even read calls like `ListAttachedUserPolicies`) — any IAM change needs the AWS root/admin console, not CLI.

**Snowflake** — account `TPRFGUJ-JNC76647`, database `GROCERYDBTPROJECT`, warehouse `COMPUTE_WH` (XSMALL, auto-suspend 60s), schemas `RAW` (tables) / `AWS_RESOURCES` (stages/pipes/integration by convention). **CLI now works** (fixed 2026-08-10): `~/.snowflake/connections.toml` `[default]` uses key-pair auth (`~/.ssh/snowflake_rsa_key.p8`) pointed at this project's db/warehouse/role; the matching public key is registered on `jdsmithwes` via `ALTER USER ... SET RSA_PUBLIC_KEY`. Use `snow sql -q "..."` directly instead of asking the user to paste query results back.

---

## Snowflake gotchas (all confirmed against the real account — don't re-derive)

- **Storage integrations are account-level** — `CREATE STORAGE INTEGRATION` names must be unqualified, unlike stages/tables/pipes.
- **Never `CREATE OR REPLACE STORAGE INTEGRATION`** once working — generates a new `STORAGE_AWS_EXTERNAL_ID` and desyncs the AWS IAM role's trust policy. Use `IF NOT EXISTS`.
- **`MATCH_BY_COLUMN_NAME` + extra table columns** (e.g. `INGESTED_FILENAME`) needs `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` on the file format, or `COPY INTO` fails on raw column count despite name-based matching.
- **`INCLUDE_METADATA = (col = METADATA$FILENAME)`** is required to combine file-metadata columns with `MATCH_BY_COLUMN_NAME`.
- **`CREATE OR REPLACE TABLE` drops manually-`ALTER`-added columns.** Re-run the `ALTER TABLE ADD COLUMN` immediately after, every time.
- **A pipe's "already loaded" tracking survives table recreation** — use `COPY INTO ... FORCE = TRUE` to force a reload.
- **`FIELD_OPTIONALLY_ENCLOSED_BY = '"'`** required on file formats reading pandas CSVs, or quoted commas get split.
- **One SQS queue per *stage*, not per pipe** — confirmed live: all four Kroger pipes (different tables, same `MY_S3_STAGE_KROGER`) share one `notification_channel`. Only one S3 Event Notification registration needed for all of them; each pipe's own `PATTERN` decides what it loads. (Walmart pipe reads a different stage — likely gets its own queue, unconfirmed, still blocked.)
- **Every pipe reading a shared stage needs its own `PATTERN`** or it'll try to load every file type sharing that prefix.

---

## Security

`.env` and `credentials/` are gitignored (verify `.gitignore` still has them — it didn't exist at all until 2026-08-10, despite earlier docs claiming otherwise). Never commit `.env`, never hardcode credentials, never share private keys/passwords in messages.

---

## Phase Status

- **Phase 1** (API setup): ✅ done.
- **Phase 2** (Snowflake): 🟡 warehouse/tables/stages done; retention policy not defined.
- **Phase 3** (Ingestion): 🟡 Kroger catalog/locations/pricing/inventory all working + auto-ingesting; Walmart blocked; no scheduler yet (manual runs only); no data quality checks yet.
- **Phase 4** (dbt): 🔮 not started.
- **Phase 5** (Forecasting): 🔮 not started — depends on accumulating enough `KROGER_PRICING` history via a real schedule, not ad hoc runs.
