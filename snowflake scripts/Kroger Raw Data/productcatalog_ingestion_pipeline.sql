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

-- [RUN ONCE] NOTE: the raw schema is GROCERY_RAW, not RAW — renamed at some
-- point after 2026-08-11 (see .claude/instructions.md's Snowflake section).
-- This line is kept only as a historical record of what originally ran;
-- don't create a literal RAW schema from this.
CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_RAW;
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
CREATE OR REPLACE TABLE GROCERYDBTPROJECT.GROCERY_RAW.KROGER_PRODUCT_CATALOG
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
ALTER TABLE GROCERYDBTPROJECT.GROCERY_RAW.KROGER_PRODUCT_CATALOG
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
  COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.KROGER_PRODUCT_CATALOG
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
COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.KROGER_PRODUCT_CATALOG
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
-- walmart/ prefix). The stage (step 1) was already created 2026-08-10,
-- before Walmart auth was even working — only the table and pipe were
-- actually new work as of 2026-08-31.
--
-- Auth resolved 2026-08-31 (see .claude/instructions.md's Walmart
-- section and entire_productcatalog_walmart.py's docstring). At that
-- point walmart/ held two file shapes that are NOT the product catalog:
-- a small TEST_walmart_grocery_catalog_*.csv (used below only to bootstrap
-- INFER_SCHEMA, since its columns match flatten_product()'s real output)
-- and walmart_taxonomy_*.csv (a completely different shape — id/name/path/
-- depth/parent_id from walmart_taxonomy.py, a one-off reference pull, not
-- part of the ongoing catalog inflow). The pipe's PATTERN below is
-- anchored specifically so it never loads either of those into the
-- product catalog table — same lesson as Kroger's PATTERN comment above:
-- once a stage might ever hold more than one file shape, don't rely on
-- MATCH_BY_COLUMN_NAME alone to sort it out.
-- =====================================================================

-- 1. [RUN ONCE — already done 2026-08-10] External stage pointing at the
-- walmart/ prefix. Kept here for reference/idempotency, not new work.
CREATE OR REPLACE STAGE GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  URL = 's3://grocerydbtprojectrawdata/walmart/'
  FILE_FORMAT = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER;

-- 2. [INFORMATIONAL] Preview the inferred schema. Scoped to the TEST
-- bootstrap file specifically via FILES => (...) — without this,
-- INFER_SCHEMA would also see walmart_taxonomy_*.csv sitting in the same
-- prefix and either error or produce a garbled merged schema. Useful to
-- eyeball, but NOT used to drive step 3 below — see that step's comment
-- for why.
SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART',
    FILE_FORMAT => 'GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER',
    FILES => ('TEST_walmart_grocery_catalog_2026-08-31T220212Z.csv')
  )
);

-- 3. [RUN ONCE] Create the table with an EXPLICIT schema — deliberately
-- NOT USING TEMPLATE (...INFER_SCHEMA...) like Kroger's step 3 above.
-- Tried that first (2026-08-31) and it produced dangerously narrow types
-- from the tiny 5-row TEST sample: itemId NUMBER(4,0) (real itemIds run to
-- 6+ digits — would overflow), upc NUMBER(12,0) (strips leading zeros,
-- the exact documented Kroger UPC lesson — see instructions.md), msrp/
-- salePrice NUMBER(4,2) (caps at $99.99). Matches Kroger's actual live
-- table instead (confirmed via DESCRIBE TABLE, 2026-08-31): every column
-- VARCHAR except the timestamp — sidesteps type-inference risk entirely,
-- real numeric/boolean casting happens in dbt, not here. Column list
-- matches flatten_product()'s output in entire_productcatalog_walmart.py.
CREATE OR REPLACE TABLE GROCERYDBTPROJECT.GROCERY_RAW.WALMART_PRODUCT_CATALOG (
  itemId VARCHAR,
  parentItemId VARCHAR,
  upc VARCHAR,
  name VARCHAR,
  brandName VARCHAR,
  categoryPath VARCHAR,
  categoryNode VARCHAR,
  msrp VARCHAR,
  salePrice VARCHAR,
  longDescription VARCHAR,
  stock VARCHAR,
  marketplace VARCHAR,
  sellerInfo VARCHAR,
  customerRating VARCHAR,
  numReviews VARCHAR,
  clearance VARCHAR,
  mediumImage VARCHAR,
  productTrackingUrl VARCHAR,
  collected_at TIMESTAMP_NTZ(9)
);

-- 3b. [RUN ONCE] Add a column to hold which source file each row came from.
ALTER TABLE GROCERYDBTPROJECT.GROCERY_RAW.WALMART_PRODUCT_CATALOG
  ADD COLUMN IF NOT EXISTS INGESTED_FILENAME STRING;

-- 4. [RUN ONCE — then AUTOMATIC] Snowpipe: auto-loads any new file
-- matching PATTERN under walmart/ into GROCERY_RAW.WALMART_PRODUCT_CATALOG.
-- PATTERN is anchored (starts right after the stage's own walmart/ prefix,
-- no leading .*) specifically to exclude TEST_-prefixed and
-- walmart_taxonomy_*.csv files sitting in the same prefix — see the
-- section header above.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.WALMART_PRODUCT_CATALOG_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.WALMART_PRODUCT_CATALOG
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART
  PATTERN = 'walmart_grocery_catalog_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME);
-- NOTE: PATTERN here is relative to the STAGE's own URL (already scoped to
-- .../walmart/), unlike Kroger's PATTERN above which is relative to a
-- stage covering multiple source prefixes — don't copy Kroger's leading
-- .* onto this one, it isn't needed and would defeat the anchoring.

-- 4b. [ONE-TIME / ON-DEMAND — NOT part of the automatic path] Manual
-- backfill, same purpose as Kroger's 4b above.
COPY INTO GROCERYDBTPROJECT.GROCERY_RAW.WALMART_PRODUCT_CATALOG
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART
  PATTERN = 'walmart_grocery_catalog_.*[.]csv'
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME)
  FORCE = TRUE;

-- 5. [INFORMATIONAL — only needed once, to wire up AWS]
SHOW PIPES LIKE 'WALMART_PRODUCT_CATALOG_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES;
-- ^ CONFIRMED 2026-08-31: notification_channel matched the same shared
-- queue ARN as Kroger's own four pipes, exactly as predicted (both
-- sources' stages share the GROCERY_PRICE_PROJECT storage integration,
-- and the channel is bound to the integration, not the stage). A new S3
-- Event Notification entry ("WalmartCatalogSnowpipeNotification", prefix
-- "walmart/", suffix ".csv") was added to the bucket's existing
-- notification config the same day, merged alongside Kroger's existing
-- entry — done via `aws s3api put-bucket-notification-configuration`
-- with the full merged config (that API replaces the whole config, so
-- always GET first and merge, never PUT a partial one).
--
-- FULLY VERIFIED END-TO-END, 2026-08-31: stage, table (explicit VARCHAR
-- schema, see step 3), pipe, PATTERN, S3 Event Notification, and
-- AUTO_INGEST were all proven working with real (small, synthetic-upload)
-- test data. Two early fresh-upload tests over a combined ~25 minutes
-- showed no auto-trigger (a manual `ALTER PIPE ... REFRESH` was used to
-- confirm the pipe/table/pattern themselves were correct in the
-- meantime — same recovery technique as the historical Kroger
-- STOPPED_MISSING_TABLE incident) — this turned out to be one-time AWS
-- propagation delay after the bucket's notification config changed for
-- the first time in a while, not a real misconfiguration: a third test
-- auto-ingested in ~17 seconds (upload to row landing), matching
-- Kroger's normal latency exactly. No special handling needed going
-- forward — this behaves like every other source now.
-- (All verification rows were TRUNCATEd afterward; the table was empty
-- again before any real production data was expected.)
