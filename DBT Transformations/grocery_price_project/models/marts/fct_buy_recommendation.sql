{{ config(
    materialized='dynamic_table',
    target_lag='24 hours',
    snowflake_warehouse='COMPUTE_WH',
    refresh_mode='FULL'
) }}

-- "Is now a good time to buy X?" — one row per product. The history-based
-- RULE decides; the ML FORECAST is a second opinion (Agent/ONTOLOGY.md).
-- Both use fct_product_price_weekly_series (Kroger: median across stores).
--
-- RULE_SIGNAL, against the item's own trailing history:
--   INSUFFICIENT_HISTORY  fewer than buy_min_weeks_for_signal observed weeks
--   STABLE_PRICE          price never changed — no better time to wait for
--   GOOD_PRICE            at its historic low, or at/below its 25th percentile
--                         AND below its typical (median) price
--   HIGH_PRICE            at/above its 75th percentile AND above its median
--   TYPICAL               otherwise
-- The median conditions matter: an item that's $3.79 nearly every week with
-- one $3.00 promo has a 25th percentile of $3.79, so without them its usual
-- price would read as a "good price".
--
-- FORECAST_DIRECTION (only when a forecast exists and was trained on data
-- through the current week): LOWER if the forecast low over the horizon is
-- forecast_move_pct below today, HIGHER if the forecast mean is that far
-- above, else FLAT; NONE when there's no usable forecast (constant or short
-- series are never trained; see dim_forecast_scope for what is trained).
--
-- The forecast low is floored at the item's observed low before it's
-- compared: on ~10-point series the model extrapolates promo tails to
-- prices the item has never sold at (sample: Jell-O history low $4.00,
-- forecast $2.81, zero-width interval). A forecast may point to a price
-- the item has actually reached, not below it; IS_FORECAST_BELOW_HISTORY
-- reports when the raw forecast did, so the agent can say so.
--
-- RECOMMENDATION:
--   BUY_NOW           good price, forecast doesn't expect lower
--   BUY_NOW_OR_WAIT   good price, but forecast expects lower by RETURN_BY_WEEK
--   WAIT              high price (RETURN_BY_WEEK set if forecast expects lower)
--   NEUTRAL           typical or stable price
--   INSUFFICIENT_HISTORY
--
-- CHEAPER_THAN_PCT (basket watch, 07_basket_watch.sql): the percentile rank
-- of today's price within the same trailing window — the share (0-100) of
-- the other observed weeks whose price was HIGHER than today's. "Cheaper than
-- 82% of the last 12 weeks." A price that never changes scores 0 (no deal);
-- NULL under buy_min_weeks_for_signal weeks. UNIT_PRICE = CURRENT_PRICE per
-- UNIT_BASIS from dim_product's parsed size (NULL unless parsed with high confidence);
-- look-alike swaps compare it within one PRODUCT_TYPE.

{% set trailing = var('history_trailing_weeks') %}
{% set move = var('forecast_move_pct') %}

with series as (

    select * from {{ ref('fct_product_price_weekly_series') }}

),

retailer_latest as (

    select RETAILER, max(PRICE_WEEK) as RETAILER_LATEST_WEEK
    from series
    group by RETAILER

),

current_obs as (

    select *
    from series
    qualify row_number() over (partition by PRODUCT_KEY order by PRICE_WEEK desc) = 1

),

history as (

    select
        s.PRODUCT_KEY,
        count(*) as WEEKS_OBSERVED,
        min(s.PRICE_WEEK) as HISTORY_START_WEEK,
        min(s.EFFECTIVE_PRICE) as HISTORY_LOW_PRICE,
        max(s.EFFECTIVE_PRICE) as HISTORY_HIGH_PRICE,
        percentile_cont({{ var('buy_good_percentile') }}) within group (order by s.EFFECTIVE_PRICE) as HISTORY_P25_PRICE,
        median(s.EFFECTIVE_PRICE) as HISTORY_MEDIAN_PRICE,
        percentile_cont({{ var('buy_high_percentile') }}) within group (order by s.EFFECTIVE_PRICE) as HISTORY_P75_PRICE,
        count_if(s.EFFECTIVE_PRICE > c.EFFECTIVE_PRICE) as WEEKS_PRICED_HIGHER

    from series s
    join current_obs c
        on c.PRODUCT_KEY = s.PRODUCT_KEY
    where s.PRICE_WEEK > dateadd('week', -{{ trailing }}, c.PRICE_WEEK)
    group by s.PRODUCT_KEY

),

