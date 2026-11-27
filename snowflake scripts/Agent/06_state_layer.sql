-- Grocery value agent — Phase 6: transactional state layer (hybrid tables).
--
-- The Snowflake counterpart of the "Lakebase" half of Databricks' LTAP design
-- (Agent/ARCHITECTURE.md §4): row-store tables, inside the same database and
-- RBAC as the marts, that hold what the agent must remember between requests
-- — the shopper's ZIP and preferred stores, named shopping lists, price
-- watches and their alerts, feedback, and a run log. Agents read and write
-- them through the procedures below, exposed as tools in 05_agent.sql. The
-- analytical marts stay read-only for agents.
--
-- Hybrid tables: every table needs a PRIMARY KEY; VARIANT/ARRAY columns are
-- avoided (JSON is stored as VARCHAR). Point reads/writes are millisecond-
-- scale and do not contend with the dynamic-table refreshes.
--
-- Shopper identity: CURRENT_USER() inside EXECUTE AS CALLER procedures. One
-- shopper today; the key is there so more can follow.
--
-- Run as ACCOUNTADMIN after 01 (roles, GROCERY_AGENT_WH). Sandbox variant:
--   sed -E 's/GROCERY_(APP|SEMANTIC|MARTS|ML|RAW)([^_A-Za-z0-9]|$)/GROCERY_DEV_\1\2/g; s/GROCERY_AGENT_WH/COMPUTE_WH/g; /^-- PROD ONLY/,$d'
-- (the schema name also appears without a trailing dot in CREATE SCHEMA, so
--  the pattern matches the name followed by any non-identifier character)

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GROCERY_AGENT_WH;

CREATE SCHEMA IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP
    COMMENT = 'Agent state (hybrid tables): shopper preferences, lists, price watches, feedback, run log';

------------------------------------------------------------------------------
-- 1. Tables
------------------------------------------------------------------------------
CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.SHOPPER_PREFERENCE (
    SHOPPER_ID          VARCHAR NOT NULL,
    HOME_ZIP            VARCHAR(5),
    PREFERRED_STORE_IDS VARCHAR COMMENT 'JSON array of Kroger STORE_IDs',
    NOTES               VARCHAR COMMENT 'Free text the shopper asked the agent to remember (diet, household size, brands to avoid)',
    UPDATED_AT          TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (SHOPPER_ID)
) COMMENT = 'One row per shopper: what the agent should remember about them.';

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST (
    LIST_ID     VARCHAR NOT NULL DEFAULT UUID_STRING(),
    SHOPPER_ID  VARCHAR NOT NULL,
    LIST_NAME   VARCHAR NOT NULL,
    CREATED_AT  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (LIST_ID),
    UNIQUE (SHOPPER_ID, LIST_NAME)
) COMMENT = 'Named shopping lists per shopper (e.g. "weekly", "thanksgiving").';

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM (
    ITEM_ID     VARCHAR NOT NULL DEFAULT UUID_STRING(),
    LIST_ID     VARCHAR NOT NULL,
    POSITION    NUMBER  NOT NULL,
    ITEM_TEXT   VARCHAR NOT NULL COMMENT 'What the shopper typed, e.g. "whole milk gallon"',
    PRODUCT_KEY VARCHAR COMMENT 'Resolved catalog product when the shopper confirmed one',
    ADDED_AT    TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (ITEM_ID),
    INDEX IDX_LIST (LIST_ID)
) COMMENT = 'Items on a shopping list, in order.';

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.PRICE_WATCH (
    WATCH_ID       VARCHAR NOT NULL DEFAULT UUID_STRING(),
    SHOPPER_ID     VARCHAR NOT NULL,
    PRODUCT_KEY    VARCHAR NOT NULL,
    TARGET_PRICE   NUMBER(10,2) COMMENT 'Alert when the lowest current price is at or below this; NULL = alert at a historic low only',
    IS_ACTIVE      BOOLEAN DEFAULT TRUE,
    CREATED_AT     TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (WATCH_ID),
    INDEX IDX_SHOPPER (SHOPPER_ID)
) COMMENT = 'Products a shopper wants to be told about when the price is right.';

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.PRICE_ALERT (
    ALERT_ID        VARCHAR NOT NULL DEFAULT UUID_STRING(),
    WATCH_ID        VARCHAR NOT NULL,
    SHOPPER_ID      VARCHAR NOT NULL,
    PRODUCT_KEY     VARCHAR NOT NULL,
    PRICE_WEEK      DATE    NOT NULL,
    PRICE           NUMBER(10,2),
    STORE_ID        VARCHAR,
    REASON          VARCHAR COMMENT 'at_or_below_target | historic_low',
    IS_ACKNOWLEDGED BOOLEAN DEFAULT FALSE,
    CREATED_AT      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (ALERT_ID),
    UNIQUE (WATCH_ID, PRICE_WEEK, REASON),
    INDEX IDX_SHOPPER_ACK (SHOPPER_ID, IS_ACKNOWLEDGED)
) COMMENT = 'Alerts raised by SP_CHECK_PRICE_WATCHES (weekly task); the agent reports unacknowledged ones.';

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.AGENT_FEEDBACK (
    FEEDBACK_ID    VARCHAR NOT NULL DEFAULT UUID_STRING(),
    SHOPPER_ID     VARCHAR NOT NULL,
    QUESTION       VARCHAR,
    ANSWER_SUMMARY VARCHAR,
    RATING         NUMBER(1) COMMENT '1 = wrong/unhelpful ... 5 = exactly right',
    COMMENT        VARCHAR,
    CREATED_AT     TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (FEEDBACK_ID)
) COMMENT = 'Shopper feedback on answers; reviewed with the golden-question evals.';

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.AGENT_RUN_LOG (
    RUN_ID      VARCHAR NOT NULL DEFAULT UUID_STRING(),
    SHOPPER_ID  VARCHAR,
    SOURCE      VARCHAR COMMENT 'eval | intelligence | api',
    QUESTION    VARCHAR,
    TOOLS       VARCHAR COMMENT 'JSON array of tool names used',
    LATENCY_MS  NUMBER,
    PASSED      BOOLEAN COMMENT 'Eval verdict when SOURCE = eval',
    CREATED_AT  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (RUN_ID)
) COMMENT = 'One row per agent request we know about (eval runner writes these).';

