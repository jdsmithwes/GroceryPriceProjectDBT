-- =====================================================================
-- ORCHESTRATION JOB RUNS
-- Per-source run history for the weekly Kroger+Walmart Fargate pipeline
-- (see Orchestration/README.md, Orchestration/entrypoint.sh's run_source
-- function, Orchestration/record_run.py). Before this, "did last
-- Friday's run succeed" required a CloudWatch log dive — this makes it
-- a queryable table like everything else in this project.
--
-- record_run.py writes one small JSON manifest to S3 per source per run
-- (success or failure, always — not just on success), and this Snowpipe
-- auto-ingests it. Same run-once-then-automatic rule as every other
-- pipe here: once the pipe + S3 Event Notification exist, no further
-- manual steps are needed for new runs.
-- =====================================================================

-- 1. [RUN ONCE] Add the new prefix to the existing storage integration's
-- allowed locations. NOT CREATE OR REPLACE — that regenerates
-- STORAGE_AWS_EXTERNAL_ID and desyncs the AWS IAM role's trust policy
-- (documented gotcha, see the Kroger/Walmart pipeline file).
ALTER STORAGE INTEGRATION GROCERY_PRICE_PROJECT SET
  STORAGE_ALLOWED_LOCATIONS = (
    's3://grocerydbtprojectrawdata/kroger/',
    's3://grocerydbtprojectrawdata/walmart/',
    's3://grocerydbtprojectrawdata/orchestration_runs/',
    's3://grocerydbtprojectrawdata/'
  );

-- 2. [RUN ONCE] External stage pointing at the orchestration_runs/
-- prefix. Reuses the existing MY_NDJSON file format (one JSON object per
-- line — record_run.py writes exactly one object per file, which is a
-- valid degenerate case of that format).
CREATE OR REPLACE STAGE GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_ORCHESTRATION_RUNS
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  URL = 's3://grocerydbtprojectrawdata/orchestration_runs/'
  FILE_FORMAT = GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON;

-- 3. [RUN ONCE] Table with an explicit, fully first-party schema — unlike
-- the raw API landing tables (deliberately all-VARCHAR to defend against
-- schema drift in external payloads), this table's shape is entirely
-- under this project's own control, so it gets real types.
CREATE OR REPLACE TABLE GROCERYDBTPROJECT.GROCERY_RAW.ORCHESTRATION_JOB_RUNS (
  SOURCE VARCHAR,
  RUN_MODE VARCHAR,
  STARTED_AT TIMESTAMP_NTZ,
  COMPLETED_AT TIMESTAMP_NTZ,
  STATUS VARCHAR,
  ERROR_MESSAGE VARCHAR,
  ROWS_COLLECTED NUMBER,
  INGESTED_FILENAME VARCHAR
);

-- 4. [RUN ONCE — then AUTOMATIC] Snowpipe: auto-loads any new manifest
-- landing under orchestration_runs/ into GROCERY_RAW.ORCHESTRATION_JOB_RUNS.
-- Query-based COPY (not MATCH_BY_COLUMN_NAME) since the source is JSON,
-- not CSV — same shape as this project's other JSON pipes.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.ORCHESTRATION_JOB_RUNS_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.ORCHESTRATION_JOB_RUNS
    (SOURCE, RUN_MODE, STARTED_AT, COMPLETED_AT, STATUS, ERROR_MESSAGE, ROWS_COLLECTED, INGESTED_FILENAME)
  FROM (
    SELECT
      $1:source::VARCHAR,
      $1:run_mode::VARCHAR,
      $1:started_at::TIMESTAMP_NTZ,
      $1:completed_at::TIMESTAMP_NTZ,
      $1:status::VARCHAR,
      $1:error_message::VARCHAR,
      $1:rows_collected::NUMBER,
      METADATA$FILENAME
    FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_ORCHESTRATION_RUNS
  )
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON);

-- 4b. [ONE-TIME / ON-DEMAND — NOT part of the automatic path] Manual
-- backfill/reload, same purpose as every other pipe's 4b in this project.
COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.ORCHESTRATION_JOB_RUNS
    (SOURCE, RUN_MODE, STARTED_AT, COMPLETED_AT, STATUS, ERROR_MESSAGE, ROWS_COLLECTED, INGESTED_FILENAME)
  FROM (
    SELECT
      $1:source::VARCHAR,
      $1:run_mode::VARCHAR,
      $1:started_at::TIMESTAMP_NTZ,
      $1:completed_at::TIMESTAMP_NTZ,
      $1:status::VARCHAR,
      $1:error_message::VARCHAR,
      $1:rows_collected::NUMBER,
      METADATA$FILENAME
    FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_ORCHESTRATION_RUNS
  )
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON)
  FORCE = TRUE;

-- 5. [INFORMATIONAL — only needed once, to wire up AWS]
SHOW PIPES LIKE 'ORCHESTRATION_JOB_RUNS_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES;
-- ^ Expected to return the same shared queue ARN as Kroger's/Walmart's
-- pipes (confirmed 2026-08-31: the notification channel is bound to the
-- GROCERY_PRICE_PROJECT storage integration, not the stage). Add a new
-- S3 Event Notification entry (prefix "orchestration_runs/", suffix
-- ".json") to the bucket's config pointed at that ARN — GET the current
-- config, add this one entry, PUT the merged result back. Never PUT a
-- partial config; that API replaces the whole thing.
