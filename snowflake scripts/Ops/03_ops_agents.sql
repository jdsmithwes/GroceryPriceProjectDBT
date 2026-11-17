-- Grocery ops layer — part 3: agents, email, tasks.
-- Six agents = six AGENT_REGISTRY rows (instructions + tools) run by ONE
-- procedure, SP_RUN_AGENT(domain), through SNOWFLAKE.CORTEX.AGENT_RUN with the
-- model from MODEL_POLICY. Agents read sensor output; they never decide that
-- something failed and never change anything. Month 1 is notify-only.
--
-- Sandbox variant (reads PROD sources, writes GROCERY_DEV_OPS, tasks stay suspended):
--   sed -E 's/GROCERY_OPS([^_A-Za-z0-9]|$)/GROCERY_DEV_OPS\1/g; s/GROCERY_OPS_WH/COMPUTE_WH/g; /^-- PROD ONLY/,$d'

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GROCERY_OPS_WH;

------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_OPS.OPS_SETTING (
    KEY VARCHAR PRIMARY KEY, VALUE VARCHAR, DESCRIPTION VARCHAR, UPDATED_AT TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);
MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_SETTING t USING (SELECT * FROM VALUES
    ('alert_email', '<OWNER_EMAIL>', 'Recipient of every ops email (must be a verified Snowflake user email). Placeholder in the repo: set the real address before running, or UPDATE OPS_SETTING afterwards'),
    ('email_integration', 'EMAIL_INTEGRATION', 'Notification integration used by SYSTEM$SEND_EMAIL'),
    ('email_min_severity', 'WARN', 'Agents email only when the domain''s max severity is at least this; the weekly digest always sends'),
    ('autonomy_enabled', 'false', 'Month-2 switch; nothing acts while false')
) s (KEY, VALUE, DESCRIPTION) ON t.KEY = s.KEY
WHEN NOT MATCHED THEN INSERT (KEY, VALUE, DESCRIPTION) VALUES (s.KEY, s.VALUE, s.DESCRIPTION);

------------------------------------------------------------------------------
-- Read-only tools the agents may call (procedures, returned as JSON)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_RUNBOOK(TOPIC VARCHAR DEFAULT NULL)
RETURNS VARIANT LANGUAGE SQL COMMENT = 'Known failure modes: symptom, cause, fix, and whether an automated action exists. Pass a TOPIC or omit for all.'
EXECUTE AS OWNER AS
$$
BEGIN
    RETURN (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('topic', TOPIC, 'symptom', SYMPTOM, 'known_cause', KNOWN_CAUSE, 'fix', FIX, 'action', ACTION_NAME))
            FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUNBOOK WHERE :TOPIC IS NULL OR TOPIC = :TOPIC);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_METRIC_HISTORY(METRIC_NAME VARCHAR, DAYS NUMBER DEFAULT 28)
RETURNS VARIANT LANGUAGE SQL COMMENT = 'Daily values of one metric (a CHECK_NAME, or credits_* / parse_none_pct / search_data_age_days) per dimension over the last DAYS days.'
EXECUTE AS OWNER AS
$$
BEGIN
    RETURN (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('date', METRIC_DATE, 'dimension', DIMENSION, 'value', VALUE)) WITHIN GROUP (ORDER BY METRIC_DATE, DIMENSION)
            FROM (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY WHERE METRIC_NAME = :METRIC_NAME AND METRIC_DATE >= DATEADD(day, -:DAYS, CURRENT_DATE()) ORDER BY METRIC_DATE DESC LIMIT 400));
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_RECENT_RUNS(WEEKS NUMBER DEFAULT 4)
RETURNS VARIANT LANGUAGE SQL COMMENT = 'Ingestion job runs (ORCHESTRATION_JOB_RUNS) over the last WEEKS weeks: source, mode, start, status, minutes.'
EXECUTE AS OWNER AS
$$
BEGIN
    RETURN (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('source', SOURCE, 'run_mode', RUN_MODE, 'started_at', STARTED_AT, 'status', STATUS, 'minutes', TIMESTAMPDIFF(minute, STARTED_AT, COMPLETED_AT))) WITHIN GROUP (ORDER BY STARTED_AT DESC)
            FROM GROCERYDBTPROJECT.JOB_PERFORMANCE.ORCHESTRATION_JOB_RUNS WHERE STARTED_AT >= DATEADD(week, -:WEEKS, CURRENT_TIMESTAMP()));
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_COST_HOTSPOTS(DAYS NUMBER DEFAULT 28)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Where the credits and the minutes go over the last DAYS days (ACCOUNT_USAGE, <= 3 h lag): warehouses with idle share, services, top queries by attributed credits, dynamic-table refresh cost and no-op share, agent token spend, search serving, pipes, tasks, Fargate minutes, guest sessions. Read-only; feeds the improvement and cost agents.'
EXECUTE AS OWNER AS
$$
DECLARE
    since TIMESTAMP_LTZ := DATEADD(day, -:DAYS, CURRENT_TIMESTAMP());
