{{ config(materialized='view') }}

with source as (

    select * from {{ source('kroger', 'kroger_product_catalog') }}

),

renamed as (

    select
        "productId" as PRODUCT_ID,
        "upc" as UPC,
        "brand" as BRAND,
        "description" as DESCRIPTION,
        "categories" as CATEGORIES,
        "countryOrigin" as COUNTRY_ORIGIN,
        "temperature" as TEMPERATURE,
        "size" as SIZE,
        "soldBy" as SOLD_BY,
        "image_url" as IMAGE_URL,
        "collected_at" as COLLECTED_AT,
        "INGESTED_FILENAME"

    from source

)

select * from renamed
