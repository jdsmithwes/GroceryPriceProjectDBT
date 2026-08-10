{{ config(materialized='ephemeral') }}

with source as (

    select * from {{ source('kroger', 'kroger_inventory') }}

),

renamed as (

    select
        PRODUCTID as PRODUCT_ID,
        LOCATIONID as LOCATION_ID,
        RAW_DATA,
        COLLECTED_AT,
        INGESTED_FILENAME

    from source

)

select * from renamed
    