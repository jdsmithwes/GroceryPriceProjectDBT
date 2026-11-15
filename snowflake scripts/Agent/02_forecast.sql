-- Grocery value agent — Phase 2: weekly price forecast (SNOWFLAKE.ML.FORECAST).
--
-- One procedure, parameterized by input table and target schema, so the same
-- code runs in the sandbox (GROCERY_DEV_*) and prod (GROCERY_*):
--
--   CALL GROCERYDBTPROJECT.GROCERY_DEV_ML.SP_REFRESH_PRICE_FORECAST(
--       'GROCERYDBTPROJECT.GROCERY_DEV_MARTS.DBT_FCT_PRODUCT_PRICE_WEEKLY_SERIES',
--       'GROCERYDBTPROJECT.GROCERY_DEV_ML', 6, 8,
--       'GROCERYDBTPROJECT.GROCERY_DEV_MARTS.DBT_DIM_FORECAST_SCOPE');   -- dbt view; NULL = all eligible (don't)
--
-- Run it on GROCERY_ML_WH (Medium, auto-suspend 60s), not COMPUTE_WH: multi-series
-- training parallelizes across nodes. The first unscoped attempt (6,733 series, XS)
-- ran 4h23m before being cancelled and cost ~4.7 credits (2026-11-15).
-- Measured on GROCERY_ML_WH (Medium) the same day: 100 series = 144 s training
-- + 28 s forecasting, ~0.19 credits -> ~0.002 credits per series per week.
-- Scope (owner decision 2026-11-15): products carried by both retailers,
-- defined by the dbt view dim_forecast_scope.
--
-- What it does:
--   1. Training view: weekly effective price per product series, only series
--      with >= MIN_WEEKS observed weeks AND at least one price change. Constant
--      series are never trained (the rule labels them STABLE_PRICE) — saves
--      credits and avoids a model "forecasting" a flat line.
--   2. Retrains the multi-series model (ON_ERROR = SKIP: a series the
--      algorithm can't fit is skipped, not fatal).
--   3. Forecasts HORIZON weeks with an 80% prediction interval and replaces
--      PRICE_FORECAST's rows in place (INSERT OVERWRITE, never DROP/CREATE —
--      fct_buy_recommendation is a dynamic table reading it).
--   4. Logs the run to PRICE_FORECAST_RUNS.
--
-- The forecast is a second opinion for fct_buy_recommendation; the
-- history-based rule decides (Agent/ONTOLOGY.md).

------------------------------------------------------------------------------
-- Sandbox schema (prod GROCERY_ML is created in 01_governance.sql)
------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_DEV_ML
    COMMENT = 'Sandbox copy of GROCERY_ML: price forecast model + output';

------------------------------------------------------------------------------
-- Procedure (create it in each ML schema that runs forecasts)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_DEV_ML.SP_REFRESH_PRICE_FORECAST(
    SERIES_TABLE VARCHAR,   -- fully qualified DBT_FCT_PRODUCT_PRICE_WEEKLY_SERIES
    ML_SCHEMA VARCHAR,      -- fully qualified schema for model + output
    HORIZON_WEEKS INTEGER,  -- weeks to forecast
    MIN_WEEKS INTEGER,      -- minimum observed weeks to train a series
    SCOPE_TABLE VARCHAR     -- fully qualified table/view with a PRODUCT_KEY column: only
                            -- these series are trained. NULL = every eligible series
                            -- (6,733 as of 2026-11-15 — 4h+ on XS; never run unscoped
                            -- without timing a sample first).
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    sql_text VARCHAR;
    training_view VARCHAR DEFAULT ML_SCHEMA || '.V_FORECAST_TRAINING';
    forecast_table VARCHAR DEFAULT ML_SCHEMA || '.PRICE_FORECAST';
    n_series INTEGER;
    n_rows INTEGER;
    n_forecast_series INTEGER;
BEGIN
    -- EXECUTE IMMEDIATE and IDENTIFIER() take a string or a variable, not a
    -- || expression, so each statement is assembled into sql_text first.
    sql_text := 'CREATE OR REPLACE VIEW ' || training_view || ' AS
        WITH eligible AS (
            SELECT PRODUCT_KEY
            FROM ' || SERIES_TABLE || '
            ' || IFF(SCOPE_TABLE IS NULL, '', 'WHERE PRODUCT_KEY IN (SELECT PRODUCT_KEY FROM ' || SCOPE_TABLE || ')') || '
            GROUP BY PRODUCT_KEY
            HAVING COUNT(*) >= ' || MIN_WEEKS || '
               AND MIN(EFFECTIVE_PRICE) < MAX(EFFECTIVE_PRICE)
        )
        SELECT s.PRODUCT_KEY AS SERIES,
               s.PRICE_WEEK::TIMESTAMP_NTZ AS TS,
               s.EFFECTIVE_PRICE::FLOAT AS Y
        FROM ' || SERIES_TABLE || ' s
        JOIN eligible e ON e.PRODUCT_KEY = s.PRODUCT_KEY';
    EXECUTE IMMEDIATE :sql_text;

    SELECT COUNT(DISTINCT SERIES), COUNT(*) INTO :n_series, :n_rows
    FROM IDENTIFIER(:training_view);

    sql_text := 'CREATE OR REPLACE SNOWFLAKE.ML.FORECAST ' || ML_SCHEMA || '.PRICE_FORECAST_MODEL(
            INPUT_DATA => TABLE(' || training_view || '),
            SERIES_COLNAME => ''SERIES'',
            TIMESTAMP_COLNAME => ''TS'',
            TARGET_COLNAME => ''Y'',
            CONFIG_OBJECT => {''ON_ERROR'': ''SKIP'', ''evaluate'': FALSE})';
    EXECUTE IMMEDIATE :sql_text;

    sql_text := 'CREATE TABLE IF NOT EXISTS ' || forecast_table || ' (
            SERIES VARCHAR, TS TIMESTAMP_NTZ, FORECAST FLOAT,
            LOWER_BOUND FLOAT, UPPER_BOUND FLOAT, TRAINED_AT TIMESTAMP_LTZ)';
    EXECUTE IMMEDIATE :sql_text;

    sql_text := 'CALL ' || ML_SCHEMA || '.PRICE_FORECAST_MODEL!FORECAST(
            FORECASTING_PERIODS => ' || HORIZON_WEEKS || ',
            CONFIG_OBJECT => {''prediction_interval'': 0.8})';
    EXECUTE IMMEDIATE :sql_text;

    sql_text := 'INSERT OVERWRITE INTO ' || forecast_table || '
        SELECT SERIES::VARCHAR, TS, FORECAST, LOWER_BOUND, UPPER_BOUND, ''' || started_at::VARCHAR || '''::TIMESTAMP_LTZ
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))';
    EXECUTE IMMEDIATE :sql_text;

    SELECT COUNT(DISTINCT SERIES) INTO :n_forecast_series
    FROM IDENTIFIER(:forecast_table);

    sql_text := 'CREATE TABLE IF NOT EXISTS ' || ML_SCHEMA || '.PRICE_FORECAST_RUNS (
            STARTED_AT TIMESTAMP_LTZ, COMPLETED_AT TIMESTAMP_LTZ, SERIES_TABLE VARCHAR,
            SERIES_TRAINED INTEGER, TRAINING_ROWS INTEGER, SERIES_FORECAST INTEGER,
            HORIZON_WEEKS INTEGER, MIN_WEEKS INTEGER, SCOPE_TABLE VARCHAR, WAREHOUSE VARCHAR)';
    EXECUTE IMMEDIATE :sql_text;

    sql_text := 'INSERT INTO ' || ML_SCHEMA || '.PRICE_FORECAST_RUNS VALUES (''' ||
        started_at::VARCHAR || '''::TIMESTAMP_LTZ, CURRENT_TIMESTAMP(), ''' || SERIES_TABLE || ''', ' ||
        n_series || ', ' || n_rows || ', ' || n_forecast_series || ', ' ||
        HORIZON_WEEKS || ', ' || MIN_WEEKS || ', ' || COALESCE('''' || SCOPE_TABLE || '''', 'NULL') ||
        ', ''' || CURRENT_WAREHOUSE() || ''')';
    EXECUTE IMMEDIATE :sql_text;

    RETURN 'trained ' || n_series || ' series (' || n_rows || ' rows); forecast ' ||
           n_forecast_series || ' series x ' || HORIZON_WEEKS || ' weeks';
END;
$$;

------------------------------------------------------------------------------
-- [PROD, Phase 5] Weekly task — runs Sunday 06:00 ET, after the Friday sweep,
-- the Saturday continuation, and the dynamic tables' 24h refresh. Owned by
-- GROCERY_ML_ROLE on GROCERY_AGENT_WH (see 01_governance.sql). Create the
-- procedure in GROCERY_ML first (same body as above).
------------------------------------------------------------------------------
-- CREATE OR REPLACE TASK GROCERYDBTPROJECT.GROCERY_ML.TASK_WEEKLY_PRICE_FORECAST
--     WAREHOUSE = GROCERY_ML_WH
--     SCHEDULE = 'USING CRON 0 6 * * SUN America/New_York'
--     COMMENT = 'Retrain + forecast weekly prices for the grocery value agent'
-- AS
--     CALL GROCERYDBTPROJECT.GROCERY_ML.SP_REFRESH_PRICE_FORECAST(
--         'GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_WEEKLY_SERIES',
--         'GROCERYDBTPROJECT.GROCERY_ML', 6, 8,
--         'GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_FORECAST_SCOPE');
-- ALTER TASK GROCERYDBTPROJECT.GROCERY_ML.TASK_WEEKLY_PRICE_FORECAST RESUME;
