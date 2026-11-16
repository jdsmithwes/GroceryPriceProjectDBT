# Operations layer — runbook

Six agents watch the grocery price pipeline from inside Snowflake. This file
is the operating manual: who owns it, what each agent checks, how severities
are decided, what the agents may and may not do, how to change a threshold or
a model, and what to do when something fires. Design and controls:
[the plan](../../.claude/plans/shimmying-herding-flamingo.md) and
[ARCHITECTURE.md](../ARCHITECTURE.md).

**Owner / on-call:** the project owner (one person). Response target for a
CRIT: one business day. Escalation path: Proton email → GitHub issue in this
repo. Alerts and reports go to the owner's email (`alert_email` in `GROCERY_OPS.OPS_SETTING`) only.

## The one principle

**Sensors decide, agents explain, humans act.** Every severity comes from a
SQL view in `GROCERY_OPS` with thresholds in `OPS_CHECK`. An agent receives
the sensor findings as JSON and may explain, correlate, rank and name a
runbook action. In month 1 nothing acts automatically. In month 2 a short
whitelist of actions (`03_autonomy.sql`, not yet written) can run, gated by
`AUTONOMY_POLICY`, each one emailed before and after.

## What runs where

| Component | Object | Schedule (ET) | Model |
|---|---|---|---|
| Sensors | `GROCERY_OPS.SP_RUN_SENSORS(domain)` + 25 `V_CHECK_*` views | with every task below | none (SQL) |
| Hourly alerts | `ALERT_INGESTION_RUN`, `ALERT_TASK_FAILED`, `ALERT_BUDGET` (serverless) | hourly | none |
| Ingestion agent | `SP_RUN_AGENT('ingestion')` | Fri 23:30, Sat 16:00, Sun 09:00 | Haiku 5.5 |
| Data quality & validation agent | `SP_RUN_AGENT('quality')` | daily 07:00, Sun 09:00 | Sonnet 5.5 |
| Cost monitoring agent | `SP_RUN_AGENT('cost')` | daily 07:00 | Haiku 5.5 |
| Job performance & observability agent | `SP_RUN_AGENT('performance')` | daily 07:00 | Sonnet 5.5 |
| Continuous improvement agent | `SP_RUN_AGENT('improvement')` | Sun 09:00 | Opus 5.5 |
| Supervisor | `SP_RUN_AGENT('supervisor')`, `('supervisor','digest')` on Sundays | daily 07:00, Sun 09:00 | Sonnet 5.5 / Opus 5.5 (digest) |
| Tasks | `TASK_OPS_DAILY`, `TASK_OPS_FRI`, `TASK_OPS_SAT`, `TASK_OPS_WEEKLY` | as above | — |
| Control plane, read | Snowsight dashboard **Grocery Ops** (tile SQL in `Agent/ops/dashboard_tiles.sql`) over `GROCERY_OPS.*` and the semantic view `GROCERY_OPS.SV_OPS` | on open | — |
| Control plane, ask / change | Cortex Agent `GROCERY_OPS.GROCERY_OPS_AGENT` (Snowflake Intelligence); six mirror objects `GROCERY_OPS.AGENT_<DOMAIN>` on the Snowsight **AI & ML › Agents** page, kept in sync by `SP_SYNC_AGENT_OBJECTS()` | on demand | Sonnet 5.5 |
| Independent watcher | AWS Lambda `grocery-ops-watcher` → SNS `grocery-ops-alerts` → Proton (deployed 2026-11-15; `Orchestration/ops-watcher/`) | daily 09:00 | — |
| Scheduler alarm | CloudWatch `grocery-ingest-friday-never-started`: no EventBridge Scheduler attempt for 7 days → same SNS topic | continuous | — |

All of it runs as `GROCERY_OPS_ROLE` on `GROCERY_OPS_WH` (X-Small, 60 s
auto-suspend) under `GROCERY_OPS_MONITOR` (2 credits/month). Scripts, in run
order: `Snowflake Scripts/Ops/01_ops_schema.sql` (role, warehouse, monitors,
tables, seeds), `02_ops_sensors.sql`, `03_ops_agents.sql`, `04_ops_alerts.sql`, `05_ops_watcher.sql`
(Snowflake side of the AWS watcher, prod only), `06_control_plane.sql` (semantic
view, control-plane agent, agent mirrors).
Each has a `sed` line in its header for the sandbox schema `GROCERY_DEV_OPS`.

