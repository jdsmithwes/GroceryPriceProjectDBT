{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- Healthy-week basket (plan healthy-week-basket.md, 2026-11-27): one row per
-- Kroger food product with its USDA food group, whether it is a plain whole
-- food, and four statuses with provenance. Kroger only: Walmart's catalog
-- carries no declarations, allergens, ingredients or nutrition facts.
--
-- FOOD_GROUP / TFP_CATEGORY: the first diet_category_map rule (by PRIORITY)
-- whose regex matches PRODUCT_TYPE (PRODUCT_NAME when the Cortex label is
-- missing). 'other' groups are the Thrifty Food Plan "miscellaneous"
-- categories and snacks — never a healthy-week pick.
--
-- IS_WHOLE_FOOD: plain food that needs no nutrition facts to be judged —
-- raw or plain frozen produce (FDA: raw whole fruits and vegetables qualify
-- automatically), shell eggs, plain raw cuts of meat, poultry and fish,
-- plain dry rice, pasta and oats, plain nuts and tofu. Anything canned,
-- dried, seasoned, breaded, smoked, cured or sauced is judged by its facts.
--
-- HEALTHY_STATUS (FDA "healthy" claim, per labelled serving; nutrient limits
-- from the diet_guideline seed — sodium <= 230 mg for every group, added
-- sugar <= 1 g / 2.5 g dairy / 5 g grains, saturated fat <= 1 g / 2 g dairy,
-- eggs, meat and poultry): whole_food | meets_limits | fails | no_facts.
-- The claim's whole-grain / food-group-equivalent test is not applied, so
-- plain refined rice and pasta can be meets_limits (the TFP buys them too).
--
-- VEGAN_STATUS: declared | whole_food_plant | no_animal_ingredients_found |
-- excluded | unknown. Excluded on any allergen "Contains" milk/egg/fish/
-- shellfish flag, any animal word in the ingredients (incl. honey, gelatin),
-- or an animal food group.
-- VEGETARIAN_STATUS: declared | whole_food | no_meat_ingredients_found |
-- excluded | unknown (dairy and eggs allowed; fish and gelatin not).
-- KOSHER_HALAL_STATUS: declared_kosher | inherently_kosher_whole_food |
-- excluded | unknown. One option for both diets (owner decision): pork,
-- shellfish, alcohol, fish without scales and any meat or poultry that is
-- not declared kosher are excluded; raw produce, plain grains, eggs, plain
-- nuts and scaled fish qualify without a symbol. Halal shoppers still have
-- to confirm meat and poultry (kosher slaughter is not zabiha); the apps
-- say so. Nothing is ever labelled "halal-certified" (61 Halal declarations
-- in the whole catalog). DECL_HALAL is kept for display.
--
-- EST_LBS: as-purchased pounds per package from the parsed size (oz / 16,
-- fl oz / 16, eggs 0.125 lb each), only for high-confidence parses; used to
-- compare a week's picks with the TFP pounds per category.

with products as (

    select
        p.PRODUCT_KEY,
        p.RETAILER,
        p.PRODUCT_ID,
        p.PRODUCT_NAME,
        p.BRAND,
        p.SIZE_TEXT,
        p.PRIMARY_COMMON_CATEGORY,
        p.TEMPERATURE,
        p.IS_FOOD,
        p.PRODUCT_TYPE,
        lower(coalesce(p.PRODUCT_TYPE, p.PRODUCT_NAME)) as TYPE_TEXT,
        p.PACKAGE_QUANTITY,
        p.UNIT_BASIS,
        p.PARSE_CONFIDENCE,
        p.IS_STORE_BRAND

    from {{ ref('dim_product') }} p
    where p.RETAILER = 'kroger'
      and p.IS_FOOD

),

mapped as (

    select
        p.*,
        m.PRIORITY as MAP_PRIORITY,
        coalesce(m.FOOD_GROUP, 'other') as FOOD_GROUP,
        coalesce(m.TFP_CATEGORY, 'unmapped') as TFP_CATEGORY,
        coalesce(m.IS_WHOLE_FOOD, false) as MAP_WHOLE_FOOD,
        -- the product name often says what the type label hides ("Brown Sugar and Bacon Pork Tenderloin")
        regexp_count(lower(p.PRODUCT_NAME),
            'seasoned|marinated|with salt|salt and pepper|salt & pepper|\\brub\\b|smoked|cooked|breaded|battered|glazed|brown sugar|bacon|fried|\\bmeal\\b|dinner|sauce|\\bbutter\\b|garlic|\\bherbs?\\b|cheese|stuffed|spicy|flavored|flavoured|instant|\\bready\\b|microwav|\\bcup\\b|\\bbowl\\b|candied|sweetened|syrup|in juice|dessert|\\bkit\\b|seasoning|teriyaki|\\bbbq\\b|barbecue|\\bhoney\\b|maple|cajun|lemon pepper|crusted|coated|skillet|steamers? in|pouch|coconut ginger|pilaf|rice mix|seasoned rice|risotto mix|street|with natural flavor|blackened|rubbed|jerk|buffalo|sriracha|chipotle') > 0 as NAME_PROCESSED

    from products p
    left join {{ ref('diet_category_map') }} m
        on regexp_count(p.TYPE_TEXT, m.PATTERN, 1, 'i') > 0
    qualify row_number() over (partition by p.PRODUCT_KEY order by m.PRIORITY nulls last) = 1

),

whole as (

    select
        *,
        not NAME_PROCESSED and case
            -- produce and plain frozen produce (raw whole fruit and vegetables qualify automatically)
            when MAP_WHOLE_FOOD
                 and (PRIMARY_COMMON_CATEGORY = 'Produce' or TEMPERATURE = 'Frozen' or PRIMARY_COMMON_CATEGORY = 'Frozen')
                 and regexp_count(TYPE_TEXT, 'canned|dried|dehydrated|freeze|juice|paste|sauce|pickled|roasted|seasoned|marinated|glazed|candied|sweetened|syrup|covered|chocolate|kit|medley in|with sauce|buttery|cheese|salad$|slaw|dip|snack|tray|cup') = 0
                then true
            -- shell eggs
            when TFP_CATEGORY = 'protein_egg'
                 and regexp_count(TYPE_TEXT, 'eggs?$') > 0
                 and regexp_count(TYPE_TEXT, 'liquid|substitute|cooked|boiled|plant|bites|white') = 0
                then true
            -- plain raw cuts of meat and poultry
            when TFP_CATEGORY in ('protein_meat', 'protein_poultry')
                 and regexp_count(TYPE_TEXT, 'ground (beef|pork|lamb|bison|turkey|chicken)|steak|\\broasts?$|\\bchops?\\b|\\bloin\\b|tenderloin|\\bribs\\b|stew meat|brisket|shoulder|leg quarters|thighs?|drumsticks?|breasts?$|breast fillets?|breast tenderloins?|whole (young )?(chicken|turkey)|cut up chicken|tenderloins$|cornish hen') > 0
                 and regexp_count(TYPE_TEXT, 'smoked|cured|seasoned|marinated|breaded|stuffed|glazed|hot dog|sausage|deli|lunch|sliced|shaved|roast beef|roasted|cooked|grilled|rotisserie|fajita|kabob|patties|patty|burger|meatball|jerky|\\bham\\b|bacon|salami|pepperoni|bologna|pastrami|prosciutto|meal|dinner|strips|nugget|tenders$|wings|bites|frozen .*meal') = 0
                then true
            -- plain raw or frozen fish and shellfish
            when TFP_CATEGORY = 'protein_seafood'
                 and regexp_count(TYPE_TEXT, 'fillets?|portions?|loins?|steak|raw .*shrimp|shrimp$|salmon$|tilapia$|\\bcod$|scallops?$|lobster tails?|mussels$|crab (legs|clusters)|whole fish|swai') > 0
                 and regexp_count(TYPE_TEXT, 'smoked|breaded|battered|coconut|stuffed|scampi|imitation|surimi|canned|salad|burgers?|cakes?|sticks|popcorn|seasoned|marinated|glazed|cooked|fried') = 0
                then true
            -- plain dry grains (facts usually exist too; this covers the ones without)
            when FOOD_GROUP = 'grains'
                 and regexp_count(TYPE_TEXT, '(rice|pasta|spaghetti|penne|rotini|rigatoni|fettuccine|linguine|macaroni|ziti|orzo|farfalle|fusilli|noodles|lasagna|shells|couscous|quinoa|barley|oats|bulgur|farro)$') > 0
                 and regexp_count(TYPE_TEXT, 'flavored|seasoned|mix|cup|microwave|cooked|ready|side|dish|instant|sauce|cheese|frozen|fried|with') = 0
                then true
            -- plain nuts, seeds and tofu
            when TFP_CATEGORY = 'protein_nuts_seeds_soy'
                 and regexp_count(TYPE_TEXT, '(almonds|walnuts|pecans|cashews|pistachios|peanuts|pine nuts|hazelnuts|macadamia nuts|mixed nuts|sunflower seeds|pumpkin seeds|chia seeds|flax ?seeds?|hemp seeds|sesame seeds|pecan halves|walnut (pieces|halves)|sliced almonds|chopped pecans|tofu|tempeh|edamame)$') > 0
                 and regexp_count(TYPE_TEXT, 'honey|candied|glazed|chocolate|covered|seasoned|flavored|baked|fried|smoked|butter|spaghetti|pasta') = 0
                then true
            else false
        end as IS_WHOLE_FOOD

    from mapped

),

limits as (

    -- FDA per-serving limits from the seed: sodium and added sugar by food
    -- group; saturated fat by TFP category where the rule names one, else
    -- by food group. Legumes carry the FDA protein-group limit.
    select
        g.FOOD_GROUP,
        g.TFP_CATEGORY,
        max(iff(g.METRIC = 'sodium_max_mg_per_serving', g.VALUE, null)) as SODIUM_MAX_MG,
        max(iff(g.METRIC = 'added_sugar_max_g_per_serving', g.VALUE, null)) as ADDED_SUGAR_MAX_G,
        max(iff(g.METRIC = 'saturated_fat_max_g_per_serving', g.VALUE, null)) as SAT_FAT_MAX_G

    from {{ ref('diet_guideline') }} g
    where g.SOURCE_KEY = 'fda_healthy_2024'
      and g.VALUE is not null
    group by g.FOOD_GROUP, g.TFP_CATEGORY

),

judged as (

    select
        w.*,
        d.DIET_AS_OF,
        d.DECLARATIONS,
        d.DECL_KOSHER, d.DECL_VEGAN, d.DECL_VEGETARIAN, d.DECL_HALAL, d.DECL_GLUTEN_FREE,
        d.DECL_DAIRY_FREE, d.DECL_EGG_FREE, d.DECL_PLANT_BASED, d.IS_ORGANIC, d.CERTIFIED_FOR_PASSOVER,
        d.CONTAINS_MILK, d.CONTAINS_EGG, d.CONTAINS_FISH, d.CONTAINS_SHELLFISH, d.CONTAINS_GLUTEN_GRAIN,
        d.CONTAINS_NUTS, d.CONTAINS_SOY, d.CONTAINS_SESAME, d.CONTAINS_ALLERGENS,
        d.HAS_INGREDIENTS, d.INGREDIENT_STATEMENT,
        d.ING_PORK, d.ING_GELATIN, d.ING_MEAT_FISH, d.ING_DAIRY, d.ING_EGG, d.ING_HONEY, d.ING_ALCOHOL, d.ING_SHELLFISH, d.ING_NON_KOSHER_FISH,
        n.NUTRITION_AS_OF, n.NUTRITIONAL_RATING, n.SERVINGS_PER_PACKAGE, n.SERVING_SIZE_QUANTITY, n.SERVING_SIZE_UNIT,
        n.NUTRIENT_COUNT,
        -- Kroger's feed omits zero-valued nutrients (0 of 11.7k products carry an explicit 0 for
        -- sodium, added sugar or saturated fat, 2026-11-27), so on a label that has facts a
        -- missing nutrient is read as 0.
        -- Labels with fewer than 6 nutrients are usually incomplete feeds, not short labels.
        coalesce(n.NUTRIENT_COUNT, 0) >= 6 and n.CALORIES is not null as HAS_FACTS,
        n.CALORIES, n.SODIUM_MG, n.ADDED_SUGAR_G, n.TOTAL_SUGAR_G, n.SATURATED_FAT_G, n.TRANS_FAT_G, n.TOTAL_FAT_G,
        n.CARBOHYDRATE_G, n.FIBER_G, n.PROTEIN_G, n.CHOLESTEROL_MG, n.POTASSIUM_MG, n.CALCIUM_MG, n.IRON_MG,

        -- the limit row for this product: category-specific saturated fat when the seed has one
        coalesce(lc.SODIUM_MAX_MG, lg.SODIUM_MAX_MG) as SODIUM_MAX_MG,
        coalesce(lc.ADDED_SUGAR_MAX_G, lg.ADDED_SUGAR_MAX_G) as ADDED_SUGAR_MAX_G,
        coalesce(lc.SAT_FAT_MAX_G, lg.SAT_FAT_MAX_G) as SAT_FAT_MAX_G,

        -- the animal-food groups and the plant groups, for the diet rules
        w.TFP_CATEGORY in ('protein_meat', 'protein_poultry', 'protein_seafood') or w.PRIMARY_COMMON_CATEGORY = 'Meat & Seafood' as IS_MEAT_OR_FISH_GROUP,
        w.TFP_CATEGORY in ('protein_egg', 'dairy_cheese')
            or (w.FOOD_GROUP = 'dairy'
                and regexp_count(w.TYPE_TEXT, 'almond|oat|soy|cashew|coconut|plant|hemp|rice|pea |macadamia|flax|nut milk|vegan|dairy.?free|non.?dairy') = 0) as IS_ANIMAL_DAIRY_OR_EGG_GROUP,
        w.FOOD_GROUP in ('vegetables', 'fruits', 'grains') or w.TFP_CATEGORY = 'protein_nuts_seeds_soy' as IS_PLANT_GROUP

    from whole w
    left join {{ ref('int_kroger_product_diet') }} d
        on d.PRODUCT_ID = w.PRODUCT_ID
    left join {{ ref('int_kroger_product_nutrition') }} n
        on n.PRODUCT_ID = w.PRODUCT_ID
    left join limits lc
        on lc.TFP_CATEGORY = w.TFP_CATEGORY
    left join limits lg
        on lg.FOOD_GROUP = iff(w.TFP_CATEGORY = 'veg_legumes', 'protein', w.FOOD_GROUP)
        and lg.TFP_CATEGORY is null

)

