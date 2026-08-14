-- Deploy the Kroger Product Catalog Viewer Streamlit app to Snowflake.
-- Run this after uploading product_catalog_viewer.py to a stage.

-- 1. Create a stage for the Streamlit app code (if not exists)
CREATE STAGE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_STAGING.STREAMLIT_APPS
    DIRECTORY = (ENABLE = TRUE);

-- 2. Upload the app file (run from SnowSQL or Snowsight):
--    PUT file:///path/to/product_catalog_viewer.py @GROCERYDBTPROJECT.GROCERY_STAGING.STREAMLIT_APPS/product_catalog_viewer AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- 3. Create the Streamlit app
CREATE OR REPLACE STREAMLIT GROCERYDBTPROJECT.GROCERY_STAGING.KROGER_PRODUCT_CATALOG_VIEWER
    ROOT_LOCATION = '@GROCERYDBTPROJECT.GROCERY_STAGING.STREAMLIT_APPS/product_catalog_viewer'
    MAIN_FILE = 'product_catalog_viewer.py'
    QUERY_WAREHOUSE = 'SNOWFLAKE_LEARNING_WH';

-- 4. Grant access (adjust role as needed)
-- GRANT USAGE ON STREAMLIT GROCERYDBTPROJECT.GROCERY_STAGING.KROGER_PRODUCT_CATALOG_VIEWER TO ROLE <your_role>;
