-- Grocery ops layer — part 1: control plane (role, warehouse, monitors,
-- tables, seeds). Plan: /Users/jamaalsmith/.claude/plans/shimmying-herding-flamingo.md
--
-- Principle: deterministic SQL sensors decide WHETHER something is wrong and
-- how severe (02_ops_sensors.sql); agents explain, rank and propose
-- (03_ops_agents.sql); humans act in month 1, a gated whitelist in month 2.
-- Everything an agent or task does is a row in this schema.
--
-- Run as ACCOUNTADMIN. The ACCOUNT-LEVEL section (role, warehouse, monitors)
-- runs once, in prod only. Sandbox variant for the rest:
--   sed -E 's/GROCERY_OPS([^_A-Za-z0-9]|$)/GROCERY_DEV_OPS\1/g; s/GROCERY_OPS_WH/COMPUTE_WH/g; /^-- ACCOUNT-LEVEL/,/^-- END ACCOUNT-LEVEL/d'
-- Sensors read PROD sources even from the sandbox schema (that is what is
-- being tested); only the ops tables are duplicated.

USE ROLE ACCOUNTADMIN;

-- ACCOUNT-LEVEL (prod only) ---------------------------------------------------
CREATE ROLE IF NOT EXISTS GROCERY_OPS_ROLE
    COMMENT = 'Owns GROCERY_OPS; runs the ops sensors, agents and tasks. Read-only everywhere else.';
GRANT ROLE GROCERY_OPS_ROLE TO ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS GROCERY_OPS_WH
    WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Ops sensors, ops agents, ops tasks. Isolated so the ops budget is visible and cannot be blamed on the product.';

-- Ops budget: 2 credits/month. Suspend only at 100% so the sensors never blind
-- themselves early; 75/90 notify.
CREATE RESOURCE MONITOR IF NOT EXISTS GROCERY_OPS_MONITOR
    WITH CREDIT_QUOTA = 2 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 75 PERCENT DO NOTIFY ON 90 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND;
ALTER WAREHOUSE GROCERY_OPS_WH SET RESOURCE_MONITOR = GROCERY_OPS_MONITOR;

-- COMPUTE_WH (dbt, dynamic tables, pipes) had no cap: 8 credits/month.
CREATE RESOURCE MONITOR IF NOT EXISTS GROCERY_COMPUTE_MONITOR
    WITH CREDIT_QUOTA = 8 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 50 PERCENT DO NOTIFY ON 75 PERCENT DO NOTIFY ON 90 PERCENT DO SUSPEND ON 100 PERCENT DO SUSPEND_IMMEDIATE;
ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = GROCERY_COMPUTE_MONITOR;

CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS
    COMMENT = 'Operations control plane: agent registry, model policy, checks, events, runs, runbook';
-- (Standard edition: Time Travel is capped at 1 day, so no DATA_RETENTION_TIME_IN_DAYS here;
--  recovery = S3 raw files + dbt rebuild, see Agent/ops/README.md)
GRANT OWNERSHIP ON SCHEMA GROCERYDBTPROJECT.GROCERY_OPS TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;

-- What the ops role may read (nothing it may change outside its schema)
GRANT USAGE ON DATABASE GROCERYDBTPROJECT TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON WAREHOUSE GROCERY_OPS_WH TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON WAREHOUSE COMPUTE_WH TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON WAREHOUSE GROCERY_AGENT_WH TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON WAREHOUSE GROCERY_ML_WH TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON WAREHOUSE GROCERY_OPS_WH TO ROLE GROCERY_OPS_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE GROCERY_OPS_ROLE;      -- ACCOUNT_USAGE
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE GROCERY_OPS_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE GROCERY_OPS_ROLE;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE GROCERY_OPS_ROLE;
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE GROCERY_OPS_ROLE;
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE GROCERY_OPS_ROLE;
GRANT EXECUTE MANAGED ALERT ON ACCOUNT TO ROLE GROCERY_OPS_ROLE;
-- read the sources the sensors look at
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.JOB_PERFORMANCE TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA GROCERYDBTPROJECT.JOB_PERFORMANCE TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_RAW_KROGER TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_RAW_KROGER TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_RAW_WALMART TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_RAW_WALMART TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_INTERMEDIATE TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_INTERMEDIATE TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA GROCERYDBTPROJECT.GROCERY_INTERMEDIATE TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_MARTS TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_MARTS TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_MARTS TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA GROCERYDBTPROJECT.GROCERY_MARTS TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_ML TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_ML TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON TASK GROCERYDBTPROJECT.GROCERY_ML.TASK_WEEKLY_PRICE_FORECAST TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_APP TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_APP TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_SEMANTIC TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES_KROGER TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES_WALMART TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES_UPC TO ROLE GROCERY_OPS_ROLE;
-- pipes do not support bulk (ALL PIPES IN SCHEMA) grants: name each one
GRANT MONITOR ON PIPE GROCERYDBTPROJECT.AWS_RESOURCES.ORCHESTRATION_JOB_RUNS_PIPE TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON PIPE GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_PRICING_PIPE TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON PIPE GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_PRODUCT_CATALOG_PIPE TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON PIPE GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_LOCATIONS_PIPE TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON PIPE GROCERYDBTPROJECT.AWS_RESOURCES_KROGER.KROGER_INVENTORY_PIPE TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON PIPE GROCERYDBTPROJECT.AWS_RESOURCES_WALMART.WALMART_PRODUCT_CATALOG_PIPE TO ROLE GROCERY_OPS_ROLE;
GRANT MONITOR ON PIPE GROCERYDBTPROJECT.AWS_RESOURCES_UPC.UPCDATABASE_PRODUCT_DETAILS_PIPE TO ROLE GROCERY_OPS_ROLE;
GRANT ROLE GROCERY_OPS_ROLE TO USER JDSMITHWES;
-- END ACCOUNT-LEVEL ------------------------------------------------------------

