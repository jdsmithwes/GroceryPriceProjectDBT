{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- One price per product per observed week — the series both the buy-signal
-- rule (fct_buy_recommendation) and the ML forecast (GROCERY_ML) work on,
-- so they always describe the same number. Kroger: MEDIAN effective price
-- across the stores observed that week (the product's typical price, same
-- basis as fct_product_price_rollup). Walmart: its one national price.
-- Unobserved weeks (collection outages) stay absent.

select
    PRODUCT_KEY,
    RETAILER,
    PRODUCT_ID,
    PRICE_WEEK,
    median(EFFECTIVE_PRICE)::number(10, 2) as EFFECTIVE_PRICE,
    min(EFFECTIVE_PRICE) as MIN_STORE_PRICE,
    count(*) as STORES_OBSERVED,
    count_if(IS_ON_PROMO) as STORES_ON_PROMO

from {{ ref('fct_price_weekly') }}
group by PRODUCT_KEY, RETAILER, PRODUCT_ID, PRICE_WEEK
