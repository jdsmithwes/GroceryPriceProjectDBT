{% set food = var('food_common_categories') %}

{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- "Is dairy getting more expensive?" — one row per retailer x common
-- category x collection week: a chained Jevons price index (the method behind
-- CPI elementary aggregates). Each link is the geometric mean of
-- week-over-week price ratios, over the grocery products observed in BOTH
-- weeks — so products appearing or disappearing don't move the index, only
-- real price changes do. The first observed week = 100.
--
-- Built on fct_product_price_weekly_series (Kroger: median price across
-- stores). A link spans consecutive OBSERVED weeks, so across a collection
-- gap (Oct 5 -> Nov 9, 2026) one link covers several calendar weeks —
-- WEEKS_SINCE_PREVIOUS says so, and answers should mention it.

with series as (

    select
        s.RETAILER,
        p.PRIMARY_COMMON_CATEGORY as COMMON_CATEGORY,
        s.PRODUCT_KEY,
        s.PRICE_WEEK,
        s.EFFECTIVE_PRICE

    from {{ ref('fct_product_price_weekly_series') }} s
    join {{ ref('dim_product') }} p
        on p.PRODUCT_KEY = s.PRODUCT_KEY
    where p.IS_GROCERY
      and s.EFFECTIVE_PRICE > 0

),

retailer_weeks as (

    select
        RETAILER,
        PRICE_WEEK,
        lag(PRICE_WEEK) over (partition by RETAILER order by PRICE_WEEK) as PREVIOUS_WEEK

    from (select distinct RETAILER, PRICE_WEEK from series)

),

links as (

    -- One row per product per pair of consecutive observed weeks
    select
        cur.RETAILER,
        cur.COMMON_CATEGORY,
        cur.PRICE_WEEK,
        w.PREVIOUS_WEEK,
        ln(cur.EFFECTIVE_PRICE / prev.EFFECTIVE_PRICE) as LOG_RATIO,
        cur.EFFECTIVE_PRICE <> prev.EFFECTIVE_PRICE as PRICE_CHANGED

    from series cur
    join retailer_weeks w
        on w.RETAILER = cur.RETAILER
        and w.PRICE_WEEK = cur.PRICE_WEEK
    join series prev
        on prev.PRODUCT_KEY = cur.PRODUCT_KEY
        and prev.PRICE_WEEK = w.PREVIOUS_WEEK

),

weekly_links as (

    select
        RETAILER,
        COMMON_CATEGORY,
        PRICE_WEEK,
        PREVIOUS_WEEK,
        avg(LOG_RATIO) as AVG_LOG_RATIO,
        count(*) as PRODUCTS_IN_LINK,
        count_if(PRICE_CHANGED) as PRODUCTS_PRICE_CHANGED

    from links
    group by RETAILER, COMMON_CATEGORY, PRICE_WEEK, PREVIOUS_WEEK

),

base_weeks as (

    select RETAILER, COMMON_CATEGORY, min(PRICE_WEEK) as BASE_WEEK, count(distinct PRODUCT_KEY) as BASE_PRODUCTS
    from series
    group by RETAILER, COMMON_CATEGORY

)

select
    b.RETAILER,
    b.COMMON_CATEGORY,
    b.BASE_WEEK as PRICE_WEEK,
    null::date as PREVIOUS_WEEK,
    null::number as WEEKS_SINCE_PREVIOUS,
    100::number(10, 2) as PRICE_INDEX,
    null::number(10, 4) as CHANGE_VS_PREVIOUS_PCT,
    b.BASE_PRODUCTS as PRODUCTS_IN_LINK,
    null::number as PRODUCTS_PRICE_CHANGED,
    b.BASE_WEEK,
    b.COMMON_CATEGORY in ({%- for cat in food %}'{{ cat }}'{{ ',' if not loop.last }}{% endfor -%}) as IS_FOOD_CATEGORY

from base_weeks b

union all

select
    l.RETAILER,
    l.COMMON_CATEGORY,
    l.PRICE_WEEK,
    l.PREVIOUS_WEEK,
    datediff('week', l.PREVIOUS_WEEK, l.PRICE_WEEK) as WEEKS_SINCE_PREVIOUS,
    round(100 * exp(sum(l.AVG_LOG_RATIO) over (
        partition by l.RETAILER, l.COMMON_CATEGORY
        order by l.PRICE_WEEK
        rows between unbounded preceding and current row
    )), 2) as PRICE_INDEX,
    round(exp(l.AVG_LOG_RATIO) - 1, 4) as CHANGE_VS_PREVIOUS_PCT,
    l.PRODUCTS_IN_LINK,
    l.PRODUCTS_PRICE_CHANGED,
    b.BASE_WEEK,
    b.COMMON_CATEGORY in ({%- for cat in food %}'{{ cat }}'{{ ',' if not loop.last }}{% endfor -%}) as IS_FOOD_CATEGORY

from weekly_links l
join base_weeks b
    on b.RETAILER = l.RETAILER
    and b.COMMON_CATEGORY = l.COMMON_CATEGORY
