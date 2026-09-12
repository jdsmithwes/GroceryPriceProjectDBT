#!/bin/sh
# Container entrypoint for the grocery-ingest ECS task. Branches on RUN_MODE,
# which EventBridge Scheduler sets per-schedule via a container override —
# NOT baked into the image, so the same task definition/image serves both
# the Friday and Saturday triggers. See Orchestration/README.md for the
# full weekly schedule this supports and why it's split across two days.
set -u

echo "grocery-ingest starting — RUN_MODE=${RUN_MODE:-<unset>}"

# Walmart's private key arrives as a Secrets-Manager-injected env var
# (multi-line PEM content), not a file path — write it to disk once here
# so entire_productcatalog_walmart.py's existing WALMART_KEY_PATH-based
# loading works completely unmodified.
if [ -n "${WALMART_PRIVATE_KEY_PEM:-}" ]; then
  printf '%s' "$WALMART_PRIVATE_KEY_PEM" > /app/walmart_key.pem
  export WALMART_KEY_PATH=/app/walmart_key.pem
fi

# Runs one source, timing it and catching its exit code instead of letting
# a hard failure abort the rest of the task. This matters more than it
# used to: with only Kroger and Walmart in the pipeline now (Aldi/Publix
# removed 2026-08-31), a hard Kroger failure under a naive `set -e` would
# silently prevent Walmart from ever running — previously masked because
# Aldi's own script swallowed its errors internally, so `set -e` was never
# actually exercised against a real hard failure. Every outcome — success
# or failure — gets a manifest row via record_run.py, so pipeline health
# is visible in GROCERY_RAW.ORCHESTRATION_JOB_RUNS without a CloudWatch
# log dive.
run_source() {
  source_name="$1"
  shift
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if "$@"; then
    status="success"
    completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 /app/record_run.py --source "$source_name" --run-mode "${RUN_MODE}" \
      --status "$status" --started-at "$started_at" --completed-at "$completed_at"
  else
    status="failed"
    completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 /app/record_run.py --source "$source_name" --run-mode "${RUN_MODE}" \
      --status "$status" --started-at "$started_at" --completed-at "$completed_at" \
      --error "$source_name exited non-zero — see CloudWatch Logs (/ecs/grocery-ingest) for this task run"
  fi
}

case "${RUN_MODE:-}" in
  friday_full)
    echo "=== Kroger pricing: reset checkpoint + full 81-store sweep ==="
    run_source kroger python3 "API Scripts/Kroger Scripts/Product Pricing/Kroger_Pricing_2026-08-10.py" --reset-checkpoint

    echo "=== Walmart: category-scoped catalog pull (Food department) ==="
    run_source walmart python3 "API Scripts/Walmart Scripts/entire_productcatalog_walmart.py"
    ;;
  saturday_kroger_continue)
    echo "=== Kroger pricing: continue from Friday's checkpoint (no reset) ==="
    run_source kroger python3 "API Scripts/Kroger Scripts/Product Pricing/Kroger_Pricing_2026-08-10.py"
    ;;
  walmart_only)
    # Retry/debug mode: re-runs just Walmart without touching the Kroger
    # checkpoint. Mirrors the old aldi_only pattern this replaces — needed
    # for the same reason: re-running the whole friday_full mode just to
    # retry Walmart would also reset and re-burn the Kroger checkpoint for
    # no reason.
    echo "=== Walmart: category-scoped catalog pull (standalone retry) ==="
    run_source walmart python3 "API Scripts/Walmart Scripts/entire_productcatalog_walmart.py"
    ;;
  test_infra)
    # Diagnostic mode: confirms secrets injection, AWS auth, Walmart key
    # delivery, and S3 network egress all work, WITHOUT touching
    # Kroger/Walmart or spending any API budget. Safe to run any time via
    # a manual `aws ecs run-task` with a RUN_MODE=test_infra environment
    # override — never wired to a schedule.
    python3 -c "
import os, boto3
print('KROGER_CLIENT_ID set:', bool(os.environ.get('KROGER_CLIENT_ID')))
print('KROGER_CLIENT_SECRET set:', bool(os.environ.get('KROGER_CLIENT_SECRET')))
print('WALMART_CONSUMER_ID set:', bool(os.environ.get('WALMART_CONSUMER_ID')))
print('WALMART_KEY_VERSION:', os.environ.get('WALMART_KEY_VERSION'))
key_path = os.environ.get('WALMART_KEY_PATH', '')
print('WALMART_KEY_PATH:', key_path)
print('WALMART_KEY_PATH exists on disk:', os.path.exists(key_path))
print('AWS_ACCESS_KEY_ID set:', bool(os.environ.get('AWS_ACCESS_KEY_ID')))
s3 = boto3.client('s3')
r = s3.list_objects_v2(Bucket='grocerydbtprojectrawdata', Prefix='kroger/', MaxKeys=1)
print('S3 list OK, got', len(r.get('Contents', [])), 'object(s)')
"
    ;;
  *)
    echo "ERROR: RUN_MODE must be one of 'friday_full', 'saturday_kroger_continue', 'walmart_only', 'test_infra' — got '${RUN_MODE:-<unset>}'" >&2
    exit 1
    ;;
esac

echo "grocery-ingest finished — RUN_MODE=${RUN_MODE}"
