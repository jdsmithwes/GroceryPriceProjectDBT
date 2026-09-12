{{ config(materialized='view') }}

-- Fans out ALIAS_PRODUCT_IDS (array of plain strings). Grain: one row per
-- product + alias id.

with source as (

    select * from {{ ref('stg_json_kroger_product_snapshot') }}

)

select
    LOCATION_ID,
    PRODUCT_ID,
    SOURCE_PIPELINE,
    COLLECTED_AT,
    INGESTED_FILENAME,
    a.value::string as ALIAS_PRODUCT_ID

from source,
lateral flatten(input => ALIAS_PRODUCT_IDS) a
