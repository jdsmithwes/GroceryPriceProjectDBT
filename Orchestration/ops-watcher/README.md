# Independent ops watcher (AWS) — not yet deployed

Purpose: one daily check from outside Snowflake that the ops supervisor ran in
the last 26 hours; SNS email to Proton if not, or if Snowflake is unreachable.
Part of the enterprise controls in the ops plan (control 2). Code:
`handler.py`. Cost: one Lambda invocation a day + one secret ≈ $0.50/month.

## Snowflake side (run as ACCOUNTADMIN; add to `Snowflake Scripts/Ops/01_ops_schema.sql` when deployed)

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

## AWS side (owner; the current IAM user lacks these permissions)

1. Secrets Manager secret `grocery/ops-watcher` (JSON): `{"account": "<org-account>", "user": "SVC_OPS_WATCHER", "private_key_pem": "<watcher.p8 contents>", "warehouse": "GROCERY_OPS_WH"}`.
2. SNS topic `grocery-ops-alerts`; subscribe `owner@example.com` and confirm.
3. Lambda `grocery-ops-watcher`: Python 3.12, 256 MB, 60 s timeout, env `SECRET_ID=grocery/ops-watcher`, `SNS_TOPIC_ARN=<arn>`, `MAX_SILENCE_HOURS=26`; layer or bundle with `PyJWT` and `cryptography`; execution role: `secretsmanager:GetSecretValue` on that secret, `sns:Publish` on that topic, basic logs.
4. EventBridge Scheduler: `cron(0 9 * * ? *)` in `America/New_York` → the Lambda (reuse the pattern in `../friday-schedule.json`; add a DLQ).
5. Test: `aws lambda invoke --function-name grocery-ops-watcher out.json` → `{"ok": true, ...}`; then suspend `TASK_OPS_DAILY` for a day in sandbox-equivalent fashion or set `MAX_SILENCE_HOURS=0` once to see the email arrive.

IAM needed by the deploying identity: `lambda:*` on this function, `iam:CreateRole/PassRole` for its execution role, `secretsmanager:CreateSecret`, `sns:CreateTopic/Subscribe`, `scheduler:CreateSchedule`.

## The matching CloudWatch alarm (Friday job never started)

`cloudwatch-friday-alarm.json` defines an alarm on the `AWS/Scheduler`
metric `InvocationAttemptCount` for `grocery-ingest-friday-full`: if the
Friday 17:00 ET window passes with zero attempts, SNS emails Proton. Create
with `aws cloudwatch put-metric-alarm --cli-input-json file://cloudwatch-friday-alarm.json`
after the SNS topic exists (needs `cloudwatch:PutMetricAlarm`).