USE WAREHOUSE GROCERY_OPS_WH;
CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS;

------------------------------------------------------------------------------
-- Control-plane tables
------------------------------------------------------------------------------
-- Every deployed thing that is supposed to run or serve: agents, tasks,
-- alerts, pipes, schedules, apps. The Operations page and the supervisor read
-- this; "did everything with a schedule run since it was due?" is a join
-- between this table and OPS_RUN.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY (
    AGENT_NAME              VARCHAR NOT NULL PRIMARY KEY,
    KIND                    VARCHAR NOT NULL COMMENT 'agent | task | alert | pipe | schedule | dynamic_tables | app | job',
    DOMAIN                  VARCHAR COMMENT 'ingestion | quality | cost | performance | improvement | supervisor | product',
    PLATFORM                VARCHAR NOT NULL COMMENT 'snowflake | aws | streamlit | local',
    RUNTIME_OBJECT          VARCHAR COMMENT 'Fully qualified object, ARN, or file',
    SCHEDULE_TEXT           VARCHAR COMMENT 'Human-readable schedule',
    EXPECTED_INTERVAL_HOURS NUMBER  COMMENT 'How often a run is expected; NULL = on demand. Silence beyond 1.5x this is a finding.',
    MODEL_TASK              VARCHAR COMMENT 'Key into MODEL_POLICY for agents',
    PROMPT_VERSION          VARCHAR,
    INSTRUCTIONS            VARCHAR COMMENT 'Agent instructions (versioned copy of Agent/ops/prompts/<agent>.md)',
    TOOLS                   VARIANT COMMENT 'Tool names this agent may call (procedure tools in GROCERY_OPS)',
    ENABLED                 BOOLEAN DEFAULT TRUE,
    OWNER                   VARCHAR DEFAULT 'JDSMITHWES',
    DESCRIPTION             VARCHAR,
    CREATED_AT              TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT              TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Registry of every deployed agent, task, alert, pipe, schedule and app the ops layer watches.';

-- Which model each kind of work uses. Changed with UPDATE (audited), never by
-- redeploying code. ENABLED = per-agent kill switch.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY (
    MODEL_TASK           VARCHAR NOT NULL PRIMARY KEY,
    MODEL                VARCHAR NOT NULL,
    FALLBACK_MODEL       VARCHAR,
    MAX_TOKENS           NUMBER  DEFAULT 20000 COMMENT 'orchestration.budget.tokens per run',
    BUDGET_SECONDS       NUMBER  DEFAULT 120,
    MONTHLY_TOKEN_BUDGET NUMBER  COMMENT 'Runs are skipped (and an event raised) once exceeded',
    ENABLED              BOOLEAN DEFAULT TRUE,
    RATIONALE            VARCHAR,
    UPDATED_AT           TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_BY           VARCHAR DEFAULT CURRENT_USER()
) COMMENT = 'Model selection per task. Edited through SP_SET_MODEL_POLICY so changes are audited.';

-- Service levels: every check cites the SLO that justifies its threshold.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.SLO (
    SLO_NAME    VARCHAR NOT NULL PRIMARY KEY,
    DESCRIPTION VARCHAR,
    TARGET      VARCHAR COMMENT 'Human-readable target, e.g. ">= 78 of 81 stores priced each week"',
    WINDOW_DAYS NUMBER DEFAULT 28,
    SLI_SQL     VARCHAR COMMENT 'Query returning one number: the indicator over the window'
);

-- The checks the sensors run. Thresholds live here, not in view code.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK (
    CHECK_NAME     VARCHAR NOT NULL PRIMARY KEY,
    DOMAIN         VARCHAR NOT NULL,
    VIEW_NAME      VARCHAR NOT NULL COMMENT 'Sensor view in GROCERY_OPS that evaluates this check',
    ENABLED        BOOLEAN DEFAULT TRUE,
    WARN_THRESHOLD NUMBER,
    CRIT_THRESHOLD NUMBER,
    SUPPRESS_HOURS NUMBER DEFAULT 168 COMMENT 'Same fingerprint is not re-raised within this window while open',
    SLO_NAME       VARCHAR,
    RUNBOOK_TOPIC  VARCHAR,
    DESCRIPTION    VARCHAR,
    UPDATED_AT     TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_BY     VARCHAR DEFAULT CURRENT_USER()
);

-- Every finding. Append-only; dedup by FINGERPRINT while open.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT (
    EVENT_ID      VARCHAR NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    DETECTED_AT   TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    DOMAIN        VARCHAR NOT NULL,
    CHECK_NAME    VARCHAR NOT NULL,
    SEVERITY      VARCHAR NOT NULL COMMENT 'INFO | WARN | CRIT',
    FINGERPRINT   VARCHAR NOT NULL COMMENT 'CHECK_NAME|SUBJECT|period: the identity of a finding across runs',
    SUBJECT       VARCHAR COMMENT 'What it is about: a run, pipe, table, store, warehouse',
    OBSERVED      VARIANT,
    EXPECTED      VARIANT,
    MESSAGE       VARCHAR,
    SOURCE        VARCHAR NOT NULL DEFAULT 'sensor' COMMENT 'sensor | agent | supervisor | autofix | alert | human',
    PERIOD_TS     TIMESTAMP_TZ COMMENT 'The time the finding is about (a run slot, a week); findings older than 14 days expire',
    RUN_ID        VARCHAR,
    STATUS        VARCHAR NOT NULL DEFAULT 'open' COMMENT 'open | acked | resolved | suppressed',
    FIRST_SEEN_AT TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_SEEN_AT  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    RESOLVED_AT   TIMESTAMP_TZ,
    ACKED_BY      VARCHAR,
    ACKED_AT      TIMESTAMP_TZ,
    EMAILED_AT    TIMESTAMP_TZ
);

-- Baselines and trend lines.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY (
    METRIC_DATE DATE    NOT NULL,
    DOMAIN      VARCHAR NOT NULL,
    METRIC_NAME VARCHAR NOT NULL,
    DIMENSION   VARCHAR NOT NULL DEFAULT '-',
    VALUE       FLOAT,
    RUN_ID      VARCHAR,
    RECORDED_AT TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (METRIC_DATE, METRIC_NAME, DIMENSION)
);

-- Every run of anything in this layer (and, via task edits, the forecast task).
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN (
    RUN_ID         VARCHAR NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    KIND           VARCHAR NOT NULL COMMENT 'sensor | agent | task | alert | selftest | autofix',
    DOMAIN         VARCHAR,
    AGENT_NAME     VARCHAR,
    STARTED_AT     TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    ENDED_AT       TIMESTAMP_TZ,
    STATUS         VARCHAR COMMENT 'success | failed | skipped',
    CHECKS_RUN     NUMBER,
    EVENTS_NEW     NUMBER,
    EVENTS_OPEN    NUMBER,
    MAX_SEVERITY   VARCHAR,
    MODEL          VARCHAR,
    PROMPT_VERSION VARCHAR,
    INPUT_TOKENS   NUMBER,
    OUTPUT_TOKENS  NUMBER,
    TOKEN_CREDITS  FLOAT,
    EMAIL_SENT     BOOLEAN DEFAULT FALSE,
    RESPONSE       VARCHAR COMMENT 'Agent response text (90-day retention by housekeeping)',
    ERROR          VARCHAR
);

-- Known failure modes, so agents cite the fix we already know.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUNBOOK (
    TOPIC       VARCHAR NOT NULL PRIMARY KEY,
    SYMPTOM     VARCHAR,
    KNOWN_CAUSE VARCHAR,
    FIX         VARCHAR,
    ACTION_NAME VARCHAR COMMENT 'Month-2 whitelist action, or human',
    SOURCE_DOC  VARCHAR
);

-- Who changed configuration (MODEL_POLICY, OPS_CHECK, AGENT_REGISTRY) and how.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.CONFIG_AUDIT (
    AUDIT_ID   VARCHAR DEFAULT UUID_STRING(),
    CHANGED_AT TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    CHANGED_BY VARCHAR DEFAULT CURRENT_USER(),
    TABLE_NAME VARCHAR,
    KEY_VALUE  VARCHAR,
    OLD_ROW    VARIANT,
    NEW_ROW    VARIANT,
    REASON     VARCHAR
);

------------------------------------------------------------------------------
-- Seeds (MERGE so re-running the script never duplicates or clobbers edits
-- made through the audited procedures)
------------------------------------------------------------------------------
MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY t
USING (SELECT * FROM VALUES
    ('ops_ingestion',   'claude-haiku-5-5',  'llama3.3-70b',      12000,  90, 1500000, 'Pattern check and short report; cheapest adequate model'),
    ('ops_quality',     'claude-sonnet-5-5', 'claude-haiku-5-5',  20000, 150, 3000000, 'Must judge whether an outlier is real (seasonal turkey vs bad parse)'),
    ('ops_cost',        'claude-haiku-5-5',  'llama3.3-70b',      12000,  90, 1500000, 'Arithmetic over a small table'),
    ('ops_performance', 'claude-sonnet-5-5', 'claude-haiku-5-5',  20000, 150, 3000000, 'Diagnosis across task, refresh and pipe logs'),
    ('ops_improvement', 'claude-opus-5-5',   'claude-sonnet-5-5', 60000, 600, 1500000, 'Open-ended trade-offs once a week; reads the cost-hotspot tool, so it needs room (raised 2026-11-17 after a 240 s run returned no text)'),
    ('ops_supervisor',  'claude-sonnet-5-5', 'claude-haiku-5-5',  20000, 150, 3000000, 'Daily correlation and escalation'),
    ('ops_digest',      'claude-opus-5-5',   'claude-sonnet-5-5', 40000, 420, 1200000, 'Weekly report needs judgement and reads the changelog + guest context (raised 2026-11-17)'),
    ('ops_summarize',   'llama3.3-70b',      'llama3.1-70b',       2000,  30, 2000000, 'JSON to a 40-line email; cheapest adequate'),
    ('product_labels',  'llama3.1-70b',      'llama3.1-8b',          12,  30, 2000000, 'Product-type labels (03_product_types.sql)'),
    ('eval_judge',      'llama3.1-70b',      'llama3.1-8b',         300,  30, 2000000, 'Eval judge in Agent/evals/run_evals.py'),
    ('value_agent',     'claude-sonnet-5-5', 'claude-sonnet-4-5', 100000, 120, 20000000, 'GROCERY_VALUE_AGENT orchestration (05_agent.sql); ~0.1 credit per eval question measured 2026-11-15')
) s (MODEL_TASK, MODEL, FALLBACK_MODEL, MAX_TOKENS, BUDGET_SECONDS, MONTHLY_TOKEN_BUDGET, RATIONALE)
ON t.MODEL_TASK = s.MODEL_TASK
WHEN NOT MATCHED THEN INSERT (MODEL_TASK, MODEL, FALLBACK_MODEL, MAX_TOKENS, BUDGET_SECONDS, MONTHLY_TOKEN_BUDGET, RATIONALE)
    VALUES (s.MODEL_TASK, s.MODEL, s.FALLBACK_MODEL, s.MAX_TOKENS, s.BUDGET_SECONDS, s.MONTHLY_TOKEN_BUDGET, s.RATIONALE);

MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.SLO t
USING (SELECT * FROM VALUES
    ('kroger_freshness',  'Kroger prices are at most 8 days old',                 '>= 95% of weeks',        28),
    ('kroger_coverage',   'Kroger stores priced each week',                       '>= 78 of 81 stores',     28),
    ('walmart_freshness', 'Walmart prices are at most 8 days old',                '>= 95% of weeks',        28),
    ('weekly_jobs',       'Scheduled ingestion jobs run and succeed',            '>= 95% of expected runs', 28),
    ('forecast_task',     'Sunday forecast task succeeds',                        '>= 95% of Sundays',      56),
    ('marts_fresh',       'Dynamic tables refresh within 36 h of new data',       '100%',                   28),
    ('agent_quality',     'Value agent golden-question score',                    '>= 90%',                 28),
    ('budget',            'Total Snowflake credits per month',                    '<= 20',                  31),
    ('ops_silence',       'Every scheduled ops component runs when due',         '100%',                   28)
) s (SLO_NAME, DESCRIPTION, TARGET, WINDOW_DAYS)
ON t.SLO_NAME = s.SLO_NAME
WHEN NOT MATCHED THEN INSERT (SLO_NAME, DESCRIPTION, TARGET, WINDOW_DAYS) VALUES (s.SLO_NAME, s.DESCRIPTION, s.TARGET, s.WINDOW_DAYS);

MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUNBOOK t
USING (SELECT * FROM VALUES
    ('scheduler_drop', 'No ORCHESTRATION_JOB_RUNS row for a Friday or Saturday slot and no ECS task, while CloudWatch AWS/Scheduler shows InvocationAttemptCount = 1 with TargetErrorCount = 1 and InvocationDroppedCount = 1 for the slot',
     'Corrected 2026-11-15 from the Scheduler metrics: EventBridge Scheduler DID attempt every Friday/Saturday slot from Oct 15 to Nov 13 2026; each attempt ended in a target error (ECS RunTask rejected) and was dropped because the schedules had no DLQ, so no task ever started. Oct 1-9 attempts succeeded; Nov 14 succeeded after the schedules were re-created on 2026-11-15. The RunTask error text was never captured (no DLQ then); grocery-ingest-dlq now receives it.',
     'Read the DLQ message for the RunTask error (task-definition revision, network config, IAM PassRole are the usual causes); fix the schedule target; re-run the slot with a one-off schedule (never friday_full on a weekday that already spent the Kroger 10k budget). The CloudWatch alarm grocery-ingest-friday-never-started (7 days without any attempt) and the Saturday ingestion sensors are the two independent detectors.',
     'human', 'Orchestration/README.md, Orchestration/ops-watcher/README.md'),
    ('pipe_stopped', 'SYSTEM$PIPE_STATUS executionState = STOPPED_MISSING_TABLE or STOPPED_*; files land in S3 but no rows arrive',
       'A target table or schema was renamed/dropped (happened 2026-08-10 after a schema rename).',
       'Recreate or repoint the target, then ALTER PIPE ... REFRESH to load the backlog. Confirm with COPY_HISTORY.',
       'human', '.claude/instructions.md'),
    ('kroger_budget_collision', 'Saturday continuation run mostly 429; fewer stores than expected on Saturday',
       'Kroger allows 10,000 calls per day; a manual off-schedule run shares the budget day with the scheduled one.',
       'Harmless: the checkpoint records completed stores only; the next scheduled run continues. Do not re-run the same day.',
       'none', '.claude/instructions.md'),
    ('walmart_429_fixed_page', 'Walmart loads about 1,400 items every week and stops at the same page',
       'The catalog walk hits HTTP 429 at lastDoc=10291077 every run; the sample is a fixed head of the catalog.',
       'Expected behaviour; a change in this number is the signal, not the number itself.',
       'none', '.claude/instructions.md'),
    ('dt_stale', 'A dynamic table has not refreshed within 36 h of new raw data, or its scheduling state is SUSPENDED',
       'Upstream refresh failed (often after a schema change) or the table auto-suspended after 5 consecutive failures.',
       'Check DYNAMIC_TABLE_REFRESH_HISTORY for the first failing table in the chain; fix its SQL via dbt (--full-refresh), then ALTER DYNAMIC TABLE ... RESUME.',
       'refresh_dynamic_table', 'Agent/README.md'),
    ('forecast_task_failed', 'TASK_WEEKLY_PRICE_FORECAST state FAILED or no run by Sunday 09:00 ET',
       'Warehouse suspended by its monitor, model training timeout, or a step after the forecast (labels, search refill, watches) failed.',
       'Read TASK_HISTORY error; if transient, EXECUTE TASK once (Sun 10:00 - Mon 06:00 ET only, monitor < 80%).',
       'rerun_forecast_task', 'Snowflake Scripts/Agent/04_search_and_basket_tool.sql'),
    ('search_stale', 'PRODUCT_SEARCH data_timestamp older than 8 days',
       'The Sunday task did not refill PRODUCT_SEARCH_SOURCE (search cannot read dynamic tables directly).',
       'INSERT OVERWRITE PRODUCT_SEARCH_SOURCE from DBT_SEARCH_PRODUCT_INDEX; the service re-indexes within its 1-day lag.',
       'refill_search_source', 'Agent/README.md'),
    ('cost_spike', 'A warehouse or service used more than 3x its 28-day p90 in a day, or the month projects over its monitor',
       'Known causes: an unscoped forecast (4.7 credits, 2026-11-15), eval runs (~0.11 credit per question), Trust Center scanner packages (~1.3 credits/day while enabled), a dbt --full-refresh of the marts.',
       'Identify the workload by QUERY_TAG / service type; stop it if still running; decide whether to raise the monitor or change the workload.',
       'human', 'Agent/ARCHITECTURE.md')
) s (TOPIC, SYMPTOM, KNOWN_CAUSE, FIX, ACTION_NAME, SOURCE_DOC)
ON t.TOPIC = s.TOPIC
WHEN NOT MATCHED THEN INSERT (TOPIC, SYMPTOM, KNOWN_CAUSE, FIX, ACTION_NAME, SOURCE_DOC) VALUES (s.TOPIC, s.SYMPTOM, s.KNOWN_CAUSE, s.FIX, s.ACTION_NAME, s.SOURCE_DOC);

-- Checks. Thresholds come from the 2026-11-15 baselines: Kroger ~900k rows and
-- 81 stores per full week (44-45 on Friday night), Walmart ~1,400 items,
-- COMPUTE_WH 0.85 credits/week, agent WH 0.21, ML WH 0.17.
MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK t
USING (SELECT * FROM VALUES
    -- ingestion
    ('run_missing',          'ingestion',   'V_CHECK_EXPECTED_RUNS',      NULL,  NULL, 168, 'weekly_jobs',       'scheduler_drop',        '1 = an expected Friday/Saturday run has no ORCHESTRATION_JOB_RUNS row 10 h after its slot (0 = ran)'),
    ('run_failed',           'ingestion',   'V_CHECK_EXPECTED_RUNS',      NULL,  NULL, 168, 'weekly_jobs',       'scheduler_drop',        '1 = a run row exists with STATUS = failed'),
    ('kroger_store_coverage','ingestion',   'V_CHECK_KROGER_COVERAGE',      78,    60, 168, 'kroger_coverage',   'kroger_budget_collision','Distinct Kroger stores priced this collection week (Sunday view)'),
    ('kroger_row_volume',    'ingestion',   'V_CHECK_LOAD_VOLUME',          40,    70, 168, 'weekly_jobs',       NULL,                    'Kroger pricing rows this week vs 4-week median, % deviation'),
    ('walmart_row_volume',   'ingestion',   'V_CHECK_LOAD_VOLUME',          30,    60, 168, 'weekly_jobs',       'walmart_429_fixed_page','Walmart catalog rows this week vs 4-week median, % deviation'),
    ('pipe_not_running',     'ingestion',   'V_CHECK_PIPES',              NULL,  NULL,  24, 'weekly_jobs',       'pipe_stopped',          '1 = SYSTEM$PIPE_STATUS executionState is not RUNNING (0 = running)'),
    ('seasonal_file_missing','ingestion',   'V_CHECK_SEASONAL',           NULL,  NULL, 168, 'weekly_jobs',       NULL,                    'A seasonal window is open but no kroger/seasonal file loaded this week'),
    -- quality
    ('source_freshness',     'quality',     'V_CHECK_FRESHNESS',             8,    10,  48, 'kroger_freshness',  'scheduler_drop',        'Days since the latest COLLECTED_AT per source'),
    ('price_outliers',       'quality',     'V_CHECK_PRICE_OUTLIERS',       50,   500, 168, NULL,                NULL,                    'Current-week prices <= 0, > 50x the product median, or week-over-week > 400%: count'),
    ('promo_ge_regular',     'quality',     'V_CHECK_PROMO_SHARE',           5,    15, 168, NULL,                NULL,                    'Share (%) of Kroger rows this week with promo >= regular (13k historically = ~1.5%)'),
    ('null_spike',           'quality',     'V_CHECK_NULLS',                 2,     5, 168, NULL,                NULL,                    'Null % on key raw columns this week (PRODUCTID, LOCATIONID, ITEMID, NAME)'),
    ('duplicate_rows',       'quality',     'V_CHECK_DUPLICATES',            0,  1000, 168, NULL,                NULL,                    'Duplicate (product, store, collected_at) rows or double-ingested files this week'),
    ('mart_integrity',       'quality',     'V_CHECK_MART_INTEGRITY',        0,     1, 168, 'marts_fresh',       'dt_stale',              'SQL ports of the critical dbt tests on the marts: failing rows'),
    ('parse_confidence_drift','quality',    'V_CHECK_PARSE_DRIFT',           5,    15, 168, NULL,                NULL,                    'Percentage-point rise in PARSE_CONFIDENCE = none vs last week'),
    ('forecast_sanity',      'quality',     'V_CHECK_FORECAST',              8,    15, 168, 'forecast_task',     'forecast_task_failed',  'Days since the last PRICE_FORECAST_RUNS row; series count within 25% of prior'),
    -- cost
    ('warehouse_daily_spike','cost',        'V_CHECK_COST_WAREHOUSE',        3,     6, 48,  'budget',            'cost_spike',            'Credits yesterday divided by max(28-day p90, 0.05): a multiple. Credits themselves are in observed.credits_yesterday'),
    ('service_daily_spike',  'cost',        'V_CHECK_COST_SERVICE',          3,     6, 48,  'budget',            'cost_spike',            'Serverless/AI/Trust Center credits yesterday divided by max(28-day p90, 0.05): a multiple. Credits are in observed.credits_yesterday'),
    ('monthly_projection',   'cost',        'V_CHECK_COST_PROJECTION',      90,   100, 72,  'budget',            'cost_spike',            'Projected month-end credits as a PERCENT of the subject''s own quota (TOTAL 20, GROCERY_COMPUTE_MONITOR 8, GROCERY_AGENT_MONITOR 10, GROCERY_OPS_MONITOR 2). Credits are in observed.*_credits'),
    ('resource_monitor_used','cost',        'V_CHECK_MONITORS',             75,    90, 72,  'budget',            'cost_spike',            'Resource monitor PERCENT of quota used this month; credits in observed.used'),
    ('agent_token_budget',   'cost',        'V_CHECK_AGENT_TOKENS',         80,   100, 72,  'budget',            'cost_spike',            'Ops agents month-to-date tokens as % of MODEL_POLICY monthly budget'),
    -- performance
    ('task_failed_or_missed','performance', 'V_CHECK_TASKS',              NULL,  NULL, 48,  'forecast_task',     'forecast_task_failed',  '1 = a task failed or its expected slot passed without a run (0 = fine)'),
    ('dt_refresh_failed',    'performance', 'V_CHECK_DYNAMIC_TABLES',     NULL,  NULL, 48,  'marts_fresh',       'dt_stale',              '1 = dynamic table refresh failed or scheduling state SUSPENDED (0 = healthy)'),
    ('dt_lag',               'performance', 'V_CHECK_DYNAMIC_TABLES',       36,    72, 48,  'marts_fresh',       'dt_stale',              'Hours since a dynamic table last refreshed successfully'),
    ('agent_wh_queueing',    'performance', 'V_CHECK_AGENT_WAREHOUSE',       0,     1, 168, NULL,                NULL,                    'GROCERY_AGENT_WH average queued load over 7 days (Standard edition: no multi-cluster)'),
    ('agent_latency_p95',    'performance', 'V_CHECK_AGENT_WAREHOUSE',      20,    60, 168, NULL,                NULL,                    'p95 query seconds on GROCERY_AGENT_WH over 7 days'),
    ('search_stale',         'performance', 'V_CHECK_SEARCH',                8,    15, 72,  'marts_fresh',       'search_stale',          'Days since PRODUCT_SEARCH data_timestamp'),
    ('eval_score',           'performance', 'V_CHECK_EVALS',                90,    70, 168, 'agent_quality',     NULL,                    'Latest golden-question pass % (below warn = WARN, below crit = CRIT)'),
    ('feedback_low',         'performance', 'V_CHECK_FEEDBACK',              1,     3, 168, 'agent_quality',     NULL,                    'Shopper feedback ratings < 3 in the last 7 days: count'),
    -- supervisor
    ('component_silent',     'supervisor',  'V_CHECK_SILENCE',            NULL,  NULL, 24,  'ops_silence',       NULL,                    'A registry component with a schedule has no OPS_RUN since 1.5x its expected interval')
) s (CHECK_NAME, DOMAIN, VIEW_NAME, WARN_THRESHOLD, CRIT_THRESHOLD, SUPPRESS_HOURS, SLO_NAME, RUNBOOK_TOPIC, DESCRIPTION)
ON t.CHECK_NAME = s.CHECK_NAME
-- descriptions, view names and runbook links follow the seed; thresholds/enabled stay as edited through SP_SET_CHECK
WHEN MATCHED THEN UPDATE SET DESCRIPTION = s.DESCRIPTION, VIEW_NAME = s.VIEW_NAME, RUNBOOK_TOPIC = s.RUNBOOK_TOPIC, SLO_NAME = s.SLO_NAME
WHEN NOT MATCHED THEN INSERT (CHECK_NAME, DOMAIN, VIEW_NAME, WARN_THRESHOLD, CRIT_THRESHOLD, SUPPRESS_HOURS, SLO_NAME, RUNBOOK_TOPIC, DESCRIPTION)
    VALUES (s.CHECK_NAME, s.DOMAIN, s.VIEW_NAME, s.WARN_THRESHOLD, s.CRIT_THRESHOLD, s.SUPPRESS_HOURS, s.SLO_NAME, s.RUNBOOK_TOPIC, s.DESCRIPTION);

-- Registry: everything already deployed plus the ops components this layer adds.
MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY t
USING (SELECT * FROM VALUES
    ('eventbridge_friday_full',     'schedule','ingestion',  'aws',       'grocery-ingest-friday-full (cron(0 17 ? * FRI *) America/New_York) -> ECS grocery-ingest:2', 'Fridays 17:00 ET', 168, NULL, 'Weekly Kroger seasonal + pricing reset + Walmart pull'),
    ('eventbridge_saturday_continue','schedule','ingestion', 'aws',       'grocery-ingest-saturday-continue (cron(0 9 ? * SAT *) America/New_York)', 'Saturdays 09:00 ET', 168, NULL, 'Finishes the remaining Kroger stores'),
    ('snowpipes',                   'pipe',    'ingestion',  'snowflake', 'AWS_RESOURCES*.*_PIPE (7 auto-ingest pipes)', 'continuous', NULL, NULL, 'S3 -> raw tables'),
    ('dynamic_tables',              'dynamic_tables','performance','snowflake','GROCERY_STAGING / INTERMEDIATE* / MARTS dynamic tables', '24 h lag, self-refreshing', 36, NULL, 'dbt-built transformation chain'),
    ('task_weekly_price_forecast',  'task',    'performance','snowflake', 'GROCERYDBTPROJECT.GROCERY_ML.TASK_WEEKLY_PRICE_FORECAST', 'Sundays 06:00 ET', 168, NULL, 'Forecast, buy signals, product labels, search refill, price watches'),
    ('grocery_value_agent',         'agent',   'product',    'snowflake', 'GROCERYDBTPROJECT.GROCERY_SEMANTIC.GROCERY_VALUE_AGENT', 'on demand', NULL, 'value_agent', 'The shopper-facing Cortex Agent'),
    ('grocery_value_app',           'app',     'product',    'streamlit', 'GROCERYDBTPROJECT.GROCERY_SEMANTIC.GROCERY_VALUE_APP', 'on demand', NULL, NULL, 'Streamlit app: chat, lookup, basket, deals, operations'),
    ('eval_runner',                 'job',     'performance','local',     'Agent/evals/run_evals.py', 'manual, after agent changes', NULL, 'eval_judge', 'Golden-question evaluation; writes its score to GROCERY_APP.AGENT_RUN_LOG'),
    ('ops_task_daily',              'task',    'supervisor', 'snowflake', 'GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_DAILY', 'daily 07:00 ET', 24, NULL, 'Sensors -> quality, cost, performance agents -> supervisor'),
    ('ops_task_friday',             'task',    'ingestion',  'snowflake', 'GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_FRI', 'Fridays 23:30 ET', 168, NULL, 'Ingestion sensors after the Friday job'),
    ('ops_task_saturday',           'task',    'ingestion',  'snowflake', 'GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_SAT', 'Saturdays 16:00 ET', 168, NULL, 'Ingestion sensors after the Saturday job'),
    ('ops_task_weekly',             'task',    'supervisor', 'snowflake', 'GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_WEEKLY', 'Sundays 09:00 ET', 168, NULL, 'Full sensors, all agents, continuous improvement, digest'),
    ('agent_ingestion',             'agent',   'ingestion',  'snowflake', 'SP_RUN_AGENT(ingestion)', 'Fri/Sat/Sun', 72, 'ops_ingestion', 'Did the Friday/Saturday jobs run as planned'),
    ('agent_quality',               'agent',   'quality',    'snowflake', 'SP_RUN_AGENT(quality)', 'daily + Sunday', 24, 'ops_quality', 'Is new data legitimate; outliers'),
    ('agent_cost',                  'agent',   'cost',       'snowflake', 'SP_RUN_AGENT(cost)', 'daily', 24, 'ops_cost', 'Spend vs baseline and budget'),
    ('agent_performance',           'agent',   'performance','snowflake', 'SP_RUN_AGENT(performance)', 'daily', 24, 'ops_performance', 'Failures, lag, latency, eval score'),
    ('agent_improvement',           'agent',   'improvement','snowflake', 'SP_RUN_AGENT(improvement)', 'Sundays', 168, 'ops_improvement', 'Efficiency, new features, cost without losing value'),
    ('agent_supervisor',            'agent',   'supervisor', 'snowflake', 'SP_RUN_AGENT(supervisor)', 'daily + Sunday digest', 24, 'ops_supervisor', 'Did everything run; correlate; escalate; digest'),
    ('aws_liveness_watcher',        'job',     'supervisor', 'aws',       'Lambda grocery-ops-watcher (daily 09:00 ET) -> SNS -> Proton', 'daily 09:00 ET', 24, NULL, 'Independent check that the supervisor ran in the last 26 h')
) s (AGENT_NAME, KIND, DOMAIN, PLATFORM, RUNTIME_OBJECT, SCHEDULE_TEXT, EXPECTED_INTERVAL_HOURS, MODEL_TASK, DESCRIPTION)
ON t.AGENT_NAME = s.AGENT_NAME
WHEN NOT MATCHED THEN INSERT (AGENT_NAME, KIND, DOMAIN, PLATFORM, RUNTIME_OBJECT, SCHEDULE_TEXT, EXPECTED_INTERVAL_HOURS, MODEL_TASK, DESCRIPTION)
    VALUES (s.AGENT_NAME, s.KIND, s.DOMAIN, s.PLATFORM, s.RUNTIME_OBJECT, s.SCHEDULE_TEXT, s.EXPECTED_INTERVAL_HOURS, s.MODEL_TASK, s.DESCRIPTION);

------------------------------------------------------------------------------
-- Audited configuration changes (the Operations page and humans use these;
-- nobody UPDATEs the config tables directly)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_SET_MODEL_POLICY(
    MODEL_TASK VARCHAR, MODEL VARCHAR, REASON VARCHAR, MAX_TOKENS NUMBER DEFAULT NULL, ENABLED BOOLEAN DEFAULT NULL)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Change the model (and optionally token cap / enabled flag) for a task, with an audit row. Takes effect on the next run.'
EXECUTE AS CALLER
AS
$$
DECLARE old_row VARIANT; new_row VARIANT;
BEGIN
    SELECT OBJECT_CONSTRUCT(*) INTO :old_row FROM GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY WHERE MODEL_TASK = :MODEL_TASK;
    IF (old_row IS NULL) THEN RETURN OBJECT_CONSTRUCT('error', 'unknown MODEL_TASK ' || :MODEL_TASK); END IF;
    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY
       SET MODEL = :MODEL, MAX_TOKENS = COALESCE(:MAX_TOKENS, MAX_TOKENS), ENABLED = COALESCE(:ENABLED, ENABLED),
           UPDATED_AT = CURRENT_TIMESTAMP(), UPDATED_BY = CURRENT_USER()
     WHERE MODEL_TASK = :MODEL_TASK;
    SELECT OBJECT_CONSTRUCT(*) INTO :new_row FROM GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY WHERE MODEL_TASK = :MODEL_TASK;
    INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.CONFIG_AUDIT (TABLE_NAME, KEY_VALUE, OLD_ROW, NEW_ROW, REASON)
    SELECT 'MODEL_POLICY', :MODEL_TASK, :old_row, :new_row, :REASON;
    RETURN new_row;
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_SET_CHECK(
    CHECK_NAME VARCHAR, REASON VARCHAR, ENABLED BOOLEAN DEFAULT NULL, WARN_THRESHOLD NUMBER DEFAULT NULL,
    CRIT_THRESHOLD NUMBER DEFAULT NULL, SUPPRESS_HOURS NUMBER DEFAULT NULL)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Enable/disable a check or change its thresholds, with an audit row.'
EXECUTE AS CALLER
AS
$$
DECLARE old_row VARIANT; new_row VARIANT;
BEGIN
    SELECT OBJECT_CONSTRUCT(*) INTO :old_row FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = :CHECK_NAME;
    IF (old_row IS NULL) THEN RETURN OBJECT_CONSTRUCT('error', 'unknown CHECK_NAME ' || :CHECK_NAME); END IF;
    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK
       SET ENABLED = COALESCE(:ENABLED, ENABLED), WARN_THRESHOLD = COALESCE(:WARN_THRESHOLD, WARN_THRESHOLD),
           CRIT_THRESHOLD = COALESCE(:CRIT_THRESHOLD, CRIT_THRESHOLD), SUPPRESS_HOURS = COALESCE(:SUPPRESS_HOURS, SUPPRESS_HOURS),
           UPDATED_AT = CURRENT_TIMESTAMP(), UPDATED_BY = CURRENT_USER()
     WHERE CHECK_NAME = :CHECK_NAME;
    SELECT OBJECT_CONSTRUCT(*) INTO :new_row FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = :CHECK_NAME;
    INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.CONFIG_AUDIT (TABLE_NAME, KEY_VALUE, OLD_ROW, NEW_ROW, REASON)
    SELECT 'OPS_CHECK', :CHECK_NAME, :old_row, :new_row, :REASON;
    RETURN new_row;
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_ACK_EVENT(EVENT_ID VARCHAR, NOTE VARCHAR DEFAULT NULL)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Acknowledge an open finding (it stays visible but stops being escalated).'
EXECUTE AS CALLER
AS
$$
BEGIN
    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT
       SET STATUS = 'acked', ACKED_BY = CURRENT_USER(), ACKED_AT = CURRENT_TIMESTAMP(),
           MESSAGE = IFF(:NOTE IS NULL, MESSAGE, MESSAGE || ' | ack: ' || :NOTE)
     WHERE EVENT_ID = :EVENT_ID AND STATUS = 'open';
    RETURN OBJECT_CONSTRUCT('acked', SQLROWCOUNT);
END;
$$;

-- Registry status: last run per component, from OPS_RUN
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_REGISTRY_STATUS AS
SELECT r.*,
       lr.LAST_RUN_AT, lr.LAST_STATUS,
       IFF(r.ENABLED AND r.EXPECTED_INTERVAL_HOURS IS NOT NULL
           AND COALESCE(lr.LAST_RUN_AT, r.CREATED_AT) < DATEADD(hour, -1.5 * r.EXPECTED_INTERVAL_HOURS, CURRENT_TIMESTAMP()),
           TRUE, FALSE) AS IS_SILENT,
       mp.MODEL, mp.ENABLED AS MODEL_ENABLED
FROM GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY r
LEFT JOIN (
    SELECT AGENT_NAME, MAX(STARTED_AT) AS LAST_RUN_AT,
           MAX_BY(STATUS, STARTED_AT) AS LAST_STATUS
    FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN GROUP BY 1
) lr ON lr.AGENT_NAME = r.AGENT_NAME
LEFT JOIN GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY mp ON mp.MODEL_TASK = r.MODEL_TASK;
