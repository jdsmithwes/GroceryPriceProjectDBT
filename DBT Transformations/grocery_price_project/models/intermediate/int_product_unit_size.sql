{{ config(materialized='view', schema='intermediate_common') }}

-- Package size per product, normalized to one unit basis so prices can be
-- compared per ounce (ontology: Unit Price):
--   UNIT_BASIS 'oz'    weight in ounces (lb, g, kg converted)
--   UNIT_BASIS 'fl_oz' volume in fluid ounces (ml, l, qt, pt, gal converted)
--   UNIT_BASIS 'ct'    item count, when no weight/volume is given
--
-- Sources and conventions (profiled 2026-11-15):
--   Kroger SIZE is structured: "16 oz", "12 fl oz", "1/2 gal". Liquid
--     multipacks give the size PER CONTAINER ("4 pk / 12 fl oz" = 48 fl oz),
--     so pk/ct/bottles/cans multiply. WEIGHT multipacks are ambiguous and
--     flagged low: "12 ct / 1.2 oz" (bars) is per item, but "8 ct / 13 oz"
--     (Texas Toast) and "18 pk / 12.7 oz" (Babybel) are totals — found in the
--     2026-11-15 spot check, where the per-item reading was 8-44x too big.
--     "8 slices / 6 oz" (cheese) is the TOTAL, so slices/sticks don't
--     multiply.
--   Walmart has no size field; the size is in NAME ("..., 15.25 oz",
--     "24 fl oz Jar"). The LAST weight/volume token is used. "N-Pack (X oz
--     Each)" multiplies. A name with a count AND one weight but no "each"
--     is ambiguous — "20 Ct, 1.3 Oz" is a total, "1.0 oz, 12 Packets" is per
--     packet — so those are flagged low confidence.
--
-- PARSE_CONFIDENCE: high (unambiguous), low (parsed, but answers should
-- caveat the per-unit price), none (no usable size — no unit price).
--
-- A view, not a dynamic table: it reads only views over raw tables, and the
-- marts (dynamic tables) may read a view as long as it contains no dynamic
-- tables (see the int_retailer_common_upcs note).

{% set units = 'floz|fo|ounces|ounce|onz|oza|oz|pounds|pound|lbs|lbr|lb|kg|grams|gram|gallons|gallon|gal|ml|liters|liter|litre|quarts|quart|qt|pints|pint|pt|g|l' %}
{% set count_words = 'count|ct|each|ea|packets|packs|pack|pk|pieces|piece|pcs|pc|capsules|pods|bags|rolls|bars|bottles|cans' %}
{% set num = '[0-9]*[.]?[0-9]+' %}
{% set measure_re = num ~ ' ?(' ~ units ~ ')([^a-z]|$)' %}
{% set count_re = num ~ ' ?-? ?(' ~ count_words ~ ')([^a-z]|$)' %}


with products as (

    select
        'kroger' as RETAILER,
        PRODUCT_ID,
        SIZE as SIZE_SOURCE

    from {{ ref('int_kroger_product_catalog_current') }}

    union all

    select
        'walmart' as RETAILER,
        ITEM_ID as PRODUCT_ID,
        NAME as SIZE_SOURCE

    from {{ ref('stg_walmart_product_catalog') }}
    qualify row_number() over (
        partition by ITEM_ID
        order by COLLECTED_AT desc, INGESTED_FILENAME desc
    ) = 1

),

normalized as (

    select
        *,
        regexp_replace(
            replace(replace(lower(SIZE_SOURCE), 'half gal', '0.5 gal'), '1/2 gal', '0.5 gal'),
            'fl[.]? ?oz[.]?|fluid ounces?', 'floz'
        ) as T

    from products

),

tokens as (

    select
        *,
        regexp_substr_all(T, '{{ measure_re }}') as MEASURES,
        regexp_substr_all(T, '{{ count_re }}') as COUNTS,

        -- Kroger "N pk / X unit": per-item size, multiply by N
        try_to_number(regexp_substr(T, '^([0-9]+) ?(ct|count|pk|pack|packs|bottles|cans|pc|bars|rolls) ?/', 1, 1, 'e', 1)) as KROGER_MULTIPACK_N,

        -- Walmart "N-Pack (X oz Each)" / "N ct ... X oz each": multiply by N
        try_to_number(regexp_substr(T, '([0-9]+) ?-? ?(pack|pk|count|ct)[^0-9]{0,20}{{ num }} ?({{ units }}) each', 1, 1, 'e', 1)) as WALMART_EACH_N

    from normalized

),

