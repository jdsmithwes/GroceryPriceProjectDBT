{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- One row per retailer listing (ontology: Product). The same physical item
-- at both retailers is two rows, linked by UPC_A / MATCHED_PRODUCT_ID when
-- int_retailer_common_upcs proves they're identical.
--
-- IS_GROCERY = the item maps to a common category in the crosswalk. That
-- filters out Walmart's Flower Shop / Food Gifts, but still includes
-- household departments (Beauty, Pet Care, Cleaning, Sporting Goods...).
-- IS_FOOD = at least one of its categories is food or drink (var
-- food_common_categories) — use it for food questions, per-ounce rankings and
-- category trends, or lipstick ($999/oz) and cat food show up.
--
-- PACKAGE_QUANTITY / UNIT_BASIS / PARSE_CONFIDENCE come from
-- int_product_unit_size (per-ounce pricing); IS_STORE_BRAND /
-- STORE_BRAND_TIER from the private_label_brands seed.
--
-- IS_SHELF_STABLE: Kroger has a real signal (TEMPERATURE = 'Ambient').
-- Walmart has none, so it falls back to common categories that are
-- shelf-stable by nature (var shelf_stable_common_categories).

{% set shelf_stable = var('shelf_stable_common_categories') %}
{% set food = var('food_common_categories') %}

with categories as (

    select
        RETAILER,
        PRODUCT_ID,
        array_agg(distinct COMMON_CATEGORY) within group (order by COMMON_CATEGORY) as COMMON_CATEGORIES,
        min(COMMON_CATEGORY) as PRIMARY_COMMON_CATEGORY,
        max(SOURCE_CATEGORY) as SOURCE_CATEGORY,
        max(SOURCE_SUBCATEGORY) as SOURCE_SUBCATEGORY

    from {{ ref('int_retailer_product_categories') }}
    where CROSSWALK_STATUS = 'mapped'
    group by RETAILER, PRODUCT_ID

),

matches as (

    select UPC_A, KROGER_PRODUCT_ID, WALMART_ITEM_ID
    from {{ ref('int_retailer_common_upcs') }}

),

kroger as (

    select
        'kroger' as RETAILER,
        k.PRODUCT_ID,
        k.DESCRIPTION as PRODUCT_NAME,
        k.BRAND,
        k.SIZE as SIZE_TEXT,
        k.UPC,
        m.UPC_A,
        m.WALMART_ITEM_ID as MATCHED_PRODUCT_ID,
        c.PRIMARY_COMMON_CATEGORY,
        c.COMMON_CATEGORIES,
        coalesce(c.SOURCE_CATEGORY, k.CATEGORIES) as SOURCE_CATEGORY,
        c.SOURCE_SUBCATEGORY,
        k.TEMPERATURE,
        c.PRODUCT_ID is not null and k.TEMPERATURE = 'Ambient' as IS_SHELF_STABLE,
        null::number(3, 2) as CUSTOMER_RATING,
        null::number as NUM_REVIEWS,
        k.IMAGE_URL,
        k.COLLECTED_AT as DATA_AS_OF

    from {{ ref('int_kroger_product_catalog_current') }} k
    left join categories c
        on c.RETAILER = 'kroger'
        and c.PRODUCT_ID = k.PRODUCT_ID
    left join matches m
        on m.KROGER_PRODUCT_ID = k.PRODUCT_ID

),

walmart_latest as (

    select *
    from {{ ref('stg_walmart_product_catalog') }}
    qualify row_number() over (
        partition by ITEM_ID
        order by COLLECTED_AT desc, INGESTED_FILENAME desc
    ) = 1

),

walmart as (

    select
        'walmart' as RETAILER,
        w.ITEM_ID as PRODUCT_ID,
        w.NAME as PRODUCT_NAME,
        w.BRAND_NAME as BRAND,
        null::varchar as SIZE_TEXT,
        w.UPC,
        m.UPC_A,
        m.KROGER_PRODUCT_ID as MATCHED_PRODUCT_ID,
        c.PRIMARY_COMMON_CATEGORY,
        c.COMMON_CATEGORIES,
        c.SOURCE_CATEGORY,
        c.SOURCE_SUBCATEGORY,
        null::varchar as TEMPERATURE,
        c.PRIMARY_COMMON_CATEGORY in (
            {%- for cat in shelf_stable %}'{{ cat }}'{{ ',' if not loop.last }}{% endfor -%}
        ) as IS_SHELF_STABLE,
        try_to_number(w.CUSTOMER_RATING, 3, 2) as CUSTOMER_RATING,
        try_to_number(w.NUM_REVIEWS) as NUM_REVIEWS,
        w.MEDIUM_IMAGE as IMAGE_URL,
        w.COLLECTED_AT as DATA_AS_OF

    from walmart_latest w
    left join categories c
        on c.RETAILER = 'walmart'
        and c.PRODUCT_ID = w.ITEM_ID
    left join matches m
        on m.WALMART_ITEM_ID = w.ITEM_ID

),

unioned as (

    select * from kroger
    union all
    select * from walmart

)

select
    u.*,
    u.PRIMARY_COMMON_CATEGORY is not null as IS_GROCERY,
    coalesce(arrays_overlap(u.COMMON_CATEGORIES, array_construct(
        {%- for cat in food %}'{{ cat }}'{{ ',' if not loop.last }}{% endfor -%}
    )), false) as IS_FOOD,
    u.UPC_A is not null as HAS_EXACT_MATCH,
    u.RETAILER || ':' || u.PRODUCT_ID as PRODUCT_KEY,

    ---------- package size (int_product_unit_size)
    s.PACKAGE_QUANTITY,
    s.UNIT_BASIS,
    s.ITEMS_IN_PACKAGE,
    coalesce(s.PARSE_CONFIDENCE, 'none') as PARSE_CONFIDENCE,

    ---------- store brand (private_label_brands seed)
    pl.BRAND is not null as IS_STORE_BRAND,
    pl.TIER as STORE_BRAND_TIER

from unioned u
left join {{ ref('int_product_unit_size') }} s
    on s.RETAILER = u.RETAILER
    and s.PRODUCT_ID = u.PRODUCT_ID
left join {{ ref('private_label_brands') }} pl
    on pl.RETAILER = u.RETAILER
    and pl.BRAND = u.BRAND
