{{ config(materialized='view') }}

-- What the PRODUCT_SEARCH Cortex Search service indexes (fuzzy product lookup
-- for the agent). This view holds the SQL; the service itself reads the plain
-- table GROCERY_SEMANTIC.PRODUCT_SEARCH_SOURCE, which the weekly task refills
-- from this view with INSERT OVERWRITE (Snowflake Scripts/Agent/
-- 04_search_and_basket_tool.sql). Cortex Search needs change tracking, and a
-- FULL-refresh dynamic table (dim_product) cannot provide it, nor can an
-- incremental dynamic table built on one (both fail with 091941, found
-- 2026-11-15) — a refreshed table is the only option.
-- SEARCH_TEXT is indexed; the other columns are returned with each hit so the
-- agent can show what matched and join to the marts by PRODUCT_KEY.

select
    PRODUCT_KEY,
    RETAILER,
    PRODUCT_ID,
    PRODUCT_NAME,
    BRAND,
    SIZE_TEXT,
    PRIMARY_COMMON_CATEGORY,
    IS_FOOD,
    IS_STORE_BRAND,
    HAS_EXACT_MATCH,
    UPC_A,
    PRODUCT_TYPE,
    -- not concat_ws: it returns NULL when any part is NULL (Walmart has no
    -- SIZE_TEXT), which left every Walmart row unsearchable on 2026-11-15
    array_to_string(array_construct_compact(PRODUCT_NAME, BRAND, SIZE_TEXT, PRIMARY_COMMON_CATEGORY, PRODUCT_TYPE), ' ') as SEARCH_TEXT

from {{ ref('dim_product') }}
where IS_GROCERY
