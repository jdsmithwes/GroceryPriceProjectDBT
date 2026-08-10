{{ config(materialized='view') }}

-- Fans out SWEETENING_METHODS (array of fixed-shape objects). Grain: one
-- row per product + sweetening method. Keys verified against the live data.

with source as (

    select * from {{ ref('stg_json_kroger_inventory') }}

)

select
    LOCATION_ID,
    PRODUCT_ID,
    COLLECTED_AT,
    INGESTED_FILENAME,
    s.value:"code"::string as SWEETENING_METHOD_CODE,
    s.value:"name"::string as SWEETENING_METHOD_NAME

from source,
lateral flatten(input => SWEETENING_METHODS) s
