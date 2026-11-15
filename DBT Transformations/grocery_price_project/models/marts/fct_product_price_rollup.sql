{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- One row per product, rolled up across the stores that currently list it
-- (Kroger: up to 81 stores; Walmart: its one national store). Use this for
-- product-level questions — "biggest price drops", "what's on sale",
-- "lowest price for X" — so an item Kroger prices the same everywhere shows
-- up once, with a store count, instead of once per store.
-- Per-store detail stays in fct_product_price_summary.
--
-- Price drops use the MEDIAN store change, so one store's odd price can't
-- headline a product; LARGEST_DROP_4W_PCT shows the best single store.

with current_rows as (

    select * from {{ ref('fct_product_price_summary') }}
    where IS_CURRENTLY_LISTED

),

rolled as (

select
    PRODUCT_KEY,
    RETAILER,
    PRODUCT_ID,

    ---------- current price across stores
    count(*) as STORES_LISTED,
    min(CURRENT_PRICE) as MIN_CURRENT_PRICE,
    median(CURRENT_PRICE) as MEDIAN_CURRENT_PRICE,
    max(CURRENT_PRICE) as MAX_CURRENT_PRICE,
    min_by(STORE_ID, CURRENT_PRICE) as CHEAPEST_STORE_ID,
    max(CURRENT_PRICE) > min(CURRENT_PRICE) as PRICE_VARIES_BY_STORE,

    ---------- promos and deals
    count_if(IS_ON_PROMO) as STORES_ON_PROMO,
    count_if(DEAL_QUALITY = 'GENUINE') as STORES_WITH_GENUINE_DEAL,
    count_if(DEAL_QUALITY = 'INFLATED_REFERENCE') as STORES_WITH_INFLATED_REFERENCE,
    count_if(IS_AT_HISTORIC_LOW) as STORES_AT_HISTORIC_LOW,
    median(PROMO_WEEK_SHARE) as MEDIAN_PROMO_WEEK_SHARE,
    median(AVG_PROMO_DISCOUNT_PCT) as MEDIAN_PROMO_DISCOUNT_PCT,

    ---------- history position
    median(PRICE_PERCENTILE) as MEDIAN_PRICE_PERCENTILE,
    min(ALL_TIME_LOW_PRICE) as ALL_TIME_LOW_PRICE,
    max(WEEKS_OBSERVED) as MAX_WEEKS_OBSERVED,

    ---------- movers (median across stores; REF_WEEK_* = most common comparison week)
    mode(REF_WEEK_4W) as REF_WEEK_4W,
    median(CHANGE_4W) as MEDIAN_CHANGE_4W,
    median(CHANGE_4W_PCT) as MEDIAN_CHANGE_4W_PCT,
    min(CHANGE_4W_PCT) as LARGEST_DROP_4W_PCT,
    count_if(CHANGE_4W < 0) as STORES_PRICE_DROPPED_4W,
    count_if(CHANGE_4W > 0) as STORES_PRICE_ROSE_4W,
    mode(REF_WEEK_8W) as REF_WEEK_8W,
    median(CHANGE_8W_PCT) as MEDIAN_CHANGE_8W_PCT,
    mode(REF_WEEK_12W) as REF_WEEK_12W,
    median(CHANGE_12W_PCT) as MEDIAN_CHANGE_12W_PCT,

    max(DATA_AS_OF) as DATA_AS_OF,
    any_value(RETAILER_LATEST_WEEK) as RETAILER_LATEST_WEEK

from current_rows
group by PRODUCT_KEY, RETAILER, PRODUCT_ID

)

-- Unit prices: price per ounce / fluid ounce / item, from the parsed package
-- size. Null when the size couldn't be parsed (PARSE_CONFIDENCE 'none').
-- Compare unit prices only within the same UNIT_BASIS.
select
    r.*,
    p.UNIT_BASIS,
    p.PARSE_CONFIDENCE,
    iff(p.PARSE_CONFIDENCE <> 'none' and p.PACKAGE_QUANTITY > 0,
        round(r.MIN_CURRENT_PRICE / p.PACKAGE_QUANTITY, 4), null) as MIN_UNIT_PRICE,
    iff(p.PARSE_CONFIDENCE <> 'none' and p.PACKAGE_QUANTITY > 0,
        round(r.MEDIAN_CURRENT_PRICE / p.PACKAGE_QUANTITY, 4), null) as MEDIAN_UNIT_PRICE

from rolled r
left join {{ ref('dim_product') }} p
    on p.PRODUCT_KEY = r.PRODUCT_KEY
