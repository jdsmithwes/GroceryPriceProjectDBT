-- Healthy-week basket safety (dim_product_diet): rows that would break a diet
-- promise. The test fails on any row.
--   * a product the vegan basket may pick that the data itself contradicts
--     (an allergen "Contains" flag or an animal ingredient) unless the maker
--     declared it vegan — the declared ones carry VEGAN_DECLARED_CONFLICT and
--     are shown with that caveat instead
--   * any meat, poultry or fish product allowed for vegan or vegetarian
--   * a kosher/halal-allowed product with a pork, shellfish or alcohol word

select PRODUCT_KEY, PRODUCT_NAME, 'vegan_allowed_but_animal_evidence' as PROBLEM
from {{ ref('dim_product_diet') }}
where VEGAN_STATUS in ('whole_food_plant', 'no_animal_ingredients_found')
  and (CONTAINS_MILK or CONTAINS_EGG or CONTAINS_FISH or CONTAINS_SHELLFISH
       or ING_MEAT_FISH or ING_DAIRY or ING_EGG or ING_HONEY or ING_GELATIN or ING_SHELLFISH)

union all

select PRODUCT_KEY, PRODUCT_NAME, 'meat_or_fish_allowed_for_vegan_or_vegetarian'
from {{ ref('dim_product_diet') }}
where TFP_CATEGORY in ('protein_meat', 'protein_poultry', 'protein_seafood')
  and (VEGAN_STATUS in ('declared', 'whole_food_plant', 'no_animal_ingredients_found')
       or VEGETARIAN_STATUS in ('declared', 'whole_food', 'no_meat_ingredients_found'))

union all

select PRODUCT_KEY, PRODUCT_NAME, 'kosher_halal_allowed_with_pork_shellfish_or_alcohol'
from {{ ref('dim_product_diet') }}
where KOSHER_HALAL_STATUS in ('declared_kosher', 'inherently_kosher_whole_food')
  and FOOD_GROUP <> 'other'   -- a kosher-certified bacon-flavoured crisp is "other", never picked
  and (ING_PORK or ING_SHELLFISH or CONTAINS_SHELLFISH or ING_ALCOHOL
       or (regexp_count(lower(PRODUCT_NAME), '\\bpork\\b|\\bbacon\\b|\\bshrimp\\b|\\blobster\\b|\\bscallops?\\b|\\bclams?\\b|\\boysters?\\b') > 0
           and regexp_count(lower(PRODUCT_NAME), 'plant-based|meatless|vegan|style|flavou?r|seasoning|crackers|chips|crisps') = 0))
