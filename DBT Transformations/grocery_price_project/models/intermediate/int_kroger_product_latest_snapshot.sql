{{ config(
    materialized='dynamic_table',
    target_lag='downstream',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- The most recent Kroger product object per PRODUCT_ID, with only the
-- store-independent arrays the healthy-week basket needs (declarations,
-- allergens, nutrition). Grain: one row per PRODUCT_ID (~11.7k rows).
--
-- Why not stg_json_kroger_product_snapshot: that view parses RAW_DATA for
-- every snapshot row (800k rows a week, all stores), and the parse happens
-- before any "latest per product" filter can. Here the window function
-- runs on the unparsed rows of the last 10 days of collection (the raw
-- COLLECTED_AT column), and PARSE_JSON touches ~11.7k rows: ~10 s on XS
-- (timed 2026-11-27) instead of minutes. Product attributes are the same
-- at every store, so one row per product is enough.
--
-- target_lag 'downstream': refreshes only when dim_product_diet does, and
-- Snowflake skips the refresh when no new raw rows landed.

with source as (

    select
        PRODUCT_ID,
        COLLECTED_AT,
        RAW_DATA

    from {{ ref('stg_kroger_product_snapshot') }}
    where COLLECTED_AT >= (
        select dateadd('day', -10, max(COLLECTED_AT))
        from {{ ref('stg_kroger_product_snapshot') }}
    )
    qualify row_number() over (
        partition by PRODUCT_ID
        order by COLLECTED_AT desc
    ) = 1

),

parsed as (

    select
        PRODUCT_ID,
        COLLECTED_AT,
        parse_json(RAW_DATA) as json_data

    from source

)

select
    PRODUCT_ID,
    COLLECTED_AT,
    json_data:"manufacturerDeclarations" as MANUFACTURER_DECLARATIONS,
    json_data:"allergens" as ALLERGENS,
    json_data:"nutritionInformation" as NUTRITION_INFORMATION,
    json_data:"organicClaimName"::string as ORGANIC_CLAIM_NAME,
    json_data:"allergensDescription"::string as ALLERGENS_DESCRIPTION,
    json_data:"certifiedForPassover"::boolean as CERTIFIED_FOR_PASSOVER

from parsed
