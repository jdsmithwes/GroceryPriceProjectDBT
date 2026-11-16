-- =============================================================================
-- 06_control_plane.sql — the ops control plane as native Snowflake surfaces
-- (replaces the Streamlit "Operations" tab, removed 2026-11-15).
--
--   1. SV_OPS            semantic view over the GROCERY_OPS tables: ask "did every
--                        agent run", "what is open", "credits vs budget" in plain
--                        English through Cortex Analyst / Snowflake Intelligence.
--   2. GROCERY_OPS_AGENT Cortex Agent object: reads SV_OPS and the runbook, and
--                        can change a model policy, a check or acknowledge a finding
--                        ONLY when the human asks (human-initiated writes stay
--                        inside the notify-only rule; the scheduled agents never
--                        get these tools).
--   3. SP_SYNC_AGENT_OBJECTS  mirrors the six AGENT_REGISTRY rows as Cortex Agent
--                        objects (AGENT_INGESTION … AGENT_SUPERVISOR) so the
--                        Snowsight "AI & ML › Agents" page is the agent inventory
--                        and each agent can be test-driven in its chat. The registry
--                        row stays the source of truth: SP_RUN_AGENT reads the
--                        registry; this procedure re-creates the mirrors. Run it
--                        after any instruction or model-policy change (deploy
--                        time, by a human; never from a task).
--   Dashboard tiles (Snowsight has no DDL for dashboards): Agent/ops/dashboard_tiles.sql
--
-- Run as GROCERY_OPS_ROLE (owner of GROCERY_OPS) in prod; ACCOUNTADMIN also works.
-- Sandbox variant (writes GROCERY_DEV_OPS, uses COMPUTE_WH):
--   sed -E 's/GROCERY_OPS([^_A-Za-z0-9]|$)/GROCERY_DEV_OPS\1/g; s/GROCERY_OPS_WH/COMPUTE_WH/g; /^-- PROD ONLY/,$d'
-- =============================================================================
USE DATABASE GROCERYDBTPROJECT;
USE SCHEMA GROCERY_OPS;

