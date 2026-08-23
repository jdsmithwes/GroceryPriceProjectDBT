#!/bin/sh
# Container entrypoint for the grocery-ingest ECS task. Branches on RUN_MODE,
# which EventBridge Scheduler sets per-schedule via a container override —
# NOT baked into the image, so the same task definition/image serves both
# the Friday and Saturday triggers. See Orchestration/README.md for the
# full weekly schedule this supports and why it's split across two days.
set -eu

echo "grocery-ingest starting — RUN_MODE=${RUN_MODE:-<unset>}"

case "${RUN_MODE:-}" in
  friday_full)
    echo "=== Kroger pricing: reset checkpoint + full 81-store sweep ==="
    python3 "API Scripts/Kroger Scripts/Product Pricing/Kroger_Pricing_2026-08-10.py" --reset-checkpoint

    echo "=== Aldi: full catalog sweep (no checkpoint needed, completes in one run) ==="
    (cd "API Scripts/Aldi Publix Scripts" && python3 ingest.py --retailers aldi --zips 30080)

    # Publix intentionally NOT run here yet — PUBLIX_CONFIG is unverified
    # against a live endpoint as of this writing. Add it below once
    # `python adapters.py probe publix` has been run and the config fixed:
    #   (cd "API Scripts/Aldi Publix Scripts" && python3 ingest.py --retailers publix --zips 30080)
    ;;
  saturday_kroger_continue)
    echo "=== Kroger pricing: continue from Friday's checkpoint (no reset) ==="
    python3 "API Scripts/Kroger Scripts/Product Pricing/Kroger_Pricing_2026-08-10.py"
    ;;
  aldi_only)
    # Retry/debug mode: re-runs just Aldi without touching the Kroger
    # checkpoint. Added 2026-08-23 after Aldi's leg of a friday_full run
    # failed on a DNS error post-Kroger — needed a way to retry Aldi alone
    # rather than re-running (and re-resetting) Kroger just to get back to
    # the Aldi step.
    echo "=== Aldi: full catalog sweep (standalone retry) ==="
    (cd "API Scripts/Aldi Publix Scripts" && python3 ingest.py --retailers aldi --zips 30080)
    ;;
  test_infra)
    # Diagnostic mode: confirms secrets injection, AWS auth, and S3 network
    # egress all work, WITHOUT touching Kroger/Aldi or spending any API
    # budget. Safe to run any time via a manual `aws ecs run-task` with a
    # RUN_MODE=test_infra environment override — never wired to a schedule.
    python3 -c "
import os, boto3
print('KROGER_CLIENT_ID set:', bool(os.environ.get('KROGER_CLIENT_ID')))
print('KROGER_CLIENT_SECRET set:', bool(os.environ.get('KROGER_CLIENT_SECRET')))
print('AWS_ACCESS_KEY_ID set:', bool(os.environ.get('AWS_ACCESS_KEY_ID')))
s3 = boto3.client('s3')
r = s3.list_objects_v2(Bucket='grocerydbtprojectrawdata', Prefix='kroger/', MaxKeys=1)
print('S3 list OK, got', len(r.get('Contents', [])), 'object(s)')
"
    ;;
  *)
    echo "ERROR: RUN_MODE must be one of 'friday_full', 'saturday_kroger_continue', 'aldi_only', 'test_infra' — got '${RUN_MODE:-<unset>}'" >&2
    exit 1
    ;;
esac

echo "grocery-ingest finished — RUN_MODE=${RUN_MODE}"
