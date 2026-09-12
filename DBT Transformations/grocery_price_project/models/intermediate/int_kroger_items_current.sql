{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- Latest stg_json_kroger_product_snapshot_items row per PRODUCT_ID +
-- LOCATION_ID — current stock level and fulfillment options per store.
-- Precomputed so the Streamlit app doesn't re-rank the full items history
-- on every page load. SOURCE_PIPELINE/ITEM_ID break COLLECTED_AT ties so
-- the chosen row is deterministic.

select *

from {{ ref('stg_json_kroger_product_snapshot_items') }}
qualify row_number() over (
    partition by PRODUCT_ID, LOCATION_ID
    order by COLLECTED_AT desc, SOURCE_PIPELINE, ITEM_ID
) = 1
