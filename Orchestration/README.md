# Orchestration

Weekly scheduled ingestion for Kroger pricing + Aldi catalog, running as an
ECS Fargate task triggered by EventBridge Scheduler. Built 2026-08-23.

**Status**: infrastructure proven, Aldi leg not yet. Built and verified
via a diagnostic `test_infra` run the same day (2026-08-23), then a real
manual `friday_full` trigger the same day exercised the actual pipeline
end to end. **Kroger's half worked cleanly** — checkpoint reset, 45/81
stores swept, matches every prior run's behavior exactly. **Aldi's half
failed** — its first-ever live attempt hit a DNS resolution error on
`api.aldi.us` (`No address associated with hostname`) on both the store
lookup and the catalog fetch, zero rows collected. Not yet re-tried or
root-caused (transient network blip in that Fargate task vs. something
persistent — genuinely unknown right now). Treat Aldi as still
mocked-payloads-only, not "verified live," despite the attempt. A one-off
`at()` schedule (`ActionAfterCompletion: DELETE`) picked up the Kroger
continuation the next day outside the regular Friday/Saturday cadence —
see "one-off triggers" below.

## Why this over Airflow / Fivetran / GitHub Actions

- **Fivetran** doesn't fit — it's a managed ELT tool for known connectors,
  not a runner for arbitrary scraping scripts, and its free tier is far
  below the row volume this project already produces.
- **Airflow** is the right tool for many interdependent pipelines needing
  backfill/observability at team scale. Three independent scripts on a
  weekly cron don't need that, and self-hosting reliably costs more in
  upkeep than the job itself — managed Airflow (MWAA) starts around
  $350+/month.
- **GitHub Actions** was ruled out by explicit preference (2026-08-23),
  despite being the simplest/cheapest option on paper.
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

- **`grocery-ingest-friday-full`** — Friday 5pm ET. Resets the Kroger
  pricing checkpoint (`--reset-checkpoint`, see
  `Kroger_Pricing_2026-08-10.py`) and runs Kroger + Aldi. Gets through
  ~45 of 81 Kroger stores before hitting the daily budget; Aldi (~6 min,
  no checkpoint needed) has no daily-budget reason to not finish in one
  run, but its first live attempt (2026-08-23) failed on a DNS error
  before collecting anything — see the Status note above. Don't assume
  Aldi's leg is reliable until that's actually re-verified.
- **`grocery-ingest-saturday-continue`** — Saturday 9am ET. Runs Kroger
  again *without* resetting — the existing resumable checkpoint logic
  picks up the remaining ~36 stores automatically. This is the same
  logic that already handles a same-day interruption; running it a
  second calendar day later works identically.

Net effect: "weekly" data is fully current within about a day of the
Friday trigger, not instantaneously at 5pm Friday — the honest tradeoff
for refreshing 81 stores under Kroger's own rate limit.

**Publix is deliberately not in either schedule yet.** `PUBLIX_CONFIG` in
`adapters.py` is unverified against a live endpoint. Scheduling it
unattended risks silently ingesting wrong data with no one watching. Add
it to the `friday_full` case in `entrypoint.sh` once
`python adapters.py probe publix --zip 30080` has been run and the config
fixed — see `API Scripts/Aldi Publix Scripts/DECISIONS.md`.

## Architecture

```
EventBridge Schedule (cron, America/New_York timezone)
  -> assumes GroceryIngestSchedulerRole
  -> ecs:RunTask on grocery-ingest-cluster, task def grocery-ingest:1
       (RUN_MODE passed as a per-schedule container environment override —
       NOT baked into the image, so one image serves both schedules)
  -> Fargate launches the task, assumes GroceryIngestTaskExecutionRole
       -> pulls image from ECR (573509103721.dkr.ecr.us-east-1.amazonaws.com/grocery-ingest)
       -> injects KROGER_CLIENT_ID/KROGER_CLIENT_SECRET/AWS_ACCESS_KEY_ID/
          AWS_SECRET_ACCESS_KEY from Secrets Manager (grocery-ingest/credentials)
       -> writes logs to CloudWatch (/ecs/grocery-ingest)
  -> entrypoint.sh branches on RUN_MODE, runs the real scripts
       -> boto3 inside the container picks up AWS_ACCESS_KEY_ID/SECRET
          from env automatically (no task role needed — static creds
          from the same secret, same pattern the scripts already use
          locally via the default credential chain)
       -> uploads land in S3 same as any manual run
       -> Snowpipe auto-ingests, same as any manual run (see
          Snowflake Scripts/Aldi Publix Raw Data/ and
          Snowflake Scripts/Kroger Raw Data/) -- nothing about the
          Snowflake side changes for a scheduled vs. manual run.
```

## Why static AWS credentials via Secrets Manager, not an ECS task role

