-- Grocery value agent — Phase 0: readiness checks and data profiling.
-- Read-only. Results size the marts, the forecast, the unit-size parser, and
-- the private-label seed; record the answers in Agent/README.md.

USE DATABASE GROCERYDBTPROJECT;
USE WAREHOUSE COMPUTE_WH;

------------------------------------------------------------------------------
-- 1. Feature availability (each should run without "unsupported" errors)
------------------------------------------------------------------------------
SELECT CURRENT_REGION(), CURRENT_ACCOUNT(), CURRENT_VERSION();
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
SHOW SEMANTIC VIEWS IN ACCOUNT;
SHOW AGENTS IN ACCOUNT;
SHOW CORTEX SEARCH SERVICES IN ACCOUNT;
SHOW SNOWFLAKE.ML.FORECAST INSTANCES IN ACCOUNT;
SHOW DATABASES LIKE 'SNOWFLAKE_INTELLIGENCE';

------------------------------------------------------------------------------
-- 2. Price history depth (forecast + rule thresholds assume >= 6–8 weeks)
------------------------------------------------------------------------------
-- Kroger: series = product x store
WITH obs AS (
    SELECT PRODUCT_ID, LOCATION_ID,
           DATEDIFF('week', MIN(VALID_FROM), MAX(LAST_SEEN_AT)) + 1 AS WEEKS_SPANNED,
           COUNT(*) AS PRICE_VERSIONS
    FROM GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRICE_HISTORY
    GROUP BY 1, 2
)
SELECT COUNT(*) AS SERIES,
       COUNT(DISTINCT PRODUCT_ID) AS PRODUCTS,
       COUNT(DISTINCT LOCATION_ID) AS STORES,
       MEDIAN(WEEKS_SPANNED) AS MEDIAN_WEEKS,
       COUNT_IF(WEEKS_SPANNED >= 8) AS SERIES_8PLUS_WEEKS,
       COUNT_IF(PRICE_VERSIONS > 1) AS SERIES_WITH_PRICE_CHANGE
FROM obs;

-- Walmart: series = item
WITH obs AS (
    SELECT ITEM_ID,
           DATEDIFF('week', MIN(VALID_FROM), MAX(LAST_SEEN_AT)) + 1 AS WEEKS_SPANNED,
           COUNT(*) AS PRICE_VERSIONS
    FROM GROCERY_INTERMEDIATE_WALMART.DBT_INT_WALMART_PRICE_HISTORY
    GROUP BY 1
)
SELECT COUNT(*) AS SERIES,
       MEDIAN(WEEKS_SPANNED) AS MEDIAN_WEEKS,
       COUNT_IF(WEEKS_SPANNED >= 8) AS SERIES_8PLUS_WEEKS,
       COUNT_IF(PRICE_VERSIONS > 1) AS SERIES_WITH_PRICE_CHANGE
FROM obs;

-- Forecast series at the planned grain: Kroger product (median across stores)
SELECT COUNT(DISTINCT PRODUCT_ID) AS KROGER_PRODUCTS_WITH_ANY_CHANGE
FROM GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRICE_HISTORY
WHERE NOT IS_CURRENT;

------------------------------------------------------------------------------
-- 3. Cross-retailer coverage
------------------------------------------------------------------------------
SELECT COUNT(*) AS SHARED_UPCS,
       COUNT_IF(HAS_KROGER_PRICE AND HAS_WALMART_PRICE) AS PRICED_AT_BOTH,
       COUNT_IF(IS_SAME_COMMON_CATEGORY) AS SAME_COMMON_CATEGORY
FROM GROCERY_INTERMEDIATE_COMMON.DBT_INT_RETAILER_COMMON_UPCS;

------------------------------------------------------------------------------
-- 4. Unit-size parsing inputs
------------------------------------------------------------------------------
-- Kroger SIZE formats: normalize digits to '#' to see the distinct shapes
SELECT REGEXP_REPLACE(LOWER(SIZE), '[0-9]+([.][0-9]+)?', '#') AS SIZE_SHAPE,
       SOLD_BY, COUNT(*) AS PRODUCTS, ANY_VALUE(SIZE) AS EXAMPLE
FROM GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRODUCT_CATALOG_CURRENT
GROUP BY 1, 2
ORDER BY PRODUCTS DESC
LIMIT 60;

-- Walmart: size usually trails the NAME ("..., 16 oz"); how often is a
-- quantity+unit pattern present?
WITH latest AS (
    SELECT NAME
    FROM GROCERY_STAGING_WALMART.DBT_STG_WALMART_PRODUCT_CATALOG
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ITEM_ID ORDER BY COLLECTED_AT DESC) = 1
)
SELECT COUNT(*) AS ITEMS,
       COUNT_IF(REGEXP_LIKE(LOWER(NAME),
           '.*[0-9]+([.][0-9]+)? ?(oz|fl oz|fl\\. oz|lb|lbs|ct|count|pk|pack|g|kg|ml|l|gal|gallon|qt|pt)\\b.*'))
           AS ITEMS_WITH_SIZE_PATTERN
FROM latest;

SELECT NAME
FROM GROCERY_STAGING_WALMART.DBT_STG_WALMART_PRODUCT_CATALOG
SAMPLE (40 ROWS);

------------------------------------------------------------------------------
-- 5. Store-brand seed inputs and shelf-stable signal
------------------------------------------------------------------------------
SELECT 'kroger' AS RETAILER, BRAND, COUNT(*) AS PRODUCTS
FROM GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRODUCT_CATALOG_CURRENT
GROUP BY 2 ORDER BY PRODUCTS DESC LIMIT 40;

SELECT 'walmart' AS RETAILER, BRAND_NAME, COUNT(DISTINCT ITEM_ID) AS PRODUCTS
FROM GROCERY_STAGING_WALMART.DBT_STG_WALMART_PRODUCT_CATALOG
GROUP BY 2 ORDER BY PRODUCTS DESC LIMIT 40;

SELECT TEMPERATURE, COUNT(*) AS PRODUCTS
FROM GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRODUCT_CATALOG_CURRENT
GROUP BY 1 ORDER BY 2 DESC;

------------------------------------------------------------------------------
-- 6. Overdue follow-up: dynamic-table refresh cost (since 2026-09-19)
------------------------------------------------------------------------------
SELECT NAME, STATE, REFRESH_ACTION, COUNT(*) AS REFRESHES,
       AVG(DATEDIFF('second', REFRESH_START_TIME, REFRESH_END_TIME)) AS AVG_SECONDS
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    DATA_TIMESTAMP_START => '2026-09-19'::TIMESTAMP_LTZ))
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

SELECT DATE_TRUNC('week', START_TIME) AS WEEK, SUM(CREDITS_USED) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE WAREHOUSE_NAME = 'COMPUTE_WH' AND START_TIME >= '2026-09-19'
GROUP BY 1 ORDER BY 1;
