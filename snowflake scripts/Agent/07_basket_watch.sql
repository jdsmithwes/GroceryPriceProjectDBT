-- Grocery value agent — Phase 7: basket watch.
--
-- A shopper saves a basket (a SHOPPING_LIST whose items carry the exact
-- PRODUCT_KEY they were priced on), sees its weekly total over the trailing
-- 12 weeks, and is told when it is a good time to buy — the basket, an item
-- in it, or a look-alike item that is a better buy.
--
-- One statistic everywhere: PERCENTILE RANK, "cheaper than X% of the last
-- 12 weeks" = the share of the other observed weeks whose price was higher
-- than today's (0-100). Robust to one-week promos; a price that never changes
-- scores 0 (no deal). Items: fct_buy_recommendation.CHEAPER_THAN_PCT (dbt).
-- Basket: the same formula over the weekly basket totals (V_BASKET_STATUS).
-- Good time = rank >= the watch's GOOD_PCT (default 75, dbt var
-- basket_good_pct) with at least 6 weeks of history.
--
-- Look-alike ("similar") = same retailer, same PRODUCT_TYPE (Cortex label),
-- same UNIT_BASIS, unit price parsed with high confidence, at least 10%
-- cheaper per unit (dbt var similar_min_unit_saving_pct) but not more than
-- 70% cheaper (bigger gaps are almost always a size-parse error), currently
-- listed, and itself at a good rank. At most 3 per item, cheapest per unit
-- first. Never an item already in the basket.
--
-- Weekly: SP_CHECK_BASKET_WATCHES() runs in TASK_WEEKLY_PRICE_FORECAST after
-- SP_CHECK_PRICE_WATCHES (04_search_and_basket_tool.sql), writes BASKET_ALERT
-- rows (one per watch, week, kind, product) and sends ONE email with every
-- new alert to the ops alert_email setting (GROCERY_OPS.OPS_SETTING; the
-- owner app has one shopper, the owner). The address is never in this file.
--
-- Guests: Snowflake Scripts/Guest/03_guest_basket_watch.sql (session-scoped
-- procedures, SHOPPER_ID 'guest:<id>', in-app alerts only, never emailed).
--
-- Run as ACCOUNTADMIN after 06. Sandbox variant (same as 06):
--   sed -E 's/GROCERY_(APP|SEMANTIC|MARTS|ML|RAW)([^_A-Za-z0-9]|$)/GROCERY_DEV_\1\2/g; s/GROCERY_AGENT_WH/COMPUTE_WH/g; /^-- PROD ONLY/,$d'
-- (GROCERY_OPS is not rewritten: the sandbox reads the prod email setting.)

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GROCERY_AGENT_WH;

------------------------------------------------------------------------------
-- 1. Tables (hybrid; JSON as VARCHAR)
------------------------------------------------------------------------------
CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH (
    WATCH_ID        VARCHAR NOT NULL DEFAULT UUID_STRING(),
    SHOPPER_ID      VARCHAR NOT NULL,
    LIST_ID         VARCHAR NOT NULL,
    GOOD_PCT        NUMBER(3,0) DEFAULT 75 COMMENT 'Good time to buy = cheaper than at least this % of the trailing weeks',
    INCLUDE_SIMILAR BOOLEAN DEFAULT TRUE COMMENT 'Also suggest look-alike items that are a better buy',
    EMAIL           BOOLEAN DEFAULT TRUE COMMENT 'Include this basket in the weekly good-time-to-buy email',
    IS_ACTIVE       BOOLEAN DEFAULT TRUE,
    CREATED_AT      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (WATCH_ID),
    UNIQUE (SHOPPER_ID, LIST_ID),
    INDEX IDX_SHOPPER (SHOPPER_ID)
) COMMENT = 'Saved baskets whose price the shopper tracks (one per shopping list).';

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT (
    ALERT_ID         VARCHAR NOT NULL DEFAULT UUID_STRING(),
    WATCH_ID         VARCHAR NOT NULL,
    SHOPPER_ID       VARCHAR NOT NULL,
    PRICE_WEEK       DATE    NOT NULL,
    KIND             VARCHAR NOT NULL COMMENT 'basket | item | similar',
    PRODUCT_KEY      VARCHAR NOT NULL DEFAULT '' COMMENT 'Item or look-alike product; empty for KIND = basket',
    SIMILAR_TO_KEY   VARCHAR NOT NULL DEFAULT '' COMMENT 'Basket item a look-alike replaces; empty otherwise',
    PRICE            NUMBER(10,2) COMMENT 'Basket total or item price',
    UNIT_PRICE       NUMBER(12,4),
    CHEAPER_THAN_PCT NUMBER(3,0),
    DETAIL           VARCHAR COMMENT 'One readable line (used in the email and the app)',
    IS_ACKNOWLEDGED  BOOLEAN DEFAULT FALSE,
    EMAILED_AT       TIMESTAMP_TZ,
    CREATED_AT       TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (ALERT_ID),
    UNIQUE (WATCH_ID, PRICE_WEEK, KIND, PRODUCT_KEY, SIMILAR_TO_KEY),
    INDEX IDX_SHOPPER_ACK (SHOPPER_ID, IS_ACKNOWLEDGED)
) COMMENT = 'Good-time-to-buy alerts raised by SP_CHECK_BASKET_WATCHES (weekly task).';

