{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- One row per Shared Product (identical UPC at both retailers): Walmart's
-- current price vs Kroger's, where "Kroger's price" is the owner's chosen
-- basis — the LOWEST current price across Kroger stores (with the store
-- named) and the MEDIAN across stores. Only prices from each retailer's
-- latest collection week count as current (IS_CURRENTLY_LISTED).
--
-- CHEAPER_RETAILER compares Walmart to Kroger's lowest store; the median
-- comparison is alongside for "typical store" answers. This is the only
-- like-for-like cross-retailer comparison; category-level comparisons
-- must go through unit prices instead.

with summary as (

    select * from {{ ref('fct_product_price_summary') }}
    where IS_CURRENTLY_LISTED

),

kroger as (

    select
        PRODUCT_ID as KROGER_PRODUCT_ID,
        min(CURRENT_PRICE) as KROGER_MIN_PRICE,
        median(CURRENT_PRICE) as KROGER_MEDIAN_PRICE,
        max(CURRENT_PRICE) as KROGER_MAX_PRICE,
        min_by(STORE_ID, CURRENT_PRICE) as KROGER_CHEAPEST_STORE_ID,
        count(*) as KROGER_STORES_PRICED,
        count_if(IS_ON_PROMO) as KROGER_STORES_ON_PROMO,
        max(DATA_AS_OF) as KROGER_DATA_AS_OF

    from summary
    where RETAILER = 'kroger'
    group by PRODUCT_ID

),

walmart as (

    select
        PRODUCT_ID as WALMART_ITEM_ID,
        CURRENT_PRICE as WALMART_PRICE,
        IS_ON_PROMO as WALMART_IS_ON_PROMO,
        DATA_AS_OF as WALMART_DATA_AS_OF

    from summary
    where RETAILER = 'walmart'

),

compared as (

    select
        u.UPC_A,
        u.KROGER_PRODUCT_ID,
        u.WALMART_ITEM_ID,
        -- Walmart names carry the package size ("..., 14.5 Oz"); Kroger's
        -- description doesn't, so its SIZE is appended. Without size, two
        -- shared products with similar names (different sizes, different
        -- UPCs) read like conflicting prices for one item.
        coalesce(u.WALMART_NAME, u.KROGER_DESCRIPTION || coalesce(', ' || kp.SIZE_TEXT, '')) as PRODUCT_NAME,
        kp.SIZE_TEXT as PACKAGE_SIZE,
        u.KROGER_DESCRIPTION as KROGER_PRODUCT_NAME,
        u.WALMART_NAME as WALMART_PRODUCT_NAME,
        coalesce(u.KROGER_BRAND, u.WALMART_BRAND) as BRAND,
        u.WALMART_COMMON_CATEGORY as COMMON_CATEGORY,
        'exact_upc' as MATCH_TYPE,

        w.WALMART_PRICE,
        w.WALMART_IS_ON_PROMO,
        k.KROGER_MIN_PRICE,
        k.KROGER_MEDIAN_PRICE,
        k.KROGER_MAX_PRICE,
        k.KROGER_CHEAPEST_STORE_ID,
        s.STORE_NAME as KROGER_CHEAPEST_STORE_NAME,
        s.CITY as KROGER_CHEAPEST_STORE_CITY,
        k.KROGER_STORES_PRICED,
        k.KROGER_STORES_ON_PROMO,
        w.WALMART_DATA_AS_OF,
        k.KROGER_DATA_AS_OF

    from {{ ref('int_retailer_common_upcs') }} u
    left join kroger k
        on k.KROGER_PRODUCT_ID = u.KROGER_PRODUCT_ID
    left join walmart w
        on w.WALMART_ITEM_ID = u.WALMART_ITEM_ID
    left join {{ ref('dim_store') }} s
        on s.STORE_ID = k.KROGER_CHEAPEST_STORE_ID
    left join {{ ref('dim_product') }} kp
        on kp.RETAILER = 'kroger'
        and kp.PRODUCT_ID = u.KROGER_PRODUCT_ID

)

select
    *,
    WALMART_PRICE is not null and KROGER_MIN_PRICE is not null as IS_PRICED_AT_BOTH,
    case
        when WALMART_PRICE is null or KROGER_MIN_PRICE is null then null
        when WALMART_PRICE < KROGER_MIN_PRICE then 'walmart'
        when KROGER_MIN_PRICE < WALMART_PRICE then 'kroger'
        else 'tie'
    end as CHEAPER_RETAILER,
    abs(WALMART_PRICE - KROGER_MIN_PRICE) as SAVINGS_VS_KROGER_MIN,
    round(abs(WALMART_PRICE - KROGER_MIN_PRICE) / nullif(greatest(WALMART_PRICE, KROGER_MIN_PRICE), 0), 4) as SAVINGS_VS_KROGER_MIN_PCT,
    case
        when WALMART_PRICE is null or KROGER_MEDIAN_PRICE is null then null
        when WALMART_PRICE < KROGER_MEDIAN_PRICE then 'walmart'
        when KROGER_MEDIAN_PRICE < WALMART_PRICE then 'kroger'
        else 'tie'
    end as CHEAPER_RETAILER_VS_MEDIAN,
    WALMART_PRICE - KROGER_MEDIAN_PRICE as WALMART_MINUS_KROGER_MEDIAN

from compared
