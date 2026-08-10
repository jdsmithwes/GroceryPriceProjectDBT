# Claude Code Context: GroceryPriceProject (SalePredictor)

**Author**: Jamaal Smith (jdsmith1906@gmail.com)  
**Company**: SmoothData  
**Project**: GroceryPriceProject / SalePredictor  
**Last Updated**: 2026-08-10  
**Status**: Phase 1 Complete ✓ · Phase 2/3 well underway (Kroger catalog + locations + pricing + inventory pipelines built; Walmart blocked)

---

## 🎯 Project Overview

**Goal**: Build a data pipeline to collect grocery pricing data from Kroger and Walmart, store it in Snowflake, transform it with dbt, and use AI to forecast when items will go on sale.

**Technology Stack**:
- **APIs**: Kroger Products API, Walmart Affiliate Marketing API
- **Data Warehouse**: Snowflake
- **Transformation**: dbt (data build tool)
- **Data Storage**: Snowflake raw tables → dbt models → analytical marts
- **Language**: Python 3.x
- **Analysis**: Python + AI for sale forecasting

---

## ⚙️ Engineering Guidelines

**Cost-effectiveness**: Any script that drives a process requiring compute power (API polling, concurrent data pulls, Snowflake warehouses/pipes, scheduled jobs, etc.) should be designed to minimize resource usage and cost — e.g., avoid redundant API calls across scripts pulling overlapping data, right-size warehouse compute (auto-suspend, smallest viable size), avoid re-fetching data that hasn't changed, and prefer batching/deduping over brute-force full re-pulls where the API allows it.

---

## 📁 Project Structure

