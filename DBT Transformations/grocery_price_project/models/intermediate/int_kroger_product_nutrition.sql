-- Dynamic table, not a view: a dynamic table (dim_product_diet) cannot read a
-- view that itself reads a dynamic table (Snowflake 002727, found 2026-11-27).
{{ config(
    materialized='dynamic_table',
    target_lag='downstream',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- Nutrition facts per Kroger product, one row per PRODUCT_ID, from the
-- latest snapshot (int_kroger_product_latest_snapshot). 599 of ~8,400
-- products carry more than one nutrition entry (as sold vs prepared); the
-- entry used is the one closest to "as sold" (Unprepared, Unspecified,
-- Ready to Eat, Ready to Drink, Prepared), then the one with the most
-- nutrients. Nutrient codes verified against the live data (2026-11-27):
-- ENER- calories, NA sodium (MGM), SUGAD added sugar, FASAT saturated fat,
-- FATRN trans fat, FAT total fat, SUGAR/SUGAR- total sugar, CHO- carbs,
-- FIBTSW fiber, PRO- protein, CHOL- cholesterol, K, CA, FE. Quantities are
-- per labelled serving; a unit of GRM on sodium or cholesterol is
-- converted to mg. The ingredient statement and Kroger's 1-100
-- nutritional rating sit on the same entry.

with entries as (

    select
        s.PRODUCT_ID,
        s.COLLECTED_AT,
        n.index as ENTRY_INDEX,
        n.value as entry

    from {{ ref('int_kroger_product_latest_snapshot') }} s,
    lateral flatten(input => s.NUTRITION_INFORMATION) n

),

chosen as (

    select
        *,
        case entry:"preparationState"."name"::string
            when 'Unprepared' then 1
            when 'Unspecified' then 2
            when 'Ready to Eat' then 3
            when 'Ready to Drink' then 4
            when 'Prepared' then 5
            else 6
        end as PREP_RANK,
        coalesce(array_size(entry:"nutrients"), 0) as NUTRIENT_COUNT

    from entries
    qualify row_number() over (
        partition by PRODUCT_ID
        order by PREP_RANK, NUTRIENT_COUNT desc, ENTRY_INDEX
    ) = 1

),

nutrients as (

    select
        c.PRODUCT_ID,
        nu.value:"code"::string as CODE,
        try_to_double(nu.value:"quantity"::string) as QUANTITY,   -- some are objects ({"description":"Approximately"})
        nu.value:"unitOfMeasure"."code"::string as UNIT_CODE

    from chosen c,
    lateral flatten(input => c.entry:"nutrients") nu

),

pivoted as (

    select
        PRODUCT_ID,
        max(iff(CODE = 'ENER-', QUANTITY, null)) as CALORIES,
        max(iff(CODE = 'NA', iff(UNIT_CODE = 'GRM', QUANTITY * 1000, QUANTITY), null)) as SODIUM_MG,
        max(iff(CODE = 'SUGAD', QUANTITY, null)) as ADDED_SUGAR_G,
        max(iff(CODE in ('SUGAR', 'SUGAR-'), QUANTITY, null)) as TOTAL_SUGAR_G,
        max(iff(CODE = 'FASAT', QUANTITY, null)) as SATURATED_FAT_G,
        max(iff(CODE = 'FATRN', QUANTITY, null)) as TRANS_FAT_G,
        max(iff(CODE = 'FAT', QUANTITY, null)) as TOTAL_FAT_G,
        max(iff(CODE = 'CHO-', QUANTITY, null)) as CARBOHYDRATE_G,
        max(iff(CODE = 'FIBTSW', QUANTITY, null)) as FIBER_G,
        max(iff(CODE = 'PRO-', QUANTITY, null)) as PROTEIN_G,
        max(iff(CODE = 'CHOL-', iff(UNIT_CODE = 'GRM', QUANTITY * 1000, QUANTITY), null)) as CHOLESTEROL_MG,
        max(iff(CODE = 'K', QUANTITY, null)) as POTASSIUM_MG,
        max(iff(CODE = 'CA', QUANTITY, null)) as CALCIUM_MG,
        max(iff(CODE = 'FE', QUANTITY, null)) as IRON_MG

    from nutrients
    group by PRODUCT_ID

)

select
    c.PRODUCT_ID,
    c.COLLECTED_AT as NUTRITION_AS_OF,
    c.entry:"ingredientStatement"::string as INGREDIENT_STATEMENT,
    try_to_number(c.entry:"nutritionalRating"::string) as NUTRITIONAL_RATING,
    c.entry:"preparationState"."name"::string as PREPARATION_STATE,
    try_to_double(c.entry:"servingsPerPackage"::string) as SERVINGS_PER_PACKAGE,
    try_to_double(c.entry:"servingSize"."quantity"::string) as SERVING_SIZE_QUANTITY,
    c.entry:"servingSize"."unitOfMeasure"."abbreviation"::string as SERVING_SIZE_UNIT,
    c.NUTRIENT_COUNT,
    p.CALORIES,
    p.SODIUM_MG,
    p.ADDED_SUGAR_G,
    p.TOTAL_SUGAR_G,
    p.SATURATED_FAT_G,
    p.TRANS_FAT_G,
    p.TOTAL_FAT_G,
    p.CARBOHYDRATE_G,
    p.FIBER_G,
    p.PROTEIN_G,
    p.CHOLESTEROL_MG,
    p.POTASSIUM_MG,
    p.CALCIUM_MG,
    p.IRON_MG

from chosen c
left join pivoted p
    on p.PRODUCT_ID = c.PRODUCT_ID
