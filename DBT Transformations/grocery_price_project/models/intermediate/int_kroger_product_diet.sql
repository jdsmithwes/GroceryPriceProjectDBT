-- Dynamic table, not a view: a dynamic table (dim_product_diet) cannot read a
-- view that itself reads a dynamic table (Snowflake 002727, found 2026-11-27).
{{ config(
    materialized='dynamic_table',
    target_lag='downstream',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- Diet evidence per Kroger product, one row per PRODUCT_ID, from the latest
-- snapshot: the manufacturer's declarations (Kosher, Vegan, Vegetarian,
-- Halal, Gluten Free, Organic, ...), the allergen "Contains" flags, and
-- ingredient-text flags found by regex in the ingredient statement
-- (int_kroger_product_nutrition). Every flag is evidence, not a verdict:
-- dim_product_diet turns them into diet statuses with a provenance label.
--
-- Ingredient regexes strip the usual false friends first (coconut milk,
-- peanut butter, cocoa butter, cream of tartar, wine vinegar, vanilla
-- extract, ginger ale, oyster mushrooms) and match on word boundaries.
-- Declaration counts 2026-11-27, all products: Kosher 3,945, Vegan 1,736,
-- Vegetarian 365, Halal 61 (so "halal" is never claimed from data alone).

with latest as (

    select * from {{ ref('int_kroger_product_latest_snapshot') }}

),

declarations as (

    select
        s.PRODUCT_ID,
        array_agg(distinct d.value::string) within group (order by d.value::string) as DECLARATIONS

    from latest s,
    lateral flatten(input => s.MANUFACTURER_DECLARATIONS) d
    group by s.PRODUCT_ID

),

allergens as (

    select
        s.PRODUCT_ID,
        count_if(a.value:"levelOfContainmentName"::string = 'Contains' and a.value:"name"::string ilike 'Milk%') > 0 as CONTAINS_MILK,
        count_if(a.value:"levelOfContainmentName"::string = 'Contains' and a.value:"name"::string ilike 'Eggs%') > 0 as CONTAINS_EGG,
        count_if(a.value:"levelOfContainmentName"::string = 'Contains' and a.value:"name"::string ilike 'Fish%') > 0 as CONTAINS_FISH,
        count_if(a.value:"levelOfContainmentName"::string = 'Contains'
                 and (a.value:"name"::string ilike 'Crustaceans%' or a.value:"name"::string ilike 'Molluscs%'
                      or a.value:"name"::string ilike 'Shellfish%')) > 0 as CONTAINS_SHELLFISH,
        count_if(a.value:"levelOfContainmentName"::string = 'Contains'
                 and (a.value:"name"::string ilike 'Wheat%' or a.value:"name"::string ilike 'Cereals%'
                      or a.value:"name"::string ilike 'Barley%' or a.value:"name"::string ilike 'Other Gluten%')) > 0 as CONTAINS_GLUTEN_GRAIN,
        count_if(a.value:"levelOfContainmentName"::string = 'Contains'
                 and (a.value:"name"::string ilike 'Peanuts%' or a.value:"name"::string ilike 'Tree Nuts%'
                      or a.value:"name"::string ilike '%Almond%' or a.value:"name"::string ilike '%Cashew%'
                      or a.value:"name"::string ilike '%Hazelnut%' or a.value:"name"::string ilike '%Brazil Nut%'
                      or a.value:"name"::string ilike '%Walnut%' or a.value:"name"::string ilike '%Pecan%'
                      or a.value:"name"::string ilike '%Pistachio%' or a.value:"name"::string ilike '%Macadamia%')) > 0 as CONTAINS_NUTS,
        count_if(a.value:"levelOfContainmentName"::string = 'Contains' and a.value:"name"::string ilike 'Soybean%') > 0 as CONTAINS_SOY,
        count_if(a.value:"levelOfContainmentName"::string = 'Contains' and a.value:"name"::string ilike 'Sesame%') > 0 as CONTAINS_SESAME,
        array_agg(distinct iff(a.value:"levelOfContainmentName"::string = 'Contains', a.value:"name"::string, null))
            within group (order by iff(a.value:"levelOfContainmentName"::string = 'Contains', a.value:"name"::string, null)) as CONTAINS_ALLERGENS

    from latest s,
    lateral flatten(input => s.ALLERGENS) a
    group by s.PRODUCT_ID

),

ingredients as (

    select
        PRODUCT_ID,
        INGREDIENT_STATEMENT,
        -- false friends removed before the animal-product regexes run
        regexp_replace(lower(INGREDIENT_STATEMENT),
            '(coconut|almond|oat|soy|soya|cashew|rice|hemp|pea|macadamia|plant|nut) (milk|cream|butter|creamer)|cocoa butter|peanut butter|shea butter|cream of tartar|non-?dairy|dairy-?free|vegan butter|plant butter|cream of (rice|wheat)|buttercup|butternut|butter beans?|milk thistle|coconut creme?|egg-?free|eggplant|honeydew|honey ?crisp|oyster mushrooms?|oyster sauce flavor|(wine|cider|rice|malt|balsamic|sherry) vinegar|vanilla extract|natural extracts?|sugar alcohols?|ginger ale|alcohol-?free|non-?alcoholic|fish-?free|meat-?free|meatless|beef-?less|chicken-?less|vegetable (broth|stock)|mushroom (broth|stock)|vegan (cheese|mayonnaise|mayo)|cashew cheese|almond cheese|crab ?apple|coconut (whipped|yogurt)|whey-?free|lactose-?free',
            ' ') as INGREDIENT_TEXT_CLEAN

    from {{ ref('int_kroger_product_nutrition') }}
    where INGREDIENT_STATEMENT is not null and length(trim(INGREDIENT_STATEMENT)) > 3

),

ingredient_flags as (

    select
        PRODUCT_ID,
        INGREDIENT_STATEMENT,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\b(pork|lard|bacon|ham|prosciutto|pancetta|pepperoni|salami|chorizo|pork fat|pork rind)\\b') > 0 as ING_PORK,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\bgelatine?\\b') > 0 as ING_GELATIN,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\b(beef|chicken|turkey|pork|lamb|veal|meat|poultry|anchov[a-z]*|fish|tuna|salmon|shrimp|crab|lobster|clams?|oysters?|lard|tallow|bacon|ham|duck|cod|sardines?|squid|gelatine?|rennet|carmine|cochineal|isinglass|bone broth|chicken (broth|stock|fat|flavor)|beef (broth|stock|fat|flavor)|fish sauce|oyster sauce|worcestershire)\\b') > 0 as ING_MEAT_FISH,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\b(milk|cheese|whey|casein[a-z]*|butter|cream|lactose|yogurt|yoghurt|ghee|buttermilk|lactalbumin|milkfat|milk fat|nonfat dry milk|dry milk|milk solids|sour cream|half and half|cream cheese|butterfat|curds?)\\b') > 0 as ING_DAIRY,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\b(eggs?|egg whites?|egg yolks?|albumen|albumin|mayonnaise|whole egg|dried egg|egg solids)\\b') > 0 as ING_EGG,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\bhoney\\b') > 0 as ING_HONEY,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\b(alcohol|wine|beer|rum|bourbon|brandy|liqueur|sake|vodka|whiskey|whisky|tequila|mirin|ale|sherry|marsala|cognac)\\b') > 0 as ING_ALCOHOL,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\b(shrimp|crab|lobster|clams?|oysters?|mussels?|scallops?|crawfish|crayfish|squid|octopus|prawns?|shellfish|molluscs?|cuttlefish|calamari)\\b') > 0 as ING_SHELLFISH,
        regexp_count(INGREDIENT_TEXT_CLEAN, '\\b(catfish|shark|swordfish|eel|monkfish|sturgeon|caviar|escolar|marlin)\\b') > 0 as ING_NON_KOSHER_FISH

    from ingredients

)