**Actual structure as of 2026-08-10** (supersedes any older/aspirational tree — this reflects what's really in the repo):

```
GroceryPriceProject/
├── .claude/
│   └── instructions.md                          # This file
├── API Scripts/
│   ├── Product Catalogs/
│   │   └── entire_productcatalog_kroger.py       # Kroger full-catalog crawl (working, live-tested)
│   │   └── entire_productcatalog_walmart.py      # Walmart catalog (blocked, see Walmart section)
│   │   └── walmart_taxonomy.py                   # Walmart category taxonomy (blocked, same reason)
│   ├── Product Location/
│   │   └── Kroger_Location_2026-08-10.py         # Kroger store locations by region (working)
│   ├── Product Pricing/
│   │   └── Kroger_Pricing_2026-08-10.py          # Per-store pricing, batched by known productId (working)
│   └── Product Inventory/
│       └── Kroger_Inventory_2026-08-10.py        # Per-store stock/fulfillment, same batching (working)
├── snowflake scripts/
│   ├── productcatalog_ingestion_pipeline.sql     # Shared setup + catalog Snowpipes (Kroger + Walmart)
│   ├── location_ingestion_pipeline.sql           # Kroger locations Snowpipe
│   ├── pricing_ingestion_pipeline.sql            # Kroger pricing Snowpipe
│   └── inventory_ingestion_pipeline.sql          # Kroger inventory Snowpipe
├── data/raw/                                     # Local CSV copies from script runs
├── credentials/walmart/                          # (empty in-repo; real keys live outside repo, see Walmart section)
├── .env                                          # API + AWS credentials (gitignored)
├── .gitignore                                    # Protects sensitive files
└── requirements.txt                              # requests, pandas, python-dotenv, boto3, cryptography
```

dbt project has not been started yet (Phase 4) — no `dbt/` directory exists.

---

## 🔑 API Credentials & Authentication

### Walmart API
**Application**: SmoothData (Web Application)  
**Consumer ID**: `a9d00627-32ca-4016-acc5-4dbe58ea5009`  
**Authentication**: RSA Key Pair (OAuth 2.0)  
**Private Key Location**: `credentials/walmart/WM_IO_private_key.pem`  
**API Type**: Affiliate Marketing API  
**Rate Limit**: Check your dashboard for quota  
**Key Endpoints**:
- `/products` - Search products
- `/products/{itemId}` - Get product details
- `/search` - Full-text search
- `/trends` - Trending products
- `/recommendations` - Product recommendations

**Docs**: https://walmart.io/docs/affiliates/v1/affiliate-marketing-api

**Catalog endpoint** (confirmed 2026-08-09): `GET https://developer.api.walmart.com/api-proxy/service/affil/product/v2/paginated/items`

Query params (all optional; `category` or `brand` recommended for faster responses): `publisherId`, `adId`, `campaignId`, `category` (id from Walmart's Taxonomy API — not yet looked up for Food/Grocery), `brand`, `specialOffer`, `soldByWmt`, `available`, `count`, plus several boolean deal/collection flags (`flashDeals`, `extraSavings`, `annualEvent`, `preOwned`, `collectibles`, `topRatedItems`, `fulfilledByWalmart`, `proSellerItems`, `limitedTimeDeals`, `marketplaceCollection`, `dailyDealItems`).

Pagination: response includes `items` (list), `totalPages`, `nextPageExist`, and `nextPage` — a full relative URL (with its own query string) to call verbatim for the next page. No offset/cursor param to construct yourself. Item fields include `itemId`, `parentItemId`, `upc`, `name`, `brandName`, `categoryPath` (e.g. `"Electronics/Audio/Headphones"`), `categoryNode`, `msrp`, `salePrice`, `longDescription`, `stock`, `marketplace`, `sellerInfo`, `productTrackingUrl`, `mediumImage`/`largeImage`.

No Food/Grocery category id looked up yet — Taxonomy API not yet reviewed.

**Request signing** (confirmed from walmart.io docs, 2026-08-09):
Every request must carry 4 headers, generated fresh per request (signature TTL is 180 seconds):

| Header | Value |
|---|---|
| `WM_CONSUMER.ID` | `WALMART_CONSUMER_ID` from `.env` |
| `WM_CONSUMER.INTIMESTAMP` | current Unix epoch time in **milliseconds** |
| `WM_SEC.KEY_VERSION` | `"1"` |
| `WM_SEC.AUTH_SIGNATURE` | see algorithm below |

Signature algorithm:
1. Build a map of the three values above (`WM_CONSUMER.ID`, `WM_CONSUMER.INTIMESTAMP`, `WM_SEC.KEY_VERSION`).
2. Sort the keys alphabetically: `WM_CONSUMER.ID`, `WM_CONSUMER.INTIMESTAMP`, `WM_SEC.KEY_VERSION`.
3. Concatenate `value + "\n"` for each key in that order → the string-to-sign (ends with a trailing `\n`).
4. Sign the UTF-8 bytes with the RSA private key (`WALMART_KEY_PATH`, PKCS#8) using **SHA256withRSA** (i.e. RSASSA-PKCS1-v1_5 + SHA-256).
5. Base64-encode the raw signature bytes → `WM_SEC.AUTH_SIGNATURE`.

Private key file: found (not in this repo) at `/Users/jamaalsmith/credentials/walmart/WM_IO_private_key.pem` as of 2026-08-10; `.env`'s `WALMART_KEY_PATH` now points at that absolute path. Confirmed locally that this private key genuinely pairs with `WM_IO_public_key.pem`.

**BLOCKED as of 2026-08-10**: live calls fail with `401 "Public Key not found for Consumer id"`. Root cause found — the Walmart developer portal app ("SalePredictor") only ever had a **Stage Consumer ID** (`a9d00627-32ca-4016-acc5-4dbe58ea5009`, the one in `.env`) provisioned; there is no Prod Consumer ID. Getting one requires re-uploading the public key via the portal's "Upload Public Key" dialog with Environment Type = Production — but that dialog **spins and silently closes with no error**, reproduced identically in both Safari and Chrome. Next step is likely contacting Walmart developer support directly (mention it fails identically across two browsers, since that rules out their default cache-clearing advice). Everything else — signing algorithm, endpoint, pagination, taxonomy parsing — is self-verified/tested and ready to go the moment Prod access comes through.

### Kroger API
**Username**: jdsmithwes@protonmail.com  
**Authentication**: OAuth 2.0 (Client Credentials), scope `product.compact`  
**API Type**: Products API + Locations API  
**Rate Limit**: 10,000 calls/day (well within budget for all pipelines built so far — a few hundred calls each)  
**Working, live-tested credentials** — unlike Walmart, Kroger has been fully functional throughout.

**Catalog endpoint**: `GET https://api.kroger.com/v1/products` with `filter.term` (no bulk "list everything" endpoint exists — see `API Scripts/Product Catalogs/entire_productcatalog_kroger.py` for the search-term-crawl workaround). Max 250 results per unique filter combination (`filter.start` + `filter.limit` ≤ 250, `filter.limit` max 50/page).

**Locations endpoint** (confirmed live 2026-08-10): `GET https://api.kroger.com/v1/locations`
Params: `filter.zipCode.near`, `filter.radiusInMiles`, `filter.limit`, `filter.start` (same pagination convention as Products). Real response fields: `locationId`, `storeNumber`, `divisionNumber`, `chain`, `name`, `address` (`addressLine1`, `city`, `state`, `zipCode`, `county`), `geolocation` (`latitude`, `longitude`, `latLng`), `hours` (per-day open/close), `phone`, `departments` (list of `{departmentId, name}`).
A real, live-verified store: `locationId = "01100695"` ("Kroger - Ponce", Atlanta, GA).

**Per-store pricing/inventory**: same `/v1/products` endpoint as the catalog, just add `filter.locationId` (required — price/stock are inherently per-store, Kroger has no national pricing) and `filter.productId` (comma-separated batch, to query known products directly instead of re-crawling by search term).
- **Hard server-enforced cap, confirmed live**: `filter.productId` accepts **at most 50 IDs per call** (HTTP 400, code `PRODUCT-2018`, `"Field 'productId' must not exceed 50 items"` above that).
- Response shape once `filter.locationId` is set: `items[].price` (`regular`, `promo`, `effectiveDate`, `expirationDate`), `items[].inventory.stockLevel` (`HIGH`/`LOW`/etc.), `items[].fulfillment` (`curbside`, `delivery`, `inStore`, `shipToHome`).

**Gotcha — leading zeros**: Kroger `productId`/`upc` values are 13-digit strings with meaningful leading zeros (e.g. `"0001111041700"`). `pandas.read_csv()` **silently strips them** if you don't pass `dtype=str` — this corrupts the ID before it ever reaches the API (a stripped ID just returns no results, fails silently). Always read Kroger ID columns with `dtype=str`.

**Docs**: No `kroger_api_openapi.json` has ever actually existed in this repo despite being referenced in older docs — everything confirmed above came from live-testing against the real API, not a spec file.

---

## ❄️ Snowflake Setup

**Account**: `TPRFGUJ-JNC76647` · **Database**: `GROCERYDBTPROJECT` · **Warehouse**: `COMPUTE_WH` (XSMALL, auto-suspend 60s) · **Schemas**: `RAW` (tables), `AWS_RESOURCES` (stages/pipes/file formats/storage integration — all AWS-related Snowflake objects live here by convention)

**S3 bucket**: `grocerydbtprojectrawdata` (AWS account `573509103721`, region `us-east-1`). All Kroger files land under a single shared prefix `kroger/`, differentiated only by filename — see "Multi-file-type Snowpipe pattern" below. Walmart uses `walmart/` (not yet populated — blocked, see Walmart section above).

**IAM role for Snowflake access**: `arn:aws:iam::573509103721:role/GroceryPriceProjectSnowflakeRole`, trust policy synced to whatever the most recent `DESC STORAGE INTEGRATION GROCERY_PRICE_PROJECT` output was. **The current IAM user (`jdsmithwes`) cannot modify this role or any IAM policy/role** (`AccessDenied` on `iam:CreatePolicy`, `iam:CreateRole`, `iam:UpdateAssumeRolePolicy`, even read calls like `iam:ListAttachedUserPolicies`) — but it CAN read the role (`iam:GetRole`) and can fully manage S3 bucket contents/notifications. Any future IAM trust-policy change needs the user to do it manually via the AWS console (root/admin login), not via CLI.

**SQL pipeline files** (`snowflake scripts/`), naming convention `%source%_ingestion_pipeline.sql`:
- `productcatalog_ingestion_pipeline.sql` — shared setup (warehouse/db/schemas/storage integration/`MY_S3_STAGE_KROGER` stage/`MY_CSV_INFER` file format) **lives in this file** — the other three assume it's been run once and don't redefine those objects. Also has the Kroger + Walmart catalog pipes.
- `location_ingestion_pipeline.sql`, `pricing_ingestion_pipeline.sql`, `inventory_ingestion_pipeline.sql` — one pipe each, reusing the shared stage/file format.

**Multi-file-type Snowpipe pattern**: all four Kroger file types (`kroger_product_catalog_*.csv`, `kroger_locations_*.csv`, `kroger_pricing_*.csv`, `kroger_inventory_*.csv`) land in the same `kroger/` S3 prefix and are read via the SAME shared stage (`MY_S3_STAGE_KROGER`) — differentiated only by a `PATTERN` clause on each pipe's `COPY INTO` (e.g. `PATTERN = '.*kroger_pricing_.*[.]csv'`). Each `AUTO_INGEST` pipe gets its **own dedicated SQS queue** (confirmed live — different ARNs per pipe), so the S3 bucket's Event Notification config needs **one `QueueConfiguration` entry per pipe** (all four, all scoped to prefix `kroger/`) — a single S3 object-create event fans out to all four queues, and each pipe's own `PATTERN` decides whether it actually loads that specific file.

**Raw-landing data convention** (per user direction 2026-08-10, ties into the cost-effectiveness Engineering Guideline above): ingestion scripts should NOT transform, flatten, or join nested API data. Only pull out the minimum join/partition keys as real columns (e.g. `productId`, `locationId`, `collected_at`) — everything else gets preserved as an untouched JSON string in a `raw_data` column. All parsing, joining, and business logic belongs in dbt staging models downstream, not in the Python ingestion scripts or the Snowflake landing tables. This is why `KROGER_LOCATIONS`/`KROGER_PRICING`/`KROGER_INVENTORY` use explicit fixed-column `CREATE TABLE` (not `INFER_SCHEMA`) — their shape is intentionally just join keys + one `raw_data` blob, not one column per API field.

**Snowflake gotchas learned the hard way this session** (all confirmed against the real account):
- **Storage integrations are account-level objects** — `CREATE STORAGE INTEGRATION` names must be unqualified (no database/schema prefix), unlike stages/tables/pipes.
- **Never re-run `CREATE OR REPLACE STORAGE INTEGRATION`** once it's working — it generates a brand-new `STORAGE_AWS_EXTERNAL_ID` and desyncs the AWS IAM role's trust policy, breaking S3 access until both sides are manually re-synced. Use `IF NOT EXISTS` instead.
- **`MATCH_BY_COLUMN_NAME` + a target table with extra columns** (e.g. `INGESTED_FILENAME` added via `ALTER TABLE`) requires `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` on the file format — otherwise `COPY INTO` fails with a raw column-count error even though name-based matching should make the count irrelevant.
- **`INCLUDE_METADATA = (col = METADATA$FILENAME)`** is the (newer) clause needed to combine file-metadata columns with `MATCH_BY_COLUMN_NAME` — they can't be combined via a plain `SELECT` list without abandoning name-based matching.
- **`CREATE OR REPLACE TABLE` wipes data AND drops manually-`ALTER`-added columns.** If you ever re-run a table-creation step, immediately re-run the `ALTER TABLE ADD COLUMN` step right after, or every downstream pipe/backfill referencing that column breaks.
- **A pipe's "already loaded this file" tracking survives table recreation.** Recreating the table doesn't let the pipe reload a file it already processed — use a manual `COPY INTO ... FORCE = TRUE` to force a reload regardless of that tracking.
- **`FIELD_OPTIONALLY_ENCLOSED_BY = '"'`** is required on any file format reading pandas-generated CSVs — pandas quotes any field containing a comma/embedded content by default, and without this setting Snowflake splits on commas inside quoted values instead of honoring the quoting.
- **When multiple file types share one S3 prefix/stage, every pipe reading from it needs its own `PATTERN` clause** — otherwise a pipe with no pattern will try to load every file type and fail (or worse, silently misload) under `MATCH_BY_COLUMN_NAME`.

**Tooling note**: Cortex Code CLI's Snowflake connection is broken (`JWT token is invalid`) — confirmed this is a genuine credential problem, not a Cortex-specific bug, since the official `snow` CLI fails identically using the same `~/.snowflake/connections.toml` `[default]` key-pair profile. VS Code's Snowflake extension works reliably because it's using a **different** connection profile in that same file (OAuth browser-login, not the broken key-pair one). **Bottom line: there is currently no way to execute SQL against this Snowflake account except manually, via the user running statements in VS Code** — Claude Code has no working direct path.

---

## 🔐 Environment Variables (.env)

**Location**: Project root (NEVER committed to git)

```bash
# Walmart API
WALMART_CONSUMER_ID=a9d00627-32ca-4016-acc5-4dbe58ea5009
WALMART_KEY_PATH=credentials/walmart/WM_IO_private_key.pem

# Kroger API
KROGER_USERNAME=jdsmithwes@protonmail.com
KROGER_PASSWORD=<your_password>
KROGER_CLIENT_ID=<your_client_id>
KROGER_CLIENT_SECRET=<your_client_secret>

# Snowflake (to be configured in Phase 2)
SNOWFLAKE_ACCOUNT=<your_account>
SNOWFLAKE_USER=<your_user>
SNOWFLAKE_PASSWORD=<your_password>
SNOWFLAKE_WAREHOUSE=<warehouse_name>
SNOWFLAKE_DATABASE=grocery_prices
SNOWFLAKE_SCHEMA=raw
```

---

## 📋 Phase Status

### Phase 1: API Setup ✅ COMPLETE
- [x] Kroger API credentials obtained (Client ID & Secret)
- [x] Walmart RSA key pair generated
- [x] Public key uploaded to Walmart
- [x] Walmart application created (SmoothData)
- [x] Walmart Consumer ID obtained
- [x] `.env` file created with credentials
- [x] `.claude/instructions.md` configured
- [x] All documentation created
- [x] Project context ready for Claude Code

### Phase 2: Snowflake Setup 🟡 MOSTLY DONE
- [x] Snowflake warehouse created (`COMPUTE_WH`)
- [x] Raw data tables designed and created (`KROGER_PRODUCT_CATALOG`, `KROGER_LOCATIONS`, `KROGER_PRICING`, `KROGER_INVENTORY`; Walmart catalog table blocked on data)
- [x] External stages configured (shared `MY_S3_STAGE_KROGER`, differentiated by pipe `PATTERN`)
- [ ] Data retention policies defined
- [ ] Snowflake credentials added to `.env` (not needed — auth happens via VS Code's own connection profile, not `.env`)

### Phase 3: Data Ingestion Pipeline 🟡 MOSTLY DONE (Kroger) / BLOCKED (Walmart)
- [x] Python scripts for API polling — Kroger catalog, locations, pricing, inventory all working and live-tested
- [x] Snowpipe auto-ingest wired up for all four Kroger file types (S3 Event Notification → SQS → pipe, per file-type `PATTERN`)
- [ ] Walmart scripts blocked — see Walmart API section above (no Prod Consumer ID)
- [ ] Scheduled data collection (daily/hourly) — scripts run manually so far, no scheduler set up yet
- [ ] Data validation & quality checks
- [ ] Pipeline monitoring & logging beyond basic Python `logging`

### Phase 4: dbt Transformation 🔮 PLANNED
- [ ] dbt project initialized
- [ ] Staging models for raw data
- [ ] Transformation models for cleaned data
- [ ] Price history fact tables
- [ ] Dimensional models (products, stores, dates)
- [ ] Documentation & tests

### Phase 5: Analysis & Forecasting 🔮 PLANNED
- [ ] Exploratory data analysis
- [ ] Sale pattern identification
- [ ] Time series analysis
- [ ] Forecasting models (ML)
- [ ] Dashboards & reporting

---

## 🔒 Security Checklist

**Critical - Always verify:**
- [x] Private key stored in `credentials/walmart/` (local only)
- [x] `.env` file in `.gitignore` (never committed)
- [x] `credentials/` directory in `.gitignore`
- [x] No credentials hardcoded in code
- [x] No passwords in documentation
- [x] `.gitignore` updated and saved

**Never do:**
- ❌ Commit `.env` file
- ❌ Share private keys
- ❌ Paste credentials in code
- ❌ Share passwords in messages
- ❌ Store secrets in version control

---

## 📊 Data Schema Notes

When building Snowflake tables, capture:
- **Product Data**: Product ID (UPC, item ID), brand, description, category
- **Price Data**: Regular price, promotional price, effective dates
- **Availability**: Stock levels (HIGH, LOW, OUT_OF_STOCK)
- **Location**: Store location, zip code, region
- **Timestamps**: When data was collected, last updated
- **Source**: Kroger vs Walmart, API version
- **Fulfillment** (Walmart): In-store, ship-to-home, delivery, curbside

---

## 🚀 Quick Start Commands

```bash
# Navigate to project
cd ~/workspaces/GroceryPriceProject

# Load environment variables
source .env

# Test API credentials
python scripts/test_api_credentials.py

# Install dependencies
pip install -r requirements.txt

# Run dbt (Phase 4+)
cd dbt && dbt run
cd dbt && dbt test
cd dbt && dbt docs generate
```

---

## 📚 Documentation Reference

**None of the files below actually exist in this repo** as of 2026-08-10, despite being referenced here since the project's early setup — treat this list as aspirational, not current state. All real Kroger/Walmart API knowledge captured in this document came from live-testing the actual APIs, not from spec files:
- `WALMART_API_KEY_SETUP.md`, `walmart_apis_overview.md`, `walmart_affiliate_api_reference.md`, `kroger_api_openapi.json`, `SETUP_VERIFICATION_CHECKLIST.md`, `WALMART_APPLICATION_SETUP_COMPLETE.md`, `test_api_credentials.py`, `scripts/` directory — none present.

---

## 💬 Using Claude Code in VSCode

**When you open this project in VSCode:**

1. Claude Code will automatically read this `.claude/instructions.md` file
2. It will have full context about:
   - Your API credentials locations
   - Your Walmart Consumer ID
   - Your project structure
   - Your phase status
   - All API documentation
   - Your data schema plans

**Example queries you can ask Claude Code:**

- "Set up Snowflake tables for raw pricing data"
- "Create a dbt model to clean and transform Walmart prices"
- "Test the Kroger API integration"
- "Build a Python script to ingest prices into Snowflake"
- "Create a forecast model for sale timing"
- "Design the dbt staging models for both APIs"
- "Add data quality tests for the price data"

**Claude Code will know:**
- Your Consumer ID: `a9d00627-32ca-4016-acc5-4dbe58ea5009`
- Your Kroger username: `jdsmithwes@protonmail.com`
- Your private key location: `credentials/walmart/WM_IO_private_key.pem`
- You're on Phase 1 (API setup complete)
- Next phase is Snowflake setup
- All your API documentation and reference materials

---

## 🎯 Common Tasks

### Test Both APIs
```bash
python scripts/test_api_credentials.py
```
This will verify your Walmart and Kroger credentials work.

### Get Kroger Product Data
1. Kroger username: `jdsmithwes@protonmail.com`
2. Use Client ID and Secret from `.env`
3. Get location IDs first (8-digit code)
4. Query `/products` with `locationId` parameter

### Get Walmart Product Data
1. Consumer ID: `a9d00627-32ca-4016-acc5-4dbe58ea5009`
2. Sign requests with private key at `credentials/walmart/WM_IO_private_key.pem`
3. Query `/products` endpoint
4. Use `/search` for full-text search

### Design Snowflake Schema
Tables you'll need:
- `products` - Product master data
- `prices` - Daily/hourly pricing
- `inventory` - Stock levels
- `sales` - Sale events and promotions
- `locations` - Store/region data
- `collection_log` - Data pipeline tracking

---

## 🔧 Troubleshooting

**"Invalid argument passed to Api Endpoint"**
- Usually means duplicate application name
- Register with a unique name in Kroger developer portal

**API Authentication Errors**
- Verify `.env` file is loaded: `source .env`
- Check Consumer ID and key path are correct
- Ensure private key file exists and is readable

**Rate Limit Errors**
- Kroger: 10,000 calls/day max
- Walmart: Check your dashboard quota
- Plan collection schedule accordingly

---

## 📞 Support & Resources

**Kroger Developer Portal**: https://developer.kroger.com/  
**Walmart Developer Portal**: https://walmart.io/  
**OpenAPI Spec**: See `kroger_api_openapi.json` in project  
**API Test Script**: `scripts/test_api_credentials.py`

---

## 📝 Next Actions

1. **Test APIs**: Run `python scripts/test_api_credentials.py` to verify both work
2. **Create Snowflake Account**: Sign up at https://www.snowflake.com if you haven't
3. **Design Schema**: Plan your raw data tables based on the data schema notes
4. **Update Phase 2**: Add Snowflake credentials to `.env` once account is set up
5. **Start Phase 2**: Set up Snowflake warehouse and raw tables

---

## 🎉 Project Milestones

- ✅ Phase 1: API Setup (August 9, 2026)
- ⏳ Phase 2: Snowflake Setup (Next)
- 🔮 Phase 3: Data Ingestion
- 🔮 Phase 4: dbt Transformation
- 🔮 Phase 5: Analysis & Forecasting

**You're on track! Keep going! 🚀**

---

**Owner**: Jamaal Smith  
**Email**: jdsmith1906@gmail.com  
**Company**: SmoothData  
**Project Status**: Ready for Phase 2