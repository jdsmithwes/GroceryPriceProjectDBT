{{ config(materialized='view') }}

-- Convenience "current state" view over stg_json_kroger_locations: one
-- row per LOCATION_ID, keeping only the most recent COLLECTED_AT.
--
-- Same raw-landing situation as the product catalog: stg_json_kroger_locations
-- is append-only (every Kroger_Location_*.py run lands new rows), so
-- LOCATION_ID alone is not unique there. This model exists so callers who
-- just want "the store list right now" don't have to think about
-- collection-run duplicates — the full history of location detail changes
-- over time stays available upstream in stg_json_kroger_locations if ever
-- needed. select * (rather than an explicit column list) is intentional
-- here — this model doesn't reshape anything, just picks the latest row
-- per store out of ~30 passthrough columns.

with source as (

    select *

    from {{ ref('stg_json_kroger_locations') }}
    qualify row_number() over (
        partition by LOCATION_ID
        order by COLLECTED_AT desc
    ) = 1

)

select *

from source
order by LOCATION_ID
