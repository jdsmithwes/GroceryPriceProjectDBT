{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- SCD Type 2 price history, one row per contiguous span of unchanged
-- PRICE_REGULAR/PRICE_PROMO for a given PRODUCT_ID + LOCATION_ID.
--
-- Materialized as a dynamic table (not view): as a view this re-ran the
-- full window-function pass on every query (49 queries/7 days measured,
-- ~1.85s and ~580MB scanned each). As a dynamic table it refreshes itself
-- within 24h of new RAW data landing — no manual `dbt run` after each
-- collection. refresh_mode FULL, not INCREMENTAL: every weekly sweep adds
-- an observation to nearly every PRODUCT_ID + LOCATION_ID partition, so an
-- incremental refresh would recompute almost every window partition anyway.
--
-- The raw layer is already append-only (every ingestion run lands new
-- rows in RAW.KROGER_PRICING/KROGER_INVENTORY rather than overwriting),
-- so the full price history already exists in
-- stg_json_kroger_product_snapshot_items — this model doesn't need a
-- dbt snapshot to *create* history, it needs to *collapse* the existing
-- one: most collection runs repeat the same price, so a naive "one row
-- per COLLECTED_AT" view would be mostly redundant noise.
--
-- A new version starts whenever PRICE_REGULAR or PRICE_PROMO actually
-- changes from the immediately preceding observation for that same
-- product+location. IS DISTINCT FROM (not !=) is required for the
-- comparison, since PRICE_PROMO is NULL whenever there's no active
-- promo — a promo starting or ending is a NULL <-> non-NULL transition,
-- and != would silently evaluate to NULL (never TRUE) across that
-- transition, missing the change entirely.
--
-- Caveat: VALID_FROM/VALID_TO reflect when THIS PIPELINE observed the
-- change, not necessarily when Kroger's price actually changed —
-- bounded by how often the ingestion scripts are run (currently manual,
-- not scheduled). A price that changed and changed back between two
-- runs would never be detected.
--
-- Filtered to rows that have a PRICE_REGULAR and/or PRICE_PROMO —
-- products with neither (not actively carried/priced at this store)
-- are tracked separately in int_kroger_unpriced_history instead, at
-- the same grain. This filter is applied before the change-detection
-- window functions below, not after, so an unpriced gap between two
-- identical-price observations doesn't fracture what is otherwise one
-- continuous price version — gap tracking is that other model's job.
-- One direct consequence: for a product that starts out unpriced and
-- later gets a price, the resulting first row here has no earlier
-- version to compare against, so its VALID_FROM *is* the date pricing
-- became active for that product+location — no separate column needed.

with source as (

    select
        PRODUCT_ID,
        LOCATION_ID,
        COLLECTED_AT,
        PRICE_REGULAR,
        PRICE_PROMO

    from {{ ref('stg_json_kroger_product_snapshot_items') }}
    where PRICE_REGULAR is not null or PRICE_PROMO is not null

),

with_change_flag as (

    select
        *,
        case
            when PRICE_REGULAR is distinct from lag(PRICE_REGULAR) over (
                partition by PRODUCT_ID, LOCATION_ID order by COLLECTED_AT
            )
            or PRICE_PROMO is distinct from lag(PRICE_PROMO) over (
                partition by PRODUCT_ID, LOCATION_ID order by COLLECTED_AT
            )
            then 1
            else 0
        end as IS_NEW_VERSION

    from source

),

with_version_number as (

    -- Running count of version-starts up to and including this row —
    -- every row within the same unbroken price span shares a number.
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

    -- One row per version. PRICE_REGULAR/PRICE_PROMO are constant
    -- within a version by construction (that's what IS_NEW_VERSION
    -- guarantees), so MIN() here is just "pick the one value" — not a
    -- real aggregation.
    select
        PRODUCT_ID,
        LOCATION_ID,
        VERSION_NUMBER,
        min(COLLECTED_AT) as VALID_FROM,
        max(COLLECTED_AT) as LAST_SEEN_AT,
        min(PRICE_REGULAR) as PRICE_REGULAR,
        min(PRICE_PROMO) as PRICE_PROMO

    from with_version_number
    group by PRODUCT_ID, LOCATION_ID, VERSION_NUMBER

)

select
    PRODUCT_ID,
    LOCATION_ID,
    PRICE_REGULAR,
    PRICE_PROMO,
    VALID_FROM,
    lead(VALID_FROM) over (
        partition by PRODUCT_ID, LOCATION_ID order by VALID_FROM
    ) as VALID_TO,
    LAST_SEEN_AT,
    lead(VALID_FROM) over (
        partition by PRODUCT_ID, LOCATION_ID order by VALID_FROM
    ) is null as IS_CURRENT

from collapsed