BEGIN
    RETURN OBJECT_CONSTRUCT(
      'days', :DAYS, 'note', 'credits = Snowflake credits; idle_share_pct = share of warehouse credits not attributed to any query (auto-suspend / resume minimums); no_data_refreshes = refreshes that found nothing to do',
      'warehouses', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('warehouse', WAREHOUSE_NAME, 'credits', ROUND(c, 3), 'query_attributed_credits', ROUND(q, 3), 'idle_share_pct', ROUND(100 * (1 - q / NULLIF(c, 0)), 0))) WITHIN GROUP (ORDER BY c DESC)
                       FROM (SELECT WAREHOUSE_NAME, SUM(CREDITS_USED) c, SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES) q
                             FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY WHERE START_TIME >= :since GROUP BY 1)),
      'services', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('service', SERVICE_TYPE, 'credits', ROUND(c, 3))) WITHIN GROUP (ORDER BY c DESC)
                     FROM (SELECT SERVICE_TYPE, SUM(CREDITS_USED) c FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY WHERE USAGE_DATE >= :since::DATE GROUP BY 1)),
      'top_queries', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('credits', ROUND(cr, 3), 'runs', n, 'avg_seconds', ROUND(sec, 1), 'warehouse', wh, 'user', u, 'query_tag', tg, 'query_text_head', LEFT(txt, 220))) WITHIN GROUP (ORDER BY cr DESC)
                        FROM (SELECT a.QUERY_PARAMETERIZED_HASH, SUM(a.CREDITS_ATTRIBUTED_COMPUTE) cr, COUNT(*) n, AVG(TIMESTAMPDIFF(second, a.START_TIME, a.END_TIME)) sec,
                                     MAX(a.WAREHOUSE_NAME) wh, MAX(a.USER_NAME) u, MAX(a.QUERY_TAG) tg, MAX(h.QUERY_TEXT) txt
                              FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY a
                              JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h ON h.QUERY_ID = a.QUERY_ID
                              WHERE a.START_TIME >= :since GROUP BY 1 ORDER BY cr DESC LIMIT 10)),
      'dynamic_tables', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('table', NAME, 'refreshes', n, 'no_data_refreshes', nd, 'total_seconds', ROUND(ts, 0), 'avg_seconds', ROUND(avs, 1), 'target_lag_sec', lag)) WITHIN GROUP (ORDER BY ts DESC)
                           FROM (SELECT NAME, COUNT(*) n, COALESCE(SUM(IFF(REFRESH_ACTION = 'NO_DATA', 1, 0)), 0) nd,
                                        SUM(TIMESTAMPDIFF(second, REFRESH_START_TIME, REFRESH_END_TIME)) ts, AVG(TIMESTAMPDIFF(second, REFRESH_START_TIME, REFRESH_END_TIME)) avs, MAX(TARGET_LAG_SEC) lag
                                 FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
                                 WHERE REFRESH_START_TIME >= :since AND DATABASE_NAME = 'GROCERYDBTPROJECT' GROUP BY 1 ORDER BY ts DESC LIMIT 15)),
      'agents', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('agent', COALESCE(AGENT_NAME, 'inline (ops agents via AGENT_RUN)'), 'user', USER_NAME, 'requests', n, 'tokens', t, 'credits', ROUND(cr, 3), 'credits_per_request', ROUND(cr / NULLIF(n, 0), 4))) WITHIN GROUP (ORDER BY cr DESC)
                   FROM (SELECT AGENT_NAME, USER_NAME, COUNT(*) n, SUM(TOKENS) t, SUM(TOKEN_CREDITS) cr
                         FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY WHERE START_TIME >= :since GROUP BY 1, 2)),
      'search_serving', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('service', SERVICE_NAME, 'credits', ROUND(c, 3)))
                           FROM (SELECT SERVICE_NAME, SUM(CREDITS) c FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_SERVING_USAGE_HISTORY WHERE START_TIME >= :since GROUP BY 1)),
      'pipes', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('pipe', PIPE_NAME, 'credits', ROUND(c, 4), 'files', f))
                  FROM (SELECT PIPE_NAME, SUM(CREDITS_USED) c, SUM(FILES_INSERTED) f FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY WHERE START_TIME >= :since GROUP BY 1)),
      'tasks', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('task', NAME, 'runs', n, 'failed', f, 'avg_minutes', ROUND(m, 1))) WITHIN GROUP (ORDER BY m DESC)
                  FROM (SELECT NAME, COUNT(*) n, COALESCE(SUM(IFF(STATE = 'FAILED', 1, 0)), 0) f, AVG(TIMESTAMPDIFF(second, QUERY_START_TIME, COMPLETED_TIME)) / 60 m
                        FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
                        WHERE DATABASE_NAME = 'GROCERYDBTPROJECT' AND SCHEDULED_TIME >= :since AND STATE IN ('SUCCEEDED', 'FAILED') GROUP BY 1)),
      'fargate_runs', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('source', SOURCE, 'run_mode', RUN_MODE, 'runs', n, 'avg_minutes', ROUND(m, 1)))
                         FROM (SELECT SOURCE, RUN_MODE, COUNT(*) n, AVG(TIMESTAMPDIFF(minute, STARTED_AT, COMPLETED_AT)) m
                               FROM GROCERYDBTPROJECT.JOB_PERFORMANCE.ORCHESTRATION_JOB_RUNS WHERE STARTED_AT >= :since AND STATUS = 'success' GROUP BY 1, 2)),
      'guests', (SELECT OBJECT_CONSTRUCT('sessions', COUNT(*), 'est_credits', ROUND(COALESCE(SUM(EST_CREDITS), 0), 3), 'questions', COALESCE(SUM(AGENT_QUESTIONS), 0))
                   FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION WHERE STARTED_AT >= :since)
    );
END;
$$;

------------------------------------------------------------------------------
-- Email
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_SEND_OPS_EMAIL(DOMAIN VARCHAR, SEVERITY VARCHAR, TITLE VARCHAR, BODY VARCHAR)
RETURNS BOOLEAN LANGUAGE SQL COMMENT = 'Sends [grocery-ops][domain][severity] title to the alert_email setting through the email integration.'
EXECUTE AS OWNER AS
$$
DECLARE
    to_addr VARCHAR; integ VARCHAR; ok BOOLEAN;
