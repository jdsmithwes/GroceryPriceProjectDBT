{{ config(materialized='ephemeral') }}

-- Kroger_Pricing_*.py and Kroger_Inventory_*.py both call the identical
-- /v1/products endpoint and land the identical raw response (see the NOTE
-- in Kroger_Pricing_*.py) — the only real difference between
-- RAW.KROGER_PRICING and RAW.KROGER_INVENTORY is which pipeline collected
-- the row. Unioned here into one model instead of two parallel ones;
-- SOURCE_PIPELINE preserves that provenance downstream.

with pricing as (

    select
        PRODUCTID as PRODUCT_ID,
        LOCATIONID as LOCATION_ID,
        RAW_DATA,
        COLLECTED_AT,
        INGESTED_FILENAME,
        'pricing' as SOURCE_PIPELINE

    from {{ source('kroger', 'kroger_pricing') }}

),

inventory as (

    select
        PRODUCTID as PRODUCT_ID,
        LOCATIONID as LOCATION_ID,
        RAW_DATA,
        COLLECTED_AT,
        INGESTED_FILENAME,
        'inventory' as SOURCE_PIPELINE

    from {{ source('kroger', 'kroger_inventory') }}

)

select * from pricing
union all
select * from inventory