------------------------------------------------------------------------------
-- 1. Semantic view
------------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW GROCERYDBTPROJECT.GROCERY_OPS.SV_OPS
  TABLES (
    COMPONENTS AS GROCERYDBTPROJECT.GROCERY_OPS.V_REGISTRY_STATUS
      PRIMARY KEY (AGENT_NAME)
      WITH SYNONYMS ('registry', 'deployed agents', 'inventory', 'agents', 'components', 'control plane')
      COMMENT = 'Every deployed component the ops layer watches (agents, tasks, schedules, pipes, apps, watcher) with its last run, status, model and whether it is silent',
    RUNS AS GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN
      PRIMARY KEY (RUN_ID)
      WITH SYNONYMS ('ops runs', 'agent runs', 'sensor runs', 'executions')
      COMMENT = 'One row per sensor pass, agent run, task or alert execution: status, duration, model, tokens, credits, email sent',
    FINDINGS AS GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT
      PRIMARY KEY (EVENT_ID)
      WITH SYNONYMS ('events', 'alerts', 'issues', 'incidents', 'ops events')
      COMMENT = 'Every finding a sensor or agent raised; STATUS open until the condition clears (resolved) or a human acknowledges it',
    CHECKS AS GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK
      PRIMARY KEY (CHECK_NAME)
      WITH SYNONYMS ('sensors', 'checks', 'monitors', 'rules')
      COMMENT = 'The deterministic SQL sensors: domain, thresholds, suppression, the SLO and runbook topic they map to',
    POLICIES AS GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY
      PRIMARY KEY (MODEL_TASK)
      WITH SYNONYMS ('model policy', 'models', 'model assignment', 'which model')
      COMMENT = 'Which LLM does which task, with token caps and monthly token budgets',
    DAILY_METRICS AS GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY
      PRIMARY KEY (METRIC_DATE, METRIC_NAME, DIMENSION)
      WITH SYNONYMS ('metrics', 'baselines', 'daily metrics', 'credits history', 'history')
      COMMENT = 'Daily metric values the sensors recorded (credits per warehouse/service, rows, stores, lag, scores) per dimension',
    SLOS AS GROCERYDBTPROJECT.GROCERY_OPS.SLO
      PRIMARY KEY (SLO_NAME)
      WITH SYNONYMS ('service levels', 'objectives', 'targets')
      COMMENT = 'Service-level objectives the checks justify their thresholds with'
  )
  RELATIONSHIPS (
    RUNS_TO_COMPONENTS      AS RUNS (AGENT_NAME)   REFERENCES COMPONENTS,
    FINDINGS_TO_RUNS        AS FINDINGS (RUN_ID)   REFERENCES RUNS,
    FINDINGS_TO_CHECKS      AS FINDINGS (CHECK_NAME) REFERENCES CHECKS,
    COMPONENTS_TO_POLICIES  AS COMPONENTS (MODEL_TASK) REFERENCES POLICIES,
    CHECKS_TO_SLOS          AS CHECKS (SLO_NAME)   REFERENCES SLOS
  )
  FACTS (
    RUNS.RUN_SECONDS      AS TIMESTAMPDIFF(second, STARTED_AT, ENDED_AT) COMMENT = 'Wall-clock seconds of the run',
    RUNS.INPUT_TOKENS     AS INPUT_TOKENS  COMMENT = 'LLM input tokens (agent runs only)',
    RUNS.OUTPUT_TOKENS    AS OUTPUT_TOKENS COMMENT = 'LLM output tokens (agent runs only)',
    RUNS.TOKEN_CREDITS    AS TOKEN_CREDITS COMMENT = 'Snowflake credits the LLM tokens cost',
    RUNS.EVENTS_NEW       AS EVENTS_NEW    COMMENT = 'Findings newly raised by this run',
    RUNS.CHECKS_RUN       AS CHECKS_RUN    COMMENT = 'Sensor checks evaluated in this run',
    RUNS.IS_FAILED        AS IFF(STATUS = 'failed', 1, 0)  COMMENT = '1 when the run failed',
    RUNS.IS_SKIPPED       AS IFF(STATUS = 'skipped', 1, 0) COMMENT = '1 when the run was skipped (nothing to analyse or budget exhausted)',
    RUNS.EMAIL_FLAG       AS IFF(EMAIL_SENT, 1, 0)         COMMENT = '1 when this run emailed the owner',
    FINDINGS.IS_OPEN      AS IFF(STATUS = 'open', 1, 0)    COMMENT = '1 when the finding is still open',
    FINDINGS.IS_CRIT      AS IFF(SEVERITY = 'CRIT', 1, 0)  COMMENT = '1 when severity is CRIT',
    FINDINGS.IS_WARN      AS IFF(SEVERITY = 'WARN', 1, 0)  COMMENT = '1 when severity is WARN',
    FINDINGS.HOURS_OPEN   AS TIMESTAMPDIFF(hour, FIRST_SEEN_AT, COALESCE(RESOLVED_AT, CURRENT_TIMESTAMP())) COMMENT = 'Hours between first seen and resolution (or now)',
    COMPONENTS.SILENT_FLAG AS IFF(IS_SILENT, 1, 0)          COMMENT = '1 when the component has not run within 1.5x its expected interval',
    COMPONENTS.ENABLED_FLAG AS IFF(ENABLED, 1, 0)           COMMENT = '1 when enabled',
    DAILY_METRICS.VALUE   AS VALUE COMMENT = 'The metric value for that day and dimension; unit depends on METRIC_NAME (credits, rows, stores, hours, percent, or 1/0 for boolean checks where 1 = condition true)'
  )
  DIMENSIONS (
    COMPONENTS.AGENT_NAME     AS AGENT_NAME     WITH SYNONYMS ('component', 'component name', 'agent') COMMENT = 'Registry key, e.g. agent_supervisor, task_weekly_price_forecast, snowpipes',
    COMPONENTS.KIND           AS KIND           COMMENT = 'agent | task | schedule | pipe | dynamic_tables | app | job | watcher',
    COMPONENTS.DOMAIN         AS DOMAIN         COMMENT = 'ingestion | quality | cost | performance | improvement | supervisor | product',
    COMPONENTS.PLATFORM       AS PLATFORM       COMMENT = 'snowflake | aws | streamlit | local',
    COMPONENTS.RUNTIME_OBJECT AS RUNTIME_OBJECT COMMENT = 'The concrete object or command that runs it',
    COMPONENTS.SCHEDULE_TEXT  AS SCHEDULE_TEXT  WITH SYNONYMS ('schedule', 'when it runs'),
    COMPONENTS.EXPECTED_INTERVAL_HOURS AS EXPECTED_INTERVAL_HOURS COMMENT = 'Hours between expected runs; NULL = on demand or reports elsewhere',
    COMPONENTS.MODEL_TASK     AS MODEL_TASK     COMMENT = 'Key into the model policy',
    COMPONENTS.MODEL          AS MODEL          WITH SYNONYMS ('llm', 'which model') COMMENT = 'Model currently assigned through the policy',
    COMPONENTS.PROMPT_VERSION AS PROMPT_VERSION,
    COMPONENTS.ENABLED        AS ENABLED,
    COMPONENTS.LAST_RUN_AT    AS LAST_RUN_AT    WITH SYNONYMS ('last run', 'last ran'),
    COMPONENTS.LAST_STATUS    AS LAST_STATUS,
    COMPONENTS.IS_SILENT      AS IS_SILENT      WITH SYNONYMS ('silent', 'overdue', 'missed') COMMENT = 'TRUE when no run within 1.5x the expected interval — silence is a finding',
    COMPONENTS.DESCRIPTION    AS DESCRIPTION,
    RUNS.RUN_ID        AS RUN_ID,
    RUNS.RUN_KIND      AS KIND        COMMENT = 'sensor | agent | task | alert | selftest | autofix',
    RUNS.RUN_DOMAIN    AS DOMAIN,
    RUNS.STARTED_AT    AS STARTED_AT  WITH SYNONYMS ('run time', 'when'),
    RUNS.RUN_DATE      AS STARTED_AT::DATE WITH SYNONYMS ('day', 'date'),
    RUNS.ENDED_AT      AS ENDED_AT,
    RUNS.STATUS        AS STATUS      COMMENT = 'success | failed | skipped',
    RUNS.MAX_SEVERITY  AS MAX_SEVERITY COMMENT = 'Highest severity among the findings the run saw: OK | INFO | WARN | CRIT',
    RUNS.MODEL         AS MODEL       COMMENT = 'LLM used (agent runs)',
    RUNS.PROMPT_VERSION AS PROMPT_VERSION,
    RUNS.EMAIL_SENT    AS EMAIL_SENT,
    RUNS.RESPONSE      AS RESPONSE    WITH SYNONYMS ('agent report', 'what the agent said', 'diagnosis') COMMENT = 'Full agent response text',
    RUNS.ERROR         AS ERROR,
    FINDINGS.EVENT_ID      AS EVENT_ID,
    FINDINGS.DETECTED_AT   AS DETECTED_AT,
    FINDINGS.DETECTED_DATE AS DETECTED_AT::DATE,
    FINDINGS.FINDING_DOMAIN AS DOMAIN,
    FINDINGS.CHECK_NAME    AS CHECK_NAME WITH SYNONYMS ('sensor', 'check'),
    FINDINGS.SEVERITY      AS SEVERITY   COMMENT = 'CRIT | WARN | INFO',
    FINDINGS.SUBJECT       AS SUBJECT    COMMENT = 'What the finding is about (a warehouse, a store, a run slot, a table)',
    FINDINGS.MESSAGE       AS MESSAGE,
    FINDINGS.SOURCE        AS SOURCE     COMMENT = 'sensor | agent | autofix | supervisor',
    FINDINGS.STATUS        AS STATUS     COMMENT = 'open | resolved | acked',
    FINDINGS.FIRST_SEEN_AT AS FIRST_SEEN_AT,
    FINDINGS.LAST_SEEN_AT  AS LAST_SEEN_AT,
    FINDINGS.RESOLVED_AT   AS RESOLVED_AT,
    FINDINGS.ACKED_BY      AS ACKED_BY,
    FINDINGS.ACKED_AT      AS ACKED_AT,
    FINDINGS.EMAILED_AT    AS EMAILED_AT,
    CHECKS.CHECK_NAME     AS CHECK_NAME,
    CHECKS.CHECK_DOMAIN   AS DOMAIN,
    CHECKS.VIEW_NAME      AS VIEW_NAME,
    CHECKS.CHECK_ENABLED  AS ENABLED,
    CHECKS.WARN_THRESHOLD AS WARN_THRESHOLD,
    CHECKS.CRIT_THRESHOLD AS CRIT_THRESHOLD,
    CHECKS.SUPPRESS_HOURS AS SUPPRESS_HOURS,
    CHECKS.SLO_NAME       AS SLO_NAME,
    CHECKS.RUNBOOK_TOPIC  AS RUNBOOK_TOPIC,
    CHECKS.CHECK_DESCRIPTION AS DESCRIPTION COMMENT = 'What the metric means and its unit',
    POLICIES.MODEL_TASK        AS MODEL_TASK,
    POLICIES.POLICY_MODEL      AS MODEL,
    POLICIES.FALLBACK_MODEL    AS FALLBACK_MODEL,
    POLICIES.MAX_TOKENS        AS MAX_TOKENS,
    POLICIES.BUDGET_SECONDS    AS BUDGET_SECONDS,
    POLICIES.MONTHLY_TOKEN_BUDGET AS MONTHLY_TOKEN_BUDGET,
    POLICIES.POLICY_ENABLED    AS ENABLED,
    POLICIES.RATIONALE         AS RATIONALE,
    POLICIES.UPDATED_AT        AS UPDATED_AT,
    DAILY_METRICS.METRIC_DATE  AS METRIC_DATE WITH SYNONYMS ('day', 'date'),
    DAILY_METRICS.METRIC_DOMAIN AS DOMAIN,
    DAILY_METRICS.METRIC_NAME  AS METRIC_NAME COMMENT = 'e.g. credits_warehouse, credits_service, cost_projection, stores_priced, run_missing',
    DAILY_METRICS.DIMENSION    AS DIMENSION   COMMENT = 'The subject the value is for (warehouse name, service, retailer, TOTAL, ...)',
    SLOS.SLO_NAME     AS SLO_NAME,
    SLOS.SLO_DESCRIPTION AS DESCRIPTION,
    SLOS.TARGET       AS TARGET,
    SLOS.WINDOW_DAYS  AS WINDOW_DAYS
  )
  METRICS (
    COMPONENTS.COMPONENT_COUNT AS COUNT(AGENT_NAME) COMMENT = 'Number of registered components',
    COMPONENTS.SILENT_COUNT    AS SUM(SILENT_FLAG)  COMMENT = 'Components that have not run within 1.5x their expected interval',
    RUNS.RUN_COUNT          AS COUNT(RUN_ID),
    RUNS.FAILED_RUNS        AS SUM(IS_FAILED),
    RUNS.SKIPPED_RUNS       AS SUM(IS_SKIPPED),
    RUNS.EMAILS_SENT        AS SUM(EMAIL_FLAG),
    RUNS.TOTAL_INPUT_TOKENS AS SUM(INPUT_TOKENS),
    RUNS.TOTAL_OUTPUT_TOKENS AS SUM(OUTPUT_TOKENS),
    RUNS.TOTAL_TOKEN_CREDITS AS SUM(TOKEN_CREDITS) COMMENT = 'Credits the agents own LLM calls cost',
    RUNS.AVG_RUN_SECONDS    AS AVG(RUN_SECONDS),
    RUNS.MAX_RUN_SECONDS    AS MAX(RUN_SECONDS),
    RUNS.LAST_RUN_TIME      AS MAX(STARTED_AT),
    FINDINGS.FINDING_COUNT  AS COUNT(EVENT_ID),
    FINDINGS.OPEN_FINDINGS  AS SUM(IS_OPEN),
    FINDINGS.CRIT_FINDINGS  AS SUM(IS_CRIT),
    FINDINGS.WARN_FINDINGS  AS SUM(IS_WARN),
    FINDINGS.AVG_HOURS_OPEN AS AVG(HOURS_OPEN) COMMENT = 'Mean time to resolve, in hours',
    DAILY_METRICS.METRIC_SUM AS SUM(VALUE),
    DAILY_METRICS.METRIC_AVG AS AVG(VALUE),
    DAILY_METRICS.METRIC_MAX AS MAX(VALUE),
    DAILY_METRICS.METRIC_LATEST AS MAX_BY(VALUE, METRIC_DATE) COMMENT = 'Most recent value'
  )
  COMMENT = 'Ops control plane for the grocery price product: components, runs, findings, checks, model policy, daily metrics, SLOs. Budget is 20 credits/month (COMPUTE 8, agent+ML 10, ops 2). Sensors decide severity; agents explain; humans act.'
