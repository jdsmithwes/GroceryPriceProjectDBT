-- target_lag='downstream' (2026-11-17): refresh only when a mart that depends on this table refreshes,
-- so the whole chain wakes COMPUTE_WH once per mart cycle instead of on its own 24 h clock.
-- Freshness is unchanged: the marts keep their 24-hour lag. Only tables with a dynamic-table
-- consumer may use this; int_kroger_unpriced_history has none and keeps '24 hours'.
{{ config(
    materialized='dynamic_table',
    target_lag='downstream',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL',
    schema='intermediate_walmart'
) }}

-- SCD Type 2 price history, one row per contiguous span of unchanged
-- MSRP/SALE_PRICE for a given ITEM_ID. Direct mirror of
-- int_kroger_price_history's technique; grain is ITEM_ID alone (Walmart
-- catalog pricing is national, no store/location dimension the way
-- Kroger's is).
--
-- Dynamic table (was a view until the grocery value agent): the agent's
-- marts read this on every question, so the window-function pass is
-- precomputed once per weekly load, same as Kroger's.
--
-- A new version starts whenever MSRP or SALE_PRICE actually changes from
-- the immediately preceding observation for that same item. IS DISTINCT
-- FROM (not !=) is required for the comparison, since both price fields
-- can be NULL — a NULL <-> non-NULL transition is itself a version
-- boundary, and != would silently evaluate to NULL (never TRUE) across it.
--
-- Filtered to rows that have an MSRP and/or SALE_PRICE — items with
-- neither are not tracked here (an int_walmart_unpriced_history companion,
-- mirroring int_kroger_unpriced_history, is a natural follow-up given
-- ~57%/~16% NULL rates on MSRP/SALE_PRICE, but out of scope for this
-- first model).

with source as (

    select
        ITEM_ID,
        COLLECTED_AT,
        MSRP,
        SALE_PRICE

    from {{ ref('stg_walmart_product_catalog') }}
    where MSRP is not null or SALE_PRICE is not null

),

with_change_flag as (

    select
        *,
        case
            when MSRP is distinct from lag(MSRP) over (
                partition by ITEM_ID order by COLLECTED_AT
            )
            or SALE_PRICE is distinct from lag(SALE_PRICE) over (
                partition by ITEM_ID order by COLLECTED_AT
            )
            then 1
            else 0
        end as IS_NEW_VERSION

    from source

),

with_version_number as (

    select
        *,
        sum(IS_NEW_VERSION) over (
            partition by ITEM_ID
            order by COLLECTED_AT
            rows between unbounded preceding and current row
        ) as VERSION_NUMBER

    from with_change_flag

),

collapsed as (

    select
        ITEM_ID,
        VERSION_NUMBER,
        min(COLLECTED_AT) as VALID_FROM,
        max(COLLECTED_AT) as LAST_SEEN_AT,
        min(MSRP) as MSRP,
        min(SALE_PRICE) as SALE_PRICE

    from with_version_number
    group by ITEM_ID, VERSION_NUMBER

)

select
    ITEM_ID,
    MSRP,
    SALE_PRICE,
    VALID_FROM,
    lead(VALID_FROM) over (
        partition by ITEM_ID order by VALID_FROM
    ) as VALID_TO,
    LAST_SEEN_AT,
    lead(VALID_FROM) over (
        partition by ITEM_ID order by VALID_FROM
    ) is null as IS_CURRENT

from collapsed
order by ITEM_ID, VALID_FROM
