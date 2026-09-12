{{ config(materialized='view') }}

-- Convenience "current state" view over stg_kroger_product_catalog: one
-- row per PRODUCT_ID, keeping only the most recent COLLECTED_AT.
--
-- stg_kroger_product_catalog is intentionally append-only (raw-landing
-- convention — every entire_productcatalog_kroger.py run lands new rows
-- rather than overwriting), so PRODUCT_ID alone is NOT unique there; see
-- that model's unique_combination_of_columns(PRODUCT_ID, INGESTED_FILENAME)
-- test. This model exists purely so callers who just want "the catalog
-- right now" don't have to think about collection-run duplicates — it
-- does not replace the staging model as a source for anything that cares
-- about catalog history over time (e.g. a future model tracking when a
-- description/brand changed), which stays fully available upstream. Same
-- collapse-to-latest idea as int_kroger_price_history, just picking the
-- latest row outright instead of collapsing consecutive-unchanged spans,
-- since there's no "version" concept here — only ever one current row.

with source as (

    select *

    from {{ ref('stg_kroger_product_catalog') }}
    qualify row_number() over (
        partition by PRODUCT_ID
        order by COLLECTED_AT desc
    ) = 1

)

select
    PRODUCT_ID,
    UPC,
    BRAND,
    DESCRIPTION,
    CATEGORIES,
    COUNTRY_ORIGIN,
    TEMPERATURE,
    SIZE,
    SOLD_BY,
    IMAGE_URL,
    COLLECTED_AT,
    INGESTED_FILENAME

from source
order by PRODUCT_ID
