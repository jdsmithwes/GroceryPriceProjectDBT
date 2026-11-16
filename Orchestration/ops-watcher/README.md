# Independent ops watcher (AWS) — deployed 2026-11-15

Deployed in us-east-1: Lambda `grocery-ops-watcher` (python3.12, x86_64, 256 MB,
60 s; code zip built from `handler.py` + PyJWT + cryptography wheels, uploaded
via `s3://grocerydbtprojectrawdata/ops-watcher/`), roles
`grocery-ops-watcher-lambda-role` / `grocery-ops-watcher-scheduler-role`,
secret `grocery/ops-watcher`, SNS topic `grocery-ops-alerts` (Proton confirmed),
EventBridge schedule `grocery-ops-watcher` (`cron(0 9 * * ? *)` America/New_York,
DLQ `grocery-ingest-dlq`), CloudWatch alarm `grocery-ingest-friday-never-started`.
Snowflake side: `Snowflake Scripts/Ops/05_ops_watcher.sql` (view, role, service
user `SVC_OPS_WATCHER`; key pair in `~/.snowflake/ops_watcher_rsa_key.{p8,pub}`).
Tested: healthy invoke `{"ok": true}`; with `MAX_SILENCE_HOURS=0` the CRIT email
arrived at Proton; env restored to 26. Deployer IAM: `iam-deployer-policy.json`
(can be detached now; the runtime roles are separate).

**Scheduler finding (2026-11-15)**: `AWS/Scheduler` metrics carry only a
`ScheduleGroup` dimension, never `ScheduleName`, so the alarm watches the whole
`default` group. The metrics also show the Oct 15 – Nov 13 outage was *not*
Scheduler dropping the schedule: every Friday/Saturday slot had
`InvocationAttemptCount = 1` with `TargetErrorCount = 1` and
`InvocationDroppedCount = 1`, i.e. ECS `RunTask` was rejected each time and the
event was dropped for lack of a DLQ. A `TargetErrorCount ≥ 1` alarm would have
caught it on day one; add it once the deployer policy allows a second alarm name.

Purpose: one daily check from outside Snowflake that the ops supervisor ran in
the last 26 hours; SNS email to Proton if not, or if Snowflake is unreachable.
Part of the enterprise controls in the ops plan (control 2). Code:
`handler.py`. Cost: one Lambda invocation a day + one secret ≈ $0.50/month.

## Snowflake side (done; kept here for reference — the maintained copy is `Snowflake Scripts/Ops/05_ops_watcher.sql`)

```sql
-- the only thing the watcher may read
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_WATCHER_HEARTBEAT AS
SELECT ROUND(TIMESTAMPDIFF(minute, MAX(STARTED_AT), CURRENT_TIMESTAMP()) / 60.0, 1) AS HOURS_SINCE_SUPERVISOR,
       MAX(STARTED_AT) AS LAST_SUPERVISOR_RUN, MAX_BY(STATUS, STARTED_AT) AS LAST_STATUS
FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUN WHERE AGENT_NAME = 'agent_supervisor';

CREATE ROLE IF NOT EXISTS GROCERY_OPS_WATCHER COMMENT = 'Read one heartbeat view; nothing else';
GRANT USAGE ON DATABASE GROCERYDBTPROJECT TO ROLE GROCERY_OPS_WATCHER;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_OPS TO ROLE GROCERY_OPS_WATCHER;
GRANT SELECT ON VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_WATCHER_HEARTBEAT TO ROLE GROCERY_OPS_WATCHER;
GRANT USAGE ON WAREHOUSE GROCERY_OPS_WH TO ROLE GROCERY_OPS_WATCHER;
-- generate the key pair locally: openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out watcher.p8 -nocrypt
--                                 openssl rsa -in watcher.p8 -pubout -out watcher.pub
CREATE USER IF NOT EXISTS SVC_OPS_WATCHER TYPE = SERVICE DEFAULT_ROLE = GROCERY_OPS_WATCHER
    RSA_PUBLIC_KEY = '<contents of watcher.pub without the BEGIN/END lines>';
GRANT ROLE GROCERY_OPS_WATCHER TO USER SVC_OPS_WATCHER;
```

## AWS side (done 2026-11-15 from Claude Code after `iam-deployer-policy.json` was attached)

1. Secrets Manager secret `grocery/ops-watcher` (JSON): `{"account": "<org-account>", "user": "SVC_OPS_WATCHER", "private_key_pem": "<watcher.p8 contents>", "warehouse": "GROCERY_OPS_WH"}`.
2. SNS topic `grocery-ops-alerts`; subscribe the owner's email and confirm.
3. Lambda `grocery-ops-watcher`: Python 3.12, 256 MB, 60 s timeout, env `SECRET_ID=grocery/ops-watcher`, `SNS_TOPIC_ARN=<arn>`, `MAX_SILENCE_HOURS=26`; layer or bundle with `PyJWT` and `cryptography`; execution role: `secretsmanager:GetSecretValue` on that secret, `sns:Publish` on that topic, basic logs.
4. EventBridge Scheduler: `cron(0 9 * * ? *)` in `America/New_York` → the Lambda (reuse the pattern in `../friday-schedule.json`; add a DLQ).
5. Test: `aws lambda invoke --function-name grocery-ops-watcher out.json` → `{"ok": true, ...}`; then suspend `TASK_OPS_DAILY` for a day in sandbox-equivalent fashion or set `MAX_SILENCE_HOURS=0` once to see the email arrive.

IAM needed by the deploying identity: see `iam-deployer-policy.json` (one customer-managed policy, scoped to the named resources only; attach it to the `jdsmithwes` IAM user from the console as root or an admin, then the deploy can be run from Claude Code). Remove it after deployment if you prefer.

## The matching CloudWatch alarm (Friday job never started)

`cloudwatch-friday-alarm.json` defines an alarm on the `AWS/Scheduler`
metric `InvocationAttemptCount` for schedule group `default` (there is no
per-schedule dimension): 7 consecutive daily periods with no attempt means the
weekly schedules stopped firing, and SNS emails Proton. A new alarm starts in
ALARM (missing data is breaching) and settles to OK at its first evaluation
with data; OK transitions send nothing. Create
with `aws cloudwatch put-metric-alarm --cli-input-json file://cloudwatch-friday-alarm.json`
after the SNS topic exists (needs `cloudwatch:PutMetricAlarm`).
