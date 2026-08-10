{{ config(materialized='view') }}

-- Fans out ALLERGENS (array of fixed-shape objects). Grain: one row per
-- product + allergen. Keys verified against the live data.

with source as (

    select * from {{ ref('stg_json_kroger_pricing') }}

)

select
    LOCATION_ID,
    PRODUCT_ID,
    COLLECTED_AT,
    INGESTED_FILENAME,
    a.value:"levelOfContainmentName"::string as LEVEL_OF_CONTAINMENT_NAME,
    a.value:"name"::string as ALLERGEN_NAME

from source,
lateral flatten(input => ALLERGENS) a
