{{ config(materialized='view') }}

-- Fans out RESTRICTIONS (array). NOTE: confirmed via live data that
-- RESTRICTIONS is an empty array [] on every single row in the dataset
-- today — this model will correctly return 0 rows until Kroger actually
-- populates it for some product. Because there's no real data to derive
-- element field names/types from, RESTRICTION stays VARIANT (the one
-- exception to "nothing nested" in this pass) — revisit and flatten
-- properly once a real example exists to verify structure against,
-- rather than guessing at a shape with zero live examples to check.

with source as (

    select * from {{ ref('stg_json_kroger_product_snapshot') }}

)

select
    LOCATION_ID,
    PRODUCT_ID,
    SOURCE_PIPELINE,
    COLLECTED_AT,
    INGESTED_FILENAME,
    r.value as RESTRICTION

from source,
lateral flatten(input => RESTRICTIONS) r