select
    s.PRODUCT_ID,
    s.COLLECTED_AT as DIET_AS_OF,
    coalesce(d.DECLARATIONS, array_construct()) as DECLARATIONS,
    coalesce(array_contains('Kosher'::variant, d.DECLARATIONS), false) as DECL_KOSHER,
    coalesce(array_contains('Vegan'::variant, d.DECLARATIONS), false) as DECL_VEGAN,
    coalesce(array_contains('Vegetarian'::variant, d.DECLARATIONS), false) as DECL_VEGETARIAN,
    coalesce(array_contains('Halal'::variant, d.DECLARATIONS), false) as DECL_HALAL,
    coalesce(array_contains('Gluten Free'::variant, d.DECLARATIONS), false) as DECL_GLUTEN_FREE,
    coalesce(array_contains('Dairy Free'::variant, d.DECLARATIONS), false) as DECL_DAIRY_FREE,
    coalesce(array_contains('Egg Free'::variant, d.DECLARATIONS), false) as DECL_EGG_FREE,
    coalesce(array_contains('Plant-Based'::variant, d.DECLARATIONS), false) as DECL_PLANT_BASED,
    coalesce(array_contains('Organic'::variant, d.DECLARATIONS), false)
        or s.ORGANIC_CLAIM_NAME ilike 'ORGANIC CLAIM%' as IS_ORGANIC,
    s.CERTIFIED_FOR_PASSOVER,
    coalesce(a.CONTAINS_MILK, false) as CONTAINS_MILK,
    coalesce(a.CONTAINS_EGG, false) as CONTAINS_EGG,
    coalesce(a.CONTAINS_FISH, false) as CONTAINS_FISH,
    coalesce(a.CONTAINS_SHELLFISH, false) as CONTAINS_SHELLFISH,
    coalesce(a.CONTAINS_GLUTEN_GRAIN, false) as CONTAINS_GLUTEN_GRAIN,
    coalesce(a.CONTAINS_NUTS, false) as CONTAINS_NUTS,
    coalesce(a.CONTAINS_SOY, false) as CONTAINS_SOY,
    coalesce(a.CONTAINS_SESAME, false) as CONTAINS_SESAME,
    coalesce(a.CONTAINS_ALLERGENS, array_construct()) as CONTAINS_ALLERGENS,
    i.INGREDIENT_STATEMENT is not null as HAS_INGREDIENTS,
    i.INGREDIENT_STATEMENT,
    coalesce(i.ING_PORK, false) as ING_PORK,
    coalesce(i.ING_GELATIN, false) as ING_GELATIN,
    coalesce(i.ING_MEAT_FISH, false) as ING_MEAT_FISH,
    coalesce(i.ING_DAIRY, false) as ING_DAIRY,
    coalesce(i.ING_EGG, false) as ING_EGG,
    coalesce(i.ING_HONEY, false) as ING_HONEY,
    coalesce(i.ING_ALCOHOL, false) as ING_ALCOHOL,
    coalesce(i.ING_SHELLFISH, false) as ING_SHELLFISH,
    coalesce(i.ING_NON_KOSHER_FISH, false) as ING_NON_KOSHER_FISH

from latest s
left join declarations d
    on d.PRODUCT_ID = s.PRODUCT_ID
left join allergens a
    on a.PRODUCT_ID = s.PRODUCT_ID
left join ingredient_flags i
    on i.PRODUCT_ID = s.PRODUCT_ID