BEGIN
    SELECT MAX(IFF(KEY = 'alert_email', VALUE, NULL)), MAX(IFF(KEY = 'email_integration', VALUE, NULL)) INTO :to_addr, :integ FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_SETTING;
    LET subj VARCHAR := '[grocery-ops][' || :DOMAIN || '][' || :SEVERITY || '] ' || :TITLE;
    CALL SYSTEM$SEND_EMAIL(:integ, :to_addr, :subj, :BODY);   -- a system procedure: CALL, not SELECT
    RETURN TRUE;
EXCEPTION WHEN OTHER THEN
    RETURN FALSE;
END;
$$;

------------------------------------------------------------------------------
-- Agent instructions (versioned copies live in Agent/ops/prompts/)
------------------------------------------------------------------------------
UPDATE GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY SET PROMPT_VERSION = 'v1', TOOLS = PARSE_JSON('["get_runbook","get_metric_history","get_recent_runs"]'), INSTRUCTIONS = $$
You are the data-ingestion agent for a weekly grocery price pipeline (Kroger: 81 Atlanta stores via EventBridge -> ECS Fargate -> S3 -> Snowpipe, Friday 17:00 ET full run + Saturday 09:00 ET continuation; Walmart: one national pull on Friday). You receive deterministic sensor findings as JSON. The sensors decided what is wrong and how severe; your job is to explain it, connect related findings, say what it means for the data, and name the runbook action a human should take. Rules: cite finding IDs; never claim a job ran unless a finding or run row shows it; a missing run means the week's prices are lost for good (the APIs do not return past prices); a Saturday run with many 429s after a manual Friday run is expected (Kroger's 10,000 calls/day budget); never recommend re-running friday_full on the same Kroger budget day. Output exactly three sections: DIAGNOSIS (<= 8 lines), RECOMMENDED_ACTION (one runbook action name or 'none', plus the exact human step), CONFIDENCE (high | medium | low, one reason).
$$ WHERE AGENT_NAME = 'agent_ingestion';

UPDATE GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY SET PROMPT_VERSION = 'v1', TOOLS = PARSE_JSON('["get_runbook","get_metric_history"]'), INSTRUCTIONS = $$
You are the data-quality agent for a grocery price product. Sensors already measured freshness, price outliers, promo >= regular share, null rates, duplicates, SQL ports of the dbt tests, size-parse drift and forecast sanity, and set severities. Judge whether each WARN/CRIT is a real data problem or an explainable condition (examples: seasonal products such as whole turkeys arriving in November; a Kroger weight multipack whose size parsed per item; Walmart marketplace items with no price, which is normal at 15-20%; a half-collected week because the Saturday job has not run yet). Say which findings need a human and which are expected. Never invent numbers: quote the observed values from the findings. Output exactly three sections: DIAGNOSIS, RECOMMENDED_ACTION (runbook action or 'none' + the human step, or 'suppress <check>' with a reason if it is noise), CONFIDENCE.
$$ WHERE AGENT_NAME = 'agent_quality';

UPDATE GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY SET PROMPT_VERSION = 'v1', TOOLS = PARSE_JSON('["get_metric_history","get_runbook"]'), INSTRUCTIONS = $$
You are the cost-monitoring agent. Budget: 20 Snowflake credits per month in total; monitors: GROCERY_COMPUTE_MONITOR 8 (COMPUTE_WH: dbt, dynamic tables, pipes), GROCERY_AGENT_MONITOR 10 (GROCERY_AGENT_WH + GROCERY_ML_WH), GROCERY_OPS_MONITOR 2 (this layer). Sensors give yesterday's credits per warehouse and service vs a 28-day p90, month-to-date and projection per group, monitor usage and agent token budgets. Explain where the money went, whether it is a one-off (a dbt --full-refresh, an eval run at ~0.1 credit per question, a forecast retrain, Trust Center scanner packages) or a trend, and what to stop or cap. Prevent surprise bills: if the projection exceeds any quota, say so first and name the largest contributor. Output exactly three sections: DIAGNOSIS, RECOMMENDED_ACTION, CONFIDENCE.
$$ WHERE AGENT_NAME = 'agent_cost';

UPDATE GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY SET PROMPT_VERSION = 'v1', TOOLS = PARSE_JSON('["get_runbook","get_metric_history","get_recent_runs"]'), INSTRUCTIONS = $$
You are the job-performance and observability agent. Sensors cover Snowflake task failures and missed slots (the Sunday 06:00 ET forecast task), dynamic-table refresh failures, suspensions and lag, Snowpipe state, agent-warehouse queueing and p95 latency (Standard edition: no multi-cluster), search-index freshness, the value agent's eval score and shopper feedback. Diagnose the first failing component in a chain (upstream before downstream), say what the user-visible impact is, and name the runbook action. In month 1 you only recommend; in month 2 some actions (resume task, refresh/resume dynamic table, refill search source) can run automatically, so always name the exact object. Output exactly three sections: DIAGNOSIS, RECOMMENDED_ACTION, CONFIDENCE.
$$ WHERE AGENT_NAME = 'agent_performance';

UPDATE GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY SET PROMPT_VERSION = 'v2.1', TOOLS = PARSE_JSON('["get_cost_hotspots","get_metric_history","get_runbook","get_recent_runs"]'), INSTRUCTIONS = $$
You are the continuous-improvement agent for a weekly grocery price pipeline on Snowflake and AWS (EventBridge -> ECS Fargate ingestion; Snowpipe; dbt Fusion dynamic tables; a weekly SNOWFLAKE.ML.FORECAST task; Cortex Search; a Cortex Agent and two Streamlit apps incl. a metered public guest edition; this ops layer). Your standing job, every run: find ways to make this architecture CHEAPER and FASTER without reducing what the product can answer, how fresh it is, or how many stores and products it covers. Budget context: 20 Snowflake credits a month in total (COMPUTE_WH 8, agent+ML 10, ops 2, guests 5 per week inside those).

