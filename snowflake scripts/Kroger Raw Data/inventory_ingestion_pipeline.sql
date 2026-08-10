-- =====================================================================
-- KROGER INVENTORY — Snowpipe ingestion for Kroger_Inventory_*.py output.
--
-- PREREQUISITE: run productcatalog_ingestion_pipeline.sql's SHARED SETUP
-- section first (warehouse, database, schemas, storage integration,
-- MY_S3_STAGE_KROGER stage, MY_CSV_INFER file format). Not redefined here
-- — all four Kroger file types (catalog, locations, pricing, inventory)
-- share ONE stage pointed at s3://grocerydbtprojectrawdata/kroger/,
-- differentiated by the PATTERN clause on each pipe below, not by
-- separate stage objects.
--
-- Table lands raw/near-raw per project convention: only productId/
-- locationId/collected_at are real columns (join/partition keys); the
-- full, untouched Kroger Products API response (for that product+store
-- combination) is preserved as JSON text in RAW_DATA. No field selection
-- (e.g. picking stockLevel vs. fulfillment flags) — that's dbt's job
-- downstream.
--
-- NOTE (cost-effectiveness, see .claude/instructions.md): Kroger_Inventory_*.py
-- and Kroger_Pricing_*.py call the identical underlying API endpoint and
-- now land identical RAW_DATA content — this table and KROGER_PRICING
-- will contain duplicate raw JSON if both scripts are run over the same
-- products/locations. Kept as separate tables per the requested folder/
-- naming structure; consider consolidating if that duplication becomes
-- costly at scale.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE GROCERYDBTPROJECT;

-- 1. [RUN ONCE] Table shape is fixed/known — no INFER_SCHEMA needed.
CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.RAW.KROGER_INVENTORY (
  PRODUCTID STRING,
  LOCATIONID STRING,
  COLLECTED_AT TIMESTAMP_TZ,
  RAW_DATA STRING
);

-- 1b. [RUN ONCE] Add a column to hold which source file each row came from.
ALTER TABLE GROCERYDBTPROJECT.RAW.KROGER_INVENTORY
  ADD COLUMN IF NOT EXISTS INGESTED_FILENAME STRING;

-- 2. [RUN ONCE — then AUTOMATIC] Snowpipe: auto-loads any new file
-- matching kroger_inventory_*.csv into RAW.KROGER_INVENTORY. Once this
-- exists and its S3 Event Notification (step 4) is configured, this is
-- the ONLY step needed forever — no manual COPY INTO required for new
-- files.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.KROGER_INVENTORY_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.RAW.KROGER_INVENTORY
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  PATTERN = '.*kroger_inventory_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME);

-- 2b. [ONE-TIME / ON-DEMAND — NOT part of the automatic path] Manual
-- backfill: use this if an inventory file already exists in the stage
-- that the pipe won't pick up automatically (predates the S3 Event
-- Notification, or the table was recreated after the pipe already
-- marked the file loaded). FORCE = TRUE bypasses that tracking.
COPY INTO GROCERYDBTPROJECT.RAW.KROGER_INVENTORY
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  PATTERN = '.*kroger_inventory_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME)
  FORCE = TRUE;

-- 3. [INFORMATIONAL]
SHOW PIPES LIKE 'KROGER_INVENTORY_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES;
-- ^ CONFIRMED 2026-08-10: this pipe's notification_channel is the SAME
-- queue ARN as the catalog, locations, and pricing pipes — the channel is
-- tied to the shared stage (MY_S3_STAGE_KROGER), not to each pipe
-- individually. No separate S3 Event Notification is needed for this
-- pipe; the single registration already set up for the catalog pipe
-- covers all four, and this pipe's own PATTERN decides which files it
-- actually loads.
