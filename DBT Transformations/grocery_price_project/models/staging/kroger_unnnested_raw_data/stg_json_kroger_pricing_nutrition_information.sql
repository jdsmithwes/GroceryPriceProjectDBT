{{ config(materialized='view') }}

-- Fans out NUTRITION_INFORMATION (array of objects), each of which has
-- its own nested NUTRIENTS array — a two-level flatten, the deepest
-- structure in this dataset. Grain: one row per product + nutrition
-- entry + nutrient. Fields from the nutrition-entry level (e.g.
-- INGREDIENT_STATEMENT, SERVING_SIZE_*) repeat across every nutrient row
-- for that entry — expected denormalization from flattening to this
-- grain, not a bug. Keys verified against the live data.

with source as (

    select * from {{ ref('stg_json_kroger_pricing') }}

),

nutrition_entries as (

    select
        LOCATION_ID,
        PRODUCT_ID,
        COLLECTED_AT,
        INGESTED_FILENAME,
        n.value as nutrition_entry

    from source,
    lateral flatten(input => NUTRITION_INFORMATION) n

)

select
    LOCATION_ID,
    PRODUCT_ID,
    COLLECTED_AT,
    INGESTED_FILENAME,

    ---------- nutrition-entry-level scalars
    nutrition_entry:"ingredientStatement"::string as INGREDIENT_STATEMENT,
    nutrition_entry:"dailyValueIntakeReference"::string as DAILY_VALUE_INTAKE_REFERENCE,
    nutrition_entry:"nutritionalRating"::string as NUTRITIONAL_RATING,
    nutrition_entry:"servingsPerPackage"::float as SERVINGS_PER_PACKAGE,

    ---------- preparationState (flattened)
    nutrition_entry:"preparationState"."code"::string as PREPARATION_STATE_CODE,
    nutrition_entry:"preparationState"."name"::string as PREPARATION_STATE_NAME,

    ---------- servingSize (flattened, incl. nested unitOfMeasure)
    nutrition_entry:"servingSize"."quantity"::float as SERVING_SIZE_QUANTITY,
    nutrition_entry:"servingSize"."unitOfMeasure"."abbreviation"::string as SERVING_SIZE_UNIT_ABBREVIATION,
    nutrition_entry:"servingSize"."unitOfMeasure"."code"::string as SERVING_SIZE_UNIT_CODE,
    nutrition_entry:"servingSize"."unitOfMeasure"."name"::string as SERVING_SIZE_UNIT_NAME,

    ---------- nutrient (fanned out, incl. nested precision/unitOfMeasure)
    nu.value:"code"::string as NUTRIENT_CODE,
    nu.value:"description"::string as NUTRIENT_DESCRIPTION,
    nu.value:"displayName"::string as NUTRIENT_DISPLAY_NAME,
    nu.value:"percentDailyIntake"::number as NUTRIENT_PERCENT_DAILY_INTAKE,
    nu.value:"quantity"::float as NUTRIENT_QUANTITY,
    nu.value:"precision"."code"::string as NUTRIENT_PRECISION_CODE,
    nu.value:"precision"."name"::string as NUTRIENT_PRECISION_NAME,
    nu.value:"unitOfMeasure"."code"::string as NUTRIENT_UNIT_CODE,
    nu.value:"unitOfMeasure"."name"::string as NUTRIENT_UNIT_NAME

from nutrition_entries,
lateral flatten(input => nutrition_entry:nutrients) nu
