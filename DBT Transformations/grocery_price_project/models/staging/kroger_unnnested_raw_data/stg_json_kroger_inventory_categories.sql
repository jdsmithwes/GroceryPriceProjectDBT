{{ config(materialized='view') }}

-- Fans out CATEGORIES (array of plain strings). Grain: one row per
-- product + category.

with source as (

    select * from {{ ref('stg_json_kroger_inventory') }}

)

select
    LOCATION_ID,
    PRODUCT_ID,
    COLLECTED_AT,
    INGESTED_FILENAME,
    c.value::string as CATEGORY

from source,
lateral flatten(input => CATEGORIES) c
