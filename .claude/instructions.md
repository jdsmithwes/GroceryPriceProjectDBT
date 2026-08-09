# Claude Code Context: GroceryPriceProject (SalePredictor)

**Author**: Jamaal Smith (jdsmith1906@gmail.com)  
**Company**: SmoothData  
**Project**: GroceryPriceProject / SalePredictor  
**Last Updated**: 2026-08-09  
**Status**: Phase 1 Complete ✓

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

## 📁 Project Structure

```
GroceryPriceProject/
├── .claude/
│   └── instructions.md                    # This file
├── credentials/
│   ├── walmart/
│   │   ├── WM_IO_private_key.pem         # KEEP PRIVATE
│   │   └── WM_IO_public_key.pem          # Uploaded to portal
│   └── kroger/
│       └── (credentials in .env only)
├── scripts/
│   ├── test_api_credentials.py           # Test both APIs
│   ├── ingest_walmart_prices.py          # Walmart data ingestion
│   └── ingest_kroger_prices.py           # Kroger data ingestion
├── dbt/
│   ├── models/
│   │   ├── staging/
│   │   ├── marts/
│   │   └── analyses/
│   └── dbt_project.yml
├── .env                                  # API credentials (gitignored)
├── .gitignore                            # Protects sensitive files
└── README.md
```

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

Private key file (`credentials/walmart/WM_IO_private_key.pem`) does not exist on disk yet as of 2026-08-09 — needs to be added before any live request can be signed/tested.

### Kroger API
**Username**: jdsmithwes@protonmail.com  
**Authentication**: OAuth 2.0 (Client Credentials)  
**API Type**: Products API  
**Rate Limit**: 10,000 calls/day  
**Key Endpoints**:
- `/products` - Search products
- `/products/{id}` - Get product details
- Pricing data available with `locationId` parameter

**Docs**: See `kroger_api_openapi.json` in project docs

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

### Phase 2: Snowflake Setup ⏳ NEXT
- [ ] Snowflake warehouse created
- [ ] Raw data tables designed (products, prices, inventory)
- [ ] External stages configured
- [ ] Data retention policies defined
- [ ] Snowflake credentials added to `.env`

### Phase 3: Data Ingestion Pipeline 🔮 PLANNED
- [ ] Python scripts for API polling
- [ ] Scheduled data collection (daily/hourly)
- [ ] Data validation & quality checks
- [ ] Error handling & retry logic
- [ ] Pipeline monitoring & logging

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

**In your project folder:**
- `WALMART_API_KEY_SETUP.md` - How RSA keys were generated
- `walmart_apis_overview.md` - Walmart API options & comparison
- `walmart_affiliate_api_reference.md` - Affiliate API endpoint details
- `kroger_api_openapi.json` - Complete Kroger API OpenAPI spec
- `SETUP_VERIFICATION_CHECKLIST.md` - Setup verification
- `WALMART_APPLICATION_SETUP_COMPLETE.md` - Walmart app setup guide
- `test_api_credentials.py` - API credential testing script

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