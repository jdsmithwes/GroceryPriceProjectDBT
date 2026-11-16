-- =============================================================================
-- 05_ops_watcher.sql — Snowflake side of the independent AWS heartbeat watcher
-- (Orchestration/ops-watcher/). Run as ACCOUNTADMIN in PROD only (no sandbox
-- copy: the watcher reads one prod view). Deployed 2026-11-15.
--
-- The watcher may read exactly one view, with a dedicated service user whose
-- key pair lives in ~/.snowflake/ops_watcher_rsa_key.{p8,pub} (private key is
-- stored in AWS Secrets Manager `grocery/ops-watcher`; never in the repo).
-- Replace <PUBLIC_KEY> with the body of ops_watcher_rsa_key.pub (no BEGIN/END
-- lines) before running; the deploy step does this with sed into a temp copy.
-- =============================================================================
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_WATCHER_HEARTBEAT
    COMMENT = 'Heartbeat read by the AWS Lambda grocery-ops-watcher: hours since the ops supervisor last ran'
AS
SELECT ROUND(TIMESTAMPDIFF(minute, MAX(STARTED_AT), CURRENT_TIMESTAMP()) / 60.0, 1) AS HOURS_SINCE_SUPERVISOR,
       TO_VARCHAR(MAX(STARTED_AT), 'YYYY-MM-DD HH24:MI TZH:TZM')               AS LAST_SUPERVISOR_RUN,
       MAX_BY(STATUS, STARTED_AT)                                                 AS LAST_STATUS
FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN
WHERE KIND = 'agent' AND AGENT_NAME = 'agent_supervisor';

CREATE ROLE IF NOT EXISTS GROCERY_OPS_WATCHER COMMENT = 'AWS heartbeat watcher: SELECT on V_WATCHER_HEARTBEAT only';
GRANT ROLE GROCERY_OPS_WATCHER TO ROLE SYSADMIN;
GRANT USAGE ON DATABASE GROCERYDBTPROJECT TO ROLE GROCERY_OPS_WATCHER;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_OPS TO ROLE GROCERY_OPS_WATCHER;
GRANT SELECT ON VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_WATCHER_HEARTBEAT TO ROLE GROCERY_OPS_WATCHER;
GRANT USAGE ON WAREHOUSE GROCERY_OPS_WH TO ROLE GROCERY_OPS_WATCHER;

CREATE USER IF NOT EXISTS SVC_OPS_WATCHER
    TYPE = SERVICE
    DEFAULT_ROLE = GROCERY_OPS_WATCHER
    DEFAULT_WAREHOUSE = GROCERY_OPS_WH
    COMMENT = 'Service user for the AWS Lambda grocery-ops-watcher (key-pair auth only)';
ALTER USER SVC_OPS_WATCHER SET RSA_PUBLIC_KEY = '<PUBLIC_KEY>';
GRANT ROLE GROCERY_OPS_WATCHER TO USER SVC_OPS_WATCHER;

-- registry row (seeded by 01_ops_schema.sql as aws_liveness_watcher): record the deployed objects.
-- EXPECTED_INTERVAL_HOURS is NULL on purpose: the watcher is read-only and reports through SNS, never into OPS_RUN.
UPDATE GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY
   SET RUNTIME_OBJECT = 'aws lambda grocery-ops-watcher (us-east-1), schedule grocery-ops-watcher, SNS grocery-ops-alerts -> Proton; reads V_WATCHER_HEARTBEAT as SVC_OPS_WATCHER',
       EXPECTED_INTERVAL_HOURS = NULL,
       DESCRIPTION = 'Independent liveness check from AWS (deployed 2026-11-15): emails Proton via SNS if no supervisor run in 26 h or Snowflake is unreachable. Read-only; it reports via SNS, never into OPS_RUN, so it is never silent here.',
       UPDATED_AT = CURRENT_TIMESTAMP()
 WHERE AGENT_NAME = 'aws_liveness_watcher';

SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_WATCHER_HEARTBEAT;
