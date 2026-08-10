{{ config(materialized='view') }}

-- Fans out IMAGES (array of objects), each of which has its own nested
-- SIZES array — a two-level flatten. Grain: one row per
-- product + image + size. Keys verified against the live data.

with source as (

    select * from {{ ref('stg_json_kroger_inventory') }}

),

images as (

    select
        LOCATION_ID,
        PRODUCT_ID,
        COLLECTED_AT,
        INGESTED_FILENAME,
        i.value as image

    from source,
    lateral flatten(input => IMAGES) i

)

select
    LOCATION_ID,
    PRODUCT_ID,
    COLLECTED_AT,
    INGESTED_FILENAME,
    image:"perspective"::string as PERSPECTIVE,
    image:"featured"::boolean as FEATURED,
    s.value:"size"::string as IMAGE_SIZE,
    s.value:"url"::string as IMAGE_URL

from images,
lateral flatten(input => image:sizes) s
