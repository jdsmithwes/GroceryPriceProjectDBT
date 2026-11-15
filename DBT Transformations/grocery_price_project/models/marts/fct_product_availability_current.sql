{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- One row per product x store: stock and fulfillment as of the LAST
-- COLLECTION (weekly), not live. Answers must say "as of <DATA_AS_OF>".
--
-- AVAILABILITY_STATUS normalizes each retailer's labels:
--   Kroger STOCK_LEVEL: HIGH -> in_stock, LOW -> low_stock,
--     TEMPORARILY_OUT_OF_STOCK -> out_of_stock, null -> unknown.
--   Walmart STOCK: Available -> in_stock; Limited supply / Last Few Items ->
--     low_stock; Not available -> not_available_online. ~98% of Walmart
--     catalog rows say "Not available" while still carrying a price, so this
--     is an online-shipping flag, not store availability — never present it
--     as "out of stock at Walmart".

with kroger as (

    select
        'kroger' as RETAILER,
        PRODUCT_ID,
        LOCATION_ID as STORE_ID,
        STOCK_LEVEL as SOURCE_STOCK_LABEL,
        case STOCK_LEVEL
            when 'HIGH' then 'in_stock'
            when 'LOW' then 'low_stock'
            when 'TEMPORARILY_OUT_OF_STOCK' then 'out_of_stock'
            else 'unknown'
        end as AVAILABILITY_STATUS,
        IN_STORE as IS_AVAILABLE_IN_STORE,
        CURBSIDE as IS_CURBSIDE_AVAILABLE,
        DELIVERY as IS_DELIVERY_AVAILABLE,
        SHIP_TO_HOME as IS_SHIP_TO_HOME_AVAILABLE,
        null::boolean as IS_CLEARANCE,
        COLLECTED_AT as DATA_AS_OF

    from {{ ref('int_kroger_items_current') }}

),

walmart as (

    select
        'walmart' as RETAILER,
        ITEM_ID as PRODUCT_ID,
        'walmart_national' as STORE_ID,
        STOCK as SOURCE_STOCK_LABEL,
        case STOCK
            when 'Available' then 'in_stock'
            when 'Limited supply' then 'low_stock'
            when 'Last Few Items' then 'low_stock'
            when 'Not available' then 'not_available_online'
            else 'unknown'
        end as AVAILABILITY_STATUS,
        null::boolean as IS_AVAILABLE_IN_STORE,
        null::boolean as IS_CURBSIDE_AVAILABLE,
        null::boolean as IS_DELIVERY_AVAILABLE,
        null::boolean as IS_SHIP_TO_HOME_AVAILABLE,
        try_to_boolean(CLEARANCE) as IS_CLEARANCE,
        COLLECTED_AT as DATA_AS_OF

    from {{ ref('stg_walmart_product_catalog') }}
    qualify row_number() over (
        partition by ITEM_ID
        order by COLLECTED_AT desc, INGESTED_FILENAME desc
    ) = 1

)

select RETAILER || ':' || PRODUCT_ID as PRODUCT_KEY, *
from (
    select * from kroger
    union all
    select * from walmart
)
