{{ config(materialized='view') }}

-- Fans out MANUFACTURER_DECLARATIONS (array of plain strings). Grain: one
-- row per product + declaration.

with source as (

    select * from {{ ref('stg_json_kroger_inventory') }}

)

select
    LOCATION_ID,
    PRODUCT_ID,
    COLLECTED_AT,
    INGESTED_FILENAME,
    m.value::string as MANUFACTURER_DECLARATION

from source,
lateral flatten(input => MANUFACTURER_DECLARATIONS) m
