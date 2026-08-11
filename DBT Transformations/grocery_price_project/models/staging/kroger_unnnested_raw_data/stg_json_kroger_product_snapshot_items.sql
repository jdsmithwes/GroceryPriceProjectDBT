{{ config(materialized='view') }}

-- Fans out ITEMS (array of objects) — this is the field carrying the
-- actual per-store price and inventory data these pipelines exist
-- for. Grain: one row per product + item variant (in practice, almost
-- always exactly one item per product, but the API allows more). Nested
-- price/inventory/fulfillment objects, and price's nested
-- effectiveDate/expirationDate objects, are all flattened inline — no
-- further arrays inside ITEMS, so this is a full, single-pass flatten.
-- Keys verified against the live data.

with source as (

    select * from {{ ref('stg_json_kroger_product_snapshot') }}

)

select
    LOCATION_ID,
    PRODUCT_ID,
    SOURCE_PIPELINE,
    COLLECTED_AT,
    INGESTED_FILENAME,

    i.value:"itemId"::string as ITEM_ID,
    i.value:"favorite"::boolean as FAVORITE,
    i.value:"size"::string as ITEM_SIZE,
    i.value:"soldBy"::string as SOLD_BY,

    ---------- inventory
    i.value:"inventory"."stockLevel"::string as STOCK_LEVEL,

    ---------- fulfillment
    i.value:"fulfillment"."curbside"::boolean as CURBSIDE,
    i.value:"fulfillment"."delivery"::boolean as DELIVERY,
    i.value:"fulfillment"."inStore"::boolean as IN_STORE,
    i.value:"fulfillment"."shipToHome"::boolean as SHIP_TO_HOME,

    ---------- price
    i.value:"price"."regular"::float as PRICE_REGULAR,
    i.value:"price"."regularPerUnitEstimate"::float as PRICE_REGULAR_PER_UNIT_ESTIMATE,
    i.value:"price"."promo"::float as PRICE_PROMO,
    i.value:"price"."promoPerUnitEstimate"::float as PRICE_PROMO_PER_UNIT_ESTIMATE,
    i.value:"price"."effectiveDate"."value"::string as PRICE_EFFECTIVE_DATE_VALUE,
    i.value:"price"."effectiveDate"."timezone"::string as PRICE_EFFECTIVE_DATE_TIMEZONE,
    i.value:"price"."expirationDate"."value"::string as PRICE_EXPIRATION_DATE_VALUE,
    i.value:"price"."expirationDate"."timezone"::string as PRICE_EXPIRATION_DATE_TIMEZONE

from source,
lateral flatten(input => ITEMS) i
