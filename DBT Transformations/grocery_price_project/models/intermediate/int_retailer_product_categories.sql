{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL',
    schema='intermediate_common'
) }}

-- One row per retailer product + source category, tagged with the
-- retailer-neutral COMMON_CATEGORY from retailer_category_crosswalk. Join
-- Kroger rows to Walmart rows on COMMON_CATEGORY to get products of the same
-- category from each retailer.
--
-- Kroger's catalog lands its categories array comma-joined, and one category
-- name ("Pasta, Sauces, Grain") itself contains commas, so it's protected
-- before splitting. Any future comma-containing Kroger category would split
-- into fragments and surface as CROSSWALK_STATUS = 'unmapped'.

with kroger as (

    select distinct
        'kroger' as RETAILER,
        c.PRODUCT_ID,
        trim(replace(f.value::string, '|', ',')) as SOURCE_CATEGORY,
        null::varchar as SOURCE_SUBCATEGORY

    from {{ ref('int_kroger_product_catalog_current') }} c,
    lateral flatten(
        input => split(replace(c.CATEGORIES, 'Pasta, Sauces, Grain', 'Pasta| Sauces| Grain'), ', ')
    ) f

),

walmart as (

    select
        'walmart' as RETAILER,
        ITEM_ID as PRODUCT_ID,
        nullif(split_part(CATEGORY_PATH, '/', 3), '') as SOURCE_CATEGORY,
        nullif(split_part(CATEGORY_PATH, '/', 4), '') as SOURCE_SUBCATEGORY

    from {{ ref('stg_walmart_product_catalog') }}
    qualify row_number() over (
        partition by ITEM_ID
        order by COLLECTED_AT desc, INGESTED_FILENAME desc
    ) = 1

),

products as (

    select * from kroger
    union all
    select * from walmart

),

crosswalk as (

    select
        lower(RETAILER) as RETAILER,
        lower(SOURCE_CATEGORY) as SOURCE_CATEGORY_KEY,
        lower(nullif(trim(SOURCE_SUBCATEGORY), '')) as SOURCE_SUBCATEGORY_KEY,
        nullif(trim(COMMON_CATEGORY), '') as COMMON_CATEGORY

    from {{ ref('retailer_category_crosswalk') }}

),

mapped as (

    select
        p.RETAILER,
        p.PRODUCT_ID,
        p.SOURCE_CATEGORY,
        p.SOURCE_SUBCATEGORY,
        sub.RETAILER is not null or cat.RETAILER is not null as IS_IN_CROSSWALK,
        iff(sub.RETAILER is not null, sub.COMMON_CATEGORY, cat.COMMON_CATEGORY) as COMMON_CATEGORY

    from products p
    left join crosswalk sub
        on sub.RETAILER = p.RETAILER
        and sub.SOURCE_CATEGORY_KEY = lower(p.SOURCE_CATEGORY)
        and sub.SOURCE_SUBCATEGORY_KEY = lower(p.SOURCE_SUBCATEGORY)
    left join crosswalk cat
        on cat.RETAILER = p.RETAILER
        and cat.SOURCE_CATEGORY_KEY = lower(p.SOURCE_CATEGORY)
        and cat.SOURCE_SUBCATEGORY_KEY is null

)

select
    RETAILER,
    PRODUCT_ID,
    COMMON_CATEGORY,
    SOURCE_CATEGORY,
    SOURCE_SUBCATEGORY,
    case
        when not IS_IN_CROSSWALK then 'unmapped'
        when COMMON_CATEGORY is null then 'excluded'
        else 'mapped'
    end as CROSSWALK_STATUS

from mapped
