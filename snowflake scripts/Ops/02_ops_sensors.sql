-- Grocery ops layer — part 2: deterministic sensors + SP_RUN_SENSORS.
-- Every V_CHECK_* view returns the same shape, one row per (check, subject):
--   CHECK_NAME, SUBJECT, PERIOD_KEY, PERIOD_TS, METRIC_VALUE, OBSERVED, EXPECTED, SEVERITY, MESSAGE
-- SEVERITY is OK | INFO | WARN | CRIT, decided here from OPS_CHECK thresholds.
-- No LLM anywhere in this file. Agents (03) only read what these produce.
--
-- Sandbox variant (reads PROD sources, writes GROCERY_DEV_OPS):
--   sed -E 's/GROCERY_OPS([^_A-Za-z0-9]|$)/GROCERY_DEV_OPS\1/g; s/GROCERY_OPS_WH/COMPUTE_WH/g'

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GROCERY_OPS_WH;
ALTER TABLE GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT ADD COLUMN IF NOT EXISTS PERIOD_TS TIMESTAMP_TZ;

------------------------------------------------------------------------------
-- Shared time helpers: the collection week runs Friday 12:00 ET -> next Friday.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_COLLECTION_WEEK AS
WITH base AS (
    SELECT CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())::DATE AS today_et
), fri AS (
    SELECT today_et,
           -- most recent Friday on or before today (Monday-start weeks: Friday = +4)
           IFF(DAYOFWEEKISO(today_et) >= 5, DATE_TRUNC(week, today_et) + 4, DATE_TRUNC(week, today_et) - 3) AS week_friday
    FROM base
)
SELECT week_friday,
       CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ(week_friday || ' 12:00:00'))::TIMESTAMP_TZ AS week_start_utc,
       CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ(week_friday || ' 17:00:00'))::TIMESTAMP_TZ AS friday_slot_utc,
       CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ((week_friday + 1) || ' 09:00:00'))::TIMESTAMP_TZ AS saturday_slot_utc,
       CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ((week_friday + 1) || ' 16:00:00'))::TIMESTAMP_TZ AS complete_after_utc,
       CURRENT_TIMESTAMP() >= CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ((week_friday + 1) || ' 16:00:00'))::TIMESTAMP_TZ AS is_complete_phase
FROM fri;

------------------------------------------------------------------------------
-- INGESTION
------------------------------------------------------------------------------
-- Expected Friday/Saturday runs vs ORCHESTRATION_JOB_RUNS. A slot with no row
-- 10 h after its time is "missing" — the Oct 17 - Nov 14 outage case.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_EXPECTED_RUNS AS
WITH weeks AS (
    SELECT DATEADD(week, -SEQ4(), DATE_TRUNC(week, CURRENT_DATE())) AS wk
    FROM TABLE(GENERATOR(ROWCOUNT => 10))
), slots AS (
    SELECT wk + 4 AS slot_date, 'friday_full' AS run_mode, s.source,
           CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ((wk + 4) || ' 17:00:00')) AS slot_utc
    FROM weeks, (SELECT 'kroger' AS source, '2026-09-04'::DATE AS since UNION ALL SELECT 'walmart', '2026-09-04' UNION ALL SELECT 'kroger_seasonal', '2026-11-20') s
    WHERE wk + 4 >= s.since
    UNION ALL
    SELECT wk + 5, 'saturday_kroger_continue', 'kroger',
           CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ((wk + 5) || ' 09:00:00'))
    FROM weeks WHERE wk + 5 >= '2026-09-05'
), evaluated AS (
    SELECT s.*,
           r.STATUS, r.STARTED_AT, r.COMPLETED_AT,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ >= DATEADD(hour, 10, s.slot_utc) AS is_due
    FROM slots s
    LEFT JOIN GROCERYDBTPROJECT.JOB_PERFORMANCE.ORCHESTRATION_JOB_RUNS r
           ON r.SOURCE = s.source AND r.RUN_MODE = s.run_mode
          AND r.STARTED_AT BETWEEN DATEADD(hour, -1, s.slot_utc) AND DATEADD(hour, 10, s.slot_utc)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.slot_date, s.run_mode, s.source ORDER BY r.STARTED_AT DESC NULLS LAST) = 1
)
SELECT IFF(STATUS = 'failed', 'run_failed', 'run_missing')                              AS CHECK_NAME,
       source || ' ' || run_mode                                                          AS SUBJECT,
       slot_date::VARCHAR                                                                 AS PERIOD_KEY,
       slot_utc::TIMESTAMP_TZ                                                             AS PERIOD_TS,
       IFF(STATUS = 'success', 0, 1)                                                      AS METRIC_VALUE,  -- 1 = missing or failed
       OBJECT_CONSTRUCT('status', COALESCE(STATUS, IFF(is_due, 'missing', 'pending')), 'started_at', STARTED_AT, 'completed_at', COMPLETED_AT) AS OBSERVED,
       OBJECT_CONSTRUCT('slot_utc', slot_utc, 'window_hours', 10)                        AS EXPECTED,
       CASE WHEN STATUS = 'success' THEN 'OK'
            WHEN STATUS = 'failed'  THEN 'CRIT'
            WHEN is_due             THEN 'CRIT'
            ELSE 'INFO' END                                                               AS SEVERITY,
       CASE WHEN STATUS = 'success' THEN 'ran'
            WHEN STATUS = 'failed'  THEN source || ' ' || run_mode || ' on ' || slot_date || ' failed'
            WHEN is_due             THEN 'no ' || source || ' ' || run_mode || ' run recorded for ' || slot_date || ' (slot ' || slot_utc || ' UTC); the job never started or never reported'
            ELSE 'pending' END                                                            AS MESSAGE
FROM evaluated;

-- Kroger stores priced this collection week. Before Saturday 16:00 ET only the
-- Friday half is expected (~44 stores); after it, the full 81.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_KROGER_COVERAGE AS
WITH w AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_COLLECTION_WEEK),
c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'kroger_store_coverage'),
obs AS (
    SELECT COUNT(DISTINCT p.LOCATIONID) AS stores, COUNT(*) AS rows_, MAX(p.COLLECTED_AT) AS last_collected
    FROM GROCERYDBTPROJECT.GROCERY_RAW_KROGER.KROGER_PRICING p, w
    WHERE p.COLLECTED_AT >= w.week_start_utc
)
SELECT 'kroger_store_coverage' AS CHECK_NAME, 'kroger' AS SUBJECT, w.week_friday::VARCHAR AS PERIOD_KEY, w.week_start_utc AS PERIOD_TS,
       obs.stores AS METRIC_VALUE,
       OBJECT_CONSTRUCT('stores', obs.stores, 'rows', obs.rows_, 'last_collected', obs.last_collected, 'phase', IFF(w.is_complete_phase, 'complete', 'friday_only')) AS OBSERVED,
       OBJECT_CONSTRUCT('stores_total', 81, 'warn_below', IFF(w.is_complete_phase, c.WARN_THRESHOLD, 40), 'crit_below', IFF(w.is_complete_phase, c.CRIT_THRESHOLD, 20)) AS EXPECTED,
       CASE WHEN CURRENT_TIMESTAMP() < DATEADD(hour, 10, w.friday_slot_utc) THEN 'INFO'
            WHEN obs.stores <= IFF(w.is_complete_phase, c.CRIT_THRESHOLD, 20) THEN 'CRIT'
            WHEN obs.stores <  IFF(w.is_complete_phase, c.WARN_THRESHOLD, 40) THEN 'WARN'
            ELSE 'OK' END AS SEVERITY,
       obs.stores || ' of 81 Kroger stores priced for the week of ' || w.week_friday || IFF(w.is_complete_phase, '', ' (Friday phase)') AS MESSAGE
FROM obs, w, c;