picked as (

    select
        *,
        array_size(MEASURES) as N_MEASURES,
        array_size(COUNTS) as N_COUNTS,
        iff(RETAILER = 'kroger', MEASURES[0]::varchar, MEASURES[array_size(MEASURES) - 1]::varchar) as MEASURE_TOKEN,
        COUNTS[0]::varchar as COUNT_TOKEN,
        case
            when RETAILER = 'kroger' then coalesce(KROGER_MULTIPACK_N, 1)
            else coalesce(WALMART_EACH_N, 1)
        end as ITEMS_IN_PACKAGE

    from tokens

),

parsed as (

    select
        *,
        try_to_double(regexp_substr(MEASURE_TOKEN, '{{ num }}')) as MEASURE_NUMBER,
        regexp_replace(regexp_replace(MEASURE_TOKEN, '^{{ num }} ?', ''), '[^a-z]', '') as MEASURE_UNIT,
        try_to_double(regexp_substr(COUNT_TOKEN, '{{ num }}')) as COUNT_NUMBER

    from picked

),

unit_map (UNIT, UNIT_BASIS, FACTOR) as (

    select * from values
        ('oz', 'oz', 1), ('ounce', 'oz', 1), ('ounces', 'oz', 1), ('onz', 'oz', 1), ('oza', 'oz', 1),
        ('lb', 'oz', 16), ('lbs', 'oz', 16), ('lbr', 'oz', 16), ('pound', 'oz', 16), ('pounds', 'oz', 16),
        ('g', 'oz', 0.035274), ('gram', 'oz', 0.035274), ('grams', 'oz', 0.035274), ('kg', 'oz', 35.274),
        ('floz', 'fl_oz', 1), ('fo', 'fl_oz', 1),
        ('ml', 'fl_oz', 0.033814), ('l', 'fl_oz', 33.814), ('liter', 'fl_oz', 33.814),
        ('liters', 'fl_oz', 33.814), ('litre', 'fl_oz', 33.814),
        ('gal', 'fl_oz', 128), ('gallon', 'fl_oz', 128), ('gallons', 'fl_oz', 128),
        ('qt', 'fl_oz', 32), ('quart', 'fl_oz', 32), ('quarts', 'fl_oz', 32),
        ('pt', 'fl_oz', 16), ('pint', 'fl_oz', 16), ('pints', 'fl_oz', 16)

)

select
    p.RETAILER || ':' || p.PRODUCT_ID as PRODUCT_KEY,
    p.RETAILER,
    p.PRODUCT_ID,
    p.SIZE_SOURCE,
    case
        when u.UNIT_BASIS is not null then round(p.MEASURE_NUMBER * u.FACTOR * p.ITEMS_IN_PACKAGE, 4)
        when p.N_MEASURES = 0 and p.COUNT_NUMBER > 0 then p.COUNT_NUMBER
    end as PACKAGE_QUANTITY,
    case
        when u.UNIT_BASIS is not null then u.UNIT_BASIS
        when p.N_MEASURES = 0 and p.COUNT_NUMBER > 0 then 'ct'
    end as UNIT_BASIS,
    p.ITEMS_IN_PACKAGE,
    case
        -- coalesce: a NULL here would make the whole test NULL and fall
        -- through to 'high' for size-less products ("bath towel")
        when u.UNIT_BASIS is null and not (p.N_MEASURES = 0 and coalesce(p.COUNT_NUMBER, 0) > 0) then 'none'
        when coalesce(p.MEASURE_NUMBER, p.COUNT_NUMBER) <= 0 then 'none'
        -- weight multipack: per-item vs total can't be told from the text
        when p.RETAILER = 'kroger' and p.ITEMS_IN_PACKAGE > 1 and u.UNIT_BASIS = 'oz' then 'low'
        when p.RETAILER = 'kroger' then 'high'
        -- Walmart: count-only, or one weight/volume with no competing count
        when p.N_MEASURES = 0 then iff(p.N_COUNTS = 1, 'high', 'low')
        when p.N_MEASURES = 1 and (p.N_COUNTS = 0 or p.WALMART_EACH_N is not null or p.COUNT_NUMBER <= 1) then 'high'
        else 'low'
    end as PARSE_CONFIDENCE

from parsed p
left join unit_map u
    on u.UNIT = p.MEASURE_UNIT
