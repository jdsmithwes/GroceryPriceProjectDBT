# GroceryPriceProject (SalePredictor) — Context

**Owner**: Jamaal Smith (jdsmith1906@gmail.com), SmoothData · **Last Updated**: 2026-08-10

**Goal**: collect grocery pricing/inventory/location data from Kroger and Walmart, land it in Snowflake via event-driven Snowpipe, transform with dbt, forecast sale timing. Full architecture + diagram: **`Project Architecture.md`** (repo root) — read that first for the big picture; this file is operational detail and hard-won gotchas.

**Status**: Phase 1 done. Phase 2/3 (Snowflake + Kroger ingestion) working end-to-end. Walmart blocked (portal bug, see below). Phase 4 (dbt) well underway: full Kroger staging layer built (30 models), marts not started.

---

## Engineering Guidelines

**Cost-effectiveness**: any script driving compute (API polling, concurrent pulls, warehouses/pipes, scheduled jobs) should minimize resource usage — avoid redundant API calls across scripts pulling overlapping data, right-size warehouse compute (auto-suspend, smallest size), batch/dedupe over brute-force re-pulls.

**Raw-landing convention**: ingestion scripts do NOT transform/flatten/join API data. Pull out only join/partition keys as real columns (`productId`, `locationId`, `collected_at`); everything else is preserved as untouched JSON text in `raw_data`. All parsing/joining/business logic belongs in dbt, not Python or the landing tables.

**Where the detail lives**: each script's docstring has live-tested endpoint/field/gotcha specifics — check the source before re-deriving anything:
- `API Scripts/Product Catalogs/entire_productcatalog_kroger.py`, `entire_productcatalog_walmart.py`, `walmart_taxonomy.py`
- `API Scripts/Product Location/`, `Product Pricing/`, `Product Inventory/` — one Kroger script each
- `snowflake scripts/Kroger Raw Data/*.sql` — one pipeline file per source, naming convention `%source%_ingestion_pipeline.sql`
- `Project Architecture.md` (repo root) — "Kroger Staging Layer (dbt)" section has the full 3-layer lineage diagrams + reasoning for why arrays are separate models from objects
- `DBT Transformations/grocery_price_project/models/staging/kroger_unnnested_raw_data/_models.yml` — every column, for every Layer 1/2 model, in one place; fill in descriptions/tests here as you go

---

## Credentials & Blockers

**Kroger** — fully working, live-tested throughout. OAuth2 client credentials in `.env` (`KROGER_CLIENT_ID`/`SECRET`), scope `product.compact`. 10,000 calls/day (pipelines built so far use a few hundred each). No bulk catalog endpoint — scripts crawl by search term or batch by known `productId` (max 50/call, server-enforced). Gotcha: `productId`/`upc` have meaningful leading zeros — always `pd.read_csv(..., dtype=str)`.

**Walmart** — BLOCKED. App only has a Stage Consumer ID; no Prod Consumer ID. The portal's "Upload Public Key" dialog (Environment Type = Production) spins and silently closes with no error, reproduced identically in Safari and Chrome — likely needs Walmart dev support. Private key lives outside the repo at `/Users/jamaalsmith/credentials/walmart/WM_IO_private_key.pem` (`.env`'s `WALMART_KEY_PATH` points there); confirmed it pairs with `WM_IO_public_key.pem`. Signing algorithm/endpoint/pagination all self-verified and ready — only Prod access is missing.

**AWS** — bucket `grocerydbtprojectrawdata`, account `573509103721`, region `us-east-1`. IAM user `jdsmithwes` can fully manage S3 (uploads, bucket notifications) but **cannot touch IAM** (`AccessDenied` on create/update policy/role, even read calls like `ListAttachedUserPolicies`) — any IAM change needs the AWS root/admin console, not CLI.

**Snowflake** — account `TPRFGUJ-JNC76647`, database `GROCERYDBTPROJECT`, warehouse `COMPUTE_WH` (XSMALL, auto-suspend 60s), schemas `RAW` (tables) / `AWS_RESOURCES` (stages/pipes/integration by convention). **CLI now works** (fixed 2026-08-10): `~/.snowflake/connections.toml` `[default]` uses key-pair auth (`~/.ssh/snowflake_rsa_key.p8`) pointed at this project's db/warehouse/role; the matching public key is registered on `jdsmithwes` via `ALTER USER ... SET RSA_PUBLIC_KEY`. Use `snow sql -q "..."` directly instead of asking the user to paste query results back.

---

## dbt

