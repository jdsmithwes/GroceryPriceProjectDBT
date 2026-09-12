{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- Materialized as a dynamic table (not view): same reasoning as
-- int_kroger_price_history — 12 queries/7 days measured at ~1.19s and
-- ~121MB scanned each as a view. Refreshes itself within 24h of new RAW
-- data; FULL refresh for the same every-partition-changes-weekly reason.
--
-- Companion to int_kroger_price_history: tracks SPANS where a product
-- had NEITHER a PRICE_REGULAR NOR a PRICE_PROMO at a given
-- PRODUCT_ID + LOCATION_ID — i.e. not actively carried/priced at that
-- store — using the same SCD Type 2 collapse-consecutive-observations
-- pattern.
--
-- Unlike int_kroger_price_history, this model needs the FULL observation
-- sequence (priced and unpriced alike) before filtering, not after —
-- detecting the transition INTO and OUT OF an unpriced span requires
-- seeing what came immediately before/after it. The final WHERE only
-- keeps the collapsed spans that were actually unpriced.
--
-- If a product goes from unpriced to priced, this model's row for that
-- span gets IS_CURRENT = FALSE (VALID_TO populated with the timestamp
-- pricing resumed) — the flip side of int_kroger_price_history's first
-- surviving version for that product+location, whose VALID_FROM is that
-- same timestamp. IS_CURRENT = TRUE here means the product is unpriced
-- as of the most recent observation and has no corresponding row (yet)
-- in int_kroger_price_history.

with source as (

    select
        PRODUCT_ID,
        LOCATION_ID,
        COLLECTED_AT,
        (PRICE_REGULAR is null and PRICE_PROMO is null) as IS_UNPRICED

    from {{ ref('stg_json_kroger_product_snapshot_items') }}

),

with_change_flag as (

    select
        *,
        case
            when IS_UNPRICED is distinct from lag(IS_UNPRICED) over (
                partition by PRODUCT_ID, LOCATION_ID order by COLLECTED_AT
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
            partition by PRODUCT_ID, LOCATION_ID
            order by COLLECTED_AT
            rows between unbounded preceding and current row
        ) as VERSION_NUMBER

    from with_change_flag

),

collapsed as (

    -- IS_UNPRICED is constant within a version by construction, same
    -- reasoning as int_kroger_price_history's MIN(PRICE_REGULAR) — just
    -- picking the one value, via BOOLOR_AGG rather than MIN/MAX since
    -- Snowflake's aggregate typing on BOOLEAN is otherwise ambiguous.
    select
        PRODUCT_ID,
        LOCATION_ID,
        VERSION_NUMBER,
        min(COLLECTED_AT) as VALID_FROM,
        max(COLLECTED_AT) as LAST_SEEN_AT,
        boolor_agg(IS_UNPRICED) as IS_UNPRICED

    from with_version_number
    group by PRODUCT_ID, LOCATION_ID, VERSION_NUMBER

),

final as (

    select
        PRODUCT_ID,
        LOCATION_ID,
        IS_UNPRICED,
        VALID_FROM,
        lead(VALID_FROM) over (
            partition by PRODUCT_ID, LOCATION_ID order by VALID_FROM
        ) as VALID_TO,
        LAST_SEEN_AT,
        lead(VALID_FROM) over (
            partition by PRODUCT_ID, LOCATION_ID order by VALID_FROM
        ) is null as IS_CURRENT

    from collapsed

)

select
    PRODUCT_ID,
    LOCATION_ID,
    VALID_FROM,
    VALID_TO,
    LAST_SEEN_AT,
    IS_CURRENT

from final
where IS_UNPRICED
