{{ config(materialized='view') }}

-- Which products the weekly ML forecast trains on (Snowflake Scripts/Agent/
-- 02_forecast.sql reads this as SCOPE_TABLE). The scope is deliberate:
-- training costs ~0.002 credits per series per week on GROCERY_ML_WH, and
-- the unscoped set (6,733 Kroger series) ran 4h+ before being cancelled.
--
-- Current rule (owner decision 2026-11-15): products carried by both
-- retailers — the head-to-head items where a "come back by" week matters
-- most. To widen, UNION ALL more rows with a new SCOPE_REASON (e.g. a
-- shopper watchlist). The procedure still drops series with fewer than 8
-- observed weeks or no price change, so Walmart rows here only train once
-- Walmart has that much history.

select
    PRODUCT_KEY,
    RETAILER,
    PRODUCT_ID,
    'shared_product' as SCOPE_REASON

from {{ ref('dim_product') }}
where HAS_EXACT_MATCH
