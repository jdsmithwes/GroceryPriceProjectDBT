# Orchestration

Weekly scheduled ingestion for Kroger pricing + Walmart product catalog,
running as an ECS Fargate task triggered by EventBridge Scheduler.
Originally built 2026-08-23 for Kroger + Aldi; Aldi (never got a working
API host — see git history for D12) and Publix (never live-verified) were
removed from the whole project 2026-09-01, and Walmart (auth resolved
2026-08-31) took Aldi's place as the second leg.

**Status**: both legs proven working. Kroger's has run live repeatedly
since 2026-08-23. Walmart's ingestion script, Snowflake landing table, and
the container's key-delivery mechanism were all verified working
2026-09-01 (see below) before being wired into the schedule.

**New since 2026-09-01**: every run of every source now writes a
success/failure manifest to Snowflake (`JOB_PERFORMANCE.ORCHESTRATION_JOB_RUNS`)
— see "Job run history" below. Previously the only way to check "did last
Friday's run actually succeed" was a CloudWatch log dive.

## Why this over Airflow / Fivetran / GitHub Actions

- **Fivetran** doesn't fit — it's a managed ELT tool for known connectors,
  not a runner for arbitrary scraping scripts, and its free tier is far
  below the row volume this project already produces.
- **Airflow** is the right tool for many interdependent pipelines needing
  backfill/observability at team scale. Two independent scripts on a
  weekly cron don't need that, and self-hosting reliably costs more in
  upkeep than the job itself — managed Airflow (MWAA) starts around
  $350+/month.
- **GitHub Actions** was ruled out by explicit preference (2026-08-23),
  despite being the simplest/cheapest option on paper.
- **Snowflake Tasks** (considered 2026-09-01, when adding Walmart) can
  only run SQL/Snowpark inside Snowflake — Kroger and Walmart's ingestion
  scripts make external authenticated API calls (OAuth2, RSA-signed
  requests) with local crypto and threaded rate-limiting. Porting that
  into Snowpark would mean rewriting and re-verifying both codebases for
  no real benefit over extending the already-working Fargate pipeline.
- **EventBridge Scheduler + Fargate**: no always-on server, pay only for
  the ~20-60 min/week this actually runs (a few cents/month), stays inside
  AWS where the rest of this project already lives, and EventBridge
  Scheduler's `ScheduleExpressionTimezone` handles the EST/EDT switch
  automatically — "5pm ET" stays 5pm local year-round with no extra logic.

## Why two schedules, not one

A full refresh of all 81 Kroger stores needs ~17,739 API calls (same cost
as the original backfill — fetching current price isn't cheaper the 2nd
time). Kroger's budget is 10,000/day. **One trigger cannot refresh all 81
stores in a single run**, full stop, regardless of what schedules it.
Walmart has no equivalent multi-day budget constraint (its category-scoped
pull is capped by `MAX_PAGES_PER_FILTER`, currently 500 pages, comfortably
inside one run), so it only needs to run once a week — bundled into the
Friday trigger rather than getting a schedule of its own.

- **`grocery-ingest-friday-full`** — Friday 5pm ET. Resets the Kroger
  pricing checkpoint (`--reset-checkpoint`, see
  `Kroger_Pricing_2026-08-10.py`) and runs Kroger, then Walmart. Kroger
  gets through ~45 of 81 stores before hitting the daily budget; Walmart's
  category-scoped pull (Food department, id `976759`) runs to completion
  in one go.
- **`grocery-ingest-saturday-continue`** — Saturday 9am ET. Runs Kroger
  again *without* resetting — the existing resumable checkpoint logic
  picks up the remaining ~36 stores automatically. Walmart doesn't need a
  continuation leg since its Friday run already completes.

Net effect: "weekly" Kroger data is fully current within about a day of
the Friday trigger, not instantaneously at 5pm Friday — the honest
tradeoff for refreshing 81 stores under Kroger's own rate limit. Walmart's
data is current the moment the Friday run finishes.