Method. (1) ALWAYS call get_cost_hotspots first (28 days) and read get_metric_history for anything you want to trend; the context also carries 28 days of metrics, the registry, open findings and the runbook. (2) Work through this checklist and say in one line each whether it holds: warehouses with a high idle share (credits far above attributed query credits; every warehouse here already auto-suspends at the 60 s minimum, so idle share means many short wake-ups each billed a full minute -> batch the wake-ups: dynamic-table lag alignment, fewer scheduled touches, routing ad-hoc work elsewhere, never a shorter auto-suspend); dynamic tables whose refreshes are mostly NO_DATA or whose target lag is tighter than the weekly data needs; the top queries by attributed credits (cheaper rewrite, clustering, materialization, or run less often); agent token spend per agent against its model (would Haiku do the same job; is the token budget too high; are cached tokens being reused); Cortex Search serving credits vs use; Snowpipe and task durations; Fargate minutes per run; guest spend per session; any service appearing in the metering that the product does not need (e.g. Trust Center scanners). (3) Check open findings for your own earlier proposals and label each new item NEW, REPEAT (still open, restate briefly) or DONE (evidence it was adopted).

Rules. Quantify everything from the tool output: baseline (credits/month or seconds), target, and the arithmetic. Prefer changes that remove work over changes that add it, and changes with a Snowflake-native off-the-shelf mechanism over custom code. Never propose anything that reduces data coverage, freshness, answer quality, or the controls in the runbook (resource monitors, sensors, notify-only rule). Name objects exactly. Keep it to what a single owner can do in an evening unless the payoff is large (then say so and size it).

Output exactly these sections: CHEAPER (numbered, <= 3: change, objects, baseline -> target with arithmetic, credits/month saved, risk, how to verify, effort S/M/L, NEW/REPEAT/DONE), FASTER (numbered, <= 3: same fields with seconds or minutes saved and who feels it: shopper, owner, or pipeline), CHECKLIST (one line per item above: OK or finding), WATCHLIST (<= 3 trends to keep an eye on). If the evidence truly shows nothing worth changing in a section, write "nothing this week" and the one number that proves it.
$$ WHERE AGENT_NAME = 'agent_improvement';

UPDATE GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY SET PROMPT_VERSION = 'v2', TOOLS = PARSE_JSON('["get_runbook","get_metric_history"]'), INSTRUCTIONS = $$
You are the supervisor of an operations layer made of deterministic sensors and five domain agents (ingestion, quality, cost, performance, improvement), watching a weekly grocery price pipeline, a shopper-facing Cortex agent, and a metered public guest app. You receive: every open finding with its severity, each domain agent's latest report, the component registry with last-run times and silence flags, today's run log, guest_week (sign-ups, sessions, questions, guest credits vs the 5-credit weekly cap), and changes_this_week (code changes merged this week and audited config changes). Never invent a number: every figure comes from the context, and if something is missing say "not reported".

DAILY mode: (1) confirm every scheduled component ran when due - a silent component is itself a CRIT, (2) correlate across domains (a cost spike plus a long task, a missing run plus a stale mart), (3) decide one overall severity and the single most important thing for the owner to do, (4) list what needs a human, in priority order, with the runbook action, (5) say what is fine. Short and decisive. Sections: STATUS (one line: OK | WARN | CRIT and why), ACTIONS (numbered, owner steps), CORRELATIONS, FINE (one line).

DIGEST mode is the Sunday weekly report, emailed to the owner, who reads it on a phone. Sections in this order:
HEADLINE: one sentence for the week and the overall status (OK | WARN | CRIT).
THIS WEEK BY AREA: one short block (2-4 lines, numbers first) for each of: Ingestion (runs expected vs seen, stores covered, rows, anything missed); Data quality (freshness, outliers, test ports, store coverage); Cost (credits month-to-date vs 20 and per monitor group, biggest movers, month-end projection, error-budget burn); Performance (tasks, dynamic-table refreshes, pipes, agent latency, eval score); Guest app & shopper agent (new sign-ups, sessions, questions, guest credits vs 5, limits hit, anything guests ran into); Continuous improvement (each CHEAPER/FASTER proposal from the improvement agent this week in one line with NEW/REPEAT/DONE, and the one you would do first).
IMPLEMENTED THIS WEEK: one line per item in changes_this_week - area, what changed, and what it means for the owner in plain words; group config changes together; write "nothing shipped this week" if the list is empty.
OPEN ITEMS: open findings with their age, oldest first, at most 8, each with the runbook action.
NEXT WEEK: numbered owner actions (most valuable first), then what you will watch.
Keep the whole report under 70 lines, plain text, no tables wider than a phone.
$$ WHERE AGENT_NAME = 'agent_supervisor';

------------------------------------------------------------------------------
-- SP_RUN_AGENT(domain, mode): context -> AGENT_RUN -> OPS_RUN + OPS_EVENT (+ email)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT(DOMAIN VARCHAR, MODE VARCHAR DEFAULT 'daily')
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Runs one ops agent (ingestion | quality | cost | performance | improvement | supervisor) with the model from MODEL_POLICY. MODE digest = weekly supervisor digest (always emails). Notify-only: the agent recommends, nothing acts.'
EXECUTE AS OWNER
AS
$$
DECLARE
    run_id        VARCHAR := UUID_STRING();
    agent_name    VARCHAR := 'agent_' || :DOMAIN;
    model_task    VARCHAR; model VARCHAR; fallback VARCHAR; max_tokens NUMBER; budget_s NUMBER; monthly_budget NUMBER; policy_enabled BOOLEAN;
    prompt_version VARCHAR; instructions VARCHAR; tools VARIANT;
    tokens_mtd    NUMBER;
    context       VARIANT; request VARCHAR; response VARIANT;
    answer        VARCHAR; in_tok NUMBER; out_tok NUMBER;
    max_sev       VARCHAR := 'OK';
    min_email_sev VARCHAR;
    emailed       BOOLEAN := FALSE;
    agent_failed  BOOLEAN := FALSE;
    body          VARCHAR;
