-- =====================================================================
-- SHARED SETUP — run once. Warehouse, database, schemas, storage
-- integration, and file formats used by BOTH the Kroger and Walmart
-- sections below.
-- =====================================================================

USE ROLE ACCOUNTADMIN;

-- [RUN ONCE]
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;
USE WAREHOUSE COMPUTE_WH;

-- [RUN ONCE]
CREATE DATABASE IF NOT EXISTS GROCERYDBTPROJECT;
USE DATABASE GROCERYDBTPROJECT;

-- [RUN ONCE]
CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.RAW;
CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES;


-- [RUN ONCE] File Format for CSV files
-- FIELD_OPTIONALLY_ENCLOSED_BY tells Snowflake to honor the double-quotes
-- pandas wraps around any field containing a comma (e.g. the "categories"
-- column, which joins multiple values with ", "). Without it, commas
-- inside quoted fields are treated as column separators.
CREATE OR REPLACE FILE FORMAT GROCERYDBTPROJECT.AWS_RESOURCES.GROCERY_CSV
    TYPE = CSV
    FIELD_OPTIONALLY_ENCLOSED_BY = '"';

-- [RUN ONCE] Storage Integration for Snowflake to access S3 bucket
-- NOTE: storage integrations are account-level objects, not schema-level —
-- the name must be unqualified (no database/schema prefix).
CREATE STORAGE INTEGRATION IF NOT EXISTS GROCERY_PRICE_PROJECT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::573509103721:role/GroceryPriceProjectSnowflakeRole'
  STORAGE_ALLOWED_LOCATIONS = (
    's3://grocerydbtprojectrawdata/kroger/',
    's3://grocerydbtprojectrawdata/walmart/',
    's3://grocerydbtprojectrawdata/'
  );
-- Avoid re-running this with OR REPLACE once it's working — doing so
-- generates a brand-new STORAGE_AWS_EXTERNAL_ID and desyncs the AWS IAM
-- role's trust policy (see DESC below), breaking access until you re-sync
-- both sides again.

-- [INFORMATIONAL — only needed once, to wire up AWS]
DESC STORAGE INTEGRATION GROCERY_PRICE_PROJECT;
-- ^ Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from this
-- output into the trust policy of GroceryPriceProjectSnowflakeRole in AWS
-- before the stages/INFER_SCHEMA calls below will actually be able to read
-- from the bucket.

-- [RUN ONCE] External Stage for Grocery Price Project S3 Bucket
CREATE OR REPLACE STAGE GROCERYDBTPROJECT.AWS_RESOURCES.GROCERY_PRICE_PROJECT_STAGE
  URL = 's3://grocerydbtprojectrawdata/'
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.GROCERY_CSV);

-- [RUN ONCE] File format with PARSE_HEADER, shared by both Kroger and Walmart stages below.
-- ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE is required because the target
-- tables have one more column (INGESTED_FILENAME) than the source files —
-- MATCH_BY_COLUMN_NAME handles matching the rest by name, but Snowflake
-- still enforces a raw column-count check on top of that unless this is
-- explicitly disabled.
CREATE OR REPLACE FILE FORMAT GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;


-- =====================================================================
-- KROGER
-- Setup steps below are [RUN ONCE]. After the PIPE (step 5) exists and
-- its S3 Event Notification is wired up in AWS, new files landing under
-- kroger/ load automatically — no further manual steps needed for those.
-- Step 5b is the exception: a one-time, on-demand backfill tool, not
-- part of the automatic path.
-- =====================================================================

-- 1. [RUN ONCE] External stage pointing at the kroger/ prefix
CREATE OR REPLACE STAGE GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  URL = 's3://grocerydbtprojectrawdata/kroger/'
  FILE_FORMAT = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER;

-- 2. [INFORMATIONAL] Preview the inferred schema — safe to re-run any time to inspect the file(s).
SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER',
    FILE_FORMAT => 'GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER'
  )
);

-- 3. [RUN ONCE] Create the table using the inferred schema.
-- Re-running this with OR REPLACE wipes the table's data AND drops the
-- manually-added INGESTED_FILENAME column (step 3b must be re-run
-- immediately after if you ever do this again).
CREATE OR REPLACE TABLE GROCERYDBTPROJECT.RAW.KROGER_PRODUCT_CATALOG
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION => '@GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER',
        FILE_FORMAT => 'GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER'
      )
    )
  );

-- 3b. [RUN ONCE] Add a column to hold which source file each row came from.
ALTER TABLE GROCERYDBTPROJECT.RAW.KROGER_PRODUCT_CATALOG
  ADD COLUMN IF NOT EXISTS INGESTED_FILENAME STRING;

-- 4. [RUN ONCE — then AUTOMATIC] Snowpipe: auto-loads any new file that
-- lands under kroger/ into RAW.KROGER_PRODUCT_CATALOG. Once this exists
-- and the S3 Event Notification below is configured, this is the ONLY
-- step needed forever — no manual COPY INTO required for new files.
-- MATCH_BY_COLUMN_NAME is required here since the file format uses PARSE_HEADER
-- and the table was built directly from the inferred (named) columns above.
-- INCLUDE_METADATA is what lets METADATA$FILENAME coexist with
-- MATCH_BY_COLUMN_NAME (they can't be combined via a plain SELECT list
-- without abandoning name-based matching).
-- PATTERN is required as of 2026-08-10: kroger/ now also receives
-- locations/pricing/inventory files (see location_ingestion_pipeline.sql,
-- pricing_ingestion_pipeline.sql, inventory_ingestion_pipeline.sql) from
-- the SAME shared stage. Without this filter, this pipe would try to load
-- those files too and fail (or worse, silently misload) under
-- MATCH_BY_COLUMN_NAME, since their columns don't match this table's.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.KROGER_PRODUCT_CATALOG_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.RAW.KROGER_PRODUCT_CATALOG
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  PATTERN = '.*kroger_product_catalog_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME);
-- NOTE: recreating a pipe via CREATE OR REPLACE PIPE may or may not
-- generate a new notification_channel — re-run step 5 below and compare
-- against what's currently configured on the S3 bucket; update the
-- bucket's Event Notification for this queue ARN if it changed.

