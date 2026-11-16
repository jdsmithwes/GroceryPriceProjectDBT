{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- One row per place a price applies (ontology: Store). Kroger prices are
-- per store, so each Kroger location is a row. Walmart's catalog prices are
-- national, so Walmart is a single virtual store, 'walmart_national' — every
-- Walmart price row in the marts points at it.

with kroger as (

    select
        'kroger' as RETAILER,
        LOCATION_ID as STORE_ID,
        NAME as STORE_NAME,
        CHAIN,
        ADDRESS_LINE1 as ADDRESS,
        CITY,
        STATE,
        ZIP_CODE,
        LATITUDE::number(9, 6) as LATITUDE,
        LONGITUDE::number(9, 6) as LONGITUDE,
        REGION,
        false as IS_VIRTUAL_STORE,
        COLLECTED_AT as DATA_AS_OF

    from {{ ref('int_kroger_locations_current') }}

),

walmart as (

    select
        'walmart' as RETAILER,
        'walmart_national' as STORE_ID,
        'Walmart (national online)' as STORE_NAME,
        'WALMART' as CHAIN,
        null::varchar as ADDRESS,
        null::varchar as CITY,
        null::varchar as STATE,
        null::varchar as ZIP_CODE,
        null::number(9, 6) as LATITUDE,
        null::number(9, 6) as LONGITUDE,
        'National' as REGION,
        true as IS_VIRTUAL_STORE,
        max(COLLECTED_AT) as DATA_AS_OF

    from {{ ref('stg_walmart_product_catalog') }}

)

select * from kroger
union all
select * from walmart
