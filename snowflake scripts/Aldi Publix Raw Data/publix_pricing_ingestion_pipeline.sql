-- =====================================================================
-- PUBLIX PRICING — Snowpipe ingestion for ingest.py's NDJSON output
-- (API Scripts/Aldi Publix Scripts/). Created 2026-08-23 alongside
-- aldi_pricing_ingestion_pipeline.sql — MY_NDJSON file format is defined
-- there, shared here, not redefined.
--
-- Same shape/reasoning as the Aldi pipeline (query-based COPY INTO for
-- NDJSON, own stage rather than a shared one) — see that file's header
-- for the full explanation. Not repeated here.
--
-- Table lands raw/near-raw per project convention: STORE_ID/SKU/
-- PRICE_SURFACE/OBSERVED_AT are pulled out as real columns (D1's grain,
-- see API Scripts/Aldi Publix Scripts/DECISIONS.md), full untouched JSON
-- record preserved in RAW_DATA VARIANT.
--
-- Remember while testing: per DECISIONS.md/README, PUBLIX_CONFIG in
-- adapters.py is entirely UNVERIFIED — run `python adapters.py probe
-- publix --zip 30080` and fix the config before trusting anything that
-- lands in this table. This pipeline will happily auto-ingest wrong data
-- if the adapter is pointed at the wrong JSON paths; the pipe has no way
-- to know the difference.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE GROCERYDBTPROJECT;

-- 1. [RUN ONCE] Stage, scoped to the publix/ prefix (own stage, not shared).
CREATE STAGE IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_PUBLIX
  URL = 's3://grocerydbtprojectrawdata/publix/'
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT;

-- 2. [RUN ONCE — SHARED, see aldi_pricing_ingestion_pipeline.sql] JSON
-- file format. Repeated here as IF NOT EXISTS so this file is runnable
-- standalone; it's a no-op if the Aldi pipeline already created it.
CREATE FILE_FORMAT IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON
  TYPE = JSON
  STRIP_OUTER_ARRAY = FALSE;

-- 3. [RUN ONCE] Table shape is fixed/known — no INFER_SCHEMA needed.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_RAW.PUBLIX_PRICING (
  STORE_ID VARCHAR,
  SKU VARCHAR,
  PRICE_SURFACE VARCHAR,
  OBSERVED_AT TIMESTAMP_TZ,
  RAW_DATA VARIANT,
  INGESTED_FILENAME VARCHAR
);

-- 4. [RUN ONCE — then AUTOMATIC] Snowpipe: auto-loads any new
-- *.ndjson file landing under s3://grocerydbtprojectrawdata/publix/.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.PUBLIX_PRICING_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.PUBLIX_PRICING
    (STORE_ID, SKU, PRICE_SURFACE, OBSERVED_AT, RAW_DATA, INGESTED_FILENAME)
  FROM (
    SELECT
      $1:store_id::STRING,
      $1:sku::STRING,
      $1:price_surface::STRING,
      $1:observed_at::TIMESTAMP_TZ,
      $1,
      METADATA$FILENAME
    FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_PUBLIX
  )
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON)
  PATTERN = '.*[.]ndjson';

-- 4b. [ONE-TIME / ON-DEMAND — NOT part of the automatic path] Manual
-- backfill: use this if a file already exists in the stage that the pipe
-- won't pick up automatically. FORCE = TRUE bypasses "already loaded"
-- tracking.
COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.PUBLIX_PRICING
  (STORE_ID, SKU, PRICE_SURFACE, OBSERVED_AT, RAW_DATA, INGESTED_FILENAME)
FROM (
  SELECT
    $1:store_id::STRING,
    $1:sku::STRING,
    $1:price_surface::STRING,
    $1:observed_at::TIMESTAMP_TZ,
    $1,
    METADATA$FILENAME
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_PUBLIX
)
FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON)
PATTERN = '.*[.]ndjson'
FORCE = TRUE;

-- 5. [ONE-TIME, AWS-SIDE] S3 Event Notification: ObjectCreated events
-- under prefix publix/ with suffix .ndjson, registered against the same
-- shared SQS queue as every other pipe in this account (see the
-- CONFIRMED note in aldi_pricing_ingestion_pipeline.sql). Done for this
-- project 2026-08-23, additive alongside the existing kroger/ and aldi/
-- rules. Rule id: PublixPricingSnowpipeNotification.

-- 6. [INFORMATIONAL]
SELECT SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES.PUBLIX_PRICING_PIPE');
-- ^ Expect executionState = "RUNNING", pendingFileCount = 0 when idle.