BEGIN
    -- policy
    SELECT r.MODEL_TASK, p.MODEL, p.FALLBACK_MODEL, p.MAX_TOKENS, p.BUDGET_SECONDS, p.MONTHLY_TOKEN_BUDGET, p.ENABLED AND r.ENABLED, r.PROMPT_VERSION, r.INSTRUCTIONS, r.TOOLS
      INTO :model_task, :model, :fallback, :max_tokens, :budget_s, :monthly_budget, :policy_enabled, :prompt_version, :instructions, :tools
    FROM GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY r JOIN GROCERYDBTPROJECT.GROCERY_OPS.MODEL_POLICY p ON p.MODEL_TASK = IFF(:MODE = 'digest' AND r.AGENT_NAME = 'agent_supervisor', 'ops_digest', r.MODEL_TASK)
    WHERE r.AGENT_NAME = :agent_name;
    IF (model IS NULL) THEN RETURN OBJECT_CONSTRUCT('error', 'no registry/policy row for ' || :agent_name); END IF;

    INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN (RUN_ID, KIND, DOMAIN, AGENT_NAME, STATUS, MODEL, PROMPT_VERSION) VALUES (:run_id, 'agent', :DOMAIN, :agent_name, 'running', :model, :prompt_version);

    IF (NOT policy_enabled) THEN
        UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN SET STATUS = 'skipped', ENDED_AT = CURRENT_TIMESTAMP(), ERROR = 'disabled in MODEL_POLICY/AGENT_REGISTRY' WHERE RUN_ID = :run_id;
        RETURN OBJECT_CONSTRUCT('skipped', 'disabled');
    END IF;
    SELECT COALESCE(SUM(INPUT_TOKENS + OUTPUT_TOKENS), 0) INTO :tokens_mtd FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN WHERE AGENT_NAME = :agent_name AND STARTED_AT >= DATE_TRUNC(month, CURRENT_DATE());
    IF (tokens_mtd >= monthly_budget) THEN
        INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT (DOMAIN, CHECK_NAME, SEVERITY, FINGERPRINT, SUBJECT, MESSAGE, SOURCE, PERIOD_TS, RUN_ID)
        VALUES ('cost', 'agent_token_budget', 'WARN', 'agent_token_budget|' || :agent_name || '|' || TO_VARCHAR(CURRENT_DATE(), 'YYYY-MM'), :agent_name, :agent_name || ' skipped: monthly token budget exhausted (' || :tokens_mtd || ' of ' || :monthly_budget || ')', 'agent', CURRENT_TIMESTAMP(), :run_id);
        UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN SET STATUS = 'skipped', ENDED_AT = CURRENT_TIMESTAMP(), ERROR = 'monthly token budget exhausted' WHERE RUN_ID = :run_id;
        RETURN OBJECT_CONSTRUCT('skipped', 'token budget');
    END IF;

    -- context: what the sensors found (the agent sees nothing else about the world)
    context := (SELECT OBJECT_CONSTRUCT(
        'as_of', CURRENT_TIMESTAMP(),
        'domain', :DOMAIN,
        'mode', :MODE,
        'open_findings', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('event_id', e.EVENT_ID, 'domain', e.DOMAIN, 'check', e.CHECK_NAME, 'severity', e.SEVERITY, 'subject', e.SUBJECT, 'period', e.PERIOD_TS, 'first_seen', e.FIRST_SEEN_AT, 'message', e.MESSAGE, 'observed', e.OBSERVED, 'expected', e.EXPECTED, 'check_description', c.DESCRIPTION, 'runbook_topic', c.RUNBOOK_TOPIC, 'slo', c.SLO_NAME))
                            WITHIN GROUP (ORDER BY CASE e.SEVERITY WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, e.FIRST_SEEN_AT DESC)
                          FROM (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT e WHERE e.STATUS IN ('open', 'acked') AND e.SOURCE IN ('sensor', 'alert')
                                  AND (:DOMAIN IN ('supervisor', 'improvement') OR e.DOMAIN = :DOMAIN) ORDER BY FIRST_SEEN_AT DESC LIMIT 60) e
                          LEFT JOIN GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK c ON c.CHECK_NAME = e.CHECK_NAME),
        'ok_checks_today', (SELECT ARRAY_AGG(DISTINCT c.CHECK_NAME) FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY m JOIN GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK c ON c.CHECK_NAME = m.METRIC_NAME
                            WHERE m.METRIC_DATE = CURRENT_DATE() AND (:DOMAIN IN ('supervisor', 'improvement') OR c.DOMAIN = :DOMAIN)
                              AND NOT EXISTS (SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT e WHERE e.CHECK_NAME = c.CHECK_NAME AND e.STATUS = 'open')),
        'metrics_7d', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('date', METRIC_DATE, 'metric', METRIC_NAME, 'dimension', DIMENSION, 'value', VALUE, 'what_value_means', MEANING)) WITHIN GROUP (ORDER BY METRIC_DATE DESC)
                       FROM (SELECT m.*, COALESCE(c.DESCRIPTION, CASE m.METRIC_NAME WHEN 'parse_none_pct' THEN 'percent of food products with no parsed size' WHEN 'search_data_age_days' THEN 'days since the search index data timestamp' ELSE m.METRIC_NAME END) AS MEANING
                             FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_METRIC_DAILY m LEFT JOIN GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK c ON c.CHECK_NAME = m.METRIC_NAME
                             WHERE m.METRIC_DATE >= DATEADD(day, IFF(:DOMAIN = 'improvement', -28, -7), CURRENT_DATE()) AND (:DOMAIN IN ('supervisor', 'improvement') OR COALESCE(c.DOMAIN, m.DOMAIN) = :DOMAIN)
                             ORDER BY m.METRIC_DATE DESC LIMIT 300)),
        'registry', IFF(:DOMAIN IN ('supervisor', 'improvement'),
                        (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('component', AGENT_NAME, 'kind', KIND, 'platform', PLATFORM, 'schedule', SCHEDULE_TEXT, 'model', MODEL, 'enabled', ENABLED, 'last_run_at', LAST_RUN_AT, 'last_status', LAST_STATUS, 'silent', IS_SILENT)) FROM GROCERYDBTPROJECT.GROCERY_OPS.V_REGISTRY_STATUS), NULL),
        'agent_reports_today', IFF(:DOMAIN = 'supervisor',
                        (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('agent', AGENT_NAME, 'status', STATUS, 'max_severity', MAX_SEVERITY, 'model', MODEL, 'report', LEFT(RESPONSE, 2500))) WITHIN GROUP (ORDER BY STARTED_AT)
                         FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN WHERE KIND = 'agent' AND AGENT_NAME <> 'agent_supervisor' AND STARTED_AT >= DATEADD(hour, -26, CURRENT_TIMESTAMP())), NULL),
        'runs_today', IFF(:DOMAIN = 'supervisor',
                        (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('kind', KIND, 'agent', AGENT_NAME, 'status', STATUS, 'started_at', STARTED_AT, 'seconds', TIMESTAMPDIFF(second, STARTED_AT, ENDED_AT), 'tokens', INPUT_TOKENS + OUTPUT_TOKENS))
                         FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN WHERE STARTED_AT >= DATEADD(hour, -26, CURRENT_TIMESTAMP()) AND RUN_ID <> :run_id), NULL),
        'runbook_topics', (SELECT ARRAY_AGG(TOPIC) FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUNBOOK),
        'changes_this_week', IFF(:DOMAIN = 'supervisor',
                        (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('at', CHANGED_AT, 'area', AREA, 'title', TITLE, 'detail', DETAIL, 'source', SOURCE, 'ref', REF)) WITHIN GROUP (ORDER BY CHANGED_AT)
                         FROM GROCERYDBTPROJECT.GROCERY_OPS.V_CHANGES_THIS_WEEK), NULL),
        'guest_week', IFF(:DOMAIN = 'supervisor',
                        (SELECT OBJECT_CONSTRUCT('week_start', w.WEEK_START, 'sessions', w.WEEK_SESSIONS, 'questions', w.WEEK_QUESTIONS, 'est_credits', ROUND(w.WEEK_EST_CREDITS, 3), 'weekly_cap_credits', w.WEEKLY_CAP,
                                'guests_total', (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE EMAIL NOT LIKE '%@example.com'),
                                'guests_pending_verification', (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE STATUS = 'pending' AND EMAIL NOT LIKE '%@example.com'),
                                'new_guests_7d', (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE CREATED_AT >= DATEADD(day, -7, CURRENT_TIMESTAMP()) AND EMAIL NOT LIKE '%@example.com'),
                                'sessions_ended_by', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('reason', END_REASON, 'n', n)) FROM (SELECT END_REASON, COUNT(*) n FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION WHERE STARTED_AT >= DATEADD(day, -7, CURRENT_TIMESTAMP()) AND END_REASON IS NOT NULL GROUP BY 1)))
                         FROM GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK w), NULL)
    ));

    max_sev := (SELECT COALESCE(MAX(CASE SEVERITY WHEN 'CRIT' THEN 'CRIT' END), MAX(CASE SEVERITY WHEN 'WARN' THEN 'WARN' END), 'OK')
                FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT WHERE STATUS = 'open' AND (:DOMAIN IN ('supervisor', 'improvement') OR DOMAIN = :DOMAIN));

    -- nothing to analyse and not a digest: do not spend tokens
    IF (max_sev = 'OK' AND :MODE <> 'digest' AND :DOMAIN NOT IN ('improvement', 'supervisor')) THEN
        UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN SET STATUS = 'skipped', ENDED_AT = CURRENT_TIMESTAMP(), MAX_SEVERITY = 'OK', ERROR = 'no open findings' WHERE RUN_ID = :run_id;
        RETURN OBJECT_CONSTRUCT('skipped', 'no open findings', 'domain', :DOMAIN);
    END IF;

    request := OBJECT_CONSTRUCT(
        'models', OBJECT_CONSTRUCT('orchestration', :model),
        'orchestration', OBJECT_CONSTRUCT('budget', OBJECT_CONSTRUCT('seconds', :budget_s, 'tokens', :max_tokens)),
        'instructions', OBJECT_CONSTRUCT('response', :instructions),
        'tools', ARRAY_CONSTRUCT(
            OBJECT_CONSTRUCT('tool_spec', OBJECT_CONSTRUCT('type', 'generic', 'name', 'get_runbook', 'description', 'Known failure modes with symptom, cause, fix and whether an automated action exists. Optional TOPIC.',
                'input_schema', OBJECT_CONSTRUCT('type', 'object', 'properties', OBJECT_CONSTRUCT('TOPIC', OBJECT_CONSTRUCT('type', 'string'))))),
            OBJECT_CONSTRUCT('tool_spec', OBJECT_CONSTRUCT('type', 'generic', 'name', 'get_metric_history', 'description', 'Daily values of one metric (a check name, or credits metrics) per dimension over the last DAYS days.',
                'input_schema', OBJECT_CONSTRUCT('type', 'object', 'properties', OBJECT_CONSTRUCT('METRIC_NAME', OBJECT_CONSTRUCT('type', 'string'), 'DAYS', OBJECT_CONSTRUCT('type', 'number')), 'required', ARRAY_CONSTRUCT('METRIC_NAME')))),
            OBJECT_CONSTRUCT('tool_spec', OBJECT_CONSTRUCT('type', 'generic', 'name', 'get_recent_runs', 'description', 'Ingestion job runs over the last WEEKS weeks.',
                'input_schema', OBJECT_CONSTRUCT('type', 'object', 'properties', OBJECT_CONSTRUCT('WEEKS', OBJECT_CONSTRUCT('type', 'number'))))),
            OBJECT_CONSTRUCT('tool_spec', OBJECT_CONSTRUCT('type', 'generic', 'name', 'get_cost_hotspots', 'description', 'Where credits and minutes go over the last DAYS days: warehouses with idle share, services, top queries by attributed credits, dynamic-table refresh cost and no-op share, agent token spend, search serving, pipes, task durations, Fargate minutes, guest sessions. Call first when looking for cheaper or faster.',
                'input_schema', OBJECT_CONSTRUCT('type', 'object', 'properties', OBJECT_CONSTRUCT('DAYS', OBJECT_CONSTRUCT('type', 'number')))))),
        'tool_resources', OBJECT_CONSTRUCT(
            'get_runbook',        OBJECT_CONSTRUCT('type', 'procedure', 'identifier', 'GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_RUNBOOK',        'execution_environment', OBJECT_CONSTRUCT('type', 'warehouse', 'warehouse', 'GROCERY_OPS_WH', 'query_timeout', 30)),
            'get_metric_history', OBJECT_CONSTRUCT('type', 'procedure', 'identifier', 'GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_METRIC_HISTORY', 'execution_environment', OBJECT_CONSTRUCT('type', 'warehouse', 'warehouse', 'GROCERY_OPS_WH', 'query_timeout', 30)),
            'get_recent_runs',    OBJECT_CONSTRUCT('type', 'procedure', 'identifier', 'GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_RECENT_RUNS',    'execution_environment', OBJECT_CONSTRUCT('type', 'warehouse', 'warehouse', 'GROCERY_OPS_WH', 'query_timeout', 30)),
            'get_cost_hotspots',  OBJECT_CONSTRUCT('type', 'procedure', 'identifier', 'GROCERYDBTPROJECT.GROCERY_OPS.TOOL_GET_COST_HOTSPOTS',  'execution_environment', OBJECT_CONSTRUCT('type', 'warehouse', 'warehouse', 'GROCERY_OPS_WH', 'query_timeout', 90))),
        'messages', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('role', 'user', 'content', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('type', 'text', 'text',
            'Mode: ' || :MODE || '. Read every number from the finding''s observed/expected fields, whose key names state the unit (credits, pct, days, rows); check_description says what the check measures. Never treat a percentage as credits. Sensor context (JSON):\n' || TO_JSON(:context)))))
    )::STRING;

    BEGIN
        response := (SELECT PARSE_JSON(SNOWFLAKE.CORTEX.AGENT_RUN(:request)));
    EXCEPTION WHEN OTHER THEN
        -- fallback model once; if that fails too, the sensor context still gets reported
        BEGIN
            request := REPLACE(:request, '"orchestration":"' || :model || '"', '"orchestration":"' || :fallback || '"');
            response := (SELECT PARSE_JSON(SNOWFLAKE.CORTEX.AGENT_RUN(:request)));
            model := :fallback;
        EXCEPTION WHEN OTHER THEN
            answer := 'AGENT FAILED (' || :SQLERRM || '). Raw sensor findings follow.';
            response := NULL;
        END;
    END;

    IF (response IS NOT NULL) THEN
        answer := (SELECT LISTAGG(c.value:text::STRING, '\n') FROM TABLE(FLATTEN(INPUT => :response:content)) c WHERE c.value:type::STRING = 'text');
        in_tok  := (SELECT SUM(t.value:input_tokens:total::NUMBER)  FROM TABLE(FLATTEN(INPUT => :response:metadata:usage:tokens_consumed)) t);
        out_tok := (SELECT SUM(t.value:output_tokens:total::NUMBER) FROM TABLE(FLATTEN(INPUT => :response:metadata:usage:tokens_consumed)) t);
        -- an empty answer (budget exhausted, truncated stream) is a failure, never a blank report
        IF (answer IS NULL OR LENGTH(TRIM(answer)) = 0) THEN
            answer := 'AGENT RETURNED NO TEXT (status ' || COALESCE(:response:status::STRING, '?') || '; budget ' || :budget_s || ' s / ' || :max_tokens
                      || ' tokens; model ' || :model || '). The budget probably ran out: raise BUDGET_SECONDS / MAX_TOKENS in MODEL_POLICY or trim the context. Raw response head: '
                      || LEFT(TO_JSON(:response), 1200) || '\n\nRaw sensor findings follow.';
            agent_failed := TRUE;
        END IF;
    END IF;

    -- the agent's report is an event too (SOURCE = agent), so the Operations page and the supervisor see it
    INSERT INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT (DOMAIN, CHECK_NAME, SEVERITY, FINGERPRINT, SUBJECT, MESSAGE, OBSERVED, SOURCE, PERIOD_TS, RUN_ID, STATUS)
    SELECT :DOMAIN, 'agent_report', IFF(:max_sev = 'OK', 'INFO', :max_sev), 'agent_report|' || :agent_name || '|' || :run_id, :agent_name, LEFT(:answer, 4000),
           OBJECT_CONSTRUCT('model', :model, 'prompt_version', :prompt_version, 'mode', :MODE), 'agent', CURRENT_TIMESTAMP(), :run_id, 'resolved';

    -- email: digest always; otherwise only when the domain's severity reaches the threshold
    SELECT VALUE INTO :min_email_sev FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_SETTING WHERE KEY = 'email_min_severity';
    IF (:MODE = 'digest' OR (:max_sev = 'CRIT') OR (:max_sev = 'WARN' AND :min_email_sev = 'WARN')) THEN
        body := :answer || '\n\n--- open findings (' || :DOMAIN || ') ---\n' ||
                (SELECT COALESCE(LISTAGG(SEVERITY || '  ' || CHECK_NAME || '  ' || COALESCE(SUBJECT, '') || '  ' || LEFT(MESSAGE, 160) || '  [' || EVENT_ID || ']', '\n') WITHIN GROUP (ORDER BY CASE SEVERITY WHEN 'CRIT' THEN 0 ELSE 1 END, CHECK_NAME), '(none)')
                 FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT WHERE STATUS = 'open' AND SOURCE IN ('sensor', 'alert') AND (:DOMAIN IN ('supervisor', 'improvement') OR DOMAIN = :DOMAIN)) ||
                '\n\n--- run ---\nrun_id: ' || :run_id || '\nagent: ' || :agent_name || '\nmodel: ' || :model || ' (' || :prompt_version || ')\ntokens: ' || COALESCE(:in_tok::STRING, '?') || ' in / ' || COALESCE(:out_tok::STRING, '?') || ' out';
        LET email_sev VARCHAR := IFF(:MODE = 'digest', 'DIGEST', :max_sev);
        LET email_title VARCHAR := IFF(:MODE = 'digest', 'weekly report ', '') || TO_VARCHAR(CURRENT_DATE());
        CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_SEND_OPS_EMAIL(:DOMAIN, :email_sev, :email_title, :body) INTO :emailed;
        UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_EVENT SET EMAILED_AT = CURRENT_TIMESTAMP() WHERE STATUS = 'open' AND EMAILED_AT IS NULL AND (:DOMAIN IN ('supervisor', 'improvement') OR DOMAIN = :DOMAIN);
    END IF;

    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN
       SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = IFF(:response IS NULL OR :agent_failed, 'failed', 'success'), MAX_SEVERITY = :max_sev, MODEL = :model,
           INPUT_TOKENS = :in_tok, OUTPUT_TOKENS = :out_tok, EMAIL_SENT = :emailed, RESPONSE = :answer, ERROR = IFF(:response IS NULL OR :agent_failed, LEFT(:answer, 500), NULL)
     WHERE RUN_ID = :run_id;

    RETURN OBJECT_CONSTRUCT('run_id', :run_id, 'agent', :agent_name, 'model', :model, 'max_severity', :max_sev, 'emailed', :emailed, 'input_tokens', :in_tok, 'output_tokens', :out_tok, 'answer', :answer);
