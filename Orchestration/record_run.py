"""
Writes a small JSON job-run manifest to S3 for auto-ingestion into
JOB_PERFORMANCE.ORCHESTRATION_JOB_RUNS (see
Snowflake Scripts/Orchestration/job_runs_ingestion_pipeline.sql). Called
by entrypoint.sh's run_source function after every source finishes
(success or failure) — this is what makes pipeline health queryable in
Snowflake instead of requiring a CloudWatch log dive.

rows_collected is deliberately not captured here: getting an exact count
back from each ingestion script into the shell adds real complexity for a
metric COPY_HISTORY/dbt already surface downstream. The column exists in
the table (nullable) for later if wanted.
"""

import argparse
import json
from datetime import datetime, timezone

import boto3

S3_BUCKET = "grocerydbtprojectrawdata"
S3_PREFIX = "orchestration_runs/"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--run-mode", required=True)
    parser.add_argument("--status", required=True, choices=["success", "failed"])
    parser.add_argument("--started-at", required=True)
    parser.add_argument("--completed-at", required=True)
    parser.add_argument("--error", default=None)
    args = parser.parse_args()

    record = {
        "source": args.source,
        "run_mode": args.run_mode,
        "started_at": args.started_at,
        "completed_at": args.completed_at,
        "status": args.status,
        "error_message": args.error,
    }

    now = datetime.now(timezone.utc)
    key = (
        f"{S3_PREFIX}dt={now.strftime('%Y-%m-%d')}/"
        f"{args.source}_{args.run_mode}_{now.strftime('%Y-%m-%dT%H%M%SZ')}.json"
    )

    boto3.client("s3").put_object(
        Bucket=S3_BUCKET, Key=key, Body=(json.dumps(record) + "\n").encode("utf-8")
    )
    print(f"Recorded run: s3://{S3_BUCKET}/{key}")


if __name__ == "__main__":
    main()
