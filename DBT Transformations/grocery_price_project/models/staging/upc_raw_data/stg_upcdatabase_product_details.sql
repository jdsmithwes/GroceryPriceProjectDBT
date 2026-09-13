{{ config(materialized='view', schema='staging_upc') }}

-- Same grain as raw (one row per lookup attempt). upcdatabase.org returns every
-- value as a string, and blanks mean unknown. Not modeled because they were empty
-- for all 90 products found on 2026-09-13: msrp (always "0.00"), alias,
-- manufacturer, ASIN, images, stores. Nutrition keys follow Open Food Facts naming
-- and many contain hyphens, so they need quoted JSON paths.

with source as (

    select
        *,
        try_parse_json(RAW_DATA) as json_data

    from {{ source('upc', 'upcdatabase_product_details') }}

)

select
    UPC,
    KROGER_PRODUCT_ID,
    WALMART_ITEM_ID,
    LOOKUP_STATUS,
    try_to_number(HTTP_STATUS) as HTTP_STATUS,
    try_to_number(API_LOOKUPS_REMAINING) as API_LOOKUPS_REMAINING,
    COLLECTED_AT,
    INGESTED_FILENAME,

    ---------- product
    nullif(json_data:"barcode"::string, '') as BARCODE,
    nullif(json_data:"title"::string, '') as TITLE,
    nullif(json_data:"description"::string, '') as DESCRIPTION,
    nullif(json_data:"brand"::string, '') as BRAND,
    nullif(json_data:"category"::string, '') as UPCDB_CATEGORY,
    nullif(json_data:"categories"::string, '') as UPCDB_CATEGORIES,
    try_to_timestamp_ntz(json_data:"added_time"::string) as UPCDB_ADDED_AT,
    try_to_timestamp_ntz(json_data:"modified_time"::string) as UPCDB_MODIFIED_AT,

    ---------- metadata
    nullif(json_data:"metadata":"quantity"::string, '') as QUANTITY,
    nullif(json_data:"metadata":"countries"::string, '') as COUNTRIES,
    nullif(json_data:"metadata":"ingredients"::string, '') as INGREDIENTS,

    ---------- nutrition per 100g
    try_to_double(json_data:"metanutrition":"energy-kcal_100g"::string) as ENERGY_KCAL_100G,
    try_to_double(json_data:"metanutrition":"fat_100g"::string) as FAT_100G,
    try_to_double(json_data:"metanutrition":"saturated-fat_100g"::string) as SATURATED_FAT_100G,
    try_to_double(json_data:"metanutrition":"carbohydrates_100g"::string) as CARBOHYDRATES_100G,
    try_to_double(json_data:"metanutrition":"sugars_100g"::string) as SUGARS_100G,
    try_to_double(json_data:"metanutrition":"fiber_100g"::string) as FIBER_100G,
    try_to_double(json_data:"metanutrition":"proteins_100g"::string) as PROTEINS_100G,
    try_to_double(json_data:"metanutrition":"salt_100g"::string) as SALT_100G,
    try_to_double(json_data:"metanutrition":"sodium_100g"::string) as SODIUM_100G,
    try_to_number(json_data:"metanutrition":"nova-group"::string) as NOVA_GROUP,
    try_to_number(json_data:"metanutrition":"nutrition-score-fr_100g"::string) as NUTRITION_SCORE_FR_100G,

    ---------- kept as VARIANT
    json_data:"metanutrition" as METANUTRITION

from source