## What each agent checks (the sensors behind it)

**Ingestion** — `run_missing` / `run_failed` (expected Friday 17:00 and
Saturday 09:00 runs vs `JOB_PERFORMANCE.ORCHESTRATION_JOB_RUNS`; a slot with
no row 10 h later is CRIT — this is the check that would have caught the Oct
17 – Nov 14 outage on day one), `kroger_store_coverage` (81 stores; Friday
phase ~44), `kroger_row_volume` / `walmart_row_volume` (vs 4-week median),
`pipe_not_running` (7 Snowpipes), `seasonal_file_missing` (in season only).

**Quality** — `source_freshness` (> 8 d warn, > 10 d crit), `price_outliers`
(≤ 0, > 50× the store's trailing median, > 5× last week), `promo_ge_regular`
share, `null_spike` on key columns (Walmart's 15–20 % no-price rows are
normal and excluded), `duplicate_rows`, `mart_integrity` (SQL ports of the
critical dbt tests), `parse_confidence_drift`, `forecast_sanity`.

**Cost** — `warehouse_daily_spike` and `service_daily_spike` (yesterday vs
28-day p90; Trust Center, Cortex and Snowpipe are services), `monthly_projection`
(per quota: total 20, COMPUTE 8, agent+ML 10, ops 2), `resource_monitor_used`,
`agent_token_budget` (the ops agents' own tokens).

**Performance** — `task_failed_or_missed` (incl. the Sunday forecast slot),
`dt_refresh_failed` and `dt_lag` (dynamic tables), `agent_wh_queueing`,
`agent_latency_p95`, `search_stale`, `eval_score` (from `AGENT_RUN_LOG`,
written by `Agent/evals/run_evals.py`), `feedback_low`.

**Supervisor** — `component_silent` (any registry component with a schedule
and no `OPS_RUN` within 1.5× its interval) plus everything above.

**Continuous improvement** — no sensors of its own; reads 28 days of metrics,
the registry and the runbook, proposes ≤ 3 changes a week with the arithmetic.

## Severity and what to do

- **CRIT** — an SLO is breached or data can be lost: a run missing, a pipe
  stopped, a task failed, a monitor ≥ 90 %, projection ≥ 100 % of quota.
  Expect an email within the hour (alerts) or at the next agent run. Act
  within a business day; the email names the runbook action.
- **WARN** — budget burning or quality drifting. Comes in the next agent
  email; no action needed the same day.
- **INFO** — recorded, never emailed.

Emails are `[grocery-ops][<domain>][<severity>] <date>`. Quiet domains send
nothing; the Sunday digest `[grocery-ops][supervisor][DIGEST]` always sends —
**a Monday morning without it means the ops layer itself is down.**

Known failure modes and their fixes are rows in `GROCERY_OPS.OPS_RUNBOOK`
(scheduler drop, pipe stopped, Kroger budget collision, Walmart 429, stale
dynamic table, failed forecast task, stale search, cost spike). Add a row
when you learn a new one; the agents read the table.

## The control plane (native Snowflake, since 2026-11-15)

The Streamlit Operations tab was retired the same day; nothing of ours sits
between you and the ops tables.

- **Dashboard** — Snowsight › Projects › Dashboards › *Grocery Ops*. Nine
  tiles (scorecards, registry, open findings, budget per monitor, credits per
  warehouse per day, recent runs, model policy, agent tokens by model, latest
  supervisor report). Snowsight has no DDL for dashboards, so the tile SQL
  lives in `Agent/ops/dashboard_tiles.sql`; build it once by pasting each
  block. Leave auto-refresh off (eight X-Small queries per open is the cost).
- **Ask** — `GROCERY_OPS.GROCERY_OPS_AGENT` in Snowflake Intelligence (or the
  Agents page chat): "did every agent run this week", "what is open",
  "credits vs the 20 ceiling", "what did the supervisor say". It answers
  through Cortex Analyst over the semantic view `SV_OPS` (components, runs,
  findings, checks, model policy, daily metrics, SLOs) plus the runbook and
  metric-history tools.
- **Change** — the same agent holds `set_model_policy`, `set_check` and
  `acknowledge_finding`, which call the audited procedures below. It is
  instructed to write only when you explicitly ask, to restate the change and
  to require a reason; that is a human-initiated action, so it stays inside
  the notify-only rule. The scheduled agents never get these tools.
- **Inventory** — Snowsight › AI & ML › Agents lists `GROCERY_OPS_AGENT`,
  the shopper agent and the six mirrors `AGENT_INGESTION … AGENT_SUPERVISOR`.
  A mirror is built from its `AGENT_REGISTRY` row and `MODEL_POLICY` by
  `SP_SYNC_AGENT_OBJECTS()`; the registry stays the source of truth and the
  scheduled runs still go through `SP_RUN_AGENT`. Each mirror can be
  test-driven in its chat with the three read-only tools.

## Changing things (all audited in `CONFIG_AUDIT`)

- **Model for a task**: `CALL GROCERY_OPS.SP_SET_MODEL_POLICY('ops_cost', 'claude-sonnet-5-5', 'why')`
  or ask `GROCERY_OPS_AGENT`: "switch the cost agent to haiku because …" (it calls the
  same procedure). Takes effect on the next run. Then `CALL GROCERY_OPS.SP_SYNC_AGENT_OBJECTS()`
  so the Snowsight mirror shows the new model. Each row has a
  fallback model and a monthly token budget; `ENABLED = FALSE` is the per-agent
  kill switch.
- **Threshold or silence a check**: `CALL GROCERY_OPS.SP_SET_CHECK('walmart_row_volume', 'why', WARN_THRESHOLD => 60)`;
  `ENABLED => FALSE` disables; `SUPPRESS_HOURS` controls re-raising.
- **Acknowledge a finding**: `CALL GROCERY_OPS.SP_ACK_EVENT('<event_id>', 'note')`.
- **Agent instructions**: edit `Agent/ops/prompts/<agent>.md`, bump the
  version, copy into `03_ops_agents.sql`, run the sandbox variant, run the
  ops golden set (to be added under `Agent/ops/evals/`), then prod, then
  `CALL GROCERY_OPS.SP_SYNC_AGENT_OBJECTS()`.
- **A new check**: a `V_CHECK_<name>` view with the standard columns plus a
  row in `OPS_CHECK`; nothing else changes.
- Every change: sandbox (`GROCERY_DEV_OPS`) → PR `dev` → `main` with the
  verification pasted in → apply in prod. Agents and tasks never run
  `CREATE OR REPLACE`.

## Verifying the layer itself

- Run `CALL GROCERY_OPS.SP_RUN_SENSORS('all')` and read the JSON; every
  check appears either in `findings` or `ok_checks`.
- `SELECT * FROM GROCERY_OPS.V_REGISTRY_STATUS WHERE IS_SILENT` must be empty.
- Fire an alert by hand: `EXECUTE ALERT GROCERY_OPS.ALERT_BUDGET`, then check
  `INFORMATION_SCHEMA.ALERT_HISTORY` and your inbox.
- The regression that must always pass: in a sandbox copy with history,
  `V_CHECK_EXPECTED_RUNS` shows the Oct 16 – Nov 14 2026 slots as `run_missing`.
- Quarterly drill (`Agent/ops/drills.md`, to be written): suspend a sandbox
  pipe, skip a heartbeat, inject a cost spike, confirm the expected emails.

## Backup and recovery

Standard edition caps Time Travel at 1 day, so recovery is: S3 raw files are
the system of record (`s3://grocerydbtprojectrawdata`, versioning on) →
re-COPY through the pipes → `dbtg build --target dev --full-refresh` rebuilds
every mart. `GROCERY_OPS` tables are rebuildable from the scripts; events
and runs are history, not state the product depends on.

## Not done yet (as of 2026-11-15)

- Build the Snowsight dashboard once from `dashboard_tiles.sql`.
  (`GROCERY_OPS_AGENT` was added to Snowflake Intelligence on 2026-11-15 with
  `ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT ADD AGENT …`;
  the same line is in `06_control_plane.sql`.)
- A second CloudWatch alarm on `AWS/Scheduler TargetErrorCount ≥ 1` (would have
  caught the Oct 15 – Nov 13 failures on day one; needs one more alarm name in
  `Orchestration/ops-watcher/iam-deployer-policy.json`).
- `03_autonomy.sql` (month 2) and `Agent/ops/evals/` (ops golden set).
- `01_governance.sql` section 5 — dbt still runs as ACCOUNTADMIN; required
  before any autonomy is enabled.
- `record_run.py` Fargate minutes; `__sources.yml` freshness thresholds.