The more standard AWS pattern is a task role the container assumes for its
own API calls (temporary, auto-rotated credentials). Deliberately not done
here: `jdsmithwes` cannot modify IAM roles after creation (see the IAM
gotchas below), so adding S3 permissions to an existing role after the
fact wasn't possible without another manual console step. Reusing the same
Secrets Manager secret that already holds the Kroger credentials — adding
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` alongside them — sidesteps
that entirely and matches how the scripts already authenticate to AWS
locally (default boto3 credential chain, not an assumed role). Tradeoff:
static long-lived keys in Secrets Manager rather than short-lived role
credentials — acceptable here since it's the same keys already used
everywhere else in this project, not a new credential surface.

## IAM — what had to be granted, and why (read before touching any of this)

`jdsmithwes` was provisioned narrowly (S3 only) before this pipeline
existed. Getting this working required, **in this order** (each discovered
by hitting a real `AccessDenied`, not anticipated up front):

1. Two new roles, created manually via the AWS console (`jdsmithwes`
   cannot create/update IAM roles or policies at all, confirmed via
   `iam:SimulatePrincipalPolicy` — AccessDenied):
   - `GroceryIngestTaskExecutionRole` (trust: `ecs-tasks.amazonaws.com`) —
     `AmazonECSTaskExecutionRolePolicy` + inline `secretsmanager:GetSecretValue`
     scoped to `grocery-ingest/*`.
   - `GroceryIngestSchedulerRole` (trust: `scheduler.amazonaws.com`) —
     inline `ecs:RunTask` scoped to the `grocery-ingest` task definition
     family + `iam:PassRole` scoped to `GroceryIngestTaskExecutionRole`.
2. `jdsmithwes` itself turned out to have **zero** access to ECR, ECS, or
   EventBridge Scheduler — not a scoping issue, those permissions simply
   didn't exist for this user. Attached `AmazonECS_FullAccess`,
   `AmazonEC2ContainerRegistryFullAccess`, `AmazonEventBridgeSchedulerFullAccess`,
   plus one inline policy for `iam:PassRole` on both new roles (never
   bundled into a full-access policy on purpose, by AWS design).
3. `jdsmithwes` could `secretsmanager:ListSecrets` but not `CreateSecret`
   — one more inline policy, scoped to `grocery-ingest/*` only (not
   account-wide Secrets Manager access).
4. `jdsmithwes` cannot `logs:GetLogEvents` — **fixed 2026-08-23** (same day,
   `CloudWatchLogsReadOnlyAccess` attached). Confirmed working by reading
   back the `test_infra` diagnostic run's actual log lines afterward.
   `logs:PutRetentionPolicy` is still missing (see the resource table
   below) — low-stakes, just means the log group never expires, unlike
   fixing log *read* access which blocked actually operating this thing.

**Lesson for next time a new AWS service gets wired into this project**:
assume `jdsmithwes` has *no* access to it until proven otherwise — don't
assume "can do X" generalizes to "can do X-adjacent-thing," each AWS
service's permission was independently absent here.

## Operating this

- **Manually trigger the same run a schedule would**: `aws ecs run-task`
  with `--task-definition grocery-ingest:1` and a container environment
  override setting `RUN_MODE` to `friday_full` or `saturday_kroger_continue`
  — see `friday-schedule.json`/`saturday-schedule.json` for the exact
  network configuration to reuse.
- **Retry just Aldi without touching Kroger**: `RUN_MODE=aldi_only`, added
  2026-08-23 specifically for this — re-running the whole `friday_full`
  mode just to get back to the Aldi step would also reset and re-burn the
  Kroger checkpoint for no reason.
- **Verify the pipeline without spending API budget**: same, but
  `RUN_MODE=test_infra` — confirms secrets injection, AWS auth, and S3
  reachability without touching Kroger or Aldi. Safe to run anytime.
- **After changing `Kroger_Pricing_2026-08-10.py` or `ingest.py`/`adapters.py`**:
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
  change, just rebuild/push.
- **`task-definition.json`, `friday-schedule.json`, `saturday-schedule.json`**
  in this folder are the exact specs used to create these resources —
  treat them as the source of truth if anything needs recreating, same
  convention as the `.sql` files under `Snowflake Scripts/`.
- **One-off triggers outside the regular weekly cadence** (e.g. "I want
  fresh data today, not Friday"): don't just `run-task` and hope you
  remember to finish it manually — create a single-fire EventBridge
  Schedule instead, same `Target` shape as the two recurring ones but
  `"ScheduleExpression": "at(YYYY-MM-DDTHH:MM:SS)"` and
  `"ActionAfterCompletion": "DELETE"` so it cleans itself up after firing
  once. Proven 2026-08-23: triggered `friday_full` immediately, then
  registered an `at()` schedule for the next morning with
  `RUN_MODE=saturday_kroger_continue` to finish the Kroger sweep — no
  recurring schedule had to be touched, and nothing needed remembering by
  a human the next day.

## Resources this created (for teardown/reference)

| Resource | Name |
|---|---|
| IAM roles | `GroceryIngestTaskExecutionRole`, `GroceryIngestSchedulerRole` |
| Secrets Manager secret | `grocery-ingest/credentials` |
| ECR repository | `grocery-ingest` |
| ECS cluster | `grocery-ingest-cluster` |
| ECS task definition | `grocery-ingest` (revision 1) |
| CloudWatch log group | `/ecs/grocery-ingest` (no retention policy set yet — another `jdsmithwes` permission gap, `logs:PutRetentionPolicy`; logs currently never expire) |
| EventBridge Schedules | `grocery-ingest-friday-full`, `grocery-ingest-saturday-continue` |
