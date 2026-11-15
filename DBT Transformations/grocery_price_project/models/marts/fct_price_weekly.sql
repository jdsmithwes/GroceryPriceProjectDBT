{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- One row per product x store x week that was actually observed
-- (ontology: Price Observation). PRICE_WEEK is the Monday of the
-- collection week (Kroger's Friday sweep and Saturday continuation land in
-- the same week).
--
-- Built from collection-level staging rows, NOT by expanding the SCD price
-- spans in int_*_price_history: a span covering a collection outage would
-- invent weeks nobody observed. Weeks with no collection (e.g. the
-- 2026-10-17 -> 2026-11-14 scheduler outage) are simply absent here.
--
-- Price semantics (Agent/ONTOLOGY.md):
--   Kroger:  REGULAR = regular; PROMO = promo only when it's actually below
--            regular (13k historical rows carry a "promo" >= regular, which
--            isn't a discount).
--   Walmart: REGULAR = MSRP (list price; null for most items); PROMO = sale
--            price when it's below MSRP. EFFECTIVE = sale price, else MSRP.
--   EFFECTIVE_PRICE is what a shopper pays that week.

with kroger_obs as (

    select
        PRODUCT_ID,
        LOCATION_ID as STORE_ID,
        COLLECTED_AT,
        PRICE_REGULAR::number(10, 2) as REGULAR_PRICE,
        PRICE_PROMO::number(10, 2) as RAW_PROMO_PRICE

    from {{ ref('stg_json_kroger_product_snapshot_items') }}
    where PRICE_REGULAR is not null or PRICE_PROMO is not null
    qualify row_number() over (
        partition by PRODUCT_ID, LOCATION_ID, date_trunc('week', COLLECTED_AT)
        order by COLLECTED_AT desc, SOURCE_PIPELINE, ITEM_ID
    ) = 1

),

kroger as (

    select
        'kroger' as RETAILER,
        PRODUCT_ID,
        STORE_ID,
        date_trunc('week', COLLECTED_AT)::date as PRICE_WEEK,
        COLLECTED_AT as OBSERVED_AT,
        REGULAR_PRICE,
        iff(RAW_PROMO_PRICE < REGULAR_PRICE or REGULAR_PRICE is null, RAW_PROMO_PRICE, null) as PROMO_PRICE

    from kroger_obs

),

walmart_obs as (

    select
        ITEM_ID as PRODUCT_ID,
        COLLECTED_AT,
        MSRP,
        SALE_PRICE

    from {{ ref('stg_walmart_product_catalog') }}
    where MSRP is not null or SALE_PRICE is not null
    qualify row_number() over (
        partition by ITEM_ID, date_trunc('week', COLLECTED_AT)
        order by COLLECTED_AT desc, INGESTED_FILENAME desc
    ) = 1

),

walmart as (

    select
        'walmart' as RETAILER,
        PRODUCT_ID,
        'walmart_national' as STORE_ID,
        date_trunc('week', COLLECTED_AT)::date as PRICE_WEEK,
        COLLECTED_AT as OBSERVED_AT,
        MSRP as REGULAR_PRICE,
        iff(SALE_PRICE < MSRP, SALE_PRICE, null) as PROMO_PRICE,
        coalesce(SALE_PRICE, MSRP) as EFFECTIVE_PRICE

    from walmart_obs

),

unioned as (

    select *, coalesce(PROMO_PRICE, REGULAR_PRICE) as EFFECTIVE_PRICE from kroger
    union all
    select * from walmart

)

select
    RETAILER || ':' || PRODUCT_ID as PRODUCT_KEY,
    RETAILER,
    PRODUCT_ID,
    STORE_ID,
    PRICE_WEEK,
    OBSERVED_AT,
    REGULAR_PRICE,
    PROMO_PRICE,
    EFFECTIVE_PRICE,
    PROMO_PRICE is not null as IS_ON_PROMO,
    iff(PROMO_PRICE is not null and REGULAR_PRICE > 0,
        round(1 - PROMO_PRICE / REGULAR_PRICE, 4), null) as DISCOUNT_PCT

from unioned
