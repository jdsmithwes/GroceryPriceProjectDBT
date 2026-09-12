{{ config(materialized='view', schema='staging_walmart') }}

-- Layer 1 thin rename over RAW_WALMART.WALMART_PRODUCT_CATALOG, same grain
-- as raw (append-only across collection runs — ITEMID alone is not unique
-- here, only unique per collection run). MSRP/SALEPRICE are cast to NUMBER
-- here (the raw table stores every column as VARCHAR per the project's
-- raw-landing convention) since int_walmart_price_history's change
-- detection needs real numeric comparison, not string comparison.

with source as (

    select * from {{ source('walmart', 'walmart_product_catalog') }}

),

renamed as (

    select
        ITEMID as ITEM_ID,
        PARENTITEMID as PARENT_ITEM_ID,
        UPC,
        NAME,
        BRANDNAME as BRAND_NAME,
        CATEGORYPATH as CATEGORY_PATH,
        CATEGORYNODE as CATEGORY_NODE,
        MSRP::number(10, 2) as MSRP,
        SALEPRICE::number(10, 2) as SALE_PRICE,
        LONGDESCRIPTION as LONG_DESCRIPTION,
        STOCK,
        MARKETPLACE,
        SELLERINFO as SELLER_INFO,
        CUSTOMERRATING as CUSTOMER_RATING,
        NUMREVIEWS as NUM_REVIEWS,
        CLEARANCE,
        MEDIUMIMAGE as MEDIUM_IMAGE,
        PRODUCTTRACKINGURL as PRODUCT_TRACKING_URL,
        COLLECTED_AT,
        INGESTED_FILENAME

    from source

)

select * from renamed
