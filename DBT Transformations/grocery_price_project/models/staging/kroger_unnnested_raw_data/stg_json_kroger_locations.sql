{{ config(materialized='view') }}

-- Flattens RAW_DATA's JSON keys into columns for
-- GROCERYDBTPROJECT.RAW.KROGER_LOCATIONS. All keys verified against the
-- live data (key-union query across every row), not a single sample.
--
-- ADDRESS, GEOLOCATION, and HOURS are fixed-shape objects, fully
-- flattened here (HOURS is deeply nested — each day is its own
-- {open, close, open24} object, also flattened).
--
-- DEPARTMENTS is left as VARIANT (array), NOT flattened here: it's
-- variable-length per location (one store had 38 departments, and
-- element shape isn't uniform — the Pharmacy entry has extra phone/hours
-- fields others don't). Turning it into columns would require a separate
-- model at a different grain (one row per location+department), not just
-- more columns on this one — a bigger decision than "add a column."

with source as (

    select * from {{ ref('stg_kroger_locations') }}

),

parsed as (

    select
        REGION,
        COLLECTED_AT,
        INGESTED_FILENAME,
        parse_json(RAW_DATA) as json_data

    from source

),

renamed as (

    select
        REGION,
        COLLECTED_AT,
        INGESTED_FILENAME,

        ---------- top-level scalars
        json_data:"locationId"::string as LOCATION_ID,
        json_data:"storeNumber"::string as STORE_NUMBER,
        json_data:"divisionNumber"::string as DIVISION_NUMBER,
        json_data:"chain"::string as CHAIN,
        json_data:"name"::string as NAME,
        json_data:"phone"::string as PHONE,

        ---------- address (flattened)
        json_data:"address"."addressLine1"::string as ADDRESS_LINE1,
        json_data:"address"."city"::string as CITY,
        json_data:"address"."state"::string as STATE,
        json_data:"address"."zipCode"::string as ZIP_CODE,
        json_data:"address"."county"::string as COUNTY,

        ---------- geolocation (flattened)
        json_data:"geolocation"."latitude"::float as LATITUDE,
        json_data:"geolocation"."longitude"::float as LONGITUDE,
        json_data:"geolocation"."latLng"::string as LAT_LNG,

        ---------- hours (flattened, incl. each day sub-object)
        json_data:"hours"."timezone"::string as HOURS_TIMEZONE,
        json_data:"hours"."gmtOffset"::string as HOURS_GMT_OFFSET,
        json_data:"hours"."open24"::boolean as HOURS_OPEN24,
        json_data:"hours"."monday"."open"::string as MONDAY_OPEN,
        json_data:"hours"."monday"."close"::string as MONDAY_CLOSE,
        json_data:"hours"."monday"."open24"::boolean as MONDAY_OPEN24,
        json_data:"hours"."tuesday"."open"::string as TUESDAY_OPEN,
        json_data:"hours"."tuesday"."close"::string as TUESDAY_CLOSE,
        json_data:"hours"."tuesday"."open24"::boolean as TUESDAY_OPEN24,
        json_data:"hours"."wednesday"."open"::string as WEDNESDAY_OPEN,
        json_data:"hours"."wednesday"."close"::string as WEDNESDAY_CLOSE,
        json_data:"hours"."wednesday"."open24"::boolean as WEDNESDAY_OPEN24,
        json_data:"hours"."thursday"."open"::string as THURSDAY_OPEN,
        json_data:"hours"."thursday"."close"::string as THURSDAY_CLOSE,
        json_data:"hours"."thursday"."open24"::boolean as THURSDAY_OPEN24,
        json_data:"hours"."friday"."open"::string as FRIDAY_OPEN,
        json_data:"hours"."friday"."close"::string as FRIDAY_CLOSE,
        json_data:"hours"."friday"."open24"::boolean as FRIDAY_OPEN24,
        json_data:"hours"."saturday"."open"::string as SATURDAY_OPEN,
        json_data:"hours"."saturday"."close"::string as SATURDAY_CLOSE,
        json_data:"hours"."saturday"."open24"::boolean as SATURDAY_OPEN24,
        json_data:"hours"."sunday"."open"::string as SUNDAY_OPEN,
        json_data:"hours"."sunday"."close"::string as SUNDAY_CLOSE,
        json_data:"hours"."sunday"."open24"::boolean as SUNDAY_OPEN24,

        ---------- array, not flattened (see note above)
        json_data:"departments" as DEPARTMENTS

    from parsed

)

select * from renamed