## Architecture

```
EventBridge Schedule (cron, America/New_York timezone)
  -> assumes GroceryIngestSchedulerRole
  -> ecs:RunTask on grocery-ingest-cluster, task def grocery-ingest:2
       (RUN_MODE passed as a per-schedule container environment override —
       NOT baked into the image, so one image serves both schedules)
  -> Fargate launches the task, assumes GroceryIngestTaskExecutionRole
       -> pulls image from ECR (573509103721.dkr.ecr.us-east-1.amazonaws.com/grocery-ingest)
       -> injects KROGER_CLIENT_ID/KROGER_CLIENT_SECRET/AWS_ACCESS_KEY_ID/
          AWS_SECRET_ACCESS_KEY/WALMART_PRIVATE_KEY_PEM from Secrets Manager
          (see "Secrets" below); WALMART_CONSUMER_ID/WALMART_KEY_VERSION
          are plain (non-secret) environment values
       -> writes logs to CloudWatch (/ecs/grocery-ingest)
  -> entrypoint.sh branches on RUN_MODE, runs each source via its
       run_source wrapper (times it, catches its exit code instead of
       letting a hard failure kill the rest of the task, calls
       record_run.py with the outcome either way)
       -> boto3 inside the container picks up AWS_ACCESS_KEY_ID/SECRET
          from env automatically (no task role needed — static creds
          from the same secret, same pattern the scripts already use
          locally via the default credential chain)
       -> ingestion output lands in S3 same as any manual run
       -> record_run.py writes one JSON manifest per source to
          s3://grocerydbtprojectrawdata/orchestration_runs/
       -> Snowpipe auto-ingests both the raw data (see
          Snowflake Scripts/Kroger Raw Data/) and the run manifests (see
          Snowflake Scripts/Orchestration/job_runs_ingestion_pipeline.sql)
          -- nothing about the Snowflake side changes for a scheduled vs.
          manual run.
```

## Secrets — how Walmart's private key gets into the container

The four original secrets (`KROGER_CLIENT_ID`, `KROGER_CLIENT_SECRET`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) live as JSON keys inside one
Secrets Manager secret, `grocery-ingest/credentials`. Walmart's RSA
private key is a multi-line PEM file locally
(`~/credentials/walmart/WM_IO_private_key_20260831v2.pem`), not a simple
string — and `jdsmithwes` cannot `GetSecretValue` on the existing secret
(confirmed 2026-09-01, `AccessDeniedException`), so there was no safe way
to read-modify-merge a new key into it without risking overwriting the
AWS credentials with something wrong. Instead of touching that secret at
all, the PEM content was pushed to a **new**, separate secret,
`grocery-ingest/walmart-key` (plain string value, no JSON wrapping).
This did turn out to need a new IAM grant, not zero — see the IAM
section below (item 3): `GroceryIngestTaskExecutionRole`'s actual
`secretsmanager:GetSecretValue` policy was scoped specifically to
`grocery-ingest/credentials-*`, not a broader `grocery-ingest/*`, so
the first `test_infra` run against the new secret failed with
`AccessDeniedException` until the policy's `Resource` was manually
widened via the console. `entrypoint.sh` writes that env var's content to
`/app/walmart_key.pem` at container startup and sets `WALMART_KEY_PATH`
to point at it — `entire_productcatalog_walmart.py` itself needed zero
code changes, since it already just reads `WALMART_KEY_PATH` from the
environment.

`WALMART_CONSUMER_ID` and `WALMART_KEY_VERSION` aren't sensitive (same
category as `AWS_REGION`) and are set as plain `environment` entries in
`task-definition.json`, not `secrets`.

## Job run history

Every source, on every run, writes a manifest via `record_run.py`
(`--source --run-mode --status --started-at --completed-at [--error]`) to
`s3://grocerydbtprojectrawdata/orchestration_runs/`, auto-ingested into
`GROCERYDBTPROJECT.JOB_PERFORMANCE.ORCHESTRATION_JOB_RUNS` — unlike the raw
API landing tables (deliberately all-VARCHAR against schema drift from
external payloads), this table has real types since its shape is fully
first-party. Query it directly:

```sql
SELECT * FROM GROCERYDBTPROJECT.JOB_PERFORMANCE.ORCHESTRATION_JOB_RUNS
ORDER BY started_at DESC;
```

`rows_collected` exists as a nullable column but isn't populated yet —
getting an exact count back from each ingestion script into the shell
adds real complexity for a metric `COPY_HISTORY`/dbt already surface
downstream; add it later if actually wanted.

DDL: `Snowflake Scripts/Orchestration/job_runs_ingestion_pipeline.sql`.

## IAM — what had to be granted, and why (read before touching any of this)

`jdsmithwes` was provisioned narrowly (S3 only) before this pipeline
existed. Getting this working required, **in this order** (each discovered
by hitting a real `AccessDenied`, not anticipated up front):

1. Two new roles, created manually via the AWS console (`jdsmithwes`
   cannot create/update IAM roles or policies at all, confirmed via
   `iam:SimulatePrincipalPolicy` — AccessDenied):
   - `GroceryIngestTaskExecutionRole` (trust: `ecs-tasks.amazonaws.com`) —
     `AmazonECSTaskExecutionRolePolicy` + inline `secretsmanager:GetSecretValue`
     scoped, as originally created, to just `grocery-ingest/credentials-*`
     (narrower than it looked — see item 3).
   - `GroceryIngestSchedulerRole` (trust: `scheduler.amazonaws.com`) —
     inline `ecs:RunTask` scoped to the `grocery-ingest` task definition
     family + `iam:PassRole` scoped to `GroceryIngestTaskExecutionRole`.
2. `jdsmithwes` itself turned out to have **zero** access to ECR, ECS, or
   EventBridge Scheduler — not a scoping issue, those permissions simply
   didn't exist for this user. Attached `AmazonECS_FullAccess`,
   `AmazonEC2ContainerRegistryFullAccess`, `AmazonEventBridgeSchedulerFullAccess`,
   plus one inline policy for `iam:PassRole` on both new roles (never
   bundled into a full-access policy on purpose, by AWS design).
