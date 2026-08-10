{{ config(materialized='ephemeral') }}

with source as (

    select * from {{ source('kroger', 'kroger_locations') }}

),

renamed as (

    select
        LOCATIONID as LOCATION_ID,
        REGION,
        RAW_DATA,
        COLLECTED_AT,
        INGESTED_FILENAME

    from source

)

select * from renamed
