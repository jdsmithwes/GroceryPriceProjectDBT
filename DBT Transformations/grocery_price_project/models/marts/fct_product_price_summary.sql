{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- One row per product x store: the latest observed price and how it sits
-- against the item's own history at that store. Answers "biggest price
-- drops", "is this sale real?", "lowest price ever?", "how often is it on
-- sale?" (definitions in Agent/ONTOLOGY.md; thresholds are dbt vars).
--
-- "Current" = the series' latest observed week. IS_CURRENTLY_LISTED says
-- whether that is also the retailer's latest collection week — a product
-- last seen weeks ago shouldn't be presented as today's price.
--
-- Changes vs 4/8/12 weeks ago use the nearest observation AT OR BEFORE that
-- date (ASOF join), and REF_WEEK_* says which week was actually used — across
-- a collection gap "4 weeks ago" can resolve to an older week, and answers
-- should say so.

{% set trailing = var('history_trailing_weeks') %}

with weekly as (

    select * from {{ ref('fct_price_weekly') }}

),

retailer_latest as (

    select RETAILER, max(PRICE_WEEK) as RETAILER_LATEST_WEEK
    from weekly
    group by RETAILER

),

with_prev as (

    select
        *,
        lag(IS_ON_PROMO) over (partition by PRODUCT_KEY, STORE_ID order by PRICE_WEEK) as PREV_IS_ON_PROMO
    from weekly

),

current_obs as (

    select *
    from weekly
    qualify row_number() over (partition by PRODUCT_KEY, STORE_ID order by PRICE_WEEK desc) = 1

),

history as (

    select
        h.PRODUCT_KEY,
        h.STORE_ID,
        min(h.PRICE_WEEK) as FIRST_OBSERVED_WEEK,
        count(*) as WEEKS_OBSERVED,
        min(h.EFFECTIVE_PRICE) as ALL_TIME_LOW_PRICE,
        max(h.EFFECTIVE_PRICE) as ALL_TIME_HIGH_PRICE,
        count_if(h.IS_ON_PROMO) / count(*) as PROMO_WEEK_SHARE,
        count_if(h.IS_ON_PROMO and not coalesce(h.PREV_IS_ON_PROMO, false)) as PROMO_EPISODES,
        avg(iff(h.IS_ON_PROMO, h.DISCOUNT_PCT, null)) as AVG_PROMO_DISCOUNT_PCT,

        count_if(h.PRICE_WEEK > dateadd('week', -{{ trailing }}, c.PRICE_WEEK)) as WEEKS_OBSERVED_TRAILING,
        min(iff(h.PRICE_WEEK > dateadd('week', -{{ trailing }}, c.PRICE_WEEK), h.EFFECTIVE_PRICE, null)) as TRAILING_LOW_PRICE,
        median(iff(h.PRICE_WEEK > dateadd('week', -{{ trailing }}, c.PRICE_WEEK), h.EFFECTIVE_PRICE, null)) as TRAILING_MEDIAN_PRICE,
        max(iff(h.PRICE_WEEK > dateadd('week', -{{ trailing }}, c.PRICE_WEEK), h.EFFECTIVE_PRICE, null)) as TRAILING_HIGH_PRICE,
        median(iff(h.PRICE_WEEK > dateadd('week', -{{ trailing }}, c.PRICE_WEEK), h.REGULAR_PRICE, null)) as TRAILING_MEDIAN_REGULAR_PRICE,
        count_if(h.PRICE_WEEK > dateadd('week', -{{ trailing }}, c.PRICE_WEEK)
                 and h.EFFECTIVE_PRICE < c.EFFECTIVE_PRICE) as TRAILING_WEEKS_CHEAPER

    from with_prev h
    join current_obs c
        on c.PRODUCT_KEY = h.PRODUCT_KEY
        and c.STORE_ID = h.STORE_ID
    group by h.PRODUCT_KEY, h.STORE_ID

),

refs as (

    select
        PRODUCT_KEY,
        STORE_ID,
        PRICE_WEEK,
        dateadd('week', -4, PRICE_WEEK) as TARGET_4W,
        dateadd('week', -8, PRICE_WEEK) as TARGET_8W,
        dateadd('week', -12, PRICE_WEEK) as TARGET_12W
    from current_obs

),

ref_4w as (
    select r.PRODUCT_KEY, r.STORE_ID, w.PRICE_WEEK as REF_WEEK_4W, w.EFFECTIVE_PRICE as PRICE_4W_AGO
    from refs r
    asof join weekly w
        match_condition (r.TARGET_4W >= w.PRICE_WEEK)
        on r.PRODUCT_KEY = w.PRODUCT_KEY and r.STORE_ID = w.STORE_ID
),

ref_8w as (
    select r.PRODUCT_KEY, r.STORE_ID, w.PRICE_WEEK as REF_WEEK_8W, w.EFFECTIVE_PRICE as PRICE_8W_AGO
    from refs r
    asof join weekly w
        match_condition (r.TARGET_8W >= w.PRICE_WEEK)
        on r.PRODUCT_KEY = w.PRODUCT_KEY and r.STORE_ID = w.STORE_ID
),

ref_12w as (
    select r.PRODUCT_KEY, r.STORE_ID, w.PRICE_WEEK as REF_WEEK_12W, w.EFFECTIVE_PRICE as PRICE_12W_AGO
    from refs r
    asof join weekly w
        match_condition (r.TARGET_12W >= w.PRICE_WEEK)
        on r.PRODUCT_KEY = w.PRODUCT_KEY and r.STORE_ID = w.STORE_ID
)

select
    c.PRODUCT_KEY,
    c.RETAILER,
    c.PRODUCT_ID,
    c.STORE_ID,

    ---------- current
    c.PRICE_WEEK as CURRENT_WEEK,
    c.OBSERVED_AT as DATA_AS_OF,
    c.PRICE_WEEK = rl.RETAILER_LATEST_WEEK as IS_CURRENTLY_LISTED,
    rl.RETAILER_LATEST_WEEK,
    c.REGULAR_PRICE as CURRENT_REGULAR_PRICE,
    c.PROMO_PRICE as CURRENT_PROMO_PRICE,
    c.EFFECTIVE_PRICE as CURRENT_PRICE,
    c.IS_ON_PROMO,
    c.DISCOUNT_PCT as CURRENT_DISCOUNT_PCT,

    ---------- history
    h.FIRST_OBSERVED_WEEK,
    h.WEEKS_OBSERVED,
    h.WEEKS_OBSERVED_TRAILING,
    h.TRAILING_LOW_PRICE,
    h.TRAILING_MEDIAN_PRICE,
    h.TRAILING_HIGH_PRICE,
    iff(h.WEEKS_OBSERVED_TRAILING > 1,
        round(h.TRAILING_WEEKS_CHEAPER / (h.WEEKS_OBSERVED_TRAILING - 1), 4), null) as PRICE_PERCENTILE,
    h.ALL_TIME_LOW_PRICE,
    h.ALL_TIME_HIGH_PRICE,
    c.EFFECTIVE_PRICE <= h.ALL_TIME_LOW_PRICE and h.WEEKS_OBSERVED > 1 as IS_AT_HISTORIC_LOW,

    ---------- movers
    r4.REF_WEEK_4W,
    r4.PRICE_4W_AGO,
    c.EFFECTIVE_PRICE - r4.PRICE_4W_AGO as CHANGE_4W,
    round((c.EFFECTIVE_PRICE - r4.PRICE_4W_AGO) / nullif(r4.PRICE_4W_AGO, 0), 4) as CHANGE_4W_PCT,
    r8.REF_WEEK_8W,
    r8.PRICE_8W_AGO,
    c.EFFECTIVE_PRICE - r8.PRICE_8W_AGO as CHANGE_8W,
    round((c.EFFECTIVE_PRICE - r8.PRICE_8W_AGO) / nullif(r8.PRICE_8W_AGO, 0), 4) as CHANGE_8W_PCT,
    r12.REF_WEEK_12W,
    r12.PRICE_12W_AGO,
    c.EFFECTIVE_PRICE - r12.PRICE_12W_AGO as CHANGE_12W,
    round((c.EFFECTIVE_PRICE - r12.PRICE_12W_AGO) / nullif(r12.PRICE_12W_AGO, 0), 4) as CHANGE_12W_PCT,

    ---------- promos
    round(h.PROMO_WEEK_SHARE, 4) as PROMO_WEEK_SHARE,
    h.PROMO_EPISODES,
    round(h.AVG_PROMO_DISCOUNT_PCT, 4) as AVG_PROMO_DISCOUNT_PCT,
    iff(h.PROMO_EPISODES > 0, round(h.WEEKS_OBSERVED / h.PROMO_EPISODES, 1), null) as WEEKS_PER_PROMO,
    case
        when not c.IS_ON_PROMO then 'NOT_ON_PROMO'
        when c.RETAILER = 'walmart'
             and c.REGULAR_PRICE >= {{ var('deal_inflated_reference_ratio') }} * h.ALL_TIME_HIGH_PRICE
            then 'INFLATED_REFERENCE'
        when c.EFFECTIVE_PRICE <= (1 - {{ var('deal_genuine_discount_pct') }}) * h.TRAILING_MEDIAN_REGULAR_PRICE
             and h.PROMO_WEEK_SHARE < {{ var('deal_routine_promo_share') }}
            then 'GENUINE'
        else 'ORDINARY'
    end as DEAL_QUALITY

from current_obs c
join retailer_latest rl
    on rl.RETAILER = c.RETAILER
join history h
    on h.PRODUCT_KEY = c.PRODUCT_KEY
    and h.STORE_ID = c.STORE_ID
left join ref_4w r4
    on r4.PRODUCT_KEY = c.PRODUCT_KEY and r4.STORE_ID = c.STORE_ID
left join ref_8w r8
    on r8.PRODUCT_KEY = c.PRODUCT_KEY and r8.STORE_ID = c.STORE_ID
left join ref_12w r12
    on r12.PRODUCT_KEY = c.PRODUCT_KEY and r12.STORE_ID = c.STORE_ID