-- Row volume this week vs the median of the previous 4 complete weeks.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_LOAD_VOLUME AS
WITH w AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_COLLECTION_WEEK),
kw AS (
    SELECT DATE_TRUNC(week, DATEADD(day, -4, CONVERT_TIMEZONE('America/New_York', COLLECTED_AT)::DATE)) + 4 AS week_friday,
           COUNT(*) AS rows_, COUNT(DISTINCT LOCATIONID) AS stores
    FROM GROCERYDBTPROJECT.GROCERY_RAW_KROGER.KROGER_PRICING
    WHERE COLLECTED_AT >= DATEADD(week, -10, CURRENT_TIMESTAMP()) GROUP BY 1
), ww AS (
    SELECT DATE_TRUNC(week, DATEADD(day, -4, CONVERT_TIMEZONE('America/New_York', COLLECTED_AT)::DATE)) + 4 AS week_friday,
           COUNT(*) AS rows_
    FROM GROCERYDBTPROJECT.GROCERY_RAW_WALMART.WALMART_PRODUCT_CATALOG
    WHERE COLLECTED_AT >= DATEADD(week, -10, CURRENT_TIMESTAMP()) GROUP BY 1
), k AS (
    SELECT 'kroger_row_volume' AS CHECK_NAME, 'kroger' AS SUBJECT,
           (SELECT rows_ FROM kw, w WHERE kw.week_friday = w.week_friday) AS this_week,
           (SELECT MEDIAN(rows_) FROM (SELECT rows_ FROM kw, w WHERE kw.week_friday < w.week_friday AND kw.stores >= 70 ORDER BY kw.week_friday DESC LIMIT 4)) AS baseline,
           (SELECT is_complete_phase FROM w) AS evaluable
    UNION ALL
    SELECT 'walmart_row_volume', 'walmart',
           (SELECT rows_ FROM ww, w WHERE ww.week_friday = w.week_friday),
           (SELECT MEDIAN(rows_) FROM (SELECT rows_ FROM ww, w WHERE ww.week_friday < w.week_friday ORDER BY ww.week_friday DESC LIMIT 4)),
           (SELECT CURRENT_TIMESTAMP() >= DATEADD(hour, 10, friday_slot_utc) FROM w)
)
SELECT k.CHECK_NAME, k.SUBJECT, w.week_friday::VARCHAR AS PERIOD_KEY, w.week_start_utc AS PERIOD_TS,
       ROUND(100 * ABS(COALESCE(k.this_week, 0) - k.baseline) / NULLIF(k.baseline, 0), 1) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('rows_this_week', k.this_week, 'baseline_median_4w', k.baseline) AS OBSERVED,
       OBJECT_CONSTRUCT('max_deviation_pct_warn', c.WARN_THRESHOLD, 'max_deviation_pct_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN NOT k.evaluable OR k.baseline IS NULL THEN 'INFO'
            WHEN COALESCE(k.this_week, 0) = 0 THEN 'CRIT'
            WHEN 100 * ABS(k.this_week - k.baseline) / k.baseline >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN 100 * ABS(k.this_week - k.baseline) / k.baseline >= c.WARN_THRESHOLD THEN 'WARN'
            ELSE 'OK' END AS SEVERITY,
       k.SUBJECT || ' rows this week: ' || COALESCE(k.this_week, 0) || ' vs 4-week median ' || ROUND(k.baseline) AS MESSAGE
FROM k CROSS JOIN w
JOIN GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK c ON c.CHECK_NAME = k.CHECK_NAME;

-- Pipe execution state for the 7 auto-ingest pipes.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_PIPES AS
WITH p AS (
    SELECT 'GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_PRICING_PIPE' AS pipe_name, PARSE_JSON(SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_PRICING_PIPE')) AS st
    UNION ALL SELECT 'GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_PRODUCT_CATALOG_PIPE', PARSE_JSON(SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_PRODUCT_CATALOG_PIPE'))
    UNION ALL SELECT 'GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_LOCATIONS_PIPE', PARSE_JSON(SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_LOCATIONS_PIPE'))
    UNION ALL SELECT 'GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_INVENTORY_PIPE', PARSE_JSON(SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_INVENTORY_PIPE'))
    UNION ALL SELECT 'GROCERYDBTPROJECT.AWS_RESOURCES_WALMART.WALMART_PRODUCT_CATALOG_PIPE', PARSE_JSON(SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES_WALMART.WALMART_PRODUCT_CATALOG_PIPE'))
    UNION ALL SELECT 'GROCERYDBTPROJECT.AWS_RESOURCES_UPC.UPCDATABASE_PRODUCT_DETAILS_PIPE', PARSE_JSON(SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES_UPC.UPCDATABASE_PRODUCT_DETAILS_PIPE'))
    UNION ALL SELECT 'GROCERYDBTPROJECT.AWS_RESOURCES.ORCHESTRATION_JOB_RUNS_PIPE', PARSE_JSON(SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES.ORCHESTRATION_JOB_RUNS_PIPE'))
)
SELECT 'pipe_not_running' AS CHECK_NAME, pipe_name AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       IFF(st:executionState::STRING = 'RUNNING', 0, 1) AS METRIC_VALUE,  -- 1 = not running
       OBJECT_CONSTRUCT('executionState', st:executionState, 'pendingFileCount', st:pendingFileCount, 'lastReceivedMessageTimestamp', st:lastReceivedMessageTimestamp, 'lastForwardedMessageTimestamp', st:lastForwardedMessageTimestamp) AS OBSERVED,
       OBJECT_CONSTRUCT('executionState', 'RUNNING') AS EXPECTED,
       IFF(st:executionState::STRING = 'RUNNING', 'OK', 'CRIT') AS SEVERITY,
       pipe_name || ' is ' || st:executionState::STRING AS MESSAGE
FROM p;

-- Seasonal catalog file expected when a season window is open (mirrors
-- kroger_seasonal_watchlist.season_for_date). Easter dates listed through 2030.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_SEASONAL AS
WITH w AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_COLLECTION_WEEK),
d AS (
    SELECT w.week_friday AS today, YEAR(w.week_friday) AS y,
           -- fourth Thursday of November
           DATEADD(week, 3, DATE_FROM_PARTS(YEAR(w.week_friday), 11, 1) + MOD(3 - DAYOFWEEKISO(DATE_FROM_PARTS(YEAR(w.week_friday), 11, 1)) + 1 + 7, 7)) AS thanksgiving
    FROM w
), easter AS (
    SELECT * FROM VALUES (2026, '2026-04-05'::DATE), (2027, '2027-03-28'), (2028, '2028-04-16'), (2029, '2029-04-01'), (2030, '2030-04-21') e (y, easter_day)
), season AS (
    SELECT d.today, d.thanksgiving,
           CASE WHEN d.today BETWEEN DATE_FROM_PARTS(d.y, 10, 20) AND d.thanksgiving THEN 'thanksgiving'
                WHEN d.today > d.thanksgiving AND d.today <= DATE_FROM_PARTS(d.y, 12, 24) THEN 'christmas'
                WHEN d.today BETWEEN DATEADD(day, -35, e.easter_day) AND e.easter_day THEN 'easter'
                WHEN d.today BETWEEN DATE_FROM_PARTS(d.y, 6, 13) AND DATE_FROM_PARTS(d.y, 7, 4) THEN 'july4'
                ELSE NULL END AS season
    FROM d LEFT JOIN easter e ON e.y = d.y
), f AS (
    SELECT COUNT(*) AS rows_, MAX(INGESTED_FILENAME) AS filename
    FROM GROCERYDBTPROJECT.GROCERY_RAW_KROGER.KROGER_PRODUCT_CATALOG c, w
    WHERE c.INGESTED_FILENAME ILIKE '%seasonal%' AND c."collected_at" >= w.week_start_utc  -- raw catalog columns are lowercase quoted identifiers
)
SELECT 'seasonal_file_missing' AS CHECK_NAME, COALESCE(s.season, 'none') AS SUBJECT, w.week_friday::VARCHAR AS PERIOD_KEY, w.week_start_utc AS PERIOD_TS,
       f.rows_ AS METRIC_VALUE,
       OBJECT_CONSTRUCT('season', s.season, 'rows_loaded', f.rows_, 'file', f.filename) AS OBSERVED,
       OBJECT_CONSTRUCT('expected', IFF(s.season IS NULL, 'no file (no season open)', 'one seasonal file this week')) AS EXPECTED,
       CASE WHEN s.season IS NULL OR w.week_friday < '2026-11-20' THEN 'OK'
            WHEN CURRENT_TIMESTAMP() < DATEADD(hour, 10, w.friday_slot_utc) THEN 'INFO'
            WHEN f.rows_ = 0 THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       IFF(s.season IS NULL, 'no seasonal window open', s.season || ' window open: ' || f.rows_ || ' seasonal rows loaded this week') AS MESSAGE
FROM season s, w, f;

------------------------------------------------------------------------------
-- QUALITY
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_FRESHNESS AS
WITH src AS (
    SELECT 'kroger_pricing' AS source, MAX(COLLECTED_AT) AS last_at FROM GROCERYDBTPROJECT.GROCERY_RAW_KROGER.KROGER_PRICING
    UNION ALL SELECT 'walmart_catalog', MAX(COLLECTED_AT) FROM GROCERYDBTPROJECT.GROCERY_RAW_WALMART.WALMART_PRODUCT_CATALOG
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'source_freshness')
SELECT 'source_freshness' AS CHECK_NAME, src.source AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       ROUND(TIMESTAMPDIFF(hour, src.last_at, CURRENT_TIMESTAMP()) / 24.0, 1) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('last_collected_at', src.last_at) AS OBSERVED,
       OBJECT_CONSTRUCT('max_age_days_warn', c.WARN_THRESHOLD, 'max_age_days_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN TIMESTAMPDIFF(hour, src.last_at, CURRENT_TIMESTAMP()) / 24.0 >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN TIMESTAMPDIFF(hour, src.last_at, CURRENT_TIMESTAMP()) / 24.0 >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       src.source || ' last collected ' || src.last_at || ' (' || ROUND(TIMESTAMPDIFF(hour, src.last_at, CURRENT_TIMESTAMP()) / 24.0, 1) || ' days ago)' AS MESSAGE
FROM src, c;

-- Price outliers in the latest observed week: <= 0, > 50x the store's trailing
-- median, or > 5x the previous observed week. Only the two latest weeks per
-- retailer are read (a windowed scan of the whole fact was too slow on XS).
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_PRICE_OUTLIERS AS
WITH weeks AS (
    SELECT RETAILER, PRICE_WEEK, ROW_NUMBER() OVER (PARTITION BY RETAILER ORDER BY PRICE_WEEK DESC) AS rn
    FROM (SELECT DISTINCT RETAILER, PRICE_WEEK FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRICE_WEEKLY)
    QUALIFY rn <= 2
), cur AS (
    SELECT f.RETAILER, f.PRODUCT_KEY, f.STORE_ID, f.PRICE_WEEK, f.EFFECTIVE_PRICE
    FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRICE_WEEKLY f JOIN weeks w ON w.RETAILER = f.RETAILER AND w.PRICE_WEEK = f.PRICE_WEEK AND w.rn = 1
), prev AS (
    SELECT f.PRODUCT_KEY, f.STORE_ID, f.EFFECTIVE_PRICE AS prev_price
    FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRICE_WEEKLY f JOIN weeks w ON w.RETAILER = f.RETAILER AND w.PRICE_WEEK = f.PRICE_WEEK AND w.rn = 2
), flagged AS (
    SELECT c.RETAILER, c.PRODUCT_KEY, c.STORE_ID, c.PRICE_WEEK, c.EFFECTIVE_PRICE, s.TRAILING_MEDIAN_PRICE, p.prev_price,
           CASE WHEN c.EFFECTIVE_PRICE <= 0 THEN 'non_positive'
                WHEN s.TRAILING_MEDIAN_PRICE > 0 AND c.EFFECTIVE_PRICE > 50 * s.TRAILING_MEDIAN_PRICE THEN 'gt_50x_median'
                WHEN p.prev_price > 0 AND c.EFFECTIVE_PRICE > 5 * p.prev_price THEN 'gt_5x_prev_week' END AS reason
    FROM cur c
    LEFT JOIN prev p ON p.PRODUCT_KEY = c.PRODUCT_KEY AND p.STORE_ID = c.STORE_ID
    LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_SUMMARY s ON s.PRODUCT_KEY = c.PRODUCT_KEY AND s.STORE_ID = c.STORE_ID
), agg AS (
    SELECT RETAILER, MAX(PRICE_WEEK) AS wk, COUNT_IF(reason IS NOT NULL) AS n_out, COUNT(*) AS n_rows,
           ARRAY_SLICE(ARRAY_AGG(IFF(reason IS NOT NULL, OBJECT_CONSTRUCT('product_key', PRODUCT_KEY, 'store', STORE_ID, 'price', EFFECTIVE_PRICE, 'median', TRAILING_MEDIAN_PRICE, 'prev', prev_price, 'reason', reason), NULL)) WITHIN GROUP (ORDER BY EFFECTIVE_PRICE DESC), 0, 8) AS examples
    FROM flagged GROUP BY 1
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'price_outliers')
SELECT 'price_outliers' AS CHECK_NAME, a.RETAILER AS SUBJECT, a.wk::VARCHAR AS PERIOD_KEY, a.wk::TIMESTAMP_TZ AS PERIOD_TS,
       a.n_out AS METRIC_VALUE,
       OBJECT_CONSTRUCT('outliers', a.n_out, 'rows_checked', a.n_rows, 'examples', a.examples) AS OBSERVED,
       OBJECT_CONSTRUCT('max_warn', c.WARN_THRESHOLD, 'max_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN a.n_out >= c.CRIT_THRESHOLD THEN 'CRIT' WHEN a.n_out >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       a.n_out || ' outlier prices among ' || a.n_rows || ' ' || a.RETAILER || ' rows in week ' || a.wk AS MESSAGE
FROM agg a, c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_PROMO_SHARE AS
WITH w AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_COLLECTION_WEEK),
obs AS (
    SELECT COUNT(*) AS n, COUNT_IF(PRICE_PROMO IS NOT NULL AND PRICE_PROMO > 0 AND PRICE_PROMO >= PRICE_REGULAR) AS n_bad
    FROM GROCERYDBTPROJECT.GROCERY_INTERMEDIATE.DBT_INT_KROGER_ITEMS_CURRENT i, w
    WHERE i.COLLECTED_AT >= w.week_start_utc
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'promo_ge_regular')
SELECT 'promo_ge_regular' AS CHECK_NAME, 'kroger' AS SUBJECT, w.week_friday::VARCHAR AS PERIOD_KEY, w.week_start_utc AS PERIOD_TS,
       ROUND(100.0 * obs.n_bad / NULLIF(obs.n, 0), 2) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('rows', obs.n, 'promo_ge_regular', obs.n_bad) AS OBSERVED,
       OBJECT_CONSTRUCT('max_share_pct_warn', c.WARN_THRESHOLD, 'max_share_pct_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN obs.n = 0 THEN 'INFO'
            WHEN 100.0 * obs.n_bad / obs.n >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN 100.0 * obs.n_bad / obs.n >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       ROUND(100.0 * obs.n_bad / NULLIF(obs.n, 0), 2) || '% of ' || obs.n || ' current Kroger prices have promo >= regular' AS MESSAGE
FROM obs, w, c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_NULLS AS
WITH w AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_COLLECTION_WEEK),
k AS (
    SELECT 'kroger_pricing' AS SUBJECT, COUNT(*) AS n,
           ROUND(100.0 * GREATEST(COUNT_IF(PRODUCTID IS NULL), COUNT_IF(LOCATIONID IS NULL), COUNT_IF(RAW_DATA IS NULL)) / NULLIF(COUNT(*), 0), 2) AS null_pct,
           OBJECT_CONSTRUCT('productid', COUNT_IF(PRODUCTID IS NULL), 'locationid', COUNT_IF(LOCATIONID IS NULL), 'raw_data', COUNT_IF(RAW_DATA IS NULL)) AS detail
    FROM GROCERYDBTPROJECT.GROCERY_RAW_KROGER.KROGER_PRICING p, w WHERE p.COLLECTED_AT >= w.week_start_utc
    UNION ALL
    SELECT 'walmart_catalog', COUNT(*),
           -- 15-20% of Walmart rows have no price every week (marketplace items): recorded, not alerted
           ROUND(100.0 * GREATEST(COUNT_IF(ITEMID IS NULL), COUNT_IF(NAME IS NULL)) / NULLIF(COUNT(*), 0), 2),
           OBJECT_CONSTRUCT('itemid', COUNT_IF(ITEMID IS NULL), 'name', COUNT_IF(NAME IS NULL), 'no_price', COUNT_IF(SALEPRICE IS NULL AND MSRP IS NULL))
    FROM GROCERYDBTPROJECT.GROCERY_RAW_WALMART.WALMART_PRODUCT_CATALOG p, w WHERE p.COLLECTED_AT >= w.week_start_utc
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'null_spike')
SELECT 'null_spike' AS CHECK_NAME, k.SUBJECT, w.week_friday::VARCHAR AS PERIOD_KEY, w.week_start_utc AS PERIOD_TS,
       k.null_pct AS METRIC_VALUE, OBJECT_CONSTRUCT('rows', k.n, 'nulls', k.detail) AS OBSERVED,
       OBJECT_CONSTRUCT('max_null_pct_warn', c.WARN_THRESHOLD, 'max_null_pct_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN k.n = 0 THEN 'INFO' WHEN k.null_pct >= c.CRIT_THRESHOLD THEN 'CRIT' WHEN k.null_pct >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       k.SUBJECT || ': ' || k.null_pct || '% nulls on key columns this week (' || k.n || ' rows)' AS MESSAGE
FROM k, w, c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_DUPLICATES AS
WITH w AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_COLLECTION_WEEK),
k AS (
    SELECT 'kroger_pricing' AS SUBJECT, COUNT(*) - COUNT(DISTINCT PRODUCTID || '|' || LOCATIONID || '|' || COLLECTED_AT::STRING) AS dups
    FROM GROCERYDBTPROJECT.GROCERY_RAW_KROGER.KROGER_PRICING p, w WHERE p.COLLECTED_AT >= w.week_start_utc
    UNION ALL
    SELECT 'walmart_catalog', COUNT(*) - COUNT(DISTINCT ITEMID || '|' || COLLECTED_AT::STRING)
    FROM GROCERYDBTPROJECT.GROCERY_RAW_WALMART.WALMART_PRODUCT_CATALOG p, w WHERE p.COLLECTED_AT >= w.week_start_utc
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'duplicate_rows')
SELECT 'duplicate_rows' AS CHECK_NAME, k.SUBJECT, w.week_friday::VARCHAR AS PERIOD_KEY, w.week_start_utc AS PERIOD_TS,
       k.dups AS METRIC_VALUE, OBJECT_CONSTRUCT('duplicate_rows', k.dups) AS OBSERVED,
       OBJECT_CONSTRUCT('max_warn', c.WARN_THRESHOLD, 'max_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN k.dups >= c.CRIT_THRESHOLD THEN 'CRIT' WHEN k.dups > c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       k.SUBJECT || ': ' || k.dups || ' duplicate rows this week' AS MESSAGE
FROM k, w, c;

-- SQL ports of the load-bearing dbt tests (same semantics as the YAML tests
-- in models/marts/_models.yml and intermediate/_models.yml).
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_MART_INTEGRITY AS
WITH t AS (
    SELECT 'dim_product.PRODUCT_KEY unique' AS test, COUNT(*) - COUNT(DISTINCT PRODUCT_KEY) AS failing FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT
    UNION ALL SELECT 'dim_product.PRODUCT_KEY not_null', COUNT_IF(PRODUCT_KEY IS NULL) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT
    UNION ALL SELECT 'dim_store.STORE_ID unique', COUNT(*) - COUNT(DISTINCT STORE_ID) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_STORE
    UNION ALL SELECT 'fct_price_weekly grain unique', COUNT(*) - COUNT(DISTINCT PRODUCT_KEY || '|' || STORE_ID || '|' || PRICE_WEEK) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRICE_WEEKLY
    UNION ALL SELECT 'fct_price_weekly -> dim_product', COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRICE_WEEKLY f WHERE NOT EXISTS (SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT d WHERE d.PRODUCT_KEY = f.PRODUCT_KEY)
    UNION ALL SELECT 'fct_product_price_rollup.PRODUCT_KEY unique', COUNT(*) - COUNT(DISTINCT PRODUCT_KEY) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_ROLLUP
    UNION ALL SELECT 'fct_buy_recommendation.RECOMMENDATION accepted_values', COUNT_IF(RECOMMENDATION NOT IN ('BUY_NOW','BUY_NOW_OR_WAIT','WAIT','NEUTRAL','INSUFFICIENT_HISTORY')) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_BUY_RECOMMENDATION
    UNION ALL SELECT 'fct_cross_retailer.UPC_A unique', COUNT(*) - COUNT(DISTINCT UPC_A) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_CROSS_RETAILER_PRICE_COMPARISON
    UNION ALL SELECT 'int_kroger_price_history one current row per product-store', COUNT(*) - COUNT(DISTINCT PRODUCT_ID || '|' || LOCATION_ID) FROM GROCERYDBTPROJECT.GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRICE_HISTORY WHERE IS_CURRENT
    UNION ALL SELECT 'dim_product.PARSE_CONFIDENCE accepted_values', COUNT_IF(PARSE_CONFIDENCE NOT IN ('high','low','none')) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'mart_integrity')
SELECT 'mart_integrity' AS CHECK_NAME, t.test AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       t.failing AS METRIC_VALUE, OBJECT_CONSTRUCT('failing_rows', t.failing) AS OBSERVED, OBJECT_CONSTRUCT('failing_rows', 0) AS EXPECTED,
       CASE WHEN t.failing >= c.CRIT_THRESHOLD THEN 'CRIT' WHEN t.failing > c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       t.test || ': ' || t.failing || ' failing rows' AS MESSAGE
FROM t, c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_PARSE_DRIFT AS
WITH now_ AS (
    SELECT RETAILER, ROUND(100.0 * COUNT_IF(PARSE_CONFIDENCE = 'none') / COUNT(*), 2) AS none_pct
    FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT WHERE IS_FOOD GROUP BY 1
), prev AS (
    SELECT DIMENSION AS RETAILER, VALUE AS none_pct_prev
    FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY
    WHERE METRIC_NAME = 'parse_none_pct' AND METRIC_DATE BETWEEN DATEADD(day, -10, CURRENT_DATE()) AND DATEADD(day, -6, CURRENT_DATE())
    QUALIFY ROW_NUMBER() OVER (PARTITION BY DIMENSION ORDER BY METRIC_DATE DESC) = 1
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'parse_confidence_drift')
SELECT 'parse_confidence_drift' AS CHECK_NAME, n.RETAILER AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       COALESCE(n.none_pct - p.none_pct_prev, 0) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('none_pct_now', n.none_pct, 'none_pct_week_ago', p.none_pct_prev) AS OBSERVED,
       OBJECT_CONSTRUCT('max_rise_pts_warn', c.WARN_THRESHOLD, 'max_rise_pts_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN p.none_pct_prev IS NULL THEN 'OK'
            WHEN n.none_pct - p.none_pct_prev >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN n.none_pct - p.none_pct_prev >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       n.RETAILER || ': ' || n.none_pct || '% of food products have no parsed size (week ago: ' || COALESCE(p.none_pct_prev::STRING, 'n/a') || ')' AS MESSAGE
FROM now_ n LEFT JOIN prev p ON p.RETAILER = n.RETAILER, c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_FORECAST AS
WITH r AS (
    SELECT STARTED_AT, SERIES_FORECAST, LAG(SERIES_FORECAST) OVER (ORDER BY STARTED_AT) AS prev_series
    FROM GROCERYDBTPROJECT.GROCERY_ML.PRICE_FORECAST_RUNS QUALIFY ROW_NUMBER() OVER (ORDER BY STARTED_AT DESC) = 1
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'forecast_sanity')
SELECT 'forecast_sanity' AS CHECK_NAME, 'price_forecast' AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       ROUND(TIMESTAMPDIFF(hour, r.STARTED_AT, CURRENT_TIMESTAMP()) / 24.0, 1) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('last_run', r.STARTED_AT, 'series_forecast', r.SERIES_FORECAST, 'previous_series', r.prev_series) AS OBSERVED,
       OBJECT_CONSTRUCT('max_age_days_warn', c.WARN_THRESHOLD, 'max_age_days_crit', c.CRIT_THRESHOLD, 'series_change_max_pct', 25) AS EXPECTED,
       CASE WHEN r.STARTED_AT IS NULL THEN 'CRIT'
            WHEN TIMESTAMPDIFF(hour, r.STARTED_AT, CURRENT_TIMESTAMP()) / 24.0 >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN TIMESTAMPDIFF(hour, r.STARTED_AT, CURRENT_TIMESTAMP()) / 24.0 >= c.WARN_THRESHOLD THEN 'WARN'
            WHEN r.prev_series > 0 AND ABS(r.SERIES_FORECAST - r.prev_series) / r.prev_series > 0.25 THEN 'WARN'
            ELSE 'OK' END AS SEVERITY,
       'last forecast run ' || r.STARTED_AT || ', ' || r.SERIES_FORECAST || ' series (previous ' || COALESCE(r.prev_series::STRING, 'n/a') || ')' AS MESSAGE
FROM r, c;

------------------------------------------------------------------------------
-- COST (ACCOUNT_USAGE lags 45 min - 3 h, so "yesterday" is the unit)
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_COST_WAREHOUSE AS
WITH d AS (
    SELECT WAREHOUSE_NAME, START_TIME::DATE AS d, SUM(CREDITS_USED) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE START_TIME >= DATEADD(day, -29, CURRENT_DATE()) AND START_TIME < CURRENT_DATE() GROUP BY 1, 2
), b AS (
    SELECT WAREHOUSE_NAME, PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY credits) AS p90, MEDIAN(credits) AS med
    FROM d WHERE d < DATEADD(day, -1, CURRENT_DATE()) GROUP BY 1
), y AS (SELECT WAREHOUSE_NAME, credits FROM d WHERE d = DATEADD(day, -1, CURRENT_DATE())),
c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'warehouse_daily_spike')
SELECT 'warehouse_daily_spike' AS CHECK_NAME, b.WAREHOUSE_NAME AS SUBJECT, DATEADD(day, -1, CURRENT_DATE())::VARCHAR AS PERIOD_KEY, DATEADD(day, -1, CURRENT_DATE())::TIMESTAMP_TZ AS PERIOD_TS,
       ROUND(COALESCE(y.credits, 0) / GREATEST(b.p90, 0.05), 2) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('credits_yesterday', ROUND(COALESCE(y.credits, 0), 3), 'p90_28d', ROUND(b.p90, 3), 'median_28d', ROUND(b.med, 3)) AS OBSERVED,
       OBJECT_CONSTRUCT('max_multiple_warn', c.WARN_THRESHOLD, 'max_multiple_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN COALESCE(y.credits, 0) < 0.2 THEN 'OK'
            WHEN COALESCE(y.credits, 0) / GREATEST(b.p90, 0.05) >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN COALESCE(y.credits, 0) / GREATEST(b.p90, 0.05) >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       b.WAREHOUSE_NAME || ' used ' || ROUND(COALESCE(y.credits, 0), 2) || ' credits yesterday (28-day p90 ' || ROUND(b.p90, 2) || ')' AS MESSAGE
FROM b LEFT JOIN y ON y.WAREHOUSE_NAME = b.WAREHOUSE_NAME, c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_COST_SERVICE AS
WITH d AS (
    SELECT SERVICE_TYPE, USAGE_DATE AS d, SUM(CREDITS_USED) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
    WHERE USAGE_DATE >= DATEADD(day, -29, CURRENT_DATE()) AND USAGE_DATE < CURRENT_DATE() AND SERVICE_TYPE <> 'WAREHOUSE_METERING' GROUP BY 1, 2
), b AS (SELECT SERVICE_TYPE, PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY credits) AS p90 FROM d WHERE d < DATEADD(day, -1, CURRENT_DATE()) GROUP BY 1),
y AS (SELECT SERVICE_TYPE, credits FROM d WHERE d = DATEADD(day, -1, CURRENT_DATE())),
c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'service_daily_spike')
SELECT 'service_daily_spike' AS CHECK_NAME, COALESCE(y.SERVICE_TYPE, b.SERVICE_TYPE) AS SUBJECT, DATEADD(day, -1, CURRENT_DATE())::VARCHAR AS PERIOD_KEY, DATEADD(day, -1, CURRENT_DATE())::TIMESTAMP_TZ AS PERIOD_TS,
       ROUND(COALESCE(y.credits, 0) / GREATEST(COALESCE(b.p90, 0), 0.05), 2) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('credits_yesterday', ROUND(COALESCE(y.credits, 0), 3), 'p90_28d', ROUND(b.p90, 3)) AS OBSERVED,
       OBJECT_CONSTRUCT('max_multiple_warn', c.WARN_THRESHOLD, 'max_multiple_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN COALESCE(y.credits, 0) < 0.2 THEN 'OK'
            WHEN COALESCE(y.credits, 0) / GREATEST(COALESCE(b.p90, 0), 0.05) >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN COALESCE(y.credits, 0) / GREATEST(COALESCE(b.p90, 0), 0.05) >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       COALESCE(y.SERVICE_TYPE, b.SERVICE_TYPE) || ' used ' || ROUND(COALESCE(y.credits, 0), 2) || ' credits yesterday (28-day p90 ' || ROUND(COALESCE(b.p90, 0), 2) || ')' AS MESSAGE
FROM b FULL OUTER JOIN y ON y.SERVICE_TYPE = b.SERVICE_TYPE, c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_COST_PROJECTION AS
WITH grp_credits AS (
    SELECT CASE WHEN WAREHOUSE_NAME = 'COMPUTE_WH' THEN 'GROCERY_COMPUTE_MONITOR'
                WHEN WAREHOUSE_NAME IN ('GROCERY_AGENT_WH', 'GROCERY_ML_WH') THEN 'GROCERY_AGENT_MONITOR'
                WHEN WAREHOUSE_NAME = 'GROCERY_OPS_WH' THEN 'GROCERY_OPS_MONITOR' ELSE 'other' END AS grp,
           SUM(CREDITS_USED) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY WHERE START_TIME >= DATE_TRUNC(month, CURRENT_DATE()) GROUP BY 1
    UNION ALL
    SELECT 'TOTAL', SUM(CREDITS_USED) FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY WHERE USAGE_DATE >= DATE_TRUNC(month, CURRENT_DATE())
), quotas AS (SELECT * FROM VALUES ('TOTAL', 20), ('GROCERY_COMPUTE_MONITOR', 8), ('GROCERY_AGENT_MONITOR', 10), ('GROCERY_OPS_MONITOR', 2) q (grp, quota)),
rows_ AS (
    SELECT q.grp, q.quota, COALESCE(g.credits, 0) AS mtd_credits, DAY(CURRENT_DATE()) AS dom, DAY(LAST_DAY(CURRENT_DATE())) AS dim
    FROM quotas q LEFT JOIN grp_credits g ON g.grp = q.grp
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'monthly_projection')
SELECT 'monthly_projection' AS CHECK_NAME, r.grp AS SUBJECT, TO_VARCHAR(CURRENT_DATE(), 'YYYY-MM') AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,  -- month-scoped: PERIOD_KEY dedups, PERIOD_TS must stay recent
       ROUND(100 * (r.mtd_credits / GREATEST(r.dom, 1) * r.dim) / r.quota, 1) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('month_to_date_credits', ROUND(r.mtd_credits, 2), 'projected_month_end_credits', ROUND(r.mtd_credits / GREATEST(r.dom, 1) * r.dim, 2), 'quota_credits', r.quota, 'projected_pct_of_quota', ROUND(100 * (r.mtd_credits / GREATEST(r.dom, 1) * r.dim) / r.quota, 1)) AS OBSERVED,
       OBJECT_CONSTRUCT('max_projected_pct_warn', c.WARN_THRESHOLD, 'max_projected_pct_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN r.dom < 3 THEN 'INFO'
            WHEN 100 * (r.mtd_credits / r.dom * r.dim) / r.quota >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN 100 * (r.mtd_credits / r.dom * r.dim) / r.quota >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       r.grp || ': ' || ROUND(r.mtd_credits, 1) || ' credits month-to-date, projecting ' || ROUND(r.mtd_credits / GREATEST(r.dom, 1) * r.dim, 1) || ' of ' || r.quota AS MESSAGE
FROM rows_ r CROSS JOIN c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_MONITORS AS
WITH m AS (
    SELECT NAME, CREDIT_QUOTA, USED_CREDITS FROM SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS
    WHERE NAME LIKE 'GROCERY%' QUALIFY ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY CREATED DESC) = 1
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'resource_monitor_used')
SELECT 'resource_monitor_used' AS CHECK_NAME, m.NAME AS SUBJECT, TO_VARCHAR(CURRENT_DATE(), 'YYYY-MM') AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,  -- month-scoped: PERIOD_KEY dedups, PERIOD_TS must stay recent
       ROUND(100 * m.USED_CREDITS / NULLIF(m.CREDIT_QUOTA, 0), 1) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('used', ROUND(m.USED_CREDITS, 2), 'quota', m.CREDIT_QUOTA) AS OBSERVED,
       OBJECT_CONSTRUCT('max_pct_warn', c.WARN_THRESHOLD, 'max_pct_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN 100 * m.USED_CREDITS / NULLIF(m.CREDIT_QUOTA, 0) >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN 100 * m.USED_CREDITS / NULLIF(m.CREDIT_QUOTA, 0) >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       m.NAME || ' at ' || ROUND(100 * m.USED_CREDITS / NULLIF(m.CREDIT_QUOTA, 0), 0) || '% of ' || m.CREDIT_QUOTA || ' credits' AS MESSAGE
FROM m, c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_AGENT_TOKENS AS
WITH u AS (
    SELECT r.MODEL_TASK, SUM(COALESCE(o.INPUT_TOKENS, 0) + COALESCE(o.OUTPUT_TOKENS, 0)) AS tokens
    FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN o JOIN GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY r ON r.AGENT_NAME = o.AGENT_NAME
    WHERE o.KIND = 'agent' AND o.STARTED_AT >= DATE_TRUNC(month, CURRENT_DATE()) GROUP BY 1
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'agent_token_budget')
SELECT 'agent_token_budget' AS CHECK_NAME, p.MODEL_TASK AS SUBJECT, TO_VARCHAR(CURRENT_DATE(), 'YYYY-MM') AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,  -- month-scoped: PERIOD_KEY dedups, PERIOD_TS must stay recent
       ROUND(100 * COALESCE(u.tokens, 0) / NULLIF(p.MONTHLY_TOKEN_BUDGET, 0), 1) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('tokens_mtd', COALESCE(u.tokens, 0), 'budget', p.MONTHLY_TOKEN_BUDGET, 'model', p.MODEL) AS OBSERVED,
       OBJECT_CONSTRUCT('max_pct_warn', c.WARN_THRESHOLD, 'max_pct_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN 100 * COALESCE(u.tokens, 0) / NULLIF(p.MONTHLY_TOKEN_BUDGET, 0) >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN 100 * COALESCE(u.tokens, 0) / NULLIF(p.MONTHLY_TOKEN_BUDGET, 0) >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       p.MODEL_TASK || ': ' || COALESCE(u.tokens, 0) || ' tokens this month of ' || p.MONTHLY_TOKEN_BUDGET AS MESSAGE
FROM GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY p LEFT JOIN u ON u.MODEL_TASK = p.MODEL_TASK, c
WHERE p.MODEL_TASK LIKE 'ops_%';

------------------------------------------------------------------------------
-- PERFORMANCE
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_TASKS AS
WITH h AS (
    SELECT DATABASE_NAME || '.' || SCHEMA_NAME || '.' || NAME AS task_name, STATE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME
    -- ACCOUNT_USAGE (<= 45 min lag): the INFORMATION_SCHEMA table function does not accept a computed range inside a view
    FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
    WHERE DATABASE_NAME = 'GROCERYDBTPROJECT' AND SCHEMA_NAME IN ('GROCERY_ML', 'GROCERY_OPS', 'GROCERY_DEV_OPS')
      AND SCHEDULED_TIME >= DATEADD(day, -8, CURRENT_TIMESTAMP()) AND STATE NOT IN ('SCHEDULED', 'EXECUTING')
), failed AS (
    SELECT task_name, STATE, ERROR_MESSAGE, SCHEDULED_TIME FROM h WHERE STATE IN ('FAILED', 'FAILED_AND_AUTO_SUSPENDED', 'CANCELLED')
), forecast_missed AS (
    -- the Sunday 06:00 ET forecast must have SUCCEEDED by Sunday 09:00 ET
    SELECT 'GROCERYDBTPROJECT.GROCERY_ML.TASK_WEEKLY_PRICE_FORECAST' AS task_name,
           CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ((DATE_TRUNC(week, CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())::DATE) - 1) || ' 06:00:00')) AS last_sunday_slot_utc
), fm AS (
    SELECT f.task_name, f.last_sunday_slot_utc,
           (SELECT COUNT(*) FROM h WHERE h.task_name = f.task_name AND h.STATE = 'SUCCEEDED' AND h.SCHEDULED_TIME >= DATEADD(hour, -1, f.last_sunday_slot_utc)) AS successes,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ >= DATEADD(hour, 3, f.last_sunday_slot_utc) AS is_due
    FROM forecast_missed f
)
SELECT 'task_failed_or_missed' AS CHECK_NAME, task_name AS SUBJECT, SCHEDULED_TIME::DATE::VARCHAR AS PERIOD_KEY, SCHEDULED_TIME::TIMESTAMP_TZ AS PERIOD_TS,
       1 AS METRIC_VALUE, OBJECT_CONSTRUCT('state', STATE, 'error', ERROR_MESSAGE, 'scheduled_time', SCHEDULED_TIME) AS OBSERVED, OBJECT_CONSTRUCT('state', 'SUCCEEDED') AS EXPECTED,
       'CRIT' AS SEVERITY, task_name || ' ' || STATE || ' at ' || SCHEDULED_TIME || ': ' || COALESCE(ERROR_MESSAGE, '') AS MESSAGE
FROM failed
UNION ALL
SELECT 'task_failed_or_missed', task_name, last_sunday_slot_utc::DATE::VARCHAR, last_sunday_slot_utc::TIMESTAMP_TZ,
       IFF(successes > 0, 0, 1), OBJECT_CONSTRUCT('successes_since_slot', successes, 'slot_utc', last_sunday_slot_utc), OBJECT_CONSTRUCT('successes', 1),
       CASE WHEN successes > 0 THEN 'OK' WHEN is_due THEN 'CRIT' ELSE 'INFO' END,
       IFF(successes > 0, 'forecast task succeeded for ' || last_sunday_slot_utc::DATE, 'no successful forecast run for the Sunday slot ' || last_sunday_slot_utc || ' UTC')
FROM fm;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_DYNAMIC_TABLES AS
-- ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY (lag up to 3 h). Suspended
-- scheduling state is added by SP_RUN_SENSORS from SHOW DYNAMIC TABLES (no
-- ACCOUNT_USAGE view carries it on this account).
WITH last_refresh AS (
    SELECT QUALIFIED_NAME, STATE, STATE_MESSAGE, TARGET_LAG_SEC, REFRESH_END_TIME
    FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
    WHERE DATABASE_NAME = 'GROCERYDBTPROJECT' AND SCHEMA_NAME NOT LIKE 'GROCERY_DEV%' AND REFRESH_START_TIME >= DATEADD(day, -14, CURRENT_TIMESTAMP())
    QUALIFY ROW_NUMBER() OVER (PARTITION BY QUALIFIED_NAME ORDER BY REFRESH_START_TIME DESC) = 1
), last_ok AS (
    SELECT QUALIFIED_NAME, MAX(DATA_TIMESTAMP) AS last_data_ts
    FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
    WHERE DATABASE_NAME = 'GROCERYDBTPROJECT' AND SCHEMA_NAME NOT LIKE 'GROCERY_DEV%' AND STATE IN ('SUCCEEDED', 'UPTODATE') AND REFRESH_START_TIME >= DATEADD(day, -14, CURRENT_TIMESTAMP())
    GROUP BY 1
), raw_latest AS (SELECT MAX(COLLECTED_AT) AS latest_raw FROM GROCERYDBTPROJECT.GROCERY_RAW_KROGER.KROGER_PRICING),
c_lag AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'dt_lag'),
base AS (
    SELECT r.QUALIFIED_NAME AS dt_name, r.STATE AS last_state, r.STATE_MESSAGE, r.TARGET_LAG_SEC, o.last_data_ts,
           ROUND(TIMESTAMPDIFF(minute, o.last_data_ts, CURRENT_TIMESTAMP()) / 60.0, 1) AS hours_since_data
    FROM last_refresh r LEFT JOIN last_ok o ON o.QUALIFIED_NAME = r.QUALIFIED_NAME
)
SELECT 'dt_refresh_failed' AS CHECK_NAME, dt_name AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       IFF(last_state = 'FAILED', 1, 0) AS METRIC_VALUE,  -- 1 = failed
       OBJECT_CONSTRUCT('last_refresh_state', last_state, 'message', STATE_MESSAGE) AS OBSERVED,
       OBJECT_CONSTRUCT('last_refresh_state', 'SUCCEEDED') AS EXPECTED,
       IFF(last_state = 'FAILED', 'CRIT', 'OK') AS SEVERITY,
       dt_name || ': last refresh ' || COALESCE(last_state, 'n/a') || COALESCE(' - ' || STATE_MESSAGE, '') AS MESSAGE
FROM base
UNION ALL
SELECT 'dt_lag', b.dt_name, CURRENT_DATE()::VARCHAR, CURRENT_TIMESTAMP(), b.hours_since_data,
       OBJECT_CONSTRUCT('last_data_timestamp', b.last_data_ts, 'target_lag_hours', ROUND(b.TARGET_LAG_SEC / 3600.0, 1), 'latest_raw', rl.latest_raw),
       OBJECT_CONSTRUCT('max_hours_warn', c.WARN_THRESHOLD, 'max_hours_crit', c.CRIT_THRESHOLD),
       -- a table whose upstream has not changed legitimately keeps an old data timestamp; only flag when newer raw data exists
       CASE WHEN b.last_data_ts IS NULL THEN 'INFO'
            WHEN b.hours_since_data >= c.CRIT_THRESHOLD AND rl.latest_raw > b.last_data_ts THEN 'CRIT'
            WHEN b.hours_since_data >= c.WARN_THRESHOLD AND rl.latest_raw > b.last_data_ts THEN 'WARN'
            ELSE 'OK' END,
       b.dt_name || ' data as of ' || COALESCE(b.last_data_ts::STRING, 'n/a') || ' (' || COALESCE(b.hours_since_data::STRING, '?') || ' h ago)'
FROM base b CROSS JOIN raw_latest rl CROSS JOIN c_lag c;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_AGENT_WAREHOUSE AS
WITH q AS (
    SELECT PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TOTAL_ELAPSED_TIME) / 1000.0 AS p95_s, COUNT(*) AS n, COUNT_IF(EXECUTION_STATUS <> 'SUCCESS') AS failed
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY WHERE WAREHOUSE_NAME = 'GROCERY_AGENT_WH' AND START_TIME >= DATEADD(day, -7, CURRENT_TIMESTAMP())
), l AS (
    SELECT AVG(AVG_QUEUED_LOAD) AS queued FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY WHERE WAREHOUSE_NAME = 'GROCERY_AGENT_WH' AND START_TIME >= DATEADD(day, -7, CURRENT_TIMESTAMP())
), c1 AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'agent_wh_queueing'),
c2 AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'agent_latency_p95')
SELECT 'agent_wh_queueing' AS CHECK_NAME, 'GROCERY_AGENT_WH' AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       ROUND(COALESCE(l.queued, 0), 3) AS METRIC_VALUE, OBJECT_CONSTRUCT('avg_queued_load_7d', l.queued) AS OBSERVED, OBJECT_CONSTRUCT('max_warn', c1.WARN_THRESHOLD, 'max_crit', c1.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN COALESCE(l.queued, 0) >= c1.CRIT_THRESHOLD THEN 'CRIT' WHEN COALESCE(l.queued, 0) > c1.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       'GROCERY_AGENT_WH average queued load over 7 days: ' || ROUND(COALESCE(l.queued, 0), 3) AS MESSAGE
FROM l, c1
UNION ALL
SELECT 'agent_latency_p95', 'GROCERY_AGENT_WH', CURRENT_DATE()::VARCHAR, CURRENT_TIMESTAMP(),
       ROUND(COALESCE(q.p95_s, 0), 1), OBJECT_CONSTRUCT('p95_seconds', q.p95_s, 'queries_7d', q.n, 'failed', q.failed), OBJECT_CONSTRUCT('max_seconds_warn', c2.WARN_THRESHOLD, 'max_seconds_crit', c2.CRIT_THRESHOLD),
       CASE WHEN COALESCE(q.p95_s, 0) >= c2.CRIT_THRESHOLD THEN 'CRIT' WHEN COALESCE(q.p95_s, 0) >= c2.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END,
       'p95 query time on GROCERY_AGENT_WH over 7 days: ' || ROUND(COALESCE(q.p95_s, 0), 1) || ' s (' || q.n || ' queries, ' || q.failed || ' failed)'
FROM q, c2;

-- Search freshness comes from a metric the sensor procedure writes (DESCRIBE
-- cannot run inside a view).
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_SEARCH AS
WITH m AS (
    SELECT VALUE AS age_days, RECORDED_AT FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY
    WHERE METRIC_NAME = 'search_data_age_days' QUALIFY ROW_NUMBER() OVER (ORDER BY METRIC_DATE DESC, RECORDED_AT DESC) = 1
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'search_stale')
SELECT 'search_stale' AS CHECK_NAME, 'GROCERY_SEMANTIC.PRODUCT_SEARCH' AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       m.age_days AS METRIC_VALUE, OBJECT_CONSTRUCT('data_age_days', m.age_days, 'measured_at', m.RECORDED_AT) AS OBSERVED,
       OBJECT_CONSTRUCT('max_days_warn', c.WARN_THRESHOLD, 'max_days_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN m.age_days IS NULL THEN 'INFO' WHEN m.age_days >= c.CRIT_THRESHOLD THEN 'CRIT' WHEN m.age_days >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       'product search index data is ' || COALESCE(m.age_days::STRING, 'unknown') || ' days old' AS MESSAGE
FROM c LEFT JOIN m ON TRUE;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_EVALS AS
WITH e AS (
    SELECT CREATED_AT::DATE AS d, COUNT(*) AS n, COUNT_IF(PASSED) AS passed
    FROM GROCERYDBTPROJECT.GROCERY_APP.AGENT_RUN_LOG WHERE SOURCE = 'eval' GROUP BY 1 QUALIFY ROW_NUMBER() OVER (ORDER BY d DESC) = 1
), c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'eval_score')
SELECT 'eval_score' AS CHECK_NAME, 'grocery_value_agent' AS SUBJECT, COALESCE(e.d::VARCHAR, 'none') AS PERIOD_KEY, COALESCE(e.d::TIMESTAMP_TZ, CURRENT_TIMESTAMP()) AS PERIOD_TS,
       ROUND(100.0 * e.passed / NULLIF(e.n, 0), 1) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('run_date', e.d, 'questions', e.n, 'passed', e.passed) AS OBSERVED,
       OBJECT_CONSTRUCT('min_pct_warn', c.WARN_THRESHOLD, 'min_pct_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN e.d IS NULL THEN 'INFO'
            WHEN 100.0 * e.passed / e.n < c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN 100.0 * e.passed / e.n < c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       IFF(e.d IS NULL, 'no eval run recorded in AGENT_RUN_LOG yet', 'latest eval ' || e.d || ': ' || e.passed || '/' || e.n || ' passed') AS MESSAGE
FROM c LEFT JOIN e ON TRUE;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_FEEDBACK AS
WITH f AS (SELECT COUNT_IF(RATING < 3) AS low, COUNT(*) AS n FROM GROCERYDBTPROJECT.GROCERY_APP.AGENT_FEEDBACK WHERE CREATED_AT >= DATEADD(day, -7, CURRENT_TIMESTAMP())),
c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'feedback_low')
SELECT 'feedback_low' AS CHECK_NAME, 'grocery_value_agent' AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       f.low AS METRIC_VALUE, OBJECT_CONSTRUCT('low_ratings_7d', f.low, 'ratings_7d', f.n) AS OBSERVED, OBJECT_CONSTRUCT('max_warn', c.WARN_THRESHOLD, 'max_crit', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN f.low >= c.CRIT_THRESHOLD THEN 'CRIT' WHEN f.low >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       f.low || ' low ratings (< 3) of ' || f.n || ' in the last 7 days' AS MESSAGE
FROM f, c;

------------------------------------------------------------------------------
-- SUPERVISOR: silence
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_SILENCE AS
SELECT 'component_silent' AS CHECK_NAME, AGENT_NAME AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       ROUND(TIMESTAMPDIFF(hour, COALESCE(LAST_RUN_AT, CREATED_AT), CURRENT_TIMESTAMP()), 1) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('last_run_at', LAST_RUN_AT, 'last_status', LAST_STATUS, 'expected_interval_hours', EXPECTED_INTERVAL_HOURS) AS OBSERVED,
       OBJECT_CONSTRUCT('max_silence_hours', 1.5 * EXPECTED_INTERVAL_HOURS) AS EXPECTED,
       IFF(IS_SILENT, 'CRIT', 'OK') AS SEVERITY,
       AGENT_NAME || IFF(IS_SILENT, ' has not run since ' || COALESCE(LAST_RUN_AT::STRING, 'ever') || ' (expected every ' || EXPECTED_INTERVAL_HOURS || ' h)', ' ran ' || LAST_RUN_AT) AS MESSAGE
FROM GROCERYDBTPROJECT.GROCERY_OPS.V_REGISTRY_STATUS
WHERE ENABLED AND PLATFORM = 'snowflake' AND KIND IN ('task', 'agent') AND EXPECTED_INTERVAL_HOURS IS NOT NULL;

------------------------------------------------------------------------------
-- SP_RUN_SENSORS(domain): evaluate the domain's checks, record metrics, raise /
-- refresh / resolve events (fingerprint dedup, suppression window), log the run.
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_SENSORS(DOMAIN VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Deterministic sensors for one domain (ingestion | quality | cost | performance | supervisor | all). No LLM. Writes OPS_METRIC_DAILY, OPS_EVENT, OPS_RUN; returns a JSON summary.'
EXECUTE AS OWNER
AS
$$
DECLARE
    run_id   VARCHAR := UUID_STRING();
    sql_text VARCHAR;
    n_checks INT := 0;
    n_new    INT := 0;
    n_open   INT := 0;
    max_sev  VARCHAR;
    summary  VARIANT;
BEGIN
    INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN (RUN_ID, KIND, DOMAIN, AGENT_NAME, STATUS)
    VALUES (:run_id, 'sensor', :DOMAIN, 'sensors_' || :DOMAIN, 'running');

    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_OPS.sensor_results (
        CHECK_NAME VARCHAR, SUBJECT VARCHAR, PERIOD_KEY VARCHAR, PERIOD_TS TIMESTAMP_TZ, METRIC_VALUE FLOAT,
        OBSERVED VARIANT, EXPECTED VARIANT, SEVERITY VARCHAR, MESSAGE VARCHAR
    );

    -- side metrics that views cannot compute themselves
    IF (:DOMAIN IN ('performance', 'all')) THEN
        BEGIN
            DESCRIBE CORTEX SEARCH SERVICE GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH;
            MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY t
            USING (SELECT CURRENT_DATE() AS METRIC_DATE, 'performance' AS DOMAIN, 'search_data_age_days' AS METRIC_NAME, '-' AS DIMENSION,
                          ROUND(TIMESTAMPDIFF(hour, "data_timestamp"::TIMESTAMP_TZ, CURRENT_TIMESTAMP()) / 24.0, 2) AS VALUE
                   FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))) s
            ON t.METRIC_DATE = s.METRIC_DATE AND t.METRIC_NAME = s.METRIC_NAME AND t.DIMENSION = s.DIMENSION
            WHEN MATCHED THEN UPDATE SET VALUE = s.VALUE, RECORDED_AT = CURRENT_TIMESTAMP(), RUN_ID = :run_id
            WHEN NOT MATCHED THEN INSERT (METRIC_DATE, DOMAIN, METRIC_NAME, DIMENSION, VALUE, RUN_ID) VALUES (s.METRIC_DATE, s.DOMAIN, s.METRIC_NAME, s.DIMENSION, s.VALUE, :run_id);
        EXCEPTION WHEN OTHER THEN
            INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.sensor_results VALUES ('search_stale', 'GROCERY_SEMANTIC.PRODUCT_SEARCH', CURRENT_DATE()::VARCHAR, CURRENT_TIMESTAMP(), NULL, NULL, NULL, 'WARN', 'could not DESCRIBE the search service: ' || :SQLERRM);
        END;
    END IF;
    IF (:DOMAIN IN ('performance', 'all')) THEN
        BEGIN
            SHOW DYNAMIC TABLES IN DATABASE GROCERYDBTPROJECT;
            INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.sensor_results
            SELECT 'dt_refresh_failed', "database_name" || '.' || "schema_name" || '.' || "name", CURRENT_DATE()::VARCHAR, CURRENT_TIMESTAMP(), 1,
                   OBJECT_CONSTRUCT('scheduling_state', "scheduling_state"), OBJECT_CONSTRUCT('scheduling_state', 'ACTIVE'), 'CRIT',
                   "database_name" || '.' || "schema_name" || '.' || "name" || ' scheduling state is ' || "scheduling_state"::STRING
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            WHERE "schema_name" NOT LIKE 'GROCERY_DEV%' AND "scheduling_state"::STRING NOT ILIKE '%ACTIVE%';
        EXCEPTION WHEN OTHER THEN
            INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.sensor_results VALUES ('dt_refresh_failed', 'sensor_error', CURRENT_DATE()::VARCHAR, CURRENT_TIMESTAMP(), NULL, NULL, NULL, 'WARN', 'SHOW DYNAMIC TABLES failed: ' || :SQLERRM);
        END;
    END IF;
    IF (:DOMAIN IN ('quality', 'all')) THEN
        MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY t
        USING (SELECT CURRENT_DATE() AS METRIC_DATE, 'quality' AS DOMAIN, 'parse_none_pct' AS METRIC_NAME, RETAILER AS DIMENSION,
                      ROUND(100.0 * COUNT_IF(PARSE_CONFIDENCE = 'none') / COUNT(*), 2) AS VALUE
               FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT WHERE IS_FOOD GROUP BY RETAILER) s
        ON t.METRIC_DATE = s.METRIC_DATE AND t.METRIC_NAME = s.METRIC_NAME AND t.DIMENSION = s.DIMENSION
        WHEN MATCHED THEN UPDATE SET VALUE = s.VALUE, RECORDED_AT = CURRENT_TIMESTAMP(), RUN_ID = :run_id
        WHEN NOT MATCHED THEN INSERT (METRIC_DATE, DOMAIN, METRIC_NAME, DIMENSION, VALUE, RUN_ID) VALUES (s.METRIC_DATE, s.DOMAIN, s.METRIC_NAME, s.DIMENSION, s.VALUE, :run_id);
    END IF;

    -- evaluate every enabled check of the domain through its view
    -- a cursor cannot bind the procedure argument, so filter inside the loop
    LET checks CURSOR FOR
        SELECT CHECK_NAME, VIEW_NAME, DOMAIN AS CHECK_DOMAIN FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE ENABLED;
    FOR c IN checks DO
        LET check_name   VARCHAR := c.CHECK_NAME;
        LET view_name    VARCHAR := c.VIEW_NAME;
        LET check_domain VARCHAR := c.CHECK_DOMAIN;
        IF (NOT (:check_domain = :DOMAIN OR :DOMAIN = 'all')) THEN CONTINUE; END IF;
        sql_text := 'INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.sensor_results ' ||
                    'SELECT CHECK_NAME, SUBJECT, PERIOD_KEY, PERIOD_TS, METRIC_VALUE, OBSERVED, EXPECTED, SEVERITY, MESSAGE ' ||
                    'FROM GROCERYDBTPROJECT.GROCERY_OPS.' || view_name || ' WHERE CHECK_NAME = ''' || check_name || '''';
        BEGIN
            EXECUTE IMMEDIATE :sql_text;
            n_checks := n_checks + 1;
        EXCEPTION WHEN OTHER THEN
            -- a broken sensor is itself a finding, never a silent gap
            INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.sensor_results
            VALUES (:check_name, 'sensor_error', CURRENT_DATE()::VARCHAR, CURRENT_TIMESTAMP(), NULL, NULL, NULL, 'WARN', 'sensor view ' || :view_name || ' failed: ' || :SQLERRM);
        END;
    END FOR;

    -- metrics for every evaluated row (OK included: this is the trend store)
    MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY t
    USING (SELECT CURRENT_DATE() AS METRIC_DATE, c.DOMAIN, r.CHECK_NAME AS METRIC_NAME, COALESCE(r.SUBJECT, '-') || IFF(r.PERIOD_KEY IS NULL, '', '@' || r.PERIOD_KEY) AS DIMENSION, r.METRIC_VALUE AS VALUE
           FROM GROCERYDBTPROJECT.GROCERY_OPS.sensor_results r JOIN GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK c ON c.CHECK_NAME = r.CHECK_NAME
           WHERE r.METRIC_VALUE IS NOT NULL
           QUALIFY ROW_NUMBER() OVER (PARTITION BY r.CHECK_NAME, r.SUBJECT, r.PERIOD_KEY ORDER BY r.PERIOD_TS DESC) = 1) s
    ON t.METRIC_DATE = s.METRIC_DATE AND t.METRIC_NAME = s.METRIC_NAME AND t.DIMENSION = s.DIMENSION
    WHEN MATCHED THEN UPDATE SET VALUE = s.VALUE, RECORDED_AT = CURRENT_TIMESTAMP(), RUN_ID = :run_id
    WHEN NOT MATCHED THEN INSERT (METRIC_DATE, DOMAIN, METRIC_NAME, DIMENSION, VALUE, RUN_ID) VALUES (s.METRIC_DATE, s.DOMAIN, s.METRIC_NAME, s.DIMENSION, s.VALUE, :run_id);

    -- events: WARN/CRIT findings about the last 14 days; dedup by fingerprint
    MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT t
    USING (SELECT r.*, c.DOMAIN, c.SUPPRESS_HOURS, r.CHECK_NAME || '|' || COALESCE(r.SUBJECT, '-') || '|' || COALESCE(r.PERIOD_KEY, '-') AS FINGERPRINT
           FROM GROCERYDBTPROJECT.GROCERY_OPS.sensor_results r JOIN GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK c ON c.CHECK_NAME = r.CHECK_NAME
           WHERE r.SEVERITY IN ('WARN', 'CRIT') AND COALESCE(r.PERIOD_TS, CURRENT_TIMESTAMP()) >= DATEADD(day, -14, CURRENT_TIMESTAMP())
           QUALIFY ROW_NUMBER() OVER (PARTITION BY FINGERPRINT ORDER BY r.PERIOD_TS DESC) = 1) s
    ON t.FINGERPRINT = s.FINGERPRINT AND t.STATUS IN ('open', 'acked')
    WHEN MATCHED THEN UPDATE SET LAST_SEEN_AT = CURRENT_TIMESTAMP(), OBSERVED = s.OBSERVED, MESSAGE = s.MESSAGE,
         SEVERITY = IFF(s.SEVERITY = 'CRIT', 'CRIT', t.SEVERITY), RUN_ID = :run_id
    WHEN NOT MATCHED THEN INSERT (DOMAIN, CHECK_NAME, SEVERITY, FINGERPRINT, SUBJECT, OBSERVED, EXPECTED, MESSAGE, SOURCE, PERIOD_TS, RUN_ID)
         VALUES (s.DOMAIN, s.CHECK_NAME, s.SEVERITY, s.FINGERPRINT, s.SUBJECT, s.OBSERVED, s.EXPECTED, s.MESSAGE, 'sensor', s.PERIOD_TS, :run_id);
    n_new := (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT WHERE RUN_ID = :run_id AND FIRST_SEEN_AT >= DATEADD(minute, -10, CURRENT_TIMESTAMP()) AND LAST_SEEN_AT = FIRST_SEEN_AT);

    -- resolve: open sensor events of this domain's checks that no longer fire
    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT t
       SET STATUS = 'resolved', RESOLVED_AT = CURRENT_TIMESTAMP()
     WHERE t.STATUS IN ('open', 'acked') AND t.SOURCE = 'sensor'
       AND t.CHECK_NAME IN (SELECT CHECK_NAME FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE ENABLED AND (DOMAIN = :DOMAIN OR :DOMAIN = 'all'))
       AND NOT EXISTS (SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_OPS.sensor_results r
                       WHERE r.SEVERITY IN ('WARN', 'CRIT') AND r.CHECK_NAME || '|' || COALESCE(r.SUBJECT, '-') || '|' || COALESCE(r.PERIOD_KEY, '-') = t.FINGERPRINT);
    -- expire: findings about periods older than 14 days
    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT
       SET STATUS = 'resolved', RESOLVED_AT = CURRENT_TIMESTAMP(), MESSAGE = MESSAGE || ' | expired (period older than 14 days)'
     WHERE STATUS IN ('open', 'acked') AND PERIOD_TS < DATEADD(day, -14, CURRENT_TIMESTAMP());

    n_open := (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT e JOIN GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK c ON c.CHECK_NAME = e.CHECK_NAME
               WHERE e.STATUS = 'open' AND (c.DOMAIN = :DOMAIN OR :DOMAIN = 'all'));
    max_sev := (SELECT COALESCE(MAX(CASE SEVERITY WHEN 'CRIT' THEN 3 WHEN 'WARN' THEN 2 WHEN 'INFO' THEN 1 ELSE 0 END), 0) FROM GROCERYDBTPROJECT.GROCERY_OPS.sensor_results);
    max_sev := CASE :max_sev WHEN '3' THEN 'CRIT' WHEN '2' THEN 'WARN' WHEN '1' THEN 'INFO' ELSE 'OK' END;

    summary := (SELECT OBJECT_CONSTRUCT(
        'run_id', :run_id, 'domain', :DOMAIN, 'checks_run', :n_checks, 'events_new', :n_new, 'events_open', :n_open, 'max_severity', :max_sev,
        'findings', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('check', CHECK_NAME, 'subject', SUBJECT, 'period', PERIOD_KEY, 'severity', SEVERITY, 'metric', METRIC_VALUE, 'message', MESSAGE, 'observed', OBSERVED))
                       WITHIN GROUP (ORDER BY CASE SEVERITY WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 WHEN 'INFO' THEN 2 ELSE 3 END, CHECK_NAME)
                     FROM (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.sensor_results WHERE SEVERITY <> 'OK' ORDER BY PERIOD_TS DESC LIMIT 40)),
        'ok_checks', (SELECT ARRAY_AGG(DISTINCT CHECK_NAME) FROM GROCERYDBTPROJECT.GROCERY_OPS.sensor_results WHERE SEVERITY = 'OK')));

    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN
       SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'success', CHECKS_RUN = :n_checks, EVENTS_NEW = :n_new, EVENTS_OPEN = :n_open, MAX_SEVERITY = :max_sev
     WHERE RUN_ID = :run_id;
    RETURN summary;
EXCEPTION WHEN OTHER THEN
    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'failed', ERROR = :SQLERRM WHERE RUN_ID = :run_id;
    RAISE;
END;
$$;
