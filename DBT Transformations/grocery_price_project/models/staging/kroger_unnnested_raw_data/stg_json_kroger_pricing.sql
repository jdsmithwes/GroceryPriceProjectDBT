{{ config(materialized='view') }}

-- Flattens RAW_DATA's JSON keys into columns for
-- GROCERYDBTPROJECT.RAW.KROGER_PRICING. raw_data here is the FULL Kroger
-- product object (same shape as stg_json_kroger_inventory, since both
-- pipelines land the identical raw response — see the NOTE in
-- Kroger_Pricing_*.py). LOCATION_ID is kept from the outer staging model
-- since it's NOT part of the product JSON itself (it's the store this
-- pull was scoped to, tracked separately by the pipeline).
--
-- ITEM_INFORMATION, RATINGS_AND_REVIEWS, and TEMPERATURE are fixed-shape
-- objects, fully flattened here. All keys verified against the live data
-- (key-union query across every row), not a single sample.
--
-- CATEGORIES, AISLE_LOCATIONS, ALIAS_PRODUCT_IDS, ALLERGENS, IMAGES,
-- ITEMS, MANUFACTURER_DECLARATIONS, NUTRITION_INFORMATION, RESTRICTIONS,
-- and SWEETENING_METHODS are left as VARIANT (arrays), NOT flattened
-- here: they're variable-length per product, and at least one (ITEMS)
-- carries the actual price/inventory data this whole pipeline exists
-- for. Turning any of these into columns would require a separate model
-- at a different grain (one row per product+array-element), not just
-- more columns on this one — a bigger decision than "add a column,"
-- worth deciding deliberately rather than guessing.

with source as (

    select * from {{ ref('stg_kroger_pricing') }}

),

parsed as (

    select
        LOCATION_ID,
        COLLECTED_AT,
        INGESTED_FILENAME,
        parse_json(RAW_DATA) as json_data

    from source

),

renamed as (

    select
        LOCATION_ID,
        COLLECTED_AT,
        INGESTED_FILENAME,

        ---------- scalars
        json_data:"productId"::string as PRODUCT_ID,
        json_data:"upc"::string as UPC,
        json_data:"productPageURI"::string as PRODUCT_PAGE_URI,
        json_data:"brand"::string as BRAND,
        json_data:"countryOrigin"::string as COUNTRY_ORIGIN,
        json_data:"description"::string as DESCRIPTION,
        json_data:"snapEligible"::boolean as SNAP_ELIGIBLE,
        json_data:"allergensDescription"::string as ALLERGENS_DESCRIPTION,
        json_data:"organicClaimName"::string as ORGANIC_CLAIM_NAME,
        json_data:"nonGmo"::boolean as NON_GMO,
        json_data:"nonGmoClaimName"::string as NON_GMO_CLAIM_NAME,
        json_data:"hypoallergenic"::boolean as HYPOALLERGENIC,
        json_data:"certifiedForPassover"::boolean as CERTIFIED_FOR_PASSOVER,
        json_data:"receiptDescription"::string as RECEIPT_DESCRIPTION,
        json_data:"warnings"::string as WARNINGS,
        json_data:"ageRestriction"::boolean as AGE_RESTRICTION,

        ---------- itemInformation (flattened)
        json_data:"itemInformation"."depth"::string as ITEM_DEPTH,
        json_data:"itemInformation"."height"::string as ITEM_HEIGHT,
        json_data:"itemInformation"."width"::string as ITEM_WIDTH,
        json_data:"itemInformation"."grossWeight"::string as ITEM_GROSS_WEIGHT,
        json_data:"itemInformation"."netWeight"::string as ITEM_NET_WEIGHT,
        json_data:"itemInformation"."averageWeightPerUnit"::string as ITEM_AVERAGE_WEIGHT_PER_UNIT,

        ---------- ratingsAndReviews (flattened)
        json_data:"ratingsAndReviews"."averageOverallRating"::float as AVERAGE_OVERALL_RATING,
        json_data:"ratingsAndReviews"."totalReviewCount"::number as TOTAL_REVIEW_COUNT,

        ---------- temperature (flattened)
        json_data:"temperature"."indicator"::string as TEMPERATURE_INDICATOR,
        json_data:"temperature"."heatSensitive"::boolean as TEMPERATURE_HEAT_SENSITIVE,

        ---------- arrays, not flattened (see note above)
        json_data:"categories" as CATEGORIES,
        json_data:"aisleLocations" as AISLE_LOCATIONS,
        json_data:"aliasProductIds" as ALIAS_PRODUCT_IDS,
        json_data:"allergens" as ALLERGENS,
        json_data:"images" as IMAGES,
        json_data:"items" as ITEMS,
        json_data:"manufacturerDeclarations" as MANUFACTURER_DECLARATIONS,
        json_data:"nutritionInformation" as NUTRITION_INFORMATION,
        json_data:"restrictions" as RESTRICTIONS,
        json_data:"sweeteningMethods" as SWEETENING_METHODS

    from parsed

)

select * from renamed