3. `jdsmithwes` could `secretsmanager:ListSecrets` and `CreateSecret`
   (scoped to `grocery-ingest/*`) but not `GetSecretValue` — confirmed
   both on the original `grocery-ingest/credentials` secret, and again
   2026-09-01 in a more specific way: adding the new
   `grocery-ingest/walmart-key` secret (see "Secrets" above) revealed
   `GroceryIngestTaskExecutionRole`'s own `GetSecretValue` policy was
   scoped to `grocery-ingest/credentials-*` specifically, not a
   `grocery-ingest/*` wildcard as assumed — the first `test_infra` run
   against the new secret failed with `AccessDeniedException`, and
   `jdsmithwes` couldn't `iam:PutRolePolicy` to fix its own role's policy
   (confirmed via direct attempt — `AccessDenied`, consistent with item 1
   above's read-only-not-write IAM access). Required a manual console
   edit of the role's inline policy to add
   `arn:aws:secretsmanager:us-east-1:573509103721:secret:grocery-ingest/walmart-key-*`
   to the `Resource` array. **Lesson**: a policy `Resource` pattern that
   looks like a prefix wildcard from the outside (`grocery-ingest/*`,
   inferred from `ListSecrets`/`CreateSecret` access) doesn't mean
   `GetSecretValue` uses the same pattern — check the actual role policy
   (`aws iam get-role-policy`, which `jdsmithwes` CAN read even though it
   can't write) before assuming a new same-prefix secret is covered.
4. `jdsmithwes` cannot `logs:GetLogEvents` — **fixed 2026-08-23** (same day,
   `CloudWatchLogsReadOnlyAccess` attached). `logs:PutRetentionPolicy` is
   still missing — low-stakes, just means the log group never expires.

**Lesson for next time a new AWS service gets wired into this project**:
assume `jdsmithwes` has *no* access to it until proven otherwise — don't
assume "can do X" generalizes to "can do X-adjacent-thing," each AWS
service's permission was independently absent here.

## Operating this

- **Manually trigger the same run a schedule would**: `aws ecs run-task`
  with `--task-definition grocery-ingest:2` and a container environment
  override setting `RUN_MODE` to `friday_full` or `saturday_kroger_continue`
  — see `friday-schedule.json`/`saturday-schedule.json` for the exact
  network configuration to reuse.
- **Retry just Walmart without touching Kroger**: `RUN_MODE=walmart_only`
  — re-running the whole `friday_full` mode just to retry Walmart would
  also reset and re-burn the Kroger checkpoint for no reason. (Replaces
  the old `aldi_only` mode from when Aldi was still part of this project.)
- **Verify the pipeline without spending API budget**: same, but
  `RUN_MODE=test_infra` — confirms secrets injection, AWS auth, Walmart
  key delivery (writes the file, checks it exists on disk), and S3
  reachability without touching Kroger or Walmart. Safe to run anytime.
- **After changing any ingestion script or `entrypoint.sh`/`record_run.py`**:
  rebuild and push, from the repo root:
  ```bash
  docker build --platform linux/amd64 -f Orchestration/Dockerfile -t grocery-ingest:latest .
  docker tag grocery-ingest:latest 573509103721.dkr.ecr.us-east-1.amazonaws.com/grocery-ingest:latest
  aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 573509103721.dkr.ecr.us-east-1.amazonaws.com
  docker push 573509103721.dkr.ecr.us-east-1.amazonaws.com/grocery-ingest:latest
  ```
  Both schedules reference the task definition's `:latest` image tag
  indirectly via the container definition's `image` field — no need to
  re-register the task definition or touch the schedules for a code-only
  change, just rebuild/push. (Registering a **new task definition
  revision** — e.g. adding/changing an env var or secret — does require
  updating both schedules' `TaskDefinitionArn`, since they pin an explicit
  revision number rather than floating on the family. Done via
  `aws scheduler update-schedule --name <name> --cli-input-json file://<schedule>.json`
  after editing the JSON.)
- **`task-definition.json`, `friday-schedule.json`, `saturday-schedule.json`**
  in this folder are the exact specs used to create/update these
  resources — treat them as the source of truth if anything needs
  recreating, same convention as the `.sql` files under `Snowflake Scripts/`.
- **One-off triggers outside the regular weekly cadence**: don't just
  `run-task` and hope you remember to finish it manually — create a
  single-fire EventBridge Schedule instead, same `Target` shape as the two
  recurring ones but `"ScheduleExpression": "at(YYYY-MM-DDTHH:MM:SS)"` and
  `"ActionAfterCompletion": "DELETE"` so it cleans itself up after firing
  once. Proven 2026-08-23 for a manual Kroger reset-and-resweep.

## Resources this created (for teardown/reference)

| Resource | Name |
|---|---|
| IAM roles | `GroceryIngestTaskExecutionRole`, `GroceryIngestSchedulerRole` |
| Secrets Manager secrets | `grocery-ingest/credentials`, `grocery-ingest/walmart-key` |
| ECR repository | `grocery-ingest` |
| ECS cluster | `grocery-ingest-cluster` |
| ECS task definition | `grocery-ingest` (revision 2 — Walmart added 2026-09-01) |
| CloudWatch log group | `/ecs/grocery-ingest` (no retention policy set — `logs:PutRetentionPolicy` gap, logs never expire) |
| EventBridge Schedules | `grocery-ingest-friday-full`, `grocery-ingest-saturday-continue` |
| S3 prefixes read by this pipeline | `s3://grocerydbtprojectrawdata/{kroger,walmart,orchestration_runs}/` |
