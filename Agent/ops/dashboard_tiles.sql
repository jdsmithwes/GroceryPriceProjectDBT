-- =============================================================================
-- Snowsight dashboard "Grocery Ops" — tile queries (the control plane's read side)
--
-- Snowsight dashboards have no DDL/API, so this file is the source of truth for
-- the tiles. Build once: Snowsight › Projects › Dashboards › + Dashboard
-- "Grocery Ops" › role GROCERY_OPS_ROLE (or ACCOUNTADMIN), warehouse
-- GROCERY_OPS_WH › for each block below: New tile › From SQL worksheet › paste
-- › run › pick the chart type noted › name the tile. Keep auto-refresh OFF
-- (each open runs 8 XS queries on GROCERY_OPS_WH; that is the only cost).
--
-- Writes (change a model, silence a check, acknowledge a finding) are not
-- dashboard operations: use GROCERY_OPS_AGENT in Snowflake Intelligence or the
-- one-line CALLs at the bottom.
-- =============================================================================

-- Tile 1 · Scorecards (table, or four Scorecard tiles from the same query) ---
SELECT
    (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_OPS.V_REGISTRY_STATUS WHERE ENABLED)                           AS COMPONENTS,
    (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_OPS.V_REGISTRY_STATUS WHERE IS_SILENT)                         AS SILENT_COMPONENTS,
    (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT WHERE STATUS = 'open')                           AS OPEN_FINDINGS,
    (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT WHERE STATUS = 'open' AND SEVERITY = 'CRIT')     AS OPEN_CRIT,
    (SELECT ROUND(OBSERVED:month_to_date_credits::FLOAT, 1) FROM GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_COST_PROJECTION WHERE SUBJECT = 'TOTAL') AS CREDITS_MTD,
    (SELECT ROUND(OBSERVED:projected_month_end_credits::FLOAT, 1) FROM GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_COST_PROJECTION WHERE SUBJECT = 'TOTAL') AS CREDITS_PROJECTED,
    20                                                                                                             AS CREDITS_BUDGET,
    (SELECT MAX(STARTED_AT) FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN WHERE AGENT_NAME = 'agent_supervisor')      AS LAST_SUPERVISOR_RUN;

-- Tile 2 · Registry — every deployed component (table) -------------------------
SELECT AGENT_NAME, KIND, DOMAIN, PLATFORM, SCHEDULE_TEXT, MODEL, ENABLED,
       LAST_RUN_AT, LAST_STATUS, IS_SILENT, PROMPT_VERSION
FROM GROCERYDBTPROJECT.GROCERY_OPS.V_REGISTRY_STATUS
ORDER BY IS_SILENT DESC, DOMAIN, KIND, AGENT_NAME;

-- Tile 3 · Open findings by severity (table) ----------------------------------
SELECT SEVERITY, DOMAIN, CHECK_NAME, SUBJECT, LEFT(MESSAGE, 160) AS MESSAGE, SOURCE, FIRST_SEEN_AT, EVENT_ID
FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT
WHERE STATUS = 'open'
ORDER BY CASE SEVERITY WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, FIRST_SEEN_AT DESC;

-- Tile 4 · Budget — projected month-end as % of each quota (bar chart: SUBJECT × PROJECTED_PCT_OF_QUOTA)
SELECT SUBJECT, ROUND(METRIC_VALUE) AS PROJECTED_PCT_OF_QUOTA,
       ROUND(OBSERVED:month_to_date_credits::FLOAT, 2)      AS CREDITS_MTD,
       ROUND(OBSERVED:projected_month_end_credits::FLOAT, 2) AS CREDITS_PROJECTED,
       OBSERVED:quota_credits::FLOAT                          AS QUOTA
FROM GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_COST_PROJECTION
ORDER BY SUBJECT;

-- Tile 5 · Credits per day by warehouse, last 28 days (line chart: USAGE_DATE × CREDITS, series WAREHOUSE_NAME)
-- Reads ACCOUNT_USAGE directly (45 min - 3 h lag); GROCERY_OPS_ROLE has SNOWFLAKE.USAGE_VIEWER.
SELECT TO_DATE(START_TIME) AS USAGE_DATE, WAREHOUSE_NAME, ROUND(SUM(CREDITS_USED), 3) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD(day, -28, CURRENT_DATE())
GROUP BY 1, 2 ORDER BY 1, 2;

-- Tile 6 · Recent runs — sensors, agents, tasks with model and tokens (table)
SELECT STARTED_AT, KIND, AGENT_NAME, STATUS, MAX_SEVERITY, MODEL, INPUT_TOKENS, OUTPUT_TOKENS,
       ROUND(TOKEN_CREDITS, 4) AS TOKEN_CREDITS, EMAIL_SENT,
       TIMESTAMPDIFF(second, STARTED_AT, ENDED_AT) AS SECONDS, LEFT(ERROR, 120) AS ERROR
FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN
ORDER BY STARTED_AT DESC
LIMIT 40;

-- Tile 7 · Model policy — which model does which job (table) -------------------
SELECT MODEL_TASK, MODEL, FALLBACK_MODEL, MAX_TOKENS, MONTHLY_TOKEN_BUDGET, ENABLED, RATIONALE, UPDATED_AT
FROM GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY
ORDER BY MODEL_TASK;

-- Tile 8 · Agent tokens month-to-date by model (bar chart: MODEL × TOKENS) ----
SELECT MODEL, COUNT(*) AS RUNS, SUM(INPUT_TOKENS + OUTPUT_TOKENS) AS TOKENS, ROUND(SUM(TOKEN_CREDITS), 3) AS CREDITS
FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN
WHERE KIND = 'agent' AND STARTED_AT >= DATE_TRUNC(month, CURRENT_DATE())
GROUP BY 1 ORDER BY 3 DESC;

-- Tile 9 · Latest supervisor report (table, one cell) --------------------------
SELECT STARTED_AT, MODEL, MAX_SEVERITY, RESPONSE
FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN
WHERE AGENT_NAME = 'agent_supervisor' AND STATUS = 'success'
ORDER BY STARTED_AT DESC LIMIT 1;

-- =============================================================================
-- Writes (one line each; audited in CONFIG_AUDIT; effective next run) ----------
-- CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_SET_MODEL_POLICY('ops_cost', 'claude-haiku-5-5', 'arithmetic over a small table');
-- CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_SET_CHECK('walmart_rows', 'seasonal catalog shrink', NULL, 40, 60, 168);
-- CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_ACK_EVENT('<EVENT_ID>', 'known; fixed by re-creating the schedules');
-- Or ask GROCERY_OPS_AGENT in Snowflake Intelligence: "switch the cost agent to haiku because ..."
