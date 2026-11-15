-- Grocery value agent — product-type labels (fine-grained "what is this item":
-- peanut butter, whole turkey, turkey lunch meat, cat food, ...).
--
-- Why: name matching cannot tell product types apart ("peanut butter" returns
-- cookies and ice cream; "turkey" returns pet food), which breaks per-ounce
-- rankings, store-brand savings, substitutes and basket matching. A label per
-- product fixes all four. Labels come from CORTEX.COMPLETE with llama3.1-70b
-- (owner's choice 2026-11-15 after a 200-product sample: cleaner, more
-- groupable labels than 8B; ~106 tokens per product; 13,005 food products
-- ≈ 1.4M tokens ≈ 1.7 credits once, then a few products a week).
--
-- Incremental: SP_LABEL_PRODUCT_TYPES labels only products in dim_product
-- that have no label yet, in batches, so the weekly task can top up new
-- products and a re-run after a failure never pays twice. Labels are stored
-- here (not in dbt) because they are model output; dbt reads the table as
-- source ml.product_type and joins it into dim_product.
--
-- Run as ACCOUNTADMIN in prod. Sandbox gets a clone of the prod table:
--   CREATE OR REPLACE TABLE GROCERYDBTPROJECT.GROCERY_DEV_ML.PRODUCT_TYPE
--       CLONE GROCERYDBTPROJECT.GROCERY_ML.PRODUCT_TYPE;

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GROCERY_AGENT_WH;

CREATE TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_ML.PRODUCT_TYPE (
    PRODUCT_KEY   VARCHAR      NOT NULL PRIMARY KEY COMMENT 'RETAILER:PRODUCT_ID, matches dim_product.PRODUCT_KEY',
    PRODUCT_TYPE  VARCHAR      COMMENT 'Normalized label: lowercase noun phrase, 1-4 words, e.g. peanut butter, whole turkey, cat food',
    RAW_LABEL     VARCHAR      COMMENT 'Model output before normalization',
    MODEL         VARCHAR      COMMENT 'Cortex model that produced the label',
    PROMPT_TOKENS NUMBER,
    TOTAL_TOKENS  NUMBER,
    LABELED_AT    TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Product-type label per food product, from CORTEX.COMPLETE (SP_LABEL_PRODUCT_TYPES). Read by dbt as source ml.product_type.';

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_ML.SP_LABEL_PRODUCT_TYPES(
    MODEL       VARCHAR DEFAULT 'llama3.1-70b',
    BATCH_SIZE  NUMBER  DEFAULT 2000,
    MAX_BATCHES NUMBER  DEFAULT 20
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Labels food products in GROCERY_MARTS.DBT_DIM_PRODUCT that have no row in PRODUCT_TYPE yet, BATCH_SIZE at a time, up to MAX_BATCHES. Returns products labeled and tokens used.'
EXECUTE AS CALLER
AS
$$
DECLARE
    batches INT := 0;
    labeled INT := 0;
    tokens  INT := 0;
    n       INT;
BEGIN
    WHILE (batches < :MAX_BATCHES) DO
        INSERT INTO GROCERYDBTPROJECT.GROCERY_ML.PRODUCT_TYPE
            (PRODUCT_KEY, PRODUCT_TYPE, RAW_LABEL, MODEL, PROMPT_TOKENS, TOTAL_TOKENS)
        WITH todo AS (
            SELECT p.PRODUCT_KEY, p.PRODUCT_NAME, p.BRAND, p.PRIMARY_COMMON_CATEGORY
            FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT p
            LEFT JOIN GROCERYDBTPROJECT.GROCERY_ML.PRODUCT_TYPE t ON t.PRODUCT_KEY = p.PRODUCT_KEY
            WHERE p.IS_FOOD AND t.PRODUCT_KEY IS NULL
            LIMIT :BATCH_SIZE
        ),
        answered AS (
            SELECT PRODUCT_KEY,
                   SNOWFLAKE.CORTEX.COMPLETE(:MODEL,
                       [{'role': 'user', 'content':
                           'Grocery product: "' || PRODUCT_NAME || '" (brand: ' || COALESCE(BRAND, 'unknown') ||
                           ', category: ' || COALESCE(PRIMARY_COMMON_CATEGORY, 'unknown') ||
                           '). Reply with ONLY the product type as a lowercase noun phrase of 1 to 4 words that names what the item is, ignoring brand, flavor and size. Examples: peanut butter, whole turkey, turkey lunch meat, cat food, ice cream, tortilla chips, sparkling water.'}],
                       {'temperature': 0, 'max_tokens': 12}) AS raw
            FROM todo
        )
        SELECT PRODUCT_KEY,
               -- first line, lowercase, letters/digits/spaces/hyphens/& only, single spaces
               NULLIF(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(LOWER(SPLIT_PART(raw:choices[0]:messages::STRING, '\n', 1)), '[^a-z0-9 &-]', '')), ' +', ' '), '') AS PRODUCT_TYPE,
               raw:choices[0]:messages::STRING,
               :MODEL,
               raw:usage:prompt_tokens::INT,
               raw:usage:total_tokens::INT
        FROM answered;

        n := SQLROWCOUNT;
        IF (n = 0) THEN
            BREAK;
        END IF;
        labeled := labeled + n;
        batches := batches + 1;
    END WHILE;

    SELECT COALESCE(SUM(TOTAL_TOKENS), 0) INTO :tokens
    FROM GROCERYDBTPROJECT.GROCERY_ML.PRODUCT_TYPE
    WHERE LABELED_AT >= DATEADD(hour, -6, CURRENT_TIMESTAMP());

    RETURN OBJECT_CONSTRUCT('model', :MODEL, 'batches', batches, 'products_labeled', labeled, 'tokens_last_6h', tokens);
END;
$$;

-- Later: the Sunday task calls this after dim_product refreshes (see 04's task
-- definition) so new products get labels within a week.
