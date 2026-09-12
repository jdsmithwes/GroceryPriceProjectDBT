{{ config(materialized='view') }}

-- Fans out AISLE_LOCATIONS (array of fixed-shape objects). Grain: one row
-- per product + aisle location. Keys verified against the live data.

with source as (

    select * from {{ ref('stg_json_kroger_product_snapshot') }}

)

select
    LOCATION_ID,
    PRODUCT_ID,
    SOURCE_PIPELINE,
    COLLECTED_AT,
    INGESTED_FILENAME,
    a.value:"bayNumber"::string as BAY_NUMBER,
    a.value:"description"::string as AISLE_DESCRIPTION,
    a.value:"number"::string as AISLE_NUMBER,
    a.value:"numberOfFacings"::number as NUMBER_OF_FACINGS,
    a.value:"side"::string as SIDE,
    a.value:"shelfNumber"::string as SHELF_NUMBER,
    a.value:"shelfPositionInBay"::string as SHELF_POSITION_IN_BAY

from source,
lateral flatten(input => AISLE_LOCATIONS) a