forecast as (

    select
        SERIES as PRODUCT_KEY,
        min(TS)::date as FORECAST_FIRST_WEEK,
        min(FORECAST) as FORECAST_LOW_PRICE,
        min_by(TS, FORECAST)::date as FORECAST_LOW_WEEK,
        min_by(LOWER_BOUND, FORECAST) as FORECAST_LOW_LOWER_BOUND,
        min_by(UPPER_BOUND, FORECAST) as FORECAST_LOW_UPPER_BOUND,
        avg(FORECAST) as FORECAST_MEAN_PRICE,
        avg((UPPER_BOUND - LOWER_BOUND) / nullif(FORECAST, 0)) as FORECAST_INTERVAL_WIDTH_PCT,
        max(TRAINED_AT) as FORECAST_TRAINED_AT

    from {{ source('ml', 'price_forecast') }}
    group by SERIES

),

signals as (

    select
        c.PRODUCT_KEY,
        c.RETAILER,
        c.PRODUCT_ID,
        c.PRICE_WEEK as CURRENT_WEEK,
        c.PRICE_WEEK = rl.RETAILER_LATEST_WEEK as IS_CURRENTLY_LISTED,
        c.EFFECTIVE_PRICE as CURRENT_PRICE,
        c.STORES_OBSERVED,
        c.STORES_ON_PROMO,

        h.WEEKS_OBSERVED,
        h.HISTORY_START_WEEK,
        h.HISTORY_LOW_PRICE,
        h.HISTORY_P25_PRICE::number(10, 2) as HISTORY_P25_PRICE,
        h.HISTORY_MEDIAN_PRICE::number(10, 2) as HISTORY_MEDIAN_PRICE,
        h.HISTORY_P75_PRICE::number(10, 2) as HISTORY_P75_PRICE,
        h.HISTORY_HIGH_PRICE,
        iff(h.WEEKS_OBSERVED < {{ var('buy_min_weeks_for_signal') }}, null,
            round(100 * h.WEEKS_PRICED_HIGHER / nullif(h.WEEKS_OBSERVED - 1, 0)))::number(3, 0) as CHEAPER_THAN_PCT,

        case
            when h.WEEKS_OBSERVED < {{ var('buy_min_weeks_for_signal') }} then 'INSUFFICIENT_HISTORY'
            when h.HISTORY_LOW_PRICE = h.HISTORY_HIGH_PRICE then 'STABLE_PRICE'
            when c.EFFECTIVE_PRICE <= h.HISTORY_LOW_PRICE then 'GOOD_PRICE'
            when c.EFFECTIVE_PRICE <= h.HISTORY_P25_PRICE
                 and c.EFFECTIVE_PRICE < h.HISTORY_MEDIAN_PRICE then 'GOOD_PRICE'
            when c.EFFECTIVE_PRICE >= h.HISTORY_P75_PRICE
                 and c.EFFECTIVE_PRICE > h.HISTORY_MEDIAN_PRICE then 'HIGH_PRICE'
            else 'TYPICAL'
        end as RULE_SIGNAL,

        f.FORECAST_FIRST_WEEK is not null as HAS_FORECAST,
        f.FORECAST_FIRST_WEEK > c.PRICE_WEEK as IS_FORECAST_FRESH,
        f.FORECAST_LOW_PRICE::number(10, 2) as FORECAST_LOW_PRICE,
        greatest(f.FORECAST_LOW_PRICE, h.HISTORY_LOW_PRICE)::number(10, 2) as FORECAST_LOW_PRICE_BOUNDED,
        f.FORECAST_LOW_PRICE < h.HISTORY_LOW_PRICE as IS_FORECAST_BELOW_HISTORY,
        f.FORECAST_LOW_WEEK,
        f.FORECAST_LOW_LOWER_BOUND::number(10, 2) as FORECAST_LOW_LOWER_BOUND,
        f.FORECAST_LOW_UPPER_BOUND::number(10, 2) as FORECAST_LOW_UPPER_BOUND,
        f.FORECAST_MEAN_PRICE::number(10, 2) as FORECAST_MEAN_PRICE,
        round(f.FORECAST_INTERVAL_WIDTH_PCT, 4) as FORECAST_INTERVAL_WIDTH_PCT,
        f.FORECAST_TRAINED_AT,

        case
            when f.FORECAST_FIRST_WEEK is null or f.FORECAST_FIRST_WEEK <= c.PRICE_WEEK then 'NONE'
            when greatest(f.FORECAST_LOW_PRICE, h.HISTORY_LOW_PRICE) <= c.EFFECTIVE_PRICE * (1 - {{ move }}) then 'LOWER'
            when f.FORECAST_MEAN_PRICE >= c.EFFECTIVE_PRICE * (1 + {{ move }}) then 'HIGHER'
            else 'FLAT'
        end as FORECAST_DIRECTION,

        greatest(c.PRICE_WEEK, rl.RETAILER_LATEST_WEEK) as DATA_AS_OF_WEEK

    from current_obs c
    join retailer_latest rl
        on rl.RETAILER = c.RETAILER
    join history h
        on h.PRODUCT_KEY = c.PRODUCT_KEY
    left join forecast f
        on f.PRODUCT_KEY = c.PRODUCT_KEY

)