------------------------------------------------------------------------------
-- 2. Procedures (agent tools). All EXECUTE AS CALLER; shopper = CURRENT_USER().
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_SET_PREFERENCE(
    HOME_ZIP VARCHAR DEFAULT NULL, PREFERRED_STORE_IDS VARCHAR DEFAULT NULL, NOTES VARCHAR DEFAULT NULL)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Remember the shopper''s home ZIP, preferred Kroger store IDs (JSON array string) and free-text notes. Only the arguments given are changed.'
EXECUTE AS CALLER
AS
$$
BEGIN
    MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.SHOPPER_PREFERENCE t
    USING (SELECT CURRENT_USER() AS SHOPPER_ID) s ON t.SHOPPER_ID = s.SHOPPER_ID
    WHEN MATCHED THEN UPDATE SET
        HOME_ZIP = COALESCE(:HOME_ZIP, t.HOME_ZIP),
        PREFERRED_STORE_IDS = COALESCE(:PREFERRED_STORE_IDS, t.PREFERRED_STORE_IDS),
        NOTES = COALESCE(:NOTES, t.NOTES),
        UPDATED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (SHOPPER_ID, HOME_ZIP, PREFERRED_STORE_IDS, NOTES)
        VALUES (s.SHOPPER_ID, :HOME_ZIP, :PREFERRED_STORE_IDS, :NOTES);
    RETURN (SELECT OBJECT_CONSTRUCT('shopper_id', SHOPPER_ID, 'home_zip', HOME_ZIP, 'preferred_store_ids', TRY_PARSE_JSON(PREFERRED_STORE_IDS), 'notes', NOTES, 'updated_at', UPDATED_AT)
            FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPER_PREFERENCE WHERE SHOPPER_ID = CURRENT_USER());
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GET_PROFILE()
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Everything the agent should remember about the shopper: preferences, shopping lists (names + item counts), active price watches, unacknowledged price alerts, and tracked baskets with this week''s rank. Call at the start of a conversation.'
EXECUTE AS CALLER
AS
$$
BEGIN
    RETURN (
        SELECT OBJECT_CONSTRUCT(
            'shopper_id', CURRENT_USER(),
            'preferences', (SELECT OBJECT_CONSTRUCT('home_zip', HOME_ZIP, 'preferred_store_ids', TRY_PARSE_JSON(PREFERRED_STORE_IDS), 'notes', NOTES, 'updated_at', UPDATED_AT)
                            FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPER_PREFERENCE WHERE SHOPPER_ID = CURRENT_USER()),
            'lists', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('list_name', l.LIST_NAME, 'items', n.n, 'updated_at', l.UPDATED_AT)) WITHIN GROUP (ORDER BY l.UPDATED_AT DESC)
                      FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l
                      LEFT JOIN (SELECT LIST_ID, COUNT(*) n FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM GROUP BY 1) n ON n.LIST_ID = l.LIST_ID
                      WHERE l.SHOPPER_ID = CURRENT_USER()),
            'price_watches', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('watch_id', w.WATCH_ID, 'product_key', w.PRODUCT_KEY, 'product', p.PRODUCT_NAME, 'target_price', w.TARGET_PRICE, 'lowest_current_price', r.MIN_CURRENT_PRICE))
                              FROM GROCERYDBTPROJECT.GROCERY_APP.PRICE_WATCH w
                              LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = w.PRODUCT_KEY
                              LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_ROLLUP r ON r.PRODUCT_KEY = w.PRODUCT_KEY
                              WHERE w.SHOPPER_ID = CURRENT_USER() AND w.IS_ACTIVE),
            'new_alerts', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('alert_id', a.ALERT_ID, 'product_key', a.PRODUCT_KEY, 'product', p.PRODUCT_NAME, 'price', a.PRICE, 'store_id', a.STORE_ID, 'reason', a.REASON, 'price_week', a.PRICE_WEEK)) WITHIN GROUP (ORDER BY a.CREATED_AT DESC)
                           FROM GROCERYDBTPROJECT.GROCERY_APP.PRICE_ALERT a
                           LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = a.PRODUCT_KEY
                           WHERE a.SHOPPER_ID = CURRENT_USER() AND NOT a.IS_ACKNOWLEDGED),
            -- tracked baskets (07_basket_watch.sql): rank this week + unseen alerts
            'basket_watches', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('list_name', s.LIST_NAME, 'current_total', s.CURRENT_TOTAL,
                                                                 'cheaper_than_pct', s.CHEAPER_THAN_PCT, 'is_good_time', s.IS_GOOD_TIME,
                                                                 'new_alerts', COALESCE(ba.n, 0)))
                               FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_STATUS s
                               LEFT JOIN (SELECT WATCH_ID, COUNT(*) n FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT
                                          WHERE SHOPPER_ID = CURRENT_USER() AND NOT IS_ACKNOWLEDGED GROUP BY 1) ba ON ba.WATCH_ID = s.WATCH_ID
                               WHERE s.SHOPPER_ID = CURRENT_USER())
        )
    );
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_SAVE_LIST(LIST_NAME VARCHAR, ITEMS_TEXT VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Create or replace a named shopping list. ITEMS_TEXT is a JSON array of item names or a comma-separated list. Returns the saved list.'
EXECUTE AS CALLER
AS
$$
DECLARE
    items   ARRAY;
    list_id VARCHAR;
BEGIN
    items := COALESCE(TRY_PARSE_JSON(:ITEMS_TEXT)::ARRAY, SPLIT(:ITEMS_TEXT, ','));
    MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST t
    USING (SELECT CURRENT_USER() AS SHOPPER_ID, :LIST_NAME AS LIST_NAME) s
       ON t.SHOPPER_ID = s.SHOPPER_ID AND t.LIST_NAME = s.LIST_NAME
    WHEN MATCHED THEN UPDATE SET UPDATED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (SHOPPER_ID, LIST_NAME) VALUES (s.SHOPPER_ID, s.LIST_NAME);
    SELECT LIST_ID INTO :list_id FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST
    WHERE SHOPPER_ID = CURRENT_USER() AND LIST_NAME = :LIST_NAME;
    DELETE FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM WHERE LIST_ID = :list_id;
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM (LIST_ID, POSITION, ITEM_TEXT)
    SELECT :list_id, index, TRIM(value::STRING) FROM TABLE(FLATTEN(INPUT => :items)) WHERE TRIM(value::STRING) <> '';
    RETURN (SELECT OBJECT_CONSTRUCT('list_name', :LIST_NAME, 'items', ARRAY_AGG(ITEM_TEXT) WITHIN GROUP (ORDER BY POSITION))
            FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM WHERE LIST_ID = :list_id);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GET_LIST(LIST_NAME VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Return a saved shopping list: its items as a JSON array (pass items_json to compare_basket) and the shopper''s home ZIP.'
EXECUTE AS CALLER
AS
$$
BEGIN
    RETURN (
        SELECT OBJECT_CONSTRUCT(
            'list_name', :LIST_NAME,
            'items', ARRAY_AGG(i.ITEM_TEXT) WITHIN GROUP (ORDER BY i.POSITION),
            'items_json', TO_JSON(ARRAY_AGG(i.ITEM_TEXT) WITHIN GROUP (ORDER BY i.POSITION)),
            'home_zip', (SELECT HOME_ZIP FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPER_PREFERENCE WHERE SHOPPER_ID = CURRENT_USER()))
        FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l
        JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM i ON i.LIST_ID = l.LIST_ID
        WHERE l.SHOPPER_ID = CURRENT_USER() AND l.LIST_NAME = :LIST_NAME
    );
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_WATCH_PRODUCT(PRODUCT_KEY VARCHAR, TARGET_PRICE NUMBER DEFAULT NULL)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Watch a product (PRODUCT_KEY from product_search or the semantic view): alert when its lowest current price is at or below TARGET_PRICE, or at a historic low when no target is given. Checked weekly.'
EXECUTE AS CALLER
AS
$$
BEGIN
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.PRICE_WATCH (SHOPPER_ID, PRODUCT_KEY, TARGET_PRICE)
    VALUES (CURRENT_USER(), :PRODUCT_KEY, :TARGET_PRICE);
    RETURN (SELECT OBJECT_CONSTRUCT('product_key', w.PRODUCT_KEY, 'product', p.PRODUCT_NAME, 'target_price', w.TARGET_PRICE,
                                    'lowest_current_price', r.MIN_CURRENT_PRICE, 'checked', 'weekly, Sundays')
            FROM GROCERYDBTPROJECT.GROCERY_APP.PRICE_WATCH w
            LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = w.PRODUCT_KEY
            LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_ROLLUP r ON r.PRODUCT_KEY = w.PRODUCT_KEY
            WHERE w.SHOPPER_ID = CURRENT_USER() AND w.PRODUCT_KEY = :PRODUCT_KEY
            ORDER BY w.CREATED_AT DESC LIMIT 1);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_CHECK_PRICE_WATCHES()
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Weekly (task): raise a PRICE_ALERT for every active watch whose product is at or below its target price, or at a historic low. One alert per watch, week and reason.'
EXECUTE AS CALLER
AS
$$
BEGIN
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.PRICE_ALERT (WATCH_ID, SHOPPER_ID, PRODUCT_KEY, PRICE_WEEK, PRICE, STORE_ID, REASON)
    SELECT w.WATCH_ID, w.SHOPPER_ID, w.PRODUCT_KEY, r.RETAILER_LATEST_WEEK, r.MIN_CURRENT_PRICE, r.CHEAPEST_STORE_ID,
           IFF(w.TARGET_PRICE IS NOT NULL AND r.MIN_CURRENT_PRICE <= w.TARGET_PRICE, 'at_or_below_target', 'historic_low') AS REASON
    FROM GROCERYDBTPROJECT.GROCERY_APP.PRICE_WATCH w
    JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_ROLLUP r ON r.PRODUCT_KEY = w.PRODUCT_KEY
    WHERE w.IS_ACTIVE
      AND ((w.TARGET_PRICE IS NOT NULL AND r.MIN_CURRENT_PRICE <= w.TARGET_PRICE) OR r.STORES_AT_HISTORIC_LOW > 0)
      AND NOT EXISTS (SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_APP.PRICE_ALERT a
                      WHERE a.WATCH_ID = w.WATCH_ID AND a.PRICE_WEEK = r.RETAILER_LATEST_WEEK
                        AND a.REASON = IFF(w.TARGET_PRICE IS NOT NULL AND r.MIN_CURRENT_PRICE <= w.TARGET_PRICE, 'at_or_below_target', 'historic_low'));
    RETURN OBJECT_CONSTRUCT('alerts_raised', SQLROWCOUNT, 'checked_at', CURRENT_TIMESTAMP());
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_ACKNOWLEDGE_ALERTS()
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Mark the shopper''s price alerts as seen after reporting them.'
EXECUTE AS CALLER
AS
$$
BEGIN
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.PRICE_ALERT SET IS_ACKNOWLEDGED = TRUE
    WHERE SHOPPER_ID = CURRENT_USER() AND NOT IS_ACKNOWLEDGED;
    RETURN OBJECT_CONSTRUCT('acknowledged', SQLROWCOUNT);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_RECORD_FEEDBACK(
    QUESTION VARCHAR, ANSWER_SUMMARY VARCHAR, RATING NUMBER, COMMENT VARCHAR DEFAULT NULL)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Store the shopper''s feedback on an answer (RATING 1-5 and an optional comment).'
EXECUTE AS CALLER
AS
$$
BEGIN
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.AGENT_FEEDBACK (SHOPPER_ID, QUESTION, ANSWER_SUMMARY, RATING, COMMENT)
    VALUES (CURRENT_USER(), :QUESTION, :ANSWER_SUMMARY, :RATING, :COMMENT);
    RETURN OBJECT_CONSTRUCT('recorded', TRUE, 'rating', :RATING);
END;
$$;

-- PROD ONLY: grants (GROCERY_AGENT_USER reads/writes its own state through the procedures)
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_APP TO ROLE GROCERY_AGENT_USER;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_APP TO ROLE GROCERY_AGENT_USER;
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_APP TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA GROCERYDBTPROJECT.GROCERY_APP TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA GROCERYDBTPROJECT.GROCERY_APP TO ROLE GROCERY_AGENT_USER;
