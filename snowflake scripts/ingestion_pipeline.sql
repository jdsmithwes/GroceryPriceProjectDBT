USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;
USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS GROCERYDBTPROJECT;
USE DATABASE GROCERYDBTPROJECT;

CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.RAW;
CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.AWS_RESOURCES;


-- File Format for CSV files
-- FIELD_OPTIONALLY_ENCLOSED_BY tells Snowflake to honor the double-quotes
-- pandas wraps around any field containing a comma (e.g. the "categories"
-- column, which joins multiple values with ", "). Without it, commas
-- inside quoted fields are treated as column separators.
CREATE OR REPLACE FILE FORMAT GROCERYDBTPROJECT.AWS_RESOURCES.GROCERY_CSV
    TYPE = CSV
    FIELD_OPTIONALLY_ENCLOSED_BY = '"';

-- Storage Integration for Snowflake to access S3 bucket
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

DESC STORAGE INTEGRATION GROCERY_PRICE_PROJECT;
-- ^ Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from this
-- output into the trust policy of GroceryPriceProjectSnowflakeRole in AWS
-- before the stages/INFER_SCHEMA calls below will actually be able to read
-- from the bucket.

-- External Stage for Grocery Price Project S3 Bucket
CREATE OR REPLACE STAGE GROCERYDBTPROJECT.AWS_RESOURCES.GROCERY_PRICE_PROJECT_STAGE
  URL = 's3://grocerydbtprojectrawdata/'
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.GROCERY_CSV);

-- 1. Create a file format with PARSE_HEADER to read column names
CREATE OR REPLACE FILE FORMAT GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_OPTIONALLY_ENCLOSED_BY = '"';

-- 2. Create an external stage pointing to your S3 bucket
CREATE OR REPLACE STAGE GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  URL = 's3://grocerydbtprojectrawdata/kroger/'
  FILE_FORMAT = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER;

-- 3. Preview the inferred schema
SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER',
    FILE_FORMAT => 'GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER'
  )
);

-- 4. Create the table using the inferred schema
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

-- 4b. Add a column to hold which source file each row came from.
ALTER TABLE GROCERYDBTPROJECT.RAW.KROGER_PRODUCT_CATALOG
  ADD COLUMN IF NOT EXISTS INGESTED_FILENAME STRING;

-- 5. Snowpipe: auto-load any new file that lands under kroger/ into RAW.KROGER_PRODUCT_CATALOG.
-- MATCH_BY_COLUMN_NAME is required here since the file format uses PARSE_HEADER
-- and the table was built directly from the inferred (named) columns above.
-- INCLUDE_METADATA is what lets METADATA$FILENAME coexist with
-- MATCH_BY_COLUMN_NAME (they can't be combined via a plain SELECT list
-- without abandoning name-based matching) — this is a newer COPY INTO
-- clause, so worth double-checking it runs clean on first execution.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.KROGER_PRODUCT_CATALOG_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.RAW.KROGER_PRODUCT_CATALOG
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_KROGER
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME);

SHOW PIPES LIKE 'KROGER_PRODUCT_CATALOG_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES;
-- ^ Copy the "notification_channel" value (an SQS queue ARN) from this
-- output. In AWS, add an S3 Event Notification on the bucket — prefix
-- "kroger/", event type "All object create events" — with that SQS ARN as
-- the destination. That's what actually triggers the pipe; nothing loads
-- automatically until this AWS-side step is done.


-- =====================================================================
-- WALMART: same pattern as Kroger above. Reuses the existing
-- MY_CSV_INFER file format and GROCERY_PRICE_PROJECT storage integration
-- (STORAGE_ALLOWED_LOCATIONS already includes the walmart/ prefix) — only
-- a new stage, table, and pipe are needed.
--
-- NOTE: as of this writing, s3://grocerydbtprojectrawdata/walmart/ has no
-- catalog file in it yet (Walmart script still blocked on Prod API
-- access). The INFER_SCHEMA / CREATE TABLE steps below need at least one
-- real file present to succeed — everything through the stage creation
-- can run now; those two will error with "Object does not exist" or an
-- empty result until a file lands there.
-- =====================================================================

-- 1. External stage pointing at the walmart/ prefix
CREATE OR REPLACE STAGE GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART
  STORAGE_INTEGRATION = GROCERY_PRICE_PROJECT
  URL = 's3://grocerydbtprojectrawdata/walmart/'
  FILE_FORMAT = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER;

-- 2. Preview the inferred schema (requires a real file in walmart/ first)
SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART',
    FILE_FORMAT => 'GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER'
  )
);

-- 3. Create the table using the inferred schema
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

-- 3b. Add a column to hold which source file each row came from.
ALTER TABLE GROCERYDBTPROJECT.RAW.WALMART_PRODUCT_CATALOG
  ADD COLUMN IF NOT EXISTS INGESTED_FILENAME STRING;

-- 4. Snowpipe: auto-load any new file that lands under walmart/ into RAW.WALMART_PRODUCT_CATALOG.
CREATE OR REPLACE PIPE GROCERYDBTPROJECT.AWS_RESOURCES.WALMART_PRODUCT_CATALOG_PIPE
  AUTO_INGEST = TRUE
AS
  COPY INTO GROCERYDBTPROJECT.RAW.WALMART_PRODUCT_CATALOG
  FROM @GROCERYDBTPROJECT.AWS_RESOURCES.MY_S3_STAGE_WALMART
  FILE_FORMAT = (FORMAT_NAME = GROCERYDBTPROJECT.AWS_RESOURCES.MY_CSV_INFER)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (INGESTED_FILENAME = METADATA$FILENAME);

SHOW PIPES LIKE 'WALMART_PRODUCT_CATALOG_PIPE' IN SCHEMA GROCERYDBTPROJECT.AWS_RESOURCES;
-- ^ This pipe gets its OWN SQS queue — a different ARN than Kroger's pipe.
-- Copy this "notification_channel" value and add a SEPARATE S3 Event
-- Notification on the bucket — prefix "walmart/", event type "All object
-- create events" — pointed at this ARN. Reusing Kroger's queue/notification
-- won't work; each pipe needs its own.