------------------------------------------------------------------------------
-- 2. Views (set-based; procedures filter by shopper/watch)
------------------------------------------------------------------------------
-- Items of every active watch that resolved to a product.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WATCH_ITEM AS
SELECT w.WATCH_ID, w.SHOPPER_ID, w.LIST_ID, l.LIST_NAME, w.GOOD_PCT, w.INCLUDE_SIMILAR, w.EMAIL,
       i.POSITION, i.ITEM_TEXT, i.PRODUCT_KEY
FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w
JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM i ON i.LIST_ID = w.LIST_ID
WHERE w.IS_ACTIVE AND i.PRODUCT_KEY IS NOT NULL AND i.PRODUCT_KEY <> '';

-- Weekly basket total over the trailing 12 weeks. Each item's weekly price
-- (Kroger: median across stores, Walmart: national) is carried forward over
-- weeks it was not observed; weeks before an item's first observation leave
-- it unpriced, and only weeks where every item has a price are COMPLETE.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WEEKLY AS
WITH weeks AS (
    SELECT DISTINCT PRICE_WEEK
    FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_WEEKLY_SERIES
    WHERE PRICE_WEEK > DATEADD('week', -12, (SELECT MAX(PRICE_WEEK) FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_WEEKLY_SERIES))
),
filled AS (
    SELECT i.WATCH_ID, i.SHOPPER_ID, i.LIST_NAME, i.GOOD_PCT, i.POSITION, wk.PRICE_WEEK, s.EFFECTIVE_PRICE AS OBSERVED_PRICE,
           LAST_VALUE(s.EFFECTIVE_PRICE) IGNORE NULLS OVER (
               PARTITION BY i.WATCH_ID, i.POSITION ORDER BY wk.PRICE_WEEK
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS PRICE
    FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WATCH_ITEM i
    CROSS JOIN weeks wk
    LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_WEEKLY_SERIES s
           ON s.PRODUCT_KEY = i.PRODUCT_KEY AND s.PRICE_WEEK = wk.PRICE_WEEK
)
SELECT WATCH_ID, SHOPPER_ID, LIST_NAME, GOOD_PCT, PRICE_WEEK,
       COUNT(*) AS ITEMS, COUNT(PRICE) AS ITEMS_PRICED, COUNT(OBSERVED_PRICE) AS ITEMS_OBSERVED,
       SUM(PRICE)::NUMBER(10,2) AS BASKET_TOTAL,
       COUNT(PRICE) = COUNT(*) AS IS_COMPLETE
FROM filled
GROUP BY WATCH_ID, SHOPPER_ID, LIST_NAME, GOOD_PCT, PRICE_WEEK;

-- One row per watch: the latest complete week ranked against the others.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_STATUS AS
WITH c AS (
    SELECT * FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WEEKLY WHERE IS_COMPLETE
),
cur AS (
    SELECT * FROM c QUALIFY ROW_NUMBER() OVER (PARTITION BY WATCH_ID ORDER BY PRICE_WEEK DESC) = 1
)
SELECT cur.WATCH_ID, cur.SHOPPER_ID, cur.LIST_NAME, cur.GOOD_PCT, cur.ITEMS,
       cur.PRICE_WEEK AS CURRENT_WEEK, cur.BASKET_TOTAL AS CURRENT_TOTAL,
       COUNT(*) AS WEEKS,
       MIN(c.BASKET_TOTAL) AS LOW_TOTAL,
       MEDIAN(c.BASKET_TOTAL)::NUMBER(10,2) AS MEDIAN_TOTAL,
       MAX(c.BASKET_TOTAL) AS HIGH_TOTAL,
       IFF(COUNT(*) < 2, NULL, ROUND(100 * COUNT_IF(c.BASKET_TOTAL > cur.BASKET_TOTAL) / (COUNT(*) - 1)))::NUMBER(3,0) AS CHEAPER_THAN_PCT,
       COUNT(*) >= 6 AND ROUND(100 * COUNT_IF(c.BASKET_TOTAL > cur.BASKET_TOTAL) / NULLIF(COUNT(*) - 1, 0)) >= cur.GOOD_PCT AS IS_GOOD_TIME
FROM cur JOIN c ON c.WATCH_ID = cur.WATCH_ID
GROUP BY cur.WATCH_ID, cur.SHOPPER_ID, cur.LIST_NAME, cur.GOOD_PCT, cur.ITEMS, cur.PRICE_WEEK, cur.BASKET_TOTAL;

-- Each basket item with its buy signal and rank.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_ITEM_STATUS AS
SELECT i.WATCH_ID, i.SHOPPER_ID, i.LIST_NAME, i.GOOD_PCT, i.POSITION, i.ITEM_TEXT, i.PRODUCT_KEY,
       p.PRODUCT_NAME, p.BRAND, p.SIZE_TEXT, b.RETAILER, b.CURRENT_WEEK, b.IS_CURRENTLY_LISTED,
       b.CURRENT_PRICE, b.UNIT_PRICE, b.UNIT_BASIS, b.WEEKS_OBSERVED, b.CHEAPER_THAN_PCT,
       b.HISTORY_LOW_PRICE, b.HISTORY_MEDIAN_PRICE, b.RECOMMENDATION, b.IS_STOCK_UP_CANDIDATE,
       COALESCE(b.CHEAPER_THAN_PCT >= i.GOOD_PCT AND b.IS_CURRENTLY_LISTED, FALSE) AS IS_GOOD_TIME
FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WATCH_ITEM i
LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_BUY_RECOMMENDATION b ON b.PRODUCT_KEY = i.PRODUCT_KEY
LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = i.PRODUCT_KEY;

-- Look-alike items that are a better buy right now (rules in the header).
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_SIMILAR AS
SELECT i.WATCH_ID, i.SHOPPER_ID, i.LIST_NAME, i.POSITION, i.ITEM_TEXT,
       i.PRODUCT_KEY AS SIMILAR_TO_KEY, b.UNIT_PRICE AS SIMILAR_TO_UNIT_PRICE,
       c.PRODUCT_KEY, p.PRODUCT_NAME, p.BRAND, p.SIZE_TEXT, c.RETAILER, c.CURRENT_WEEK,
       c.CURRENT_PRICE, c.UNIT_PRICE, c.UNIT_BASIS, c.CHEAPER_THAN_PCT, b.PRODUCT_TYPE,
       ROUND(100 * (1 - c.UNIT_PRICE / b.UNIT_PRICE))::NUMBER(3,0) AS UNIT_SAVING_PCT
FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WATCH_ITEM i
JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_BUY_RECOMMENDATION b ON b.PRODUCT_KEY = i.PRODUCT_KEY
JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_BUY_RECOMMENDATION c
     ON c.RETAILER = b.RETAILER AND c.PRODUCT_TYPE = b.PRODUCT_TYPE AND c.UNIT_BASIS = b.UNIT_BASIS
    AND c.PRODUCT_KEY <> b.PRODUCT_KEY
LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = c.PRODUCT_KEY
WHERE i.INCLUDE_SIMILAR
  AND b.UNIT_PRICE > 0 AND c.UNIT_PRICE > 0
  AND c.IS_CURRENTLY_LISTED
  AND c.UNIT_PRICE <= b.UNIT_PRICE * (1 - 0.10)      -- dbt var similar_min_unit_saving_pct
  AND c.UNIT_PRICE >= b.UNIT_PRICE * 0.30            -- > 70% cheaper = size-parse error
  AND c.CHEAPER_THAN_PCT >= i.GOOD_PCT
  AND NOT EXISTS (SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WATCH_ITEM x
                  WHERE x.WATCH_ID = i.WATCH_ID AND x.PRODUCT_KEY = c.PRODUCT_KEY)
QUALIFY ROW_NUMBER() OVER (PARTITION BY i.WATCH_ID, i.POSITION ORDER BY c.UNIT_PRICE, c.PRODUCT_KEY) <= 3;

------------------------------------------------------------------------------
-- 3. Procedures. EXECUTE AS CALLER; shopper = CURRENT_USER().
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_TRACK_BASKET(
    LIST_NAME VARCHAR, ITEMS_JSON VARCHAR, GOOD_PCT NUMBER DEFAULT 75, INCLUDE_SIMILAR BOOLEAN DEFAULT TRUE)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Save a basket and track its price. ITEMS_JSON = [{"item": "whole milk gallon", "product_key": "kroger:..."}] (product keys from compare_basket). Alerts when the basket, an item, or a look-alike is cheaper than at least GOOD_PCT% of the last 12 weeks. Checked weekly.'
EXECUTE AS CALLER
AS
$$
DECLARE
    items   ARRAY;
    list_id VARCHAR;
BEGIN
    items := PARSE_JSON(:ITEMS_JSON)::ARRAY;
    MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST t
    USING (SELECT CURRENT_USER() AS SHOPPER_ID, :LIST_NAME AS LIST_NAME) s
       ON t.SHOPPER_ID = s.SHOPPER_ID AND t.LIST_NAME = s.LIST_NAME
    WHEN MATCHED THEN UPDATE SET UPDATED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (SHOPPER_ID, LIST_NAME) VALUES (s.SHOPPER_ID, s.LIST_NAME);
    SELECT LIST_ID INTO :list_id FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST
    WHERE SHOPPER_ID = CURRENT_USER() AND LIST_NAME = :LIST_NAME;
    DELETE FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM WHERE LIST_ID = :list_id;
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM (LIST_ID, POSITION, ITEM_TEXT, PRODUCT_KEY)
    SELECT :list_id, index,
           TRIM(COALESCE(value:item::STRING, value::STRING)),
           NULLIF(TRIM(value:product_key::STRING), '')
    FROM TABLE(FLATTEN(INPUT => :items))
    WHERE TRIM(COALESCE(value:item::STRING, value::STRING)) <> '';
    MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH t
    USING (SELECT CURRENT_USER() AS SHOPPER_ID, :list_id AS LIST_ID) s
       ON t.SHOPPER_ID = s.SHOPPER_ID AND t.LIST_ID = s.LIST_ID
    WHEN MATCHED THEN UPDATE SET GOOD_PCT = :GOOD_PCT, INCLUDE_SIMILAR = :INCLUDE_SIMILAR, IS_ACTIVE = TRUE, UPDATED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (SHOPPER_ID, LIST_ID, GOOD_PCT, INCLUDE_SIMILAR) VALUES (s.SHOPPER_ID, s.LIST_ID, :GOOD_PCT, :INCLUDE_SIMILAR);
    RETURN (SELECT OBJECT_CONSTRUCT('list_name', :LIST_NAME, 'items', COUNT(*), 'items_tracked', COUNT(PRODUCT_KEY),
                                    'good_pct', :GOOD_PCT, 'checked', 'weekly, Sundays')
            FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM WHERE LIST_ID = :list_id);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_BASKET_STATUS(LIST_NAME VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'A tracked basket now: weekly total for the last 12 weeks, its rank ("cheaper than X% of weeks"), each item''s price and rank, look-alike better buys, and unseen alerts.'
EXECUTE AS CALLER
AS
$$
DECLARE
    wid VARCHAR;
BEGIN
    SELECT MAX(w.WATCH_ID) INTO :wid
    FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w
    JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
    WHERE w.SHOPPER_ID = CURRENT_USER() AND l.LIST_NAME = :LIST_NAME AND w.IS_ACTIVE;
    IF (wid IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('list_name', :LIST_NAME, 'tracked', FALSE);
    END IF;
    RETURN OBJECT_CONSTRUCT(
        'list_name', :LIST_NAME, 'tracked', TRUE,
        'basket', (SELECT OBJECT_CONSTRUCT('current_week', CURRENT_WEEK, 'current_total', CURRENT_TOTAL, 'weeks', WEEKS,
                                           'low_total', LOW_TOTAL, 'median_total', MEDIAN_TOTAL, 'high_total', HIGH_TOTAL,
                                           'cheaper_than_pct', CHEAPER_THAN_PCT, 'good_pct', GOOD_PCT, 'is_good_time', IS_GOOD_TIME, 'items', ITEMS)
                   FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_STATUS WHERE WATCH_ID = :wid),
        'trend', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('week', PRICE_WEEK, 'total', BASKET_TOTAL, 'complete', IS_COMPLETE,
                                                    'items_priced', ITEMS_PRICED, 'items_observed', ITEMS_OBSERVED)) WITHIN GROUP (ORDER BY PRICE_WEEK)
                  FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WEEKLY WHERE WATCH_ID = :wid),
        'items', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('position', POSITION, 'item', ITEM_TEXT, 'product_key', PRODUCT_KEY, 'product', PRODUCT_NAME,
                                                    'brand', BRAND, 'size', SIZE_TEXT, 'retailer', RETAILER, 'price', CURRENT_PRICE,
                                                    'unit_price', UNIT_PRICE, 'unit_basis', UNIT_BASIS, 'weeks', WEEKS_OBSERVED,
                                                    'cheaper_than_pct', CHEAPER_THAN_PCT, 'median_price', HISTORY_MEDIAN_PRICE,
                                                    'recommendation', RECOMMENDATION, 'stock_up', IS_STOCK_UP_CANDIDATE,
                                                    'is_good_time', IS_GOOD_TIME, 'listed', IS_CURRENTLY_LISTED)) WITHIN GROUP (ORDER BY POSITION)
                  FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_ITEM_STATUS WHERE WATCH_ID = :wid),
        'similar', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('position', POSITION, 'for_item', ITEM_TEXT, 'similar_to_key', SIMILAR_TO_KEY,
                                                      'product_key', PRODUCT_KEY, 'product', PRODUCT_NAME, 'brand', BRAND, 'size', SIZE_TEXT,
                                                      'retailer', RETAILER, 'price', CURRENT_PRICE, 'unit_price', UNIT_PRICE, 'unit_basis', UNIT_BASIS,
                                                      'unit_saving_pct', UNIT_SAVING_PCT, 'cheaper_than_pct', CHEAPER_THAN_PCT)) WITHIN GROUP (ORDER BY POSITION, UNIT_PRICE)
                    FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_SIMILAR WHERE WATCH_ID = :wid),
        'alerts', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('alert_id', ALERT_ID, 'kind', KIND, 'price_week', PRICE_WEEK, 'detail', DETAIL)) WITHIN GROUP (ORDER BY CREATED_AT DESC)
                   FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT WHERE WATCH_ID = :wid AND NOT IS_ACKNOWLEDGED)
    );
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_LIST_BASKET_WATCHES()
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'The shopper''s tracked baskets with their current rank and number of unseen alerts.'
EXECUTE AS CALLER
AS
$$
BEGIN
    RETURN (
        SELECT COALESCE(ARRAY_AGG(OBJECT_CONSTRUCT('list_name', l.LIST_NAME, 'good_pct', w.GOOD_PCT, 'include_similar', w.INCLUDE_SIMILAR,
                                                   'current_total', s.CURRENT_TOTAL, 'cheaper_than_pct', s.CHEAPER_THAN_PCT, 'weeks', s.WEEKS,
                                                   'is_good_time', s.IS_GOOD_TIME, 'new_alerts', COALESCE(a.n, 0)))
                                     WITHIN GROUP (ORDER BY l.LIST_NAME), ARRAY_CONSTRUCT())
        FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w
        JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
        LEFT JOIN GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_STATUS s ON s.WATCH_ID = w.WATCH_ID
        LEFT JOIN (SELECT WATCH_ID, COUNT(*) n FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT
                   WHERE SHOPPER_ID = CURRENT_USER() AND NOT IS_ACKNOWLEDGED GROUP BY 1) a ON a.WATCH_ID = w.WATCH_ID
        WHERE w.SHOPPER_ID = CURRENT_USER() AND w.IS_ACTIVE
    );
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_UNTRACK_BASKET(LIST_NAME VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Stop tracking a basket (the shopping list itself is kept).'
EXECUTE AS CALLER
AS
$$
BEGIN
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH SET IS_ACTIVE = FALSE, UPDATED_AT = CURRENT_TIMESTAMP()
    WHERE SHOPPER_ID = CURRENT_USER()
      AND LIST_ID IN (SELECT LIST_ID FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST WHERE SHOPPER_ID = CURRENT_USER() AND LIST_NAME = :LIST_NAME);
    RETURN OBJECT_CONSTRUCT('list_name', :LIST_NAME, 'untracked', SQLROWCOUNT);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_ACK_BASKET_ALERTS(LIST_NAME VARCHAR DEFAULT NULL)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Mark the shopper''s basket alerts as seen (one basket, or all when LIST_NAME is NULL).'
EXECUTE AS CALLER
AS
$$
BEGIN
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT SET IS_ACKNOWLEDGED = TRUE
    WHERE SHOPPER_ID = CURRENT_USER() AND NOT IS_ACKNOWLEDGED
      AND (:LIST_NAME IS NULL OR WATCH_ID IN (
            SELECT w.WATCH_ID FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w
            JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
            WHERE w.SHOPPER_ID = CURRENT_USER() AND l.LIST_NAME = :LIST_NAME));
    RETURN OBJECT_CONSTRUCT('acknowledged', SQLROWCOUNT);
END;
$$;

-- Weekly (task). Raises alerts for every active watch, then emails the new
-- ones once. Idempotent: a re-run in the same week inserts and sends nothing.
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_CHECK_BASKET_WATCHES()
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Weekly (task): raise BASKET_ALERT rows for baskets, items and look-alikes that are cheaper than the watch''s GOOD_PCT of the last 12 weeks, then send one email with the new alerts to the ops alert_email setting.'
EXECUTE AS CALLER
AS
$$
DECLARE
    n_raised NUMBER;
    marker   TIMESTAMP_TZ;
    body     VARCHAR;
    subj     VARCHAR;
    to_addr  VARCHAR;
    integ    VARCHAR;
    sent     BOOLEAN DEFAULT FALSE;
    n_mailed NUMBER DEFAULT 0;
BEGIN
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT
        (WATCH_ID, SHOPPER_ID, PRICE_WEEK, KIND, PRODUCT_KEY, SIMILAR_TO_KEY, PRICE, UNIT_PRICE, CHEAPER_THAN_PCT, DETAIL)
    WITH cand AS (
        SELECT WATCH_ID, SHOPPER_ID, CURRENT_WEEK AS PRICE_WEEK, 'basket' AS KIND, '' AS PRODUCT_KEY, '' AS SIMILAR_TO_KEY,
               CURRENT_TOTAL AS PRICE, NULL::NUMBER(12,4) AS UNIT_PRICE, CHEAPER_THAN_PCT,
               'Basket "' || LIST_NAME || '": $' || TRIM(TO_VARCHAR(CURRENT_TOTAL, '999,990.00')) || ' this week, cheaper than '
               || CHEAPER_THAN_PCT || '% of the last ' || WEEKS || ' weeks (typical $' || TRIM(TO_VARCHAR(MEDIAN_TOTAL, '999,990.00')) || ').' AS DETAIL
        FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_STATUS WHERE IS_GOOD_TIME
        UNION ALL
        SELECT WATCH_ID, SHOPPER_ID, CURRENT_WEEK, 'item', PRODUCT_KEY, '', CURRENT_PRICE, UNIT_PRICE, CHEAPER_THAN_PCT,
               '"' || LIST_NAME || '" item: ' || COALESCE(PRODUCT_NAME, ITEM_TEXT) || ' $' || TRIM(TO_VARCHAR(CURRENT_PRICE, '9,990.00'))
               || ' at ' || INITCAP(RETAILER) || ', cheaper than ' || CHEAPER_THAN_PCT || '% of the last ' || WEEKS_OBSERVED || ' weeks'
               || IFF(IS_STOCK_UP_CANDIDATE, ' (keeps: stock up)', '') || '.'
        FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_ITEM_STATUS WHERE IS_GOOD_TIME
        UNION ALL
        SELECT WATCH_ID, SHOPPER_ID, CURRENT_WEEK, 'similar', PRODUCT_KEY, SIMILAR_TO_KEY, CURRENT_PRICE, UNIT_PRICE, CHEAPER_THAN_PCT,
               '"' || LIST_NAME || '" swap for ' || ITEM_TEXT || ': ' || COALESCE(PRODUCT_NAME, PRODUCT_KEY) || COALESCE(' ' || SIZE_TEXT, '')
               || ' $' || TRIM(TO_VARCHAR(CURRENT_PRICE, '9,990.00')) || ' at ' || INITCAP(RETAILER) || ', ' || UNIT_SAVING_PCT || '% less per '
               || UNIT_BASIS || ', cheaper than ' || CHEAPER_THAN_PCT || '% of its weeks.'
        FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_SIMILAR
    )
    SELECT c.* FROM cand c
    WHERE NOT EXISTS (SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT a
                      WHERE a.WATCH_ID = c.WATCH_ID AND a.PRICE_WEEK = c.PRICE_WEEK AND a.KIND = c.KIND
                        AND a.PRODUCT_KEY = c.PRODUCT_KEY AND a.SIMILAR_TO_KEY = c.SIMILAR_TO_KEY)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.WATCH_ID, c.PRICE_WEEK, c.KIND, c.PRODUCT_KEY, c.SIMILAR_TO_KEY ORDER BY c.PRICE) = 1;
    n_raised := SQLROWCOUNT;

    -- one email with every alert not yet emailed, for watches that want email
    marker := CURRENT_TIMESTAMP();
    SELECT LISTAGG(a.DETAIL, '\n') WITHIN GROUP (ORDER BY l.LIST_NAME, DECODE(a.KIND, 'basket', 0, 'item', 1, 2), a.DETAIL),
           LISTAGG(DISTINCT l.LIST_NAME, ', ') WITHIN GROUP (ORDER BY l.LIST_NAME),
           COUNT(*)
      INTO :body, :subj, :n_mailed
    FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT a
    JOIN GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w ON w.WATCH_ID = a.WATCH_ID
    JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
    WHERE a.EMAILED_AT IS NULL AND NOT a.IS_ACKNOWLEDGED AND w.EMAIL AND w.IS_ACTIVE AND a.CREATED_AT <= :marker
      AND w.SHOPPER_ID NOT LIKE 'guest:%';   -- guests see alerts in the app only (Guest/03_guest_basket_watch.sql)

    IF (n_mailed > 0) THEN
        SELECT MAX(IFF(KEY = 'alert_email', VALUE, NULL)), MAX(IFF(KEY = 'email_integration', VALUE, NULL))
          INTO :to_addr, :integ FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_SETTING;
        subj := '[grocery] good time to buy: ' || subj;
        body := 'Good time to buy (percentile rank: cheaper than X% of the last 12 weeks of prices).\n\n' || body
                || '\n\nOpen the app''s My basket tab for the trend and to mark these seen.';
        BEGIN
            CALL SYSTEM$SEND_EMAIL(:integ, :to_addr, :subj, :body);
            sent := TRUE;
        EXCEPTION WHEN OTHER THEN
            sent := FALSE;
        END;
        IF (sent) THEN
            UPDATE GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT a SET EMAILED_AT = CURRENT_TIMESTAMP()
            WHERE a.EMAILED_AT IS NULL AND NOT a.IS_ACKNOWLEDGED AND a.CREATED_AT <= :marker
              AND a.WATCH_ID IN (SELECT WATCH_ID FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH WHERE EMAIL AND IS_ACTIVE AND SHOPPER_ID NOT LIKE 'guest:%');
        END IF;
    END IF;
    RETURN OBJECT_CONSTRUCT('alerts_raised', n_raised, 'alerts_emailed', IFF(sent, n_mailed, 0), 'email_sent', sent, 'checked_at', CURRENT_TIMESTAMP());
END;
$$;

-- PROD ONLY: grants (same pattern as 06: the agent role uses the procedures)
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH TO ROLE GROCERY_AGENT_USER;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT TO ROLE GROCERY_AGENT_USER;
GRANT SELECT ON VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WATCH_ITEM TO ROLE GROCERY_AGENT_USER;
GRANT SELECT ON VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WEEKLY TO ROLE GROCERY_AGENT_USER;
GRANT SELECT ON VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_STATUS TO ROLE GROCERY_AGENT_USER;
GRANT SELECT ON VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_ITEM_STATUS TO ROLE GROCERY_AGENT_USER;
GRANT SELECT ON VIEW GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_SIMILAR TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_TRACK_BASKET(VARCHAR, VARCHAR, NUMBER, BOOLEAN) TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_BASKET_STATUS(VARCHAR) TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_LIST_BASKET_WATCHES() TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_UNTRACK_BASKET(VARCHAR) TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_ACK_BASKET_ALERTS(VARCHAR) TO ROLE GROCERY_AGENT_USER;
-- SP_CHECK_BASKET_WATCHES runs from TASK_WEEKLY_PRICE_FORECAST (04_search_and_basket_tool.sql) as its owner.
