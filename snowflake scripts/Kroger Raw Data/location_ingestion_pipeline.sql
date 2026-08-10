-- =====================================================================
-- KROGER LOCATIONS — Snowpipe ingestion for Kroger_Location_*.py output.
--
-- PREREQUISITE: run productcatalog_ingestion_pipeline.sql's SHARED SETUP
-- section first (warehouse, database, schemas, storage integration,
-- MY_S3_STAGE_KROGER stage, MY_CSV_INFER file format). Not redefined here
-- to avoid maintaining duplicate copies of the same shared objects across
-- files — all four Kroger file types (catalog, locations, pricing,
-- inventory) share ONE stage pointed at s3://grocerydbtprojectrawdata/kroger/,
-- differentiated by the PATTERN clause on each pipe below, not by
-- separate stage objects.
--
-- Table lands raw/near-raw per project convention: only locationId/
-- region/collected_at are real columns (join/partition keys); the full,
-- untouched Kroger Locations API response is preserved as JSON text in
-- RAW_DATA. No field selection or reshaping — that's dbt's job downstream.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE GROCERYDBTPROJECT;

-- 1. [RUN ONCE] Table shape is fixed/known (unlike the catalog table,
-- which uses INFER_SCHEMA against Kroger's wide, evolving product
-- fields) — no need for the INFER_SCHEMA dance here.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.RAW.KROGER_LOCATIONS (
  LOCATIONID STRING,
  REGION STRING,
  COLLECTED_AT TIMESTAMP_TZ,
  RAW_DATA STRING
);

-- 1b. [RUN ONCE] Add a column to hold which source file each row came from.
ALTER TABLE GROCERYDBTPROJECT.RAW.KROGER_LOCATIONS
  ADD COLUMN IF NOT EXISTS INGESTED_FILENAME STRING;

-- 2. [RUN ONCE — then AUTOMATIC] Snowpipe: auto-loads any new file
-- matching kroger_locations_*.csv into RAW.KROGER_LOCATIONS. Once this
-- exists and its S3 Event Notification (step 4) is configured, this is
-- the ONLY step needed forever — no manual COPY INTO required for new
-- files.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.KROGER_LOCATIONS_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.RAW.KROGER_LOCATIONS
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  PATTERN = '.*kroger_locations_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME);

-- 2b. [ONE-TIME / ON-DEMAND — NOT part of the automatic path] Manual
-- backfill: use this if a locations file already exists in the stage
-- that the pipe won't pick up automatically (predates the S3 Event
-- Notification, or the table was recreated after the pipe already
-- marked the file loaded). FORCE = TRUE bypasses that tracking.
COPY INTO GROCERYDBTPROJECT.RAW.KROGER_LOCATIONS
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  PATTERN = '.*kroger_locations_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME)
  FORCE = TRUE;

-- 3. [INFORMATIONAL]
SHOW PIPES LIKE 'KROGER_LOCATIONS_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES;
-- ^ CONFIRMED 2026-08-10: this pipe's notification_channel is the SAME
-- queue ARN as the catalog, pricing, and inventory pipes — the channel is
-- tied to the shared stage (MY_S3_STAGE_KROGER), not to each pipe
-- individually. No separate S3 Event Notification is needed for this
-- pipe; the single registration already set up for the catalog pipe
-- covers all four, and this pipe's own PATTERN decides which files it
-- actually loads.