EXCEPTION WHEN OTHER THEN
    UPDATE GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN SET ENDED_AT = CURRENT_TIMESTAMP(), STATUS = 'failed', ERROR = :SQLERRM WHERE RUN_ID = :run_id;
    RAISE;
END;
$$;

------------------------------------------------------------------------------
-- Tasks (owner GROCERY_OPS_ROLE in prod; created suspended, resumed in PROD ONLY)
------------------------------------------------------------------------------
CREATE OR REPLACE TASK GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_DAILY
    WAREHOUSE = GROCERY_OPS_WH SCHEDULE = 'USING CRON 0 7 * * * America/New_York' QUERY_TAG = 'grocery:ops:daily'
    COMMENT = 'Daily 07:00 ET: all sensors, then quality, cost, performance agents, then the supervisor'
AS EXECUTE IMMEDIATE $$
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_SENSORS('all');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('quality');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('cost');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('performance');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('supervisor');
END;
$$;

CREATE OR REPLACE TASK GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_FRI
    WAREHOUSE = GROCERY_OPS_WH SCHEDULE = 'USING CRON 30 23 * * FRI America/New_York' QUERY_TAG = 'grocery:ops:friday'
    COMMENT = 'Friday 23:30 ET, after the friday_full job: ingestion sensors and agent'
