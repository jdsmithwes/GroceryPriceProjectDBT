# Grocery value agent — runbook

The agent answers value-for-money questions about groceries at Kroger (81
Atlanta-area stores) and Walmart (national online prices) in Snowflake. This
file says what runs where, how to change it, and how to check it. Definitions
are in [ONTOLOGY.md](ONTOLOGY.md); the design review in
[ARCHITECTURE.md](ARCHITECTURE.md).

## What exists (prod, database `GROCERYDBTPROJECT`)

| Layer | Object | Built by | Refresh |
|---|---|---|---|
| Marts | `GROCERY_MARTS.DBT_*` (17 dynamic tables) | dbt `models/marts/` | self, 24h lag |
| Forecast | `GROCERY_ML.PRICE_FORECAST`, `SP_REFRESH_PRICE_FORECAST` | `Snowflake Scripts/Agent/02_forecast.sql` | task, Sundays 06:00 ET |
| Semantic | `GROCERY_SEMANTIC.DBT_SV_GROCERY_PRICING` (semantic view) | dbt `models/semantic/sv_grocery_pricing.sql` | on `dbtg build` |
| Search | `GROCERY_SEMANTIC.PRODUCT_SEARCH` over `PRODUCT_SEARCH_SOURCE` | `04_search_and_basket_tool.sql` | table refilled by the Sunday task; service re-indexes within 1 day |
| Basket tool | `GROCERY_SEMANTIC.SP_COMPARE_BASKET(items, zip, max_stores)` | `04_search_and_basket_tool.sql` | — |
| Agent | `GROCERY_SEMANTIC.GROCERY_VALUE_AGENT` (10 tools) | `05_agent.sql` | — |
| Product types | `GROCERY_ML.PRODUCT_TYPE`, `SP_LABEL_PRODUCT_TYPES` | `03_product_types.sql` | Sunday task labels new products |
| Shopper state | `GROCERY_APP.*` hybrid tables + `SP_GET_PROFILE`, `SP_SAVE_LIST`, `SP_WATCH_PRODUCT`, … | `06_state_layer.sql` | written by the agent; watches checked by the Sunday task |
| App | `GROCERY_SEMANTIC.GROCERY_VALUE_APP` (Streamlit) | `Streamlit/deploy_streamlit.sql` | redeploy after editing `Streamlit/grocery_value_app.py` |
| Governance | roles `GROCERY_TRANSFORMER`, `GROCERY_ML_ROLE`, `GROCERY_AGENT_USER`; `GROCERY_AGENT_WH` (XS) and `GROCERY_ML_WH` (M) under `GROCERY_AGENT_MONITOR` (10 credits/month) | `01_governance.sql` | — |

Use the agent in Snowflake Intelligence (role `GROCERY_AGENT_USER` or
ACCOUNTADMIN) or through the REST API as `run_evals.py` does.

## Changing things

Everything goes to the sandbox first (`GROCERY_DEV_*` schemas), then prod.

- **Marts or semantic view**: edit the dbt model, then
  `dbtg build --target sandbox --select <model>`, check, then
  `dbtg build --target dev --select <model>` (`dev` = prod). A change to a
  dynamic table's SQL needs `--full-refresh` on it and its descendants or dbt
  skips it ("No configuration changes were identified").
- **Search, basket tool, agent**: edit the numbered script, make the sandbox
  variant with the `sed` line in its header, run it with `snow sql -f`, test,
  then run the prod script. The agent's instructions live in `05_agent.sql`;
  `CREATE OR REPLACE AGENT` makes a new version.
- **Definitions**: change `ONTOLOGY.md` first, then the semantic-view comments
  and the agent instructions that copy from it.

## Checking it

- **Evals**: `python3 Agent/evals/run_evals.py` (prod) or `--sandbox`. Runs the
  41 golden questions, judges answers with a reference query and an LLM
  judge, writes `Agent/evals/results_<ts>.json`. Target ≥ 90%. Run before and
  after any agent or semantic-view change.
- **Weekly task**: `SELECT * FROM TABLE(GROCERYDBTPROJECT.INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'TASK_WEEKLY_PRICE_FORECAST'))`
  and `GROCERY_ML.PRICE_FORECAST_RUNS`.
- **Search freshness**: `DESCRIBE CORTEX SEARCH SERVICE GROCERY_SEMANTIC.PRODUCT_SEARCH`
  (`data_timestamp`, `indexing_state`).
- **Cost**: `GROCERY_AGENT_MONITOR` notifies at 75% and suspends at 90%;
  review `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_*_USAGE_HISTORY` and
  `WAREHOUSE_METERING_HISTORY` weekly.

## Known limits (say them in answers)

- Walmart is a ~1,400-item catalog slice with one national price; most items
  have no Walmart match, and the basket tool's nearest match can be a
  different product (it returns the names).
- Price history has no data for Oct 12 – Nov 8, 2026.
- Unit prices exist for ~92% of Kroger and ~61% of Walmart products; weight
  multipacks at Kroger are low confidence.
- Products are not typed yet ("peanut butter" matches cookies); product-type
  labels are the next data change.
