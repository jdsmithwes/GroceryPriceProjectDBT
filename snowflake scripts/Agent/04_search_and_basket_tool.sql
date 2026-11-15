-- Grocery value agent — Phase 4: product search + basket comparison tool.
-- Run as ACCOUNTADMIN after 01_governance.sql (needs GROCERY_AGENT_WH and
-- the GROCERY_SEMANTIC schema) and after `dbtg build --select semantic`
-- (needs the DBT_SEARCH_PRODUCT_INDEX view and DBT_SV_GROCERY_PRICING).
--
-- Sandbox variant: replace schema names and the warehouse —
--   sed -E 's/GROCERY_(SEMANTIC|MARTS|ML|RAW)\./GROCERY_DEV_\1./g; s/GROCERY_AGENT_WH/COMPUTE_WH/g'
-- and stop before the PROD ONLY section.
--
-- Sections:
--   1. PRODUCT_SEARCH_SOURCE — plain table the search service indexes. Cortex
--      Search needs change tracking, which no dynamic table in this project
--      can provide (FULL refresh, see the view's comment), so the weekly task
--      refills this table from the dbt view with INSERT OVERWRITE (keeps the
--      table, its change tracking and the service binding intact).
--   2. PRODUCT_SEARCH — Cortex Search service (fuzzy lookup by name/brand/size/
--      category, both retailers). Serving cost is per GB indexed per hour;
--      15k short rows is a few MB — negligible. TARGET_LAG 1 day.
--   3. SP_COMPARE_BASKET — the agent's basket tool: resolves each item at each
--      retailer through the search service, prices it at Walmart and every
--      Kroger store (optionally the nearest stores to a ZIP), and returns per-
--      store totals, the best single store, the best Walmart + one-Kroger-store
--      split, and what it could not find. Returns the matches so the agent can
--      show what was compared.
--   4. PROD ONLY: add the refresh step to the Sunday task; grants.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GROCERY_AGENT_WH;

------------------------------------------------------------------------------
-- 1. Search source table (refilled weekly from the dbt view)
------------------------------------------------------------------------------
-- CREATE OR REPLACE (not IF NOT EXISTS): the view's columns changed on
-- 2026-11-15 (PRODUCT_TYPE); the service below is recreated right after, so
-- losing the table's change-tracking history here is fine.
CREATE OR REPLACE TABLE GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH_SOURCE
    CHANGE_TRACKING = TRUE
    COMMENT = 'Copy of GROCERY_SEMANTIC.DBT_SEARCH_PRODUCT_INDEX for the PRODUCT_SEARCH Cortex Search service; refilled weekly by TASK_WEEKLY_PRICE_FORECAST (dynamic tables cannot provide change tracking).'
AS SELECT * FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.DBT_SEARCH_PRODUCT_INDEX WHERE FALSE;

INSERT OVERWRITE INTO GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH_SOURCE
SELECT * FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.DBT_SEARCH_PRODUCT_INDEX;

------------------------------------------------------------------------------
-- 2. Cortex Search service
------------------------------------------------------------------------------
CREATE OR REPLACE CORTEX SEARCH SERVICE GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH
    ON SEARCH_TEXT
    ATTRIBUTES RETAILER, PRIMARY_COMMON_CATEGORY, PRODUCT_TYPE, IS_FOOD, IS_STORE_BRAND, HAS_EXACT_MATCH
    WAREHOUSE = GROCERY_AGENT_WH
    TARGET_LAG = '1 day'
    COMMENT = 'Fuzzy product lookup for the grocery value agent: name + brand + size + category over both retailers. Filter on RETAILER / IS_FOOD; join hits to the marts by PRODUCT_KEY.'
AS SELECT * FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH_SOURCE;

------------------------------------------------------------------------------
-- 3. Basket comparison procedure (agent custom tool)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_SEMANTIC.SP_COMPARE_BASKET(
    ITEMS_TEXT VARCHAR,          -- JSON array of item names, or a comma-separated list
    ZIP_CODE   VARCHAR DEFAULT NULL,   -- Georgia ZIP: limits Kroger to the nearest stores
    MAX_STORES NUMBER  DEFAULT 10      -- how many nearest Kroger stores to price when a ZIP is given
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Prices a shopping list at Walmart and at Kroger stores (nearest to ZIP_CODE when given): matches per item, per-store totals, best single store, best Walmart + one Kroger store split, items not found. Prices are the latest collected (see AS_OF).'
EXECUTE AS CALLER
AS
$$
DECLARE
    items ARRAY;
BEGIN
    items := COALESCE(TRY_PARSE_JSON(:ITEMS_TEXT)::ARRAY, SPLIT(:ITEMS_TEXT, ','));

    -- Temp tables are schema-qualified: the agent's session has no current
    -- schema, so unqualified CREATE TEMPORARY TABLE fails (found 2026-11-15).
    -- Items, trimmed and numbered
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_items AS
    SELECT index AS item_no, TRIM(value::STRING) AS item
    FROM TABLE(FLATTEN(INPUT => :items))
    WHERE TRIM(value::STRING) <> '';

    -- Top 3 search hits per item per retailer; rank 1 is the match used.
    -- SEARCH_PREVIEW needs a constant request, so this loops (one call per
    -- item per retailer) instead of calling it per row.
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_hits (
        item_no INT, item STRING, retailer STRING, hit_rank INT,
        product_key STRING, product_name STRING, brand STRING, size_text STRING, has_exact_match BOOLEAN
    );
    LET items_cur CURSOR FOR SELECT item_no, item FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_items;
    FOR rec IN items_cur DO
        LET item_no INT := rec.item_no;
        LET item STRING := rec.item;
        LET retailers ARRAY := ARRAY_CONSTRUCT('kroger', 'walmart');
        LET j INT := 0;
        WHILE (j < 2) DO
            LET retailer STRING := retailers[j]::STRING;
            LET request STRING := OBJECT_CONSTRUCT(
                'query',   :item,
                'columns', ARRAY_CONSTRUCT('PRODUCT_KEY', 'PRODUCT_NAME', 'BRAND', 'SIZE_TEXT', 'HAS_EXACT_MATCH'),
                'filter',  OBJECT_CONSTRUCT('@eq', OBJECT_CONSTRUCT('RETAILER', :retailer)),
                'limit',   3)::STRING;
            LET hits STRING := SNOWFLAKE.CORTEX.SEARCH_PREVIEW('GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH', :request);
            INSERT INTO GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_hits
            SELECT :item_no, :item, :retailer, h.index + 1,
                   h.value:PRODUCT_KEY::STRING, h.value:PRODUCT_NAME::STRING, h.value:BRAND::STRING,
                   h.value:SIZE_TEXT::STRING, h.value:HAS_EXACT_MATCH::BOOLEAN
            FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:hits):results)) h;
            j := j + 1;
        END WHILE;
    END FOR;

    -- Stores to price: every Kroger store, or the MAX_STORES nearest to ZIP_CODE
    -- (an unknown ZIP falls back to every store, with no distances)
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_stores AS
    WITH z AS (
        SELECT latitude, longitude FROM GROCERYDBTPROJECT.GROCERY_RAW.DBT_ZIP_CENTROIDS_GA WHERE zip_code = :ZIP_CODE
    )
    SELECT s.store_id, s.store_name, s.city, s.retailer,
           ROUND(HAVERSINE(z.latitude, z.longitude, s.latitude, s.longitude) * 0.621371, 1) AS miles
    FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_STORE s
    LEFT JOIN z ON s.retailer = 'kroger'
    QUALIFY s.retailer = 'walmart'
         OR z.latitude IS NULL
         OR ROW_NUMBER() OVER (PARTITION BY s.retailer ORDER BY HAVERSINE(z.latitude, z.longitude, s.latitude, s.longitude)) <= :MAX_STORES;

    -- Current prices of every hit at every store being priced
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices_all AS
    SELECT DISTINCT h.product_key, st.store_id, st.store_name, st.city, st.miles,
           p.current_price, p.is_on_promo, p.data_as_of
    FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_hits h
    JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_SUMMARY p
         ON p.product_key = h.product_key AND p.is_currently_listed
    JOIN GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_stores st ON st.store_id = p.store_id;

    -- The hit used per item and retailer: the highest-ranked one with a
    -- current price at any store being priced (a top hit that is no longer
    -- listed would otherwise make the item "missing").
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_choice AS
    SELECT h.item_no, h.retailer, MIN(h.hit_rank) AS hit_rank
    FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_hits h
    WHERE EXISTS (
        SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices_all p
        WHERE p.product_key = h.product_key
    )
    GROUP BY 1, 2;

    -- Current price of each chosen product at each store
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices AS
    SELECT h.item_no, h.item, h.retailer, h.product_key, h.product_name,
           p.store_id, p.store_name, p.city, p.miles,
           p.current_price, p.is_on_promo, p.data_as_of
    FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_hits h
    JOIN GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_choice c ON c.item_no = h.item_no AND c.retailer = h.retailer AND c.hit_rank = h.hit_rank
    JOIN GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices_all p ON p.product_key = h.product_key;

    -- Per-store totals (only stores that have every item are directly comparable)
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_totals AS
    SELECT retailer, store_id, store_name, city, miles,
           COUNT(DISTINCT item_no)                        AS items_found,
           ROUND(SUM(current_price), 2)                   AS total,
           SUM(IFF(is_on_promo, 1, 0))                    AS items_on_promo,
           ARRAY_AGG(OBJECT_CONSTRUCT('item', item, 'product', product_name, 'price', current_price)) WITHIN GROUP (ORDER BY item_no) AS lines
    FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices
    GROUP BY 1, 2, 3, 4, 5;

    LET n_items INT := (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_items);

    -- Assembled with joins and aggregates only: correlated subqueries inside
    -- OBJECT_CONSTRUCT are "unsupported subquery type" in Snowflake.
    LET result VARIANT := (
        WITH best_store AS (
            SELECT * FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_totals ORDER BY items_found DESC, total ASC LIMIT 1
        ),
        best_kroger AS (
            SELECT * FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_totals WHERE retailer = 'kroger' ORDER BY items_found DESC, total ASC LIMIT 1
        ),
        walmart AS (
            SELECT * FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_totals WHERE retailer = 'walmart'
        ),
        split_lines AS (
            SELECT i.item_no, i.item,
                   k.current_price AS kroger_price, w.current_price AS walmart_price,
                   CASE WHEN k.current_price IS NULL AND w.current_price IS NULL THEN NULL
                        WHEN k.current_price IS NULL THEN 'walmart'
                        WHEN w.current_price IS NULL THEN 'kroger'
                        WHEN w.current_price < k.current_price THEN 'walmart' ELSE 'kroger' END AS buy_at,
                   LEAST(COALESCE(k.current_price, w.current_price), COALESCE(w.current_price, k.current_price)) AS price
            FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_items i
            LEFT JOIN best_kroger bk ON TRUE
            LEFT JOIN GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices k ON k.item_no = i.item_no AND k.retailer = 'kroger' AND k.store_id = bk.store_id
            LEFT JOIN GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices w ON w.item_no = i.item_no AND w.retailer = 'walmart'
        ),
        split AS (
            SELECT ROUND(SUM(price), 2) AS total, COUNT_IF(price IS NOT NULL) AS items_found,
                   ARRAY_AGG(OBJECT_CONSTRUCT('item', item, 'buy_at', buy_at, 'price', price, 'kroger_price', kroger_price, 'walmart_price', walmart_price)) WITHIN GROUP (ORDER BY item_no) AS lines
            FROM split_lines
        ),
        best AS (
            SELECT h.* FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_hits h
            JOIN GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_choice c ON c.item_no = h.item_no AND c.retailer = h.retailer AND c.hit_rank = h.hit_rank
        ),
        alts AS (
            SELECT h.item_no, h.retailer, ARRAY_AGG(h.product_name) WITHIN GROUP (ORDER BY h.hit_rank) AS alternatives
            FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_hits h
            LEFT JOIN GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_choice c ON c.item_no = h.item_no AND c.retailer = h.retailer
            WHERE h.hit_rank <> COALESCE(c.hit_rank, 1) GROUP BY 1, 2
        ),
        matches AS (
            SELECT i.item_no,
                   OBJECT_CONSTRUCT(
                       'item', i.item,
                       'kroger',  IFF(k.product_key IS NULL, NULL, OBJECT_CONSTRUCT('product_key', k.product_key, 'product', k.product_name, 'brand', k.brand, 'size', k.size_text, 'identical_at_walmart', k.has_exact_match, 'alternatives', ak.alternatives)),
                       'walmart', IFF(w.product_key IS NULL, NULL, OBJECT_CONSTRUCT('product_key', w.product_key, 'product', w.product_name, 'brand', w.brand, 'identical_at_kroger', w.has_exact_match, 'alternatives', aw.alternatives))
                   ) AS match
            FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_items i
            LEFT JOIN best k  ON k.item_no = i.item_no AND k.retailer = 'kroger'
            LEFT JOIN alts ak ON ak.item_no = i.item_no AND ak.retailer = 'kroger'
            LEFT JOIN best w  ON w.item_no = i.item_no AND w.retailer = 'walmart'
            LEFT JOIN alts aw ON aw.item_no = i.item_no AND aw.retailer = 'walmart'
        ),
        missing AS (
            SELECT * FROM (
                SELECT i.item,
                       IFF(COUNT_IF(p.retailer = 'kroger') = 0, 'no current Kroger price', NULL) AS kroger,
                       IFF(COUNT_IF(p.retailer = 'walmart') = 0, 'no current Walmart price', NULL) AS walmart
                FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_items i
                LEFT JOIN GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices p ON p.item_no = i.item_no
                GROUP BY i.item_no, i.item
            ) WHERE kroger IS NOT NULL OR walmart IS NOT NULL
        ),
        top_totals AS (
            SELECT * FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_totals ORDER BY items_found DESC, total ASC LIMIT 8
        )
        SELECT OBJECT_CONSTRUCT(
            'items_requested', :n_items,
            'zip_code', :ZIP_CODE,
            'kroger_stores_priced', (SELECT COUNT(*) FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_stores WHERE retailer = 'kroger'),
            'as_of', (SELECT MAX(data_as_of) FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.basket_prices),
            'matches', (SELECT ARRAY_AGG(match) WITHIN GROUP (ORDER BY item_no) FROM matches),
            'store_totals', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('retailer', retailer, 'store', store_name, 'city', city, 'miles', miles, 'items_found', items_found, 'total', total, 'items_on_promo', items_on_promo)) WITHIN GROUP (ORDER BY items_found DESC, total ASC) FROM top_totals),
            'best_single_store', (SELECT OBJECT_CONSTRUCT('retailer', retailer, 'store', store_name, 'city', city, 'miles', miles, 'items_found', items_found, 'total', total, 'lines', lines) FROM best_store),
            'walmart', (SELECT OBJECT_CONSTRUCT('items_found', items_found, 'total', total, 'lines', lines) FROM walmart),
            'split', (SELECT OBJECT_CONSTRUCT(
                          'kroger_store', (SELECT store_name FROM best_kroger),
                          'items_found', items_found, 'total', total,
                          'savings_vs_best_single_store', ROUND((SELECT total FROM best_store) - total, 2),
                          'lines', lines) FROM split),
            'missing', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('item', item, 'kroger', kroger, 'walmart', walmart)) FROM missing),
            'notes', 'Totals compare only when items_found is equal. Matches are the best search hit per retailer that has a current price; check them. Kroger prices vary by store; Walmart is one national online price.'
        )
    );

    RETURN result;
