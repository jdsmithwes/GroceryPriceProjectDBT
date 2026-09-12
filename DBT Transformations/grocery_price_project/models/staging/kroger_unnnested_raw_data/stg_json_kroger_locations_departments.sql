{{ config(materialized='view') }}

-- Fans out DEPARTMENTS (array, variable-length, non-uniform per element —
-- most departments are just {departmentId, name}, but some also carry
-- their own address/geolocation/hours/phone/offsite, e.g. off-site
-- Pharmacy). Grain: one row per location + department. All keys verified
-- against the live data (key-union query across every element), not a
-- single sample. Day-of-week hours sub-objects are assumed to share the
-- same {open, close, open24} shape as the parent location's HOURS
-- (confirmed for the day-keys themselves; not independently re-verified
-- per day for departments) — Snowflake's : path access returns NULL for
-- any missing key rather than erroring, so this is safe either way.

with source as (

    select * from {{ ref('stg_json_kroger_locations') }}

),

departments as (

    select
        LOCATION_ID,
        REGION,
        COLLECTED_AT,
        INGESTED_FILENAME,
        d.value as department

    from source,
    lateral flatten(input => DEPARTMENTS) d

),

renamed as (

    select
        LOCATION_ID,
        REGION,
        COLLECTED_AT,
        INGESTED_FILENAME,

        ---------- scalars
        department:"departmentId"::string as DEPARTMENT_ID,
        department:"name"::string as DEPARTMENT_NAME,
        department:"phone"::string as DEPARTMENT_PHONE,
        department:"offsite"::boolean as DEPARTMENT_OFFSITE,

        ---------- address (flattened; department-level has no county)
        department:"address"."addressLine1"::string as ADDRESS_LINE1,
        department:"address"."city"::string as CITY,
        department:"address"."state"::string as STATE,
        department:"address"."zipCode"::string as ZIP_CODE,

        ---------- geolocation (flattened)
        department:"geolocation"."latitude"::float as LATITUDE,
        department:"geolocation"."longitude"::float as LONGITUDE,
        department:"geolocation"."latLng"::string as LAT_LNG,

        ---------- hours (flattened, incl. each day sub-object; no timezone/gmtOffset at department level)
        department:"hours"."open24"::boolean as HOURS_OPEN24,
        department:"hours"."monday"."open"::string as MONDAY_OPEN,
        department:"hours"."monday"."close"::string as MONDAY_CLOSE,
        department:"hours"."monday"."open24"::boolean as MONDAY_OPEN24,
        department:"hours"."tuesday"."open"::string as TUESDAY_OPEN,
        department:"hours"."tuesday"."close"::string as TUESDAY_CLOSE,
        department:"hours"."tuesday"."open24"::boolean as TUESDAY_OPEN24,
        department:"hours"."wednesday"."open"::string as WEDNESDAY_OPEN,
        department:"hours"."wednesday"."close"::string as WEDNESDAY_CLOSE,
        department:"hours"."wednesday"."open24"::boolean as WEDNESDAY_OPEN24,
        department:"hours"."thursday"."open"::string as THURSDAY_OPEN,
        department:"hours"."thursday"."close"::string as THURSDAY_CLOSE,
        department:"hours"."thursday"."open24"::boolean as THURSDAY_OPEN24,
        department:"hours"."friday"."open"::string as FRIDAY_OPEN,
        department:"hours"."friday"."close"::string as FRIDAY_CLOSE,
        department:"hours"."friday"."open24"::boolean as FRIDAY_OPEN24,
        department:"hours"."saturday"."open"::string as SATURDAY_OPEN,
        department:"hours"."saturday"."close"::string as SATURDAY_CLOSE,
        department:"hours"."saturday"."open24"::boolean as SATURDAY_OPEN24,
        department:"hours"."sunday"."open"::string as SUNDAY_OPEN,
        department:"hours"."sunday"."close"::string as SUNDAY_CLOSE,
        department:"hours"."sunday"."open24"::boolean as SUNDAY_OPEN24

    from departments

)

select * from renamed
