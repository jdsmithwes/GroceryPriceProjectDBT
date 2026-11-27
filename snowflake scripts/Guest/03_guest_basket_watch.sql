-- =============================================================================
-- 03_guest_basket_watch.sql — basket watch for signed-in guests
--
-- The owner app's basket watch (Snowflake Scripts/Agent/07_basket_watch.sql)
-- keys everything on CURRENT_USER(), and every guest shares one service user
-- (SVC_GUEST_APP). So guests get their own EXECUTE AS OWNER procedures that
-- take the app's SESSION_ID, resolve it server-side to the guest, and act only
-- on that guest's rows (SHOPPER_ID = 'guest:' || GUEST_ID). The guest role gets
-- USAGE on these procedures and nothing on BASKET_WATCH / BASKET_ALERT.
--
-- Same tables, views and weekly check as the owner app: the Sunday task's
-- SP_CHECK_BASKET_WATCHES raises guest alerts too. Guests see them in the app
-- (My basket tab, next session); they are never emailed from Snowflake
-- (SYSTEM$SEND_EMAIL reaches only verified account users), so guest watches
-- are stored with EMAIL = FALSE and the owner email skips 'guest:' shoppers.
--
-- Cost bounds (GUEST_SETTING rows, change without redeploying):
--   basket_watch_enabled       kill switch for the feature
--   basket_watch_max_baskets   tracked baskets per guest (3)
--   basket_watch_max_items     items per tracked basket (15)
--   basket_watch_max_total     tracked baskets across all guests (200)
-- Writes and reads need an allowed session (SP_GUEST_STATUS), so a capped or
-- expired session cannot keep spending; the app meters each call with
-- SP_GUEST_RECORD kind 'basket_watch'.
--
-- Run as ACCOUNTADMIN after 07_basket_watch.sql and 02_guest_login.sql.
-- Sandbox variant:
--   sed -E 's/GROCERY_APP([^_A-Za-z0-9]|$)/GROCERY_DEV_APP\1/g; /^-- PROD ONLY/,$d'
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE SCHEMA GROCERYDBTPROJECT.GROCERY_APP;

MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING t
USING (SELECT * FROM VALUES
    ('basket_watch_enabled',     'true', 'Guests may track baskets (false hides nothing already saved but refuses new tracking and status reads)'),
    ('basket_watch_max_baskets', '3',    'Tracked baskets per guest'),
    ('basket_watch_max_items',   '15',   'Items per tracked basket'),
    ('basket_watch_max_total',   '200',  'Active tracked baskets across all guests (bounds the Sunday check)')
) s (KEY, VALUE, DESCRIPTION) ON t.KEY = s.KEY
WHEN NOT MATCHED THEN INSERT (KEY, VALUE, DESCRIPTION) VALUES (s.KEY, s.VALUE, s.DESCRIPTION);

------------------------------------------------------------------------------
-- Session -> shopper. Returns NULL unless the session is allowed right now
-- and the feature is on; REASON says why not.
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_SHOPPER(SESSION_ID VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Internal: resolve an allowed guest session to its basket-watch shopper id (guest:<GUEST_ID>). Not granted to the guest role.'
EXECUTE AS OWNER
AS
$$
DECLARE
    st VARIANT; enabled BOOLEAN;
BEGIN
    SELECT MAX(IFF(KEY = 'basket_watch_enabled', VALUE = 'true', NULL)) INTO :enabled FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING;
    IF (NOT COALESCE(enabled, TRUE)) THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'basket_watch_disabled'); END IF;
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_STATUS(:SESSION_ID) INTO :st;
    IF (NOT COALESCE(st:allowed::BOOLEAN, FALSE)) THEN
        RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', COALESCE(st:reason::STRING, 'no_session'));
    END IF;
    RETURN OBJECT_CONSTRUCT('ok', TRUE, 'shopper_id', 'guest:' || st:guest_id::STRING);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_TRACK_BASKET(
    SESSION_ID VARCHAR, LIST_NAME VARCHAR, ITEMS_JSON VARCHAR, GOOD_PCT NUMBER, INCLUDE_SIMILAR BOOLEAN)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Guest: save a basket (ITEMS_JSON = [{"item","product_key"}] from compare_basket) and track its price weekly. Limits from GUEST_SETTING.'