select
    PRODUCT_KEY, RETAILER, PRODUCT_ID, PRODUCT_NAME, BRAND, SIZE_TEXT, PRIMARY_COMMON_CATEGORY, TEMPERATURE,
    PRODUCT_TYPE, IS_STORE_BRAND, PACKAGE_QUANTITY, UNIT_BASIS, PARSE_CONFIDENCE,
    FOOD_GROUP, TFP_CATEGORY, MAP_PRIORITY, IS_WHOLE_FOOD,

    ---------- healthy (FDA nutrient limits)
    SODIUM_MAX_MG, ADDED_SUGAR_MAX_G, SAT_FAT_MAX_G,
    HAS_FACTS,
    case
        when IS_WHOLE_FOOD then 'whole_food'
        when not HAS_FACTS then 'no_facts'
        when coalesce(SODIUM_MG, 0) <= SODIUM_MAX_MG and coalesce(ADDED_SUGAR_G, 0) <= ADDED_SUGAR_MAX_G
             and coalesce(SATURATED_FAT_G, 0) <= SAT_FAT_MAX_G then 'meets_limits'
        else 'fails'
    end as HEALTHY_STATUS,
    case
        when IS_WHOLE_FOOD or not HAS_FACTS then null
        else rtrim(
            iff(coalesce(SODIUM_MG, 0) > SODIUM_MAX_MG, 'sodium ' || SODIUM_MG::int || ' mg; ', '')
            || iff(coalesce(ADDED_SUGAR_G, 0) > ADDED_SUGAR_MAX_G, 'added sugar ' || ADDED_SUGAR_G || ' g; ', '')
            || iff(coalesce(SATURATED_FAT_G, 0) > SAT_FAT_MAX_G, 'saturated fat ' || SATURATED_FAT_G || ' g; ', ''), '; ')
    end as HEALTHY_FAIL_REASON,

    ---------- diets, with provenance
    case
        -- a meat, poultry or fish product is never vegan, whatever the declaration says
        -- (a Tyson chicken breast carried a "Vegan" declaration, 2026-11-27)
        when IS_MEAT_OR_FISH_GROUP then 'excluded'
        when DECL_VEGAN then 'declared'
        when CONTAINS_MILK or CONTAINS_EGG or CONTAINS_FISH or CONTAINS_SHELLFISH
             or ING_MEAT_FISH or ING_DAIRY or ING_EGG or ING_HONEY or ING_GELATIN or ING_SHELLFISH
             or IS_ANIMAL_DAIRY_OR_EGG_GROUP then 'excluded'
        when IS_WHOLE_FOOD and IS_PLANT_GROUP then 'whole_food_plant'
        when HAS_INGREDIENTS and IS_PLANT_GROUP then 'no_animal_ingredients_found'
        when HAS_INGREDIENTS and FOOD_GROUP = 'dairy' then 'no_animal_ingredients_found'
        else 'unknown'
    end as VEGAN_STATUS,
    case
        when IS_MEAT_OR_FISH_GROUP then 'excluded'
        when DECL_VEGETARIAN or DECL_VEGAN then 'declared'
        when CONTAINS_FISH or CONTAINS_SHELLFISH or ING_MEAT_FISH or ING_GELATIN or ING_SHELLFISH then 'excluded'
        when IS_WHOLE_FOOD and (IS_PLANT_GROUP or TFP_CATEGORY = 'protein_egg') then 'whole_food'
        when HAS_INGREDIENTS and not IS_MEAT_OR_FISH_GROUP then 'no_meat_ingredients_found'
        else 'unknown'
    end as VEGETARIAN_STATUS,
    case
        when ING_PORK or ING_SHELLFISH or CONTAINS_SHELLFISH or ING_ALCOHOL or ING_NON_KOSHER_FISH
             or PRIMARY_COMMON_CATEGORY = 'Adult Beverage'
             or regexp_count(TYPE_TEXT, '\\bpork\\b|\\bham\\b|bacon|\\blard\\b|pepperoni|prosciutto|pancetta|salami|salame|chorizo|carnitas|al pastor|wine|beer|shrimp|prawn|crab|lobster|clam|oyster|scallop|mussel|squid|calamari|crawfish|octopus|catfish|swordfish|shark|\\beel\\b|surimi|imitation crab|seafood blend|gelatin') > 0
            then 'excluded'
        when IS_MEAT_OR_FISH_GROUP and not DECL_KOSHER
             and not (TFP_CATEGORY = 'protein_seafood' and IS_WHOLE_FOOD
                      and regexp_count(TYPE_TEXT, 'salmon|tilapia|\\bcod\\b|tuna|trout|halibut|snapper|grouper|mahi|haddock|pollock|flounder|perch|whiting|branzino|sardine|herring|mackerel|anchov|walleye|bass|sole|swai') > 0)
            then 'excluded'
        when DECL_KOSHER then 'declared_kosher'
        when IS_WHOLE_FOOD and (IS_PLANT_GROUP or TFP_CATEGORY in ('protein_egg', 'protein_seafood')) then 'inherently_kosher_whole_food'
        else 'unknown'
    end as KOSHER_HALAL_STATUS,

    -- a "Vegan" declaration that the allergen or ingredient data contradicts: still 'declared'
    -- (the pack is the shopper's evidence), but the apps say so next to the pick
    DECL_VEGAN and (CONTAINS_MILK or CONTAINS_EGG or CONTAINS_FISH or CONTAINS_SHELLFISH
                    or ING_MEAT_FISH or ING_DAIRY or ING_EGG or ING_HONEY or ING_GELATIN) as VEGAN_DECLARED_CONFLICT,

    ---------- evidence (what the statuses were built from)
    DECLARATIONS, DECL_KOSHER, DECL_VEGAN, DECL_VEGETARIAN, DECL_HALAL, DECL_GLUTEN_FREE, DECL_DAIRY_FREE, DECL_EGG_FREE, DECL_PLANT_BASED,
    IS_ORGANIC, CERTIFIED_FOR_PASSOVER,
    CONTAINS_MILK, CONTAINS_EGG, CONTAINS_FISH, CONTAINS_SHELLFISH, CONTAINS_GLUTEN_GRAIN, CONTAINS_NUTS, CONTAINS_SOY, CONTAINS_SESAME, CONTAINS_ALLERGENS,
    HAS_INGREDIENTS, INGREDIENT_STATEMENT,
    ING_PORK, ING_GELATIN, ING_MEAT_FISH, ING_DAIRY, ING_EGG, ING_HONEY, ING_ALCOHOL, ING_SHELLFISH, ING_NON_KOSHER_FISH,

    ---------- nutrition (per labelled serving)
    NUTRITIONAL_RATING, SERVINGS_PER_PACKAGE, SERVING_SIZE_QUANTITY, SERVING_SIZE_UNIT,
    CALORIES, SODIUM_MG, ADDED_SUGAR_G, TOTAL_SUGAR_G, SATURATED_FAT_G, TRANS_FAT_G, TOTAL_FAT_G,
    CARBOHYDRATE_G, FIBER_G, PROTEIN_G, CHOLESTEROL_MG, POTASSIUM_MG, CALCIUM_MG, IRON_MG,

    ---------- size
    case
        when PARSE_CONFIDENCE <> 'high' or coalesce(PACKAGE_QUANTITY, 0) <= 0 then null
        when UNIT_BASIS in ('oz', 'fl_oz') then PACKAGE_QUANTITY / 16
        when UNIT_BASIS = 'ct' and TFP_CATEGORY = 'protein_egg' then PACKAGE_QUANTITY * 0.125
        else null
    end::number(10, 3) as EST_LBS,

    coalesce(DIET_AS_OF, NUTRITION_AS_OF) as DATA_AS_OF

from judged
