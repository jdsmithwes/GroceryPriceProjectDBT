-- =====================================================================
-- UPC DATABASE — Snowpipe ingestion for
-- API Scripts/UPC Product Info Scripts/upcdatabase_product_details.py output
-- (s3://grocerydbtprojectrawdata/upc/upcdatabase_product_details_*.csv).
--
-- Same raw-landing convention as Kroger pricing: UPC plus the matching
-- Kroger/Walmart ids, lookup status, and collected_at are real columns;
-- the untouched upcdatabase.org response body is RAW_DATA. Reuses the
-- GROCERY_PRICE_PROJECT storage integration (its allowed locations already
-- include the bucket root) and the shared MY_CSV_INFER file format.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE GROCERYDBTPROJECT;

-- 1. [RUN ONCE] Per-source schemas, matching GROCERY_RAW_KROGER/_WALMART.
CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_RAW_UPC;
CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES_UPC;

-- 2. [RUN ONCE] Stage scoped to the upc/ prefix.
CREATE STAGE IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES_UPC.MY_S3_STAGE_UPC
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  URL = 's3://grocerydbtprojectrawdata/upc/'
  FILE_FORMAT = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER;

-- 3. [RUN ONCE] Explicit schema (no INFER_SCHEMA — see the Walmart section of
-- productcatalog_ingestion_pipeline.sql for why). Column names match the
-- script's CSV header; MATCH_BY_COLUMN_NAME is case-insensitive.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_RAW_UPC.UPCDATABASE_PRODUCT_DETAILS (
  UPC VARCHAR,
  KROGER_PRODUCT_ID VARCHAR,
  WALMART_ITEM_ID VARCHAR,
  LOOKUP_STATUS VARCHAR,
  HTTP_STATUS VARCHAR,
  API_LOOKUPS_REMAINING VARCHAR,
  COLLECTED_AT TIMESTAMP_TZ,
  RAW_DATA VARCHAR,
  INGESTED_FILENAME VARCHAR
);

-- 4. [RUN ONCE — then AUTOMATIC] PATTERN is relative to the stage URL (upc/),
-- so it skips upc/_checkpoints/*.json.
CREATE PIPE IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES_UPC.UPCDATABASE_PRODUCT_DETAILS_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.GROCERY_RAW_UPC.UPCDATABASE_PRODUCT_DETAILS
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES_UPC.MY_S3_STAGE_UPC
  PATTERN = 'upcdatabase_product_details_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME);

-- 5. [RUN ONCE — AWS side] The pipe shares the integration's SQS queue (same
-- notification_channel as every other pipe). The bucket needs one more S3 Event
-- Notification entry: Id "UpcDatabaseSnowpipeNotification", prefix "upc/",
-- suffix ".csv", ObjectCreated:*, pointed at that queue. put-bucket-notification-
-- configuration replaces the whole config — always GET, merge, then PUT.
SHOW PIPES LIKE 'UPCDATABASE_PRODUCT_DETAILS_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES_UPC;

-- 6. [ON-DEMAND] Backfill files the pipe missed (e.g. before the notification existed).
-- ALTER PIPE GROCERYDBTPROJECT.AWS_RESOURCES_UPC.UPCDATABASE_PRODUCT_DETAILS_PIPE REFRESH;