-- 4b. [ONE-TIME / ON-DEMAND — NOT part of the automatic path] Manual
-- backfill: use this if a file already exists in the stage that the pipe
-- won't pick up automatically — either because it predates the S3 Event
-- Notification setup, or because CREATE OR REPLACE TABLE wiped the data
-- after the pipe already marked the file as loaded (the pipe's own
-- "already loaded" tracking survives table recreation).
-- FORCE = TRUE bypasses that tracking and reloads regardless. Re-run this
-- any time you need to force a reload; it is NOT run automatically.
COPY INTO GROCERYDBTPROJECT.RAW.KROGER_PRODUCT_CATALOG
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  PATTERN = '.*kroger_product_catalog_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME)
  FORCE = TRUE;

-- 5. [INFORMATIONAL — only needed once, to wire up AWS]
SHOW PIPES LIKE 'KROGER_PRODUCT_CATALOG_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES;
-- ^ Copy the "notification_channel" value (an SQS queue ARN) from this
-- output. In AWS, add an S3 Event Notification on the bucket — prefix
-- "kroger/", event type "All object create events" — with that SQS ARN as
-- the destination. That's what actually triggers the pipe; nothing loads
-- automatically until this AWS-side step is done. Once done, this whole
-- Kroger section requires no further manual intervention for new files.
--
-- CONFIRMED 2026-08-10: this same queue ARN is shared by ALL FOUR Kroger
-- pipes (catalog, locations, pricing, inventory) — the notification
-- channel appears to be tied to the STAGE (MY_S3_STAGE_KROGER), not to
-- each individual pipe. One S3 Event Notification registration for this
-- one queue is therefore sufficient for all four; Snowflake internally
-- routes the incoming message to every pipe reading from that stage, and
-- each pipe's own PATTERN decides whether it actually loads a given file.
-- (Earlier comments in these files claiming each pipe gets its own
-- dedicated queue were an untested assumption that turned out wrong —
-- corrected here once real SHOW PIPES output from all four confirmed it.)
-- See location_ingestion_pipeline.sql / pricing_ingestion_pipeline.sql /
-- inventory_ingestion_pipeline.sql for the other three.


-- =====================================================================
-- WALMART
-- Same pattern as Kroger above, and the same run-once-then-automatic
-- rule applies once the pipe + S3 Event Notification are wired up.
-- Reuses the existing MY_CSV_INFER file format and GROCERY_PRICE_PROJECT
-- storage integration (STORAGE_ALLOWED_LOCATIONS already includes the
-- walmart/ prefix) — only a new stage, table, and pipe are needed.
--
-- NOTE: as of this writing, s3://grocerydbtprojectrawdata/walmart/ has no
-- catalog file in it yet (Walmart script still blocked on Prod API
-- access). The INFER_SCHEMA / CREATE TABLE steps below need at least one
-- real file present to succeed — everything through the stage creation
-- can run now; those two will error with "Object does not exist" or an
-- empty result until a file lands there.
-- =====================================================================

-- 1. [RUN ONCE] External stage pointing at the walmart/ prefix
CREATE OR REPLACE STAGE GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  URL = 's3://grocerydbtprojectrawdata/walmart/'
  FILE_FORMAT = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER;

-- 2. [INFORMATIONAL] Preview the inferred schema (requires a real file in walmart/ first)
SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART',
    FILE_FORMAT => 'GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER'
  )
);

-- 3. [RUN ONCE] Create the table using the inferred schema.
-- Same caveat as Kroger: OR REPLACE wipes data and drops INGESTED_FILENAME.
CREATE OR REPLACE TABLE GROCERYDBTPROJECT.RAW.WALMART_PRODUCT_CATALOG
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION => '@GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART',
        FILE_FORMAT => 'GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER'
      )
    )
  );

-- 3b. [RUN ONCE] Add a column to hold which source file each row came from.
ALTER TABLE GROCERYDBTPROJECT.RAW.WALMART_PRODUCT_CATALOG
  ADD COLUMN IF NOT EXISTS INGESTED_FILENAME STRING;

-- 4. [RUN ONCE — then AUTOMATIC] Snowpipe: auto-loads any new file that
-- lands under walmart/ into RAW.WALMART_PRODUCT_CATALOG. Same as Kroger's
-- pipe — once this and its S3 Event Notification exist, no further manual
-- steps are needed for new files.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.WALMART_PRODUCT_CATALOG_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.RAW.WALMART_PRODUCT_CATALOG
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME);

-- 5. [INFORMATIONAL — only needed once, to wire up AWS]
SHOW PIPES LIKE 'WALMART_PRODUCT_CATALOG_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES;
-- ^ The notification channel appears to be tied to the STAGE, not the
-- pipe (confirmed 2026-08-10: all four Kroger pipes, which share one
-- stage, share one queue). This pipe reads from a DIFFERENT stage
-- (MY_S3_STAGE_WALMART), so it likely gets its own distinct queue —
-- unverified since Walmart data is still blocked upstream (see Walmart
-- API section in .claude/instructions.md). When Walmart is unblocked,
-- confirm via this SHOW PIPES output, then add a SEPARATE S3 Event
-- Notification on the bucket for the walmart/ prefix pointed at whatever
-- ARN comes back — don't assume it's the same as Kroger's shared queue.