**Project**: `DBT Transformations/grocery_price_project/` (renamed from the default `dbt init` scaffold — don't be surprised by leftover references to `jaffle_shop` in old commits). **Always run dbt via the `dbtg` shell function** (added to `~/.zshrc`), not bare `dbt`/`dbtf` — it auto-targets this project's `--project-dir` regardless of current directory: `dbtg run`, `dbtg test`, `dbtg compile`, etc. Bare `dbt`/`dbtf` will fail with "No dbt_project.yml found" unless you're sitting in the exact project directory.

**Connection**: `~/.dbt/profiles.yml`, profile `grocery_price_project`, same key-pair auth as the `snow` CLI (`~/.ssh/snowflake_rsa_key.p8`, role `ACCOUNTADMIN`). Profile's base `schema: grocery` combines with each model's `+schema:` config (`staging`/`marts` in `dbt_project.yml`) into dbt's default `{base}_{custom}` naming — so staging models land in `GROCERYDBTPROJECT.GROCERY_STAGING`, not `RAW`. (Other unrelated profiles — `dbt_stockproject` etc. — also live in that same `profiles.yml`; don't touch those.)

**Folder structure**: all 30 Kroger staging models live in one folder, `models/staging/kroger_unnnested_raw_data/` — Layer 1 (`stg_kroger_*`, thin rename), Layer 2 (`stg_json_kroger_*`, JSON keys + fixed-shape objects flattened), and the 21 Layer 3 array fan-out models (`stg_json_kroger_{pricing,inventory}_items`, `_images`, `_nutrition_information`, etc., plus `stg_json_kroger_locations_departments`), alongside `_models.yml` and `__sources.yml`. Full reasoning + lineage diagrams in `Project Architecture.md`. `models/marts/` is currently empty — the original dbt-init tutorial content (customers/orders/products) was deleted as unrelated boilerplate.

**dbt gotchas** (confirmed this session):
- **dbt Fusion's CLI wants `--project-dir` *after* the subcommand** (`dbt run --project-dir X`), not before (`dbt --project-dir X run` errors with "No such option"). This is why `dbtg` is a shell function, not a plain alias.
- **`generate_base_model()` from dbt-codegen has a real bug**, reproduced in isolation: for `stg_kroger_product_catalog` specifically, it appended 3 phantom columns (`region`, `locationId`, `raw_data`) that belong to a *different* source table. Confirmed via `DESCRIBE TABLE` that the live table doesn't have them. Fixed by hand-writing that one model instead of trusting the macro; the other three sources generated correctly.
- **`INFER_SCHEMA` inferred `productId`/`upc` as `NUMBER`**, silently dropping their meaningful leading zeros in every row of `KROGER_PRODUCT_CATALOG`. Fixed by overriding just those two columns' inferred type to `VARCHAR` via `OBJECT_INSERT` on the `INFER_SCHEMA` output before `CREATE TABLE ... USING TEMPLATE`, then reloading from S3 (source CSVs were never affected, so nothing was actually lost).
- **Snowflake's `INFER_SCHEMA`-derived tables use case-sensitive quoted identifiers** (e.g. `"productId"`, not `PRODUCTID`) — reference them with matching double-quotes in dbt SQL, or they silently fail to resolve (Snowflake folds unquoted identifiers to uppercase).
- **Arrays vs. objects need fundamentally different handling.** A fixed-shape nested object (e.g. `address`, `temperature`) can be flattened into more columns on the *same* row/grain. A JSON array (e.g. `items`, `nutrition_information`) cannot — it needs its own model at a new grain (`LATERAL FLATTEN`, one row per array element). Two fields (`images`, `nutrition_information`) needed a *second* fan-out for their own nested sub-arrays. Always confirm real type via `TYPEOF()`/live data before assuming — don't guess from one sample.
- **`RESTRICTIONS` (pricing/inventory) is an empty array on every row today** — confirmed via live query, not assumed. Its fan-out model exists and will start returning rows the moment Kroger populates it; don't be alarmed by 0 rows.
- **Never add a `unique` dbt test on `PRODUCT_ID`/`LOCATION_ID` alone** — these are append-only raw snapshots (multiple collection runs accumulate), so single-column uniqueness doesn't hold even though it might look like it should. `not_null` is safe and already verified against live data.

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
- **Phase 4** (dbt): 🟡 Kroger staging layer done (30 models: catalog + 3-layer locations/pricing/inventory, all live-verified); marts (joins + business logic) not started.
- **Phase 5** (Forecasting): 🔮 not started — depends on accumulating enough `KROGER_PRICING` history via a real schedule, not ad hoc runs.