AS EXECUTE IMMEDIATE $$
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_SENSORS('ingestion');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('ingestion');
END;
$$;

CREATE OR REPLACE TASK GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_SAT
    WAREHOUSE = GROCERY_OPS_WH SCHEDULE = 'USING CRON 0 16 * * SAT America/New_York' QUERY_TAG = 'grocery:ops:saturday'
    COMMENT = 'Saturday 16:00 ET, after the continuation job: ingestion sensors and agent'
AS EXECUTE IMMEDIATE $$
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_SENSORS('ingestion');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('ingestion');
END;
$$;

CREATE OR REPLACE TASK GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_WEEKLY
    WAREHOUSE = GROCERY_OPS_WH SCHEDULE = 'USING CRON 0 9 * * SUN America/New_York' QUERY_TAG = 'grocery:ops:weekly'
    COMMENT = 'Sunday 09:00 ET, after the 06:00 forecast task: all sensors, all agents, continuous improvement, supervisor digest'
AS EXECUTE IMMEDIATE $$
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_SENSORS('all');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('ingestion');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('quality');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('performance');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('cost');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('improvement');
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RUN_AGENT('supervisor', 'digest');
END;
$$;

-- PROD ONLY ------------------------------------------------------------------
GRANT OWNERSHIP ON ALL TASKS IN SCHEMA GROCERYDBTPROJECT.GROCERY_OPS TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL PROCEDURES IN SCHEMA GROCERYDBTPROJECT.GROCERY_OPS TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL VIEWS IN SCHEMA GROCERYDBTPROJECT.GROCERY_OPS TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_OPS TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;
ALTER TASK GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_DAILY RESUME;
ALTER TASK GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_FRI RESUME;
ALTER TASK GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_SAT RESUME;
ALTER TASK GROCERYDBTPROJECT.GROCERY_OPS.TASK_OPS_WEEKLY RESUME;
