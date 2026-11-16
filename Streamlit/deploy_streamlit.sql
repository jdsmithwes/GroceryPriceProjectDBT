-- Deploy the Streamlit apps to Snowflake. Run as ACCOUNTADMIN.
--
-- Grocery Value app (2026-11-15): chat with GROCERY_VALUE_AGENT, item lookup
-- by store, basket pricing and saved lists, deals and trends. Lives with the
-- agent in GROCERY_SEMANTIC and runs on GROCERY_AGENT_WH. From the repo root:
--
--   snow stage copy Streamlit/grocery_value_app.py @GROCERYDBTPROJECT.GROCERY_SEMANTIC.STREAMLIT_APPS/grocery_value_app --overwrite
--   snow sql -f Streamlit/deploy_streamlit.sql

CREATE STAGE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_SEMANTIC.STREAMLIT_APPS
    DIRECTORY = (ENABLE = TRUE);

CREATE OR REPLACE STREAMLIT GROCERYDBTPROJECT.GROCERY_SEMANTIC.GROCERY_VALUE_APP
    ROOT_LOCATION = '@GROCERYDBTPROJECT.GROCERY_SEMANTIC.STREAMLIT_APPS/grocery_value_app'
    MAIN_FILE = 'grocery_value_app.py'
    QUERY_WAREHOUSE = 'GROCERY_AGENT_WH'
    COMMENT = 'Grocery Value: agent chat, item lookup by store, basket pricing, deals and trends over the grocery marts';

GRANT USAGE ON STREAMLIT GROCERYDBTPROJECT.GROCERY_SEMANTIC.GROCERY_VALUE_APP TO ROLE GROCERY_AGENT_USER;

-- Older Kroger catalog viewer (Streamlit/product_catalog_viewer.py), kept for
-- browsing the raw catalog with images; redeploy the same way into
-- GROCERY_STAGING.STREAMLIT_APPS/product_catalog_viewer if still wanted:
-- CREATE OR REPLACE STREAMLIT GROCERYDBTPROJECT.GROCERY_STAGING.KROGER_PRODUCT_CATALOG_VIEWER
--     ROOT_LOCATION = '@GROCERYDBTPROJECT.GROCERY_STAGING.STREAMLIT_APPS/product_catalog_viewer'
--     MAIN_FILE = 'product_catalog_viewer.py'
--     QUERY_WAREHOUSE = 'SNOWFLAKE_LEARNING_WH';