END;
$$;

------------------------------------------------------------------------------
-- 4. PROD ONLY: weekly refresh of the search table; grants
------------------------------------------------------------------------------
-- The Sunday task (02_forecast.sql) gains one step: refill PRODUCT_SEARCH_SOURCE
-- after dim_product has refreshed (it refreshes itself within 24 h of the
-- Friday/Saturday loads). The service re-indexes within its 1-day lag.
ALTER TASK GROCERYDBTPROJECT.GROCERY_ML.TASK_WEEKLY_PRICE_FORECAST SUSPEND;
CREATE OR REPLACE TASK GROCERYDBTPROJECT.GROCERY_ML.TASK_WEEKLY_PRICE_FORECAST
    WAREHOUSE = GROCERY_ML_WH
    SCHEDULE = 'USING CRON 0 6 * * SUN America/New_York'
    COMMENT = 'Weekly: refresh price series (and its upstream chain), retrain + forecast the scoped products, refresh buy recommendations, label new products, refill the product search table, check price watches'
AS
EXECUTE IMMEDIATE $$
BEGIN
    ALTER DYNAMIC TABLE GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_WEEKLY_SERIES REFRESH;
    CALL GROCERYDBTPROJECT.GROCERY_ML.SP_REFRESH_PRICE_FORECAST(
        'GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_WEEKLY_SERIES',
        'GROCERYDBTPROJECT.GROCERY_ML', 6, 8,
        'GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_FORECAST_SCOPE');
    ALTER DYNAMIC TABLE GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_BUY_RECOMMENDATION REFRESH;
    ALTER DYNAMIC TABLE GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT REFRESH;
    -- label new food products (03_product_types.sql), then refresh so the
    -- labels reach dim_product and the search table
    CALL GROCERYDBTPROJECT.GROCERY_ML.SP_LABEL_PRODUCT_TYPES('llama3.1-70b', 2000, 5);
    ALTER DYNAMIC TABLE GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT REFRESH;
    INSERT OVERWRITE INTO GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH_SOURCE
    SELECT * FROM GROCERYDBTPROJECT.GROCERY_SEMANTIC.DBT_SEARCH_PRODUCT_INDEX;
    -- price watches (06_state_layer.sql): raise alerts on the new week's prices
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_CHECK_PRICE_WATCHES();
END;
$$;
ALTER TASK GROCERYDBTPROJECT.GROCERY_ML.TASK_WEEKLY_PRICE_FORECAST RESUME;

GRANT USAGE ON CORTEX SEARCH SERVICE GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH TO ROLE GROCERY_AGENT_USER;
GRANT SELECT ON SEMANTIC VIEW GROCERYDBTPROJECT.GROCERY_SEMANTIC.DBT_SV_GROCERY_PRICING TO ROLE GROCERY_AGENT_USER;
GRANT SELECT ON VIEW GROCERYDBTPROJECT.GROCERY_SEMANTIC.DBT_SEARCH_PRODUCT_INDEX TO ROLE GROCERY_AGENT_USER;
GRANT SELECT ON TABLE GROCERYDBTPROJECT.GROCERY_RAW.DBT_ZIP_CENTROIDS_GA TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_RAW TO ROLE GROCERY_AGENT_USER;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_SEMANTIC.SP_COMPARE_BASKET(VARCHAR, VARCHAR, NUMBER) TO ROLE GROCERY_AGENT_USER;
