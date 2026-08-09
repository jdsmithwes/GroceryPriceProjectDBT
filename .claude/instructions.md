# Claude Code Context for GroceryPriceProject

## Project Overview

**Goal**: Build a data pipeline to collect grocery pricing data from Kroger and Walmart, store it in Snowflake, transform it with dbt, and forecast when items will go on sale using AI.

**Owner**: Jamaal Smith (jdsmith1906@gmail.com)

---

## Tech Stack

- **APIs**: Kroger Products API, Walmart Affiliate Marketing API
- **Data Warehouse**: Snowflake
- **Transformation**: dbt (data build tool)
- **Analysis**: Python + AI for forecasting
- **Language**: Python 3.x

---

## Project Structure

```
GroceryPriceProject/
├── .claude/
│   ├── instructions.md                    # This file
│   └── SETUP.md                          # Setup instructions
├── credentials/
│   ├── walmart/
│   │   ├── WM_IO_private_key.pem         # RSA private key (NEVER share)
│   │   └── WM_IO_public_key.pem          # RSA public key
│   └── kroger/
│       ├── client_id.txt
│       └── client_secret.txt
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
├── .gitignore
└── README.md
```

---

## API Credentials

### Walmart
- **Consumer ID**: a9d00627-32ca-4016-acc5-4dbe58ea5009
- **Private Key Location**: `credentials/walmart/WM_IO_private_key.pem`
- **API Type**: Affiliate Marketing API
- **Rate Limit**: Check dashboard for your quota
- **Docs**: https://walmart.io/docs/affiliates/v1/affiliate-marketing-api

### Kroger
- **Client ID**: [Stored in credentials/kroger/]
- **Client Secret**: [Stored in credentials/kroger/]
- **API Type**: Products API (OAuth 2.0)
- **Rate Limit**: 10,000 calls/day
- **Docs**: [Kroger API OpenAPI spec in project]

---

## Environment Variables (.env)

```bash
# Walmart
WALMART_CONSUMER_ID=<your_consumer_id>
WALMART_KEY_PATH=credentials/walmart/WM_IO_private_key.pem

# Kroger
KROGER_CLIENT_ID=<your_client_id>
KROGER_CLIENT_SECRET=<your_client_secret>

# Snowflake
SNOWFLAKE_ACCOUNT=<your_account>
SNOWFLAKE_USER=<your_user>
SNOWFLAKE_PASSWORD=<your_password>
SNOWFLAKE_WAREHOUSE=<warehouse_name>
SNOWFLAKE_DATABASE=grocery_prices
SNOWFLAKE_SCHEMA=raw
```

---

## Phase Status

### Phase 1: API Setup ✓ COMPLETE
- [x] Kroger API credentials obtained
- [x] Walmart RSA key pair generated
- [x] Public key uploaded to Walmart
- [x] Walmart application created
- [x] Documentation created

### Phase 2: Snowflake Setup (NEXT)
- [ ] Snowflake warehouse created
- [ ] Raw data tables designed
- [ ] External stages configured
- [ ] Data retention policies defined

### Phase 3: Data Ingestion Pipeline (PLANNED)
- [ ] Python scripts for API polling
- [ ] Scheduled data collection
- [ ] Data validation
- [ ] Pipeline monitoring

### Phase 4: dbt Transformation (PLANNED)
- [ ] dbt models designed
- [ ] Raw → clean data transformations
- [ ] Price history tables
- [ ] Fact tables for analysis

### Phase 5: Analysis & Forecasting (PLANNED)
- [ ] Exploratory data analysis
- [ ] Sale pattern identification
- [ ] Forecasting models
- [ ] Dashboards

---

## Important Notes

### Security
⚠️ **CRITICAL**: 
- Never commit `credentials/` directory to git
- Never commit `.env` file
- `.env` and `credentials/` are in `.gitignore`
- Private keys are local-only; never share them

### API Rate Limits
- **Kroger**: 10,000 calls/day across all endpoints
- **Walmart**: Check dashboard (varies by tier)
- Plan data collection schedule accordingly

### Data Schema Planning
When designing Snowflake tables, capture:
- Product IDs (Kroger UPC, Walmart item ID)
- Regular price
- Promotional price
- Stock levels
- Store location
- Timestamp (when data was collected)
- Fulfillment options (Walmart)

---

## Quick Start Commands

```bash
# Install dependencies
pip install -r requirements.txt

# Test API credentials
python scripts/test_api_credentials.py

# Load environment variables
source .env

# Run dbt transformations
cd dbt && dbt run

# Test a specific dbt model
cd dbt && dbt run --select model_name
```

---

## Common Tasks

### Add a new Kroger store location
1. Update `scripts/store_configs.py`
2. Test with `test_api_credentials.py`
3. Add to dbt staging model

### Change data collection frequency
1. Update `scripts/ingest_*.py` schedule
2. Test locally first
3. Update deployment configs

### Add a new price metric
1. Update API response parsing
2. Add column to Snowflake staging table
3. Create dbt transformation
4. Update downstream models

---

## Documentation Reference

See project documentation for:
- `WALMART_API_KEY_SETUP.md` - How the RSA key pair was created
- `walmart_apis_overview.md` - Walmart API options and comparison
- `kroger_api_openapi.json` - Complete Kroger API specification
- `WALMART_APPLICATION_SETUP_COMPLETE.md` - Setup completion checklist

---

## When Using Claude Code in VSCode

1. Open the project folder in VSCode
2. Claude Code will read this `.claude/instructions.md` file
3. All context about your project is available
4. You can reference phase status, credentials locations, API docs, etc.

---

## Questions?

If Claude Code asks clarifying questions:
- Refer to the "Project Overview" section
- Check the "Phase Status" to see what's been completed
- Reference the appropriate documentation file for details

---

**Last Updated**: 2026-08-09  
**Project Owner**: Jamaal Smith