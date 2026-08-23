-- =====================================================================
-- ALDI PRICING — Snowpipe ingestion for ingest.py's NDJSON output
-- (API Scripts/Aldi Publix Scripts/). Created 2026-08-23 alongside
-- publix_pricing_ingestion_pipeline.sql, which shares the MY_NDJSON file
-- format defined here — not redefined there.
--
-- Different shape than the Kroger pipeline: Kroger lands CSV via
-- MATCH_BY_COLUMN_NAME; this is NDJSON (one JSON object per line, see
-- PriceObservation.to_json() in ingest.py), so the pipe uses a
-- query-based COPY INTO instead — MATCH_BY_COLUMN_NAME alone can't also
-- populate a "keep everything" column, since RAW_DATA doesn't correspond
-- to a literal top-level "raw_data" JSON key (the source has "raw" as one
-- key among several flat top-level fields, not one wrapper key holding
-- everything).
--
-- Table lands raw/near-raw per project convention: STORE_ID/SKU/
-- PRICE_SURFACE/OBSERVED_AT are pulled out as real columns (this is D1's
-- documented grain — see API Scripts/Aldi Publix Scripts/DECISIONS.md),
-- the full untouched JSON record is preserved in RAW_DATA VARIANT. No
-- field selection beyond that — dbt's job downstream, same as Kroger.
--
-- Unlike Kroger (one shared stage, 4 pipes differentiated by PATTERN),
-- Aldi and Publix each get their OWN stage, matching the existing
-- MY_S3_STAGE_WALMART precedent of one-stage-per-retailer-prefix.
--
-- CONFIRMED 2026-08-23: the SQS notification_channel is the SAME across
-- ALL pipes in this account, including these two — it's bound to the
-- STORAGE INTEGRATION (GROCERY_PRICE_PROJECT), not to the stage. This
-- corrects the original plan's assumption that new stages would get new
-- queues. Practical effect: only one SQS queue to ever worry about
-- account-wide, but S3 Event Notification rules are still registered
-- per-prefix (see step 4) to keep each retailer's files from triggering
-- irrelevant pipe evaluations.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE GROCERYDBTPROJECT;

-- 1. [RUN ONCE] Stage, scoped to the aldi/ prefix (own stage, not shared).
CREATE STAGE IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_ALDI
  URL = 's3://grocerydbtprojectrawdata/aldi/'
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT;

-- 2. [RUN ONCE] JSON file format — shared with the Publix pipeline.
-- STRIP_OUTER_ARRAY = FALSE because NDJSON is one object per line, not a
-- single array wrapping every record.
CREATE FILE_FORMAT IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON
  TYPE = JSON
  STRIP_OUTER_ARRAY = FALSE;

-- 3. [RUN ONCE] Table shape is fixed/known — no INFER_SCHEMA needed.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_RAW.ALDI_PRICING (
  STORE_ID VARCHAR,
  SKU VARCHAR,
  PRICE_SURFACE VARCHAR,
  OBSERVED_AT TIMESTAMP_TZ,
  RAW_DATA VARIANT,
  INGESTED_FILENAME VARCHAR
);

-- 4. [RUN ONCE — then AUTOMATIC] Snowpipe: auto-loads any new
-- *.ndjson file landing under s3://grocerydbtprojectrawdata/aldi/.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.ALDI_PRICING_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.ALDI_PRICING
    (STORE_ID, SKU, PRICE_SURFACE, OBSERVED_AT, RAW_DATA, INGESTED_FILENAME)
  FROM (
    SELECT
      $1:store_id::STRING,
      $1:sku::STRING,
      $1:price_surface::STRING,
      $1:observed_at::TIMESTAMP_TZ,
      $1,
      METADATA$FILENAME
    FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_ALDI
  )
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON)
  PATTERN = '.*[.]ndjson';

-- 4b. [ONE-TIME / ON-DEMAND — NOT part of the automatic path] Manual
-- backfill: use this if a file already exists in the stage that the pipe
-- won't pick up automatically. FORCE = TRUE bypasses "already loaded"
-- tracking.
COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.ALDI_PRICING
  (STORE_ID, SKU, PRICE_SURFACE, OBSERVED_AT, RAW_DATA, INGESTED_FILENAME)
FROM (
  SELECT
    $1:store_id::STRING,
    $1:sku::STRING,
    $1:price_surface::STRING,
    $1:observed_at::TIMESTAMP_TZ,
    $1,
    METADATA$FILENAME
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_ALDI
)
FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_NDJSON)
PATTERN = '.*[.]ndjson'
FORCE = TRUE;

-- 5. [ONE-TIME, AWS-SIDE] S3 Event Notification: ObjectCreated events
-- under prefix aldi/ with suffix .ndjson must be registered against the
-- shared SQS queue (see the CONFIRMED note above) for AUTO_INGEST to
-- actually fire. Done for this project 2026-08-23 via the AWS CLI
-- (added to the bucket's existing notification config alongside the
-- pre-existing kroger/ and new publix/ rules — additive PUT, not a
-- replace, or Kroger/Walmart auto-ingest would have silently broken).
-- Rule id: AldiPricingSnowpipeNotification.

-- 6. [INFORMATIONAL]
SELECT SYSTEM$PIPE_STATUS('GROCERYDBTPROJECT.AWS_RESOURCES.ALDI_PRICING_PIPE');
-- ^ Expect executionState = "RUNNING", pendingFileCount = 0 when idle.