;

------------------------------------------------------------------------------
-- 2. Interactive control-plane agent (Snowflake Intelligence / Snowsight Agents)
------------------------------------------------------------------------------
CREATE OR REPLACE AGENT GROCERYDBTPROJECT.GROCERY_OPS.GROCERY_OPS_AGENT
COMMENT = 'Control-plane assistant for the grocery price product operations layer: what ran, what is open, what it costs, which model does what. Writes (model policy, check thresholds, acknowledgements) only on an explicit human request.'
PROFILE = '{"display_name": "Grocery Ops Control Plane", "color": "orange"}'
FROM SPECIFICATION $$
{
  "models": { "orchestration": "claude-sonnet-5-5" },
  "orchestration": { "budget": { "seconds": 90, "tokens": 60000 } },
  "instructions": {
    "response": "You are the control plane for the grocery price product's operations layer. Owner: one data engineer. Budget: 20 Snowflake credits per month (COMPUTE 8, agent+ML 10, ops 2). Design rule: deterministic SQL sensors decide whether something is wrong and how severe; agents explain; humans act. Use ops_analyst for anything about components, runs, findings, checks, model policy, daily metrics or SLOs. Prefer short tables; always include EVENT_ID for findings and RUN_ID for runs so they can be acted on. Severity words: CRIT = SLO breached or data loss possible, WARN = budget burning, INFO. Boolean check metrics store 1 = condition true (bad). When asked 'did everything run', list every enabled component with an expected interval and whether it is silent. For 'why' questions, use get_runbook and the agent RESPONSE text from the latest run. Writes: call set_model_policy, set_check or acknowledge_finding ONLY when the user explicitly asks for that change in this conversation, restate exactly what you are about to change, require a reason, and report the audit result. Never suggest running CREATE OR REPLACE, resizing warehouses, changing monitors or re-running AWS jobs; those are human-only actions and the runbook names them.",
    "orchestration": "For questions about state or history use ops_analyst first. Use get_metric_history for a trend of one metric, get_recent_runs for ingestion job runs, get_runbook for known failure modes. Use a write tool only after the user has clearly asked for the change and given a reason.",
    "sample_questions": [
      { "question": "Did every agent and task run when it should have this week?" },
      { "question": "What findings are open right now, by severity?" },
      { "question": "How many credits has November used, and what is each monitor group projecting?" },
      { "question": "Which model does each agent use and how many tokens did they spend this month?" },
      { "question": "What did the supervisor say in its last run?" },
      { "question": "Switch the cost agent to claude-haiku-5-5 because its findings are arithmetic." }
    ]
  },
  "tools": [
    { "tool_spec": { "type": "cortex_analyst_text_to_sql", "name": "ops_analyst",
        "description": "Ops control plane: components (deployed agents, tasks, schedules, pipes, apps) with last run and silence, ops runs with model/tokens/credits, findings with severity and status, sensor checks and thresholds, model policy, daily metrics (credits, rows, stores), SLOs." } },
    { "tool_spec": { "type": "generic", "name": "get_runbook",
        "description": "Known failure modes with symptom, cause, fix and whether an automated action exists. Optional TOPIC.",
        "input_schema": { "type": "object", "properties": { "TOPIC": { "type": "string" } } } } },
    { "tool_spec": { "type": "generic", "name": "get_metric_history",
        "description": "Daily values of one metric (a check name or a credits metric) per dimension over the last DAYS days.",
        "input_schema": { "type": "object", "properties": { "METRIC_NAME": { "type": "string" }, "DAYS": { "type": "number" } }, "required": ["METRIC_NAME"] } } },
    { "tool_spec": { "type": "generic", "name": "get_recent_runs",
        "description": "Ingestion job runs (Kroger/Walmart Friday and Saturday jobs) over the last WEEKS weeks.",
        "input_schema": { "type": "object", "properties": { "WEEKS": { "type": "number" } } } } },
    { "tool_spec": { "type": "generic", "name": "set_model_policy",
        "description": "HUMAN-REQUESTED WRITE. Change which model a task uses (optionally its token cap or enabled flag). Audited. Takes effect on the next run.",
        "input_schema": { "type": "object", "properties": {
            "MODEL_TASK": { "type": "string", "description": "e.g. ops_cost, ops_supervisor, ops_digest, value_agent" },
            "MODEL": { "type": "string", "description": "claude-haiku-5-5 | claude-sonnet-5-5 | claude-opus-5-5 | llama3.1-70b | llama3.1-8b" },
            "REASON": { "type": "string", "description": "Required; goes to CONFIG_AUDIT" },
            "MAX_TOKENS": { "type": "number" }, "ENABLED": { "type": "boolean" } },
          "required": ["MODEL_TASK", "MODEL", "REASON"] } } },
    { "tool_spec": { "type": "generic", "name": "set_check",
        "description": "HUMAN-REQUESTED WRITE. Enable/disable a sensor check or change its warn/crit thresholds or suppression hours. Audited.",
        "input_schema": { "type": "object", "properties": {
            "CHECK_NAME": { "type": "string" }, "REASON": { "type": "string" },
            "ENABLED": { "type": "boolean" }, "WARN_THRESHOLD": { "type": "number" },
            "CRIT_THRESHOLD": { "type": "number" }, "SUPPRESS_HOURS": { "type": "number" } },
          "required": ["CHECK_NAME", "REASON"] } } },
    { "tool_spec": { "type": "generic", "name": "acknowledge_finding",
        "description": "HUMAN-REQUESTED WRITE. Acknowledge one open finding by EVENT_ID with an optional note.",
        "input_schema": { "type": "object", "properties": { "EVENT_ID": { "type": "string" }, "NOTE": { "type": "string" } }, "required": ["EVENT_ID"] } } }
  ],
  "tool_resources": {
    "ops_analyst":         { "semantic_view": "GROCERYDBTPROJECT.GROCERY_OPS.SV_OPS", "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_OPS_WH", "query_timeout": 60 } },
    "get_runbook":         { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_RUNBOOK",        "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_OPS_WH", "query_timeout": 30 } },
    "get_metric_history":  { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_METRIC_HISTORY", "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_OPS_WH", "query_timeout": 30 } },
    "get_recent_runs":     { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_RECENT_RUNS",    "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_OPS_WH", "query_timeout": 30 } },
    "set_model_policy":    { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_OPS.SP_SET_MODEL_POLICY",     "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_OPS_WH", "query_timeout": 30 } },
    "set_check":           { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_OPS.SP_SET_CHECK",            "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_OPS_WH", "query_timeout": 30 } },
    "acknowledge_finding": { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_OPS.SP_ACK_EVENT",            "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_OPS_WH", "query_timeout": 30 } }
  }
}
$$;

------------------------------------------------------------------------------
-- 3. Mirror the six scheduled agents as Cortex Agent objects (inventory + test chat)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_SYNC_AGENT_OBJECTS()
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Re-creates GROCERY_OPS.AGENT_<DOMAIN> Cortex Agent objects from the AGENT_REGISTRY rows (instructions, tools) and MODEL_POLICY (model, budget) so the Snowsight Agents page lists them and each can be test-driven. The registry stays the source of truth; SP_RUN_AGENT reads the registry. Run by a human after an instruction or policy change; never from a task.'
EXECUTE AS OWNER
AS
$$
DECLARE
    synced ARRAY := ARRAY_CONSTRUCT();
    spec   VARCHAR; ddl VARCHAR; obj VARCHAR;
    c CURSOR FOR
        SELECT r.AGENT_NAME, r.DOMAIN, r.DESCRIPTION, r.INSTRUCTIONS, r.TOOLS, r.PROMPT_VERSION, r.SCHEDULE_TEXT,
               p.MODEL, p.MAX_TOKENS, p.BUDGET_SECONDS
        FROM GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY r
        JOIN GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY p ON p.MODEL_TASK = r.MODEL_TASK
        WHERE r.KIND = 'agent' AND r.AGENT_NAME LIKE 'agent_%' AND r.INSTRUCTIONS IS NOT NULL
        ORDER BY r.AGENT_NAME;
BEGIN
    FOR rec IN c DO
        obj := 'GROCERYDBTPROJECT.GROCERY_OPS.' || UPPER(rec.AGENT_NAME);
        spec := TO_JSON(OBJECT_CONSTRUCT(
            'models', OBJECT_CONSTRUCT('orchestration', rec.MODEL),
            'orchestration', OBJECT_CONSTRUCT('budget', OBJECT_CONSTRUCT('seconds', rec.BUDGET_SECONDS, 'tokens', rec.MAX_TOKENS)),
            'instructions', OBJECT_CONSTRUCT(
                'response', rec.INSTRUCTIONS,
                'orchestration', 'Interactive mirror of the scheduled ' || rec.DOMAIN || ' agent. In chat you receive no sensor JSON automatically: call get_metric_history and get_recent_runs to fetch evidence, get_runbook for known fixes. You cannot change anything; recommend and cite.',
                'sample_questions', ARRAY_CONSTRUCT(
                    OBJECT_CONSTRUCT('question', 'What would you report today for the ' || rec.DOMAIN || ' domain?'),
                    OBJECT_CONSTRUCT('question', 'Which runbook entries apply to this domain?'))),
            'tools', ARRAY_CONSTRUCT(
                OBJECT_CONSTRUCT('tool_spec', OBJECT_CONSTRUCT('type', 'generic', 'name', 'get_runbook', 'description', 'Known failure modes with symptom, cause, fix and whether an automated action exists. Optional TOPIC.',
                    'input_schema', OBJECT_CONSTRUCT('type', 'object', 'properties', OBJECT_CONSTRUCT('TOPIC', OBJECT_CONSTRUCT('type', 'string'))))),
                OBJECT_CONSTRUCT('tool_spec', OBJECT_CONSTRUCT('type', 'generic', 'name', 'get_metric_history', 'description', 'Daily values of one metric (a check name, or credits metrics) per dimension over the last DAYS days.',
                    'input_schema', OBJECT_CONSTRUCT('type', 'object', 'properties', OBJECT_CONSTRUCT('METRIC_NAME', OBJECT_CONSTRUCT('type', 'string'), 'DAYS', OBJECT_CONSTRUCT('type', 'number')), 'required', ARRAY_CONSTRUCT('METRIC_NAME')))),
                OBJECT_CONSTRUCT('tool_spec', OBJECT_CONSTRUCT('type', 'generic', 'name', 'get_recent_runs', 'description', 'Ingestion job runs over the last WEEKS weeks.',
                    'input_schema', OBJECT_CONSTRUCT('type', 'object', 'properties', OBJECT_CONSTRUCT('WEEKS', OBJECT_CONSTRUCT('type', 'number')))))),
            'tool_resources', OBJECT_CONSTRUCT(
                'get_runbook',        OBJECT_CONSTRUCT('type', 'procedure', 'identifier', 'GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_RUNBOOK',        'execution_environment', OBJECT_CONSTRUCT('type', 'warehouse', 'warehouse', 'GROCERY_OPS_WH', 'query_timeout', 30)),
                'get_metric_history', OBJECT_CONSTRUCT('type', 'procedure', 'identifier', 'GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_METRIC_HISTORY', 'execution_environment', OBJECT_CONSTRUCT('type', 'warehouse', 'warehouse', 'GROCERY_OPS_WH', 'query_timeout', 30)),
                'get_recent_runs',    OBJECT_CONSTRUCT('type', 'procedure', 'identifier', 'GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_RECENT_RUNS',    'execution_environment', OBJECT_CONSTRUCT('type', 'warehouse', 'warehouse', 'GROCERY_OPS_WH', 'query_timeout', 30)))
        ));
        ddl := 'CREATE OR REPLACE AGENT ' || obj
            || ' COMMENT = ' || '''' || REPLACE('Mirror of AGENT_REGISTRY.' || rec.AGENT_NAME || ' (prompt ' || COALESCE(rec.PROMPT_VERSION, 'v?') || ', model ' || rec.MODEL || ', runs ' || COALESCE(rec.SCHEDULE_TEXT, 'on demand') || ' via SP_RUN_AGENT). ' || COALESCE(rec.DESCRIPTION, ''), '''', '''''') || ''''
            || ' PROFILE = ' || '''' || TO_JSON(OBJECT_CONSTRUCT('display_name', 'Ops: ' || INITCAP(rec.DOMAIN) || ' agent', 'color', 'orange')) || ''''
            || ' FROM SPECIFICATION $' || '$' || spec || '$' || '$';
        EXECUTE IMMEDIATE :ddl;
        synced := ARRAY_APPEND(synced, OBJECT_CONSTRUCT('agent', obj, 'model', rec.MODEL, 'prompt_version', rec.PROMPT_VERSION));
    END FOR;
    RETURN OBJECT_CONSTRUCT('synced', synced, 'count', ARRAY_SIZE(synced));
END;
$$;

CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_SYNC_AGENT_OBJECTS();

-- registry rows for the two new control-plane surfaces
MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY t
USING (SELECT * FROM VALUES
    ('grocery_ops_agent', 'agent', 'supervisor', 'snowflake', 'GROCERYDBTPROJECT.GROCERY_OPS.GROCERY_OPS_AGENT (Snowflake Intelligence / Snowsight Agents)', 'on demand', NULL, 'ops_control_plane', 'Interactive control-plane agent over SV_OPS; human-requested writes to model policy, checks and acknowledgements'),
    ('sv_ops',            'semantic_view', 'supervisor', 'snowflake', 'GROCERYDBTPROJECT.GROCERY_OPS.SV_OPS', 'n/a', NULL, NULL, 'Ops semantic view: components, runs, findings, checks, policy, metrics, SLOs')
) s (AGENT_NAME, KIND, DOMAIN, PLATFORM, RUNTIME_OBJECT, SCHEDULE_TEXT, EXPECTED_INTERVAL_HOURS, MODEL_TASK, DESCRIPTION)
ON t.AGENT_NAME = s.AGENT_NAME
WHEN MATCHED THEN UPDATE SET RUNTIME_OBJECT = s.RUNTIME_OBJECT, DESCRIPTION = s.DESCRIPTION, UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (AGENT_NAME, KIND, DOMAIN, PLATFORM, RUNTIME_OBJECT, SCHEDULE_TEXT, EXPECTED_INTERVAL_HOURS, MODEL_TASK, DESCRIPTION)
    VALUES (s.AGENT_NAME, s.KIND, s.DOMAIN, s.PLATFORM, s.RUNTIME_OBJECT, s.SCHEDULE_TEXT, s.EXPECTED_INTERVAL_HOURS, s.MODEL_TASK, s.DESCRIPTION);

MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY t
USING (SELECT 'ops_control_plane' AS MODEL_TASK, 'claude-sonnet-5-5' AS MODEL, 'claude-haiku-5-5' AS FALLBACK_MODEL, 60000 AS MAX_TOKENS, 90 AS BUDGET_SECONDS, 2000000 AS MONTHLY_TOKEN_BUDGET, TRUE AS ENABLED,
              'Interactive control-plane questions need SQL generation over 7 tables and careful write confirmation; Sonnet. Change the agent object spec to switch (the object holds the model).' AS RATIONALE) s
ON t.MODEL_TASK = s.MODEL_TASK
WHEN NOT MATCHED THEN INSERT (MODEL_TASK, MODEL, FALLBACK_MODEL, MAX_TOKENS, BUDGET_SECONDS, MONTHLY_TOKEN_BUDGET, ENABLED, RATIONALE)
    VALUES (s.MODEL_TASK, s.MODEL, s.FALLBACK_MODEL, s.MAX_TOKENS, s.BUDGET_SECONDS, s.MONTHLY_TOKEN_BUDGET, s.ENABLED, s.RATIONALE);

-- smoke tests
SELECT * FROM SEMANTIC_VIEW(GROCERYDBTPROJECT.GROCERY_OPS.SV_OPS DIMENSIONS COMPONENTS.AGENT_NAME, COMPONENTS.KIND, COMPONENTS.IS_SILENT, COMPONENTS.LAST_STATUS METRICS RUNS.RUN_COUNT) ORDER BY 1;
SELECT * FROM SEMANTIC_VIEW(GROCERYDBTPROJECT.GROCERY_OPS.SV_OPS DIMENSIONS FINDINGS.SEVERITY METRICS FINDINGS.FINDING_COUNT, FINDINGS.OPEN_FINDINGS) ORDER BY 1;
SHOW AGENTS IN SCHEMA GROCERYDBTPROJECT.GROCERY_OPS;

-- PROD ONLY ------------------------------------------------------------------
-- Let the owner's role use the control plane interactively (ACCOUNTADMIN already can).
GRANT SELECT ON SEMANTIC VIEW GROCERYDBTPROJECT.GROCERY_OPS.SV_OPS TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON AGENT GROCERYDBTPROJECT.GROCERY_OPS.GROCERY_OPS_AGENT TO ROLE GROCERY_OPS_ROLE;
-- Make the agent appear in Snowflake Intelligence (now "Snowflake CoWork"). Agents are never added
-- automatically; the legacy SNOWFLAKE_INTELLIGENCE.AGENTS schema is deprecated for visibility. Done 2026-11-15.
ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT ADD AGENT GROCERYDBTPROJECT.GROCERY_OPS.GROCERY_OPS_AGENT;
