{{ config(materialized='view', schema='intermediate_common') }}

-- One row per UPC carried by both Kroger and Walmart. Kroger's PRODUCT_ID is
-- the UPC without its check digit, zero-padded to 13 digits, so it matches the
-- first 11 digits of Walmart's 12-digit UPC-A. LOOKUP_PRIORITY orders products
-- for external detail lookups: priced at both retailers first, then a
-- round-robin across Walmart common categories so picks aren't one category.

with walmart_latest as (

    select
        ITEM_ID,
        UPC,
        NAME,
        BRAND_NAME

    from {{ ref('stg_walmart_product_catalog') }}
    qualify row_number() over (
        partition by ITEM_ID
        order by COLLECTED_AT desc, INGESTED_FILENAME desc
    ) = 1

),

walmart_priced as (

    select distinct ITEM_ID
    from {{ ref('int_walmart_price_history') }}
    where IS_CURRENT

),

walmart as (

    select
        w.UPC as UPC_A,
        w.ITEM_ID as WALMART_ITEM_ID,
        w.NAME as WALMART_NAME,
        w.BRAND_NAME as WALMART_BRAND,
        wp.ITEM_ID is not null as HAS_WALMART_PRICE

    from walmart_latest w
    left join walmart_priced wp
        on wp.ITEM_ID = w.ITEM_ID
    where regexp_like(w.UPC, '^[0-9]{12}$')
    qualify row_number() over (
        partition by w.UPC
        order by (wp.ITEM_ID is not null) desc, w.ITEM_ID
    ) = 1

),

kroger_priced as (

    select distinct PRODUCT_ID
    from {{ ref('int_kroger_price_history') }}
    where IS_CURRENT

),

categories as (

    select
        RETAILER,
        PRODUCT_ID,
        array_agg(distinct COMMON_CATEGORY) within group (order by COMMON_CATEGORY) as COMMON_CATEGORIES

    from {{ ref('int_retailer_product_categories') }}
    where CROSSWALK_STATUS = 'mapped'
    group by RETAILER, PRODUCT_ID

),

matched as (

    select
        w.UPC_A,
        '0' || w.UPC_A as EAN_13,
        k.PRODUCT_ID as KROGER_PRODUCT_ID,
        w.WALMART_ITEM_ID,
        k.BRAND as KROGER_BRAND,
        k.DESCRIPTION as KROGER_DESCRIPTION,
        w.WALMART_BRAND,
        w.WALMART_NAME,
        kc.COMMON_CATEGORIES as KROGER_COMMON_CATEGORIES,
        wc.COMMON_CATEGORIES[0]::varchar as WALMART_COMMON_CATEGORY,
        coalesce(arrays_overlap(kc.COMMON_CATEGORIES, wc.COMMON_CATEGORIES), false) as IS_SAME_COMMON_CATEGORY,
        kp.PRODUCT_ID is not null as HAS_KROGER_PRICE,
        w.HAS_WALMART_PRICE,
        mod(
            10 - mod(
                3 * (
                    substr(w.UPC_A, 1, 1)::int + substr(w.UPC_A, 3, 1)::int + substr(w.UPC_A, 5, 1)::int
                    + substr(w.UPC_A, 7, 1)::int + substr(w.UPC_A, 9, 1)::int + substr(w.UPC_A, 11, 1)::int
                )
                + substr(w.UPC_A, 2, 1)::int + substr(w.UPC_A, 4, 1)::int + substr(w.UPC_A, 6, 1)::int
                + substr(w.UPC_A, 8, 1)::int + substr(w.UPC_A, 10, 1)::int,
                10
            ),
            10
        ) = substr(w.UPC_A, 12, 1)::int as IS_CHECK_DIGIT_VALID

    from walmart w
    join {{ ref('int_kroger_product_catalog_current') }} k
        on k.PRODUCT_ID = lpad(left(w.UPC_A, 11), 13, '0')
    left join kroger_priced kp
        on kp.PRODUCT_ID = k.PRODUCT_ID
    left join categories kc
        on kc.RETAILER = 'kroger'
        and kc.PRODUCT_ID = k.PRODUCT_ID
    left join categories wc
        on wc.RETAILER = 'walmart'
        and wc.PRODUCT_ID = w.WALMART_ITEM_ID

),

ranked as (

    select
        *,
        row_number() over (
            partition by coalesce(WALMART_COMMON_CATEGORY, 'unmapped')
            order by (HAS_KROGER_PRICE and HAS_WALMART_PRICE) desc, IS_SAME_COMMON_CATEGORY desc, UPC_A
        ) as CATEGORY_RANK

    from matched

)

select
    *,
    row_number() over (
        order by
            (HAS_KROGER_PRICE and HAS_WALMART_PRICE) desc,
            IS_CHECK_DIGIT_VALID desc,
            CATEGORY_RANK,
            IS_SAME_COMMON_CATEGORY desc,
            UPC_A
    ) as LOOKUP_PRIORITY

from ranked