EXECUTE AS OWNER
AS
$$
DECLARE
    who VARIANT; shopper VARCHAR; items ARRAY; list_id VARCHAR; name VARCHAR;
    max_baskets NUMBER; max_items NUMBER; max_total NUMBER; mine NUMBER; total NUMBER; exists_already NUMBER; pct NUMBER;
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_SHOPPER(:SESSION_ID) INTO :who;
    IF (NOT who:ok::BOOLEAN) THEN RETURN who; END IF;
    shopper := who:shopper_id::STRING;
    name := LEFT(TRIM(:LIST_NAME), 60);
    IF (name IS NULL OR name = '') THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'name_required'); END IF;
    items := TRY_PARSE_JSON(:ITEMS_JSON)::ARRAY;
    IF (items IS NULL OR ARRAY_SIZE(items) = 0) THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'no_items'); END IF;
    pct := LEAST(90, GREATEST(60, COALESCE(:GOOD_PCT, 75)));

    SELECT MAX(IFF(KEY = 'basket_watch_max_baskets', VALUE::NUMBER, NULL)), MAX(IFF(KEY = 'basket_watch_max_items', VALUE::NUMBER, NULL)),
           MAX(IFF(KEY = 'basket_watch_max_total', VALUE::NUMBER, NULL))
      INTO :max_baskets, :max_items, :max_total FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING;
    IF (ARRAY_SIZE(items) > max_items) THEN
        RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'too_many_items', 'max_items', :max_items);
    END IF;
    SELECT COUNT_IF(w.SHOPPER_ID = :shopper), COUNT(*), COUNT_IF(w.SHOPPER_ID = :shopper AND l.LIST_NAME = :name)
      INTO :mine, :total, :exists_already
    FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w
    JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
    WHERE w.IS_ACTIVE AND w.SHOPPER_ID LIKE 'guest:%';
    IF (exists_already = 0 AND mine >= max_baskets) THEN
        RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'too_many_baskets', 'max_baskets', :max_baskets);
    END IF;
    IF (exists_already = 0 AND total >= max_total) THEN
        RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'guest_capacity');
    END IF;

    MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST t
    USING (SELECT :shopper AS SHOPPER_ID, :name AS LIST_NAME) s
       ON t.SHOPPER_ID = s.SHOPPER_ID AND t.LIST_NAME = s.LIST_NAME
    WHEN MATCHED THEN UPDATE SET UPDATED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (SHOPPER_ID, LIST_NAME) VALUES (s.SHOPPER_ID, s.LIST_NAME);
    SELECT LIST_ID INTO :list_id FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST WHERE SHOPPER_ID = :shopper AND LIST_NAME = :name;
    DELETE FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM WHERE LIST_ID = :list_id;
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM (LIST_ID, POSITION, ITEM_TEXT, PRODUCT_KEY)
    SELECT :list_id, index, LEFT(TRIM(COALESCE(value:item::STRING, value::STRING)), 200), NULLIF(TRIM(value:product_key::STRING), '')
    FROM TABLE(FLATTEN(INPUT => :items))
    WHERE TRIM(COALESCE(value:item::STRING, value::STRING)) <> '';
    MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH t
    USING (SELECT :shopper AS SHOPPER_ID, :list_id AS LIST_ID) s
       ON t.SHOPPER_ID = s.SHOPPER_ID AND t.LIST_ID = s.LIST_ID
    WHEN MATCHED THEN UPDATE SET GOOD_PCT = :pct, INCLUDE_SIMILAR = COALESCE(:INCLUDE_SIMILAR, TRUE), EMAIL = FALSE, IS_ACTIVE = TRUE, UPDATED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (SHOPPER_ID, LIST_ID, GOOD_PCT, INCLUDE_SIMILAR, EMAIL) VALUES (s.SHOPPER_ID, s.LIST_ID, :pct, COALESCE(:INCLUDE_SIMILAR, TRUE), FALSE);
    RETURN (SELECT OBJECT_CONSTRUCT('ok', TRUE, 'list_name', :name, 'items', COUNT(*), 'items_tracked', COUNT(PRODUCT_KEY), 'good_pct', :pct)
            FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM WHERE LIST_ID = :list_id);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_LIST_BASKET_WATCHES(SESSION_ID VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Guest: tracked baskets with this week''s rank and unseen alert count.'
EXECUTE AS OWNER
AS
$$
DECLARE
    who VARIANT; shopper VARCHAR;
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_SHOPPER(:SESSION_ID) INTO :who;
    IF (NOT who:ok::BOOLEAN) THEN RETURN who; END IF;
    shopper := who:shopper_id::STRING;
    RETURN (
        SELECT OBJECT_CONSTRUCT('ok', TRUE, 'baskets', COALESCE(ARRAY_AGG(OBJECT_CONSTRUCT(
                   'list_name', l.LIST_NAME, 'good_pct', w.GOOD_PCT, 'include_similar', w.INCLUDE_SIMILAR,
                   'current_total', s.CURRENT_TOTAL, 'cheaper_than_pct', s.CHEAPER_THAN_PCT, 'weeks', s.WEEKS,
                   'is_good_time', s.IS_GOOD_TIME, 'new_alerts', COALESCE(a.n, 0))) WITHIN GROUP (ORDER BY l.LIST_NAME), ARRAY_CONSTRUCT()))
        FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w
        JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
        LEFT JOIN GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_STATUS s ON s.WATCH_ID = w.WATCH_ID
        LEFT JOIN (SELECT WATCH_ID, COUNT(*) n FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT
                   WHERE SHOPPER_ID = :shopper AND NOT IS_ACKNOWLEDGED GROUP BY 1) a ON a.WATCH_ID = w.WATCH_ID
        WHERE w.SHOPPER_ID = :shopper AND w.IS_ACTIVE
    );
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_STATUS(SESSION_ID VARCHAR, LIST_NAME VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Guest: one tracked basket now (same shape as SP_BASKET_STATUS): weekly trend, rank, items, look-alike swaps, unseen alerts.'
EXECUTE AS OWNER
AS
$$
DECLARE
    who VARIANT; shopper VARCHAR; wid VARCHAR;
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_SHOPPER(:SESSION_ID) INTO :who;
    IF (NOT who:ok::BOOLEAN) THEN RETURN who; END IF;
    shopper := who:shopper_id::STRING;
    SELECT MAX(w.WATCH_ID) INTO :wid
    FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w
    JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
    WHERE w.SHOPPER_ID = :shopper AND l.LIST_NAME = :LIST_NAME AND w.IS_ACTIVE;
    IF (wid IS NULL) THEN RETURN OBJECT_CONSTRUCT('ok', TRUE, 'list_name', :LIST_NAME, 'tracked', FALSE); END IF;
    RETURN OBJECT_CONSTRUCT(
        'ok', TRUE, 'list_name', :LIST_NAME, 'tracked', TRUE,
        'basket', (SELECT OBJECT_CONSTRUCT('current_week', CURRENT_WEEK, 'current_total', CURRENT_TOTAL, 'weeks', WEEKS,
                                           'low_total', LOW_TOTAL, 'median_total', MEDIAN_TOTAL, 'high_total', HIGH_TOTAL,
                                           'cheaper_than_pct', CHEAPER_THAN_PCT, 'good_pct', GOOD_PCT, 'is_good_time', IS_GOOD_TIME, 'items', ITEMS,
                                           'ranked_items', RANKED_ITEMS, 'full_total', FULL_TOTAL)
                   FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_STATUS WHERE WATCH_ID = :wid),
        'trend', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('week', PRICE_WEEK, 'total', BASKET_TOTAL, 'complete', IS_COMPLETE, 'full_total', FULL_TOTAL, 'ranked_items', RANKED_ITEMS,
                                                    'items_priced', ITEMS_PRICED, 'items_observed', ITEMS_OBSERVED)) WITHIN GROUP (ORDER BY PRICE_WEEK)
                  FROM GROCERYDBTPROJECT.GROCERY_APP.V_BASKET_WEEKLY WHERE WATCH_ID = :wid),
        'items', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('position', POSITION, 'item', ITEM_TEXT, 'product_key', PRODUCT_KEY, 'product', PRODUCT_NAME,
                                                    'brand', BRAND, 'size', SIZE_TEXT, 'retailer', RETAILER, 'price', CURRENT_PRICE,
                                                    'unit_price', UNIT_PRICE, 'unit_basis', UNIT_BASIS, 'weeks', WEEKS_OBSERVED,
                                                    'cheaper_than_pct', CHEAPER_THAN_PCT, 'median_price', HISTORY_MEDIAN_PRICE,
                                                    'recommendation', RECOMMENDATION, 'stock_up', IS_STOCK_UP_CANDIDATE,
                                                    'is_good_time', IS_GOOD_TIME, 'listed', IS_CURRENTLY_LISTED, 'ranked', IS_RANKED)) WITHIN GROUP (ORDER BY POSITION)
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

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_UNTRACK_BASKET(SESSION_ID VARCHAR, LIST_NAME VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Guest: stop tracking one of their baskets.'
EXECUTE AS OWNER
AS
$$
DECLARE
    who VARIANT; shopper VARCHAR;
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_SHOPPER(:SESSION_ID) INTO :who;
    IF (NOT who:ok::BOOLEAN) THEN RETURN who; END IF;
    shopper := who:shopper_id::STRING;
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH SET IS_ACTIVE = FALSE, UPDATED_AT = CURRENT_TIMESTAMP()
    WHERE SHOPPER_ID = :shopper
      AND LIST_ID IN (SELECT LIST_ID FROM GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST WHERE SHOPPER_ID = :shopper AND LIST_NAME = :LIST_NAME);
    RETURN OBJECT_CONSTRUCT('ok', TRUE, 'list_name', :LIST_NAME, 'untracked', SQLROWCOUNT);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_ACK_BASKET_ALERTS(SESSION_ID VARCHAR, LIST_NAME VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Guest: mark the alerts of one of their baskets as seen.'
EXECUTE AS OWNER
AS
$$
DECLARE
    who VARIANT; shopper VARCHAR;
BEGIN
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_SHOPPER(:SESSION_ID) INTO :who;
    IF (NOT who:ok::BOOLEAN) THEN RETURN who; END IF;
    shopper := who:shopper_id::STRING;
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.BASKET_ALERT SET IS_ACKNOWLEDGED = TRUE
    WHERE SHOPPER_ID = :shopper AND NOT IS_ACKNOWLEDGED
      AND WATCH_ID IN (SELECT w.WATCH_ID FROM GROCERYDBTPROJECT.GROCERY_APP.BASKET_WATCH w
                       JOIN GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST l ON l.LIST_ID = w.LIST_ID
                       WHERE w.SHOPPER_ID = :shopper AND l.LIST_NAME = :LIST_NAME);
    RETURN OBJECT_CONSTRUCT('ok', TRUE, 'acknowledged', SQLROWCOUNT);
END;
$$;

-- PROD ONLY ------------------------------------------------------------------
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_TRACK_BASKET(VARCHAR, VARCHAR, VARCHAR, NUMBER, BOOLEAN) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_LIST_BASKET_WATCHES(VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_STATUS(VARCHAR, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_UNTRACK_BASKET(VARCHAR, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_ACK_BASKET_ALERTS(VARCHAR, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
-- SP_GUEST_BASKET_SHOPPER stays ungranted (internal).