select
    signals.*,
    case
        when RULE_SIGNAL = 'INSUFFICIENT_HISTORY' then 'INSUFFICIENT_HISTORY'
        when RULE_SIGNAL = 'GOOD_PRICE' and FORECAST_DIRECTION = 'LOWER' then 'BUY_NOW_OR_WAIT'
        when RULE_SIGNAL = 'GOOD_PRICE' then 'BUY_NOW'
        when RULE_SIGNAL = 'HIGH_PRICE' then 'WAIT'
        else 'NEUTRAL'
    end as RECOMMENDATION,
    iff(FORECAST_DIRECTION = 'LOWER' and RULE_SIGNAL in ('GOOD_PRICE', 'HIGH_PRICE'),
        FORECAST_LOW_WEEK, null) as RETURN_BY_WEEK,
    case
        when FORECAST_DIRECTION = 'NONE' then null
        when RULE_SIGNAL = 'GOOD_PRICE' then FORECAST_DIRECTION <> 'LOWER'
        when RULE_SIGNAL = 'HIGH_PRICE' then FORECAST_DIRECTION = 'LOWER'
    end as SIGNALS_AGREE,

    -- Stock-up: worth buying extra of now — the item keeps (shelf-stable)
    -- and today's price is good by the rule.
    coalesce(p.IS_SHELF_STABLE, false) as IS_SHELF_STABLE,
    coalesce(p.IS_SHELF_STABLE, false) and RULE_SIGNAL = 'GOOD_PRICE' as IS_STOCK_UP_CANDIDATE,

    -- per-unit price and type, for look-alike swaps (basket watch)
    p.PRODUCT_TYPE,
    p.UNIT_BASIS,
    iff(p.PARSE_CONFIDENCE <> 'high' or coalesce(p.PACKAGE_QUANTITY, 0) <= 0, null,
        (CURRENT_PRICE / p.PACKAGE_QUANTITY))::number(12, 4) as UNIT_PRICE

from signals
left join {{ ref('dim_product') }} p
    on p.PRODUCT_KEY = signals.PRODUCT_KEY
