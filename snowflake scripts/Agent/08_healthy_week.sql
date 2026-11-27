-- Grocery value agent — Phase 8: healthy week basket.
-- (plan: ~/.claude/plans/healthy-week-basket.md, 2026-11-27)
--
-- A shopper gives a weekly budget, a diet (none, vegetarian, vegan,
-- kosher_halal) and a Georgia ZIP. SP_SUGGEST_WEEKLY_BASKET proposes a
-- week of groceries from the nearest Kroger that fits the budget, respects
-- the diet, meets healthy-eating limits and favours items at a good price
-- right now. The apps save the result through SP_TRACK_BASKET /
-- SP_GUEST_TRACK_BASKET, so the Sunday basket check covers it from then on.
--
-- RULES PICK, AI EXPLAINS (owner decision). Every rule cites a source held
-- in the dbt seed diet_guideline (GROCERY_RAW.DBT_DIET_GUIDELINE):
--   * How the budget is split: USDA Thrifty Food Plan 2021 market-basket
--     cost shares per food group and subcategory (tables A4.10 males 20-50,
--     A4.11 females 20-50; PROFILE 'adult' averages the two). The TFP's
--     "miscellaneous" share (~8%: oils, coffee, condiments, sweets) is left
--     unallocated and reported, never spent on picks.
--   * Which items qualify: dim_product_diet (dbt) — a real food group,
--     HEALTHY_STATUS whole_food or meets_limits (FDA "healthy" per-serving
--     limits), and the diet's status allowed. Kroger only: Walmart carries
--     no diet or nutrition data.
--   * Which item wins within a category: VALUE_SCORE = 0.5 x percentile
--     rank (fct_buy_recommendation.CHEAPER_THAN_PCT, the basket-watch
--     statistic) + 0.3 x price per pound vs the category + 0.2 x Kroger's
--     nutritional rating.
--   * Diet moves: a category the diet rules out (or that has no eligible
--     item at the store) passes its dollars to the diet's alternatives
--     (vegan: legumes, nuts/seeds/soy, fortified plant milks; vegetarian:
--     those plus eggs; kosher/halal: legumes, nuts, eggs, scaled fish).
--     No raw meat or poultry in the catalog is declared kosher (2026-11-27),
--     so the kosher/halal basket carries none and says so; halal shoppers
--     are told to confirm meat and poultry themselves.
--   * Picking: pass 1 takes the best-value item in every category that has
--     dollars, largest categories first, while the running total fits the
--     budget; pass 2 (up to 3 rounds) adds a second item to categories still
--     under 1.5x target, one product type once, at most MAX_ITEMS in all;
--     pass 3 raises quantities (up to 4 of an item) in the categories
--     furthest under target until the budget or every target is met, so
--     $75 buys a week of food, not 15 single packs.
--   * Candidates with a Kroger nutritional rating under 30 are skipped
--     (data-quality floor: a vegan cheese rated 9/100 was winning its
--     category by default), unless they are plain whole foods.
--   * Narrative: SNOWFLAKE.CORTEX.COMPLETE('claude-haiku-5-5') writes 8-12
--     lines of meal-prep ideas that may name items only by their [n] tag.
--     Lines without a valid tag, with a tag outside the picks, or with
--     health-claim words are dropped before the text is returned (prompt
--     version in PROMPT_VERSION; prompt-engineer-toolkit checklist applied:
--     explicit task, schema, exclusions, no contradictions). Token usage is
--     returned for metering. A Cortex failure returns the basket without text.
--
-- Guests: Snowflake Scripts/Guest/05_guest_healthy_week.sql wraps this with
-- a session check and limits.
--
-- Run as ACCOUNTADMIN after 07 and the dbt build of dim_product_diet.
-- Sandbox variant (same as 07):
--   sed -E 's/GROCERY_(APP|SEMANTIC|MARTS|ML|RAW)([^_A-Za-z0-9]|$)/GROCERY_DEV_\1\2/g; s/GROCERY_AGENT_WH/COMPUTE_WH/g; /^-- PROD ONLY/,$d'

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GROCERY_AGENT_WH;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_SUGGEST_WEEKLY_BASKET(
    BUDGET NUMBER, DIET VARCHAR, ZIP_CODE VARCHAR,
    PROFILE VARCHAR DEFAULT 'adult', MAX_ITEMS NUMBER DEFAULT 15, WITH_NARRATIVE BOOLEAN DEFAULT TRUE)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Propose a week of healthy groceries at the nearest Kroger for a weekly BUDGET (USD 20-500), a DIET (none | vegetarian | vegan | kosher_halal) and a Georgia ZIP_CODE. Budget split by USDA Thrifty Food Plan shares; items must meet FDA "healthy" per-serving limits and the diet; best value by percentile rank. Returns items (product keys for SP_TRACK_BASKET), per-group targets vs spend, sources, notes, a short meal-prep narrative and its token count.'
EXECUTE AS OWNER
AS
$$
DECLARE
    budget_n NUMBER(10,2); diet_n VARCHAR; prof VARCHAR; max_n NUMBER;
    sid VARCHAR; n_picks NUMBER DEFAULT 0; total NUMBER(10,2) DEFAULT 0;
    round_n NUMBER DEFAULT 0; inserted NUMBER DEFAULT 1;
    items_text VARCHAR; prompt_sys VARCHAR; prompt_user VARCHAR; resp VARIANT; raw_text VARCHAR;
    narrative VARCHAR; tokens NUMBER; model VARCHAR DEFAULT 'claude-haiku-5-5';
    prompt_version VARCHAR DEFAULT 'healthy_week_narrative v1 (2026-11-27)';
BEGIN
    budget_n := LEAST(500, GREATEST(20, COALESCE(:BUDGET, 75)));
    diet_n := CASE LOWER(TRIM(COALESCE(:DIET, 'none')))
                  WHEN 'vegan' THEN 'vegan' WHEN 'vegetarian' THEN 'vegetarian'
                  WHEN 'kosher_halal' THEN 'kosher_halal' WHEN 'kosher' THEN 'kosher_halal' WHEN 'halal' THEN 'kosher_halal'
                  WHEN 'kosher / halal-friendly' THEN 'kosher_halal' ELSE 'none' END;
    prof := CASE LOWER(TRIM(COALESCE(:PROFILE, 'adult'))) WHEN 'adult_male' THEN 'adult_male' WHEN 'adult_female' THEN 'adult_female' ELSE 'adult' END;
    max_n := LEAST(30, GREATEST(5, COALESCE(:MAX_ITEMS, 15)));

    -- 1. Store: the nearest Kroger with current prices to the ZIP; an unknown ZIP falls back
    --    to the Kroger store with the most priced products. (Temp tables are schema-qualified:
    --    owner's-rights procedures have no current schema.)
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_APP.hw_store AS
    WITH z AS (SELECT LATITUDE, LONGITUDE FROM GROCERYDBTPROJECT.GROCERY_RAW.DBT_ZIP_CENTROIDS_GA WHERE ZIP_CODE = :ZIP_CODE),
    priced AS (SELECT STORE_ID, COUNT(*) AS N, MAX(DATA_AS_OF) AS AS_OF
               FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_SUMMARY WHERE IS_CURRENTLY_LISTED GROUP BY STORE_ID)
    SELECT s.STORE_ID, s.STORE_NAME, s.CITY, p.N AS PRICED_PRODUCTS, p.AS_OF,
           ROUND(HAVERSINE(z.LATITUDE, z.LONGITUDE, s.LATITUDE, s.LONGITUDE) * 0.621371, 1) AS MILES
    FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_STORE s
    JOIN priced p ON p.STORE_ID = s.STORE_ID
    LEFT JOIN z ON TRUE
    WHERE s.RETAILER = 'kroger'
    QUALIFY ROW_NUMBER() OVER (ORDER BY HAVERSINE(z.LATITUDE, z.LONGITUDE, s.LATITUDE, s.LONGITUDE) NULLS LAST, p.N DESC, s.STORE_ID) = 1;
    SELECT MAX(STORE_ID) INTO :sid FROM GROCERYDBTPROJECT.GROCERY_APP.hw_store;
    IF (sid IS NULL) THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'no_store_prices'); END IF;

    -- 2. Candidates at that store: eligible by food group, FDA limits and diet; scored.
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_APP.hw_cand AS
    WITH c AS (
        SELECT d.PRODUCT_KEY, d.PRODUCT_NAME, d.BRAND, d.SIZE_TEXT, d.PRODUCT_TYPE, d.FOOD_GROUP, d.TFP_CATEGORY,
               d.IS_WHOLE_FOOD, d.HEALTHY_STATUS, d.VEGAN_STATUS, d.VEGETARIAN_STATUS, d.KOSHER_HALAL_STATUS,
               d.DECL_HALAL, d.VEGAN_DECLARED_CONFLICT, d.EST_LBS, d.NUTRITIONAL_RATING,
               d.SODIUM_MG, d.ADDED_SUGAR_G, d.SATURATED_FAT_G, d.PROTEIN_G, d.FIBER_G, d.CONTAINS_ALLERGENS, d.IS_STORE_BRAND,
               p.CURRENT_PRICE AS PRICE, p.IS_ON_PROMO, b.CHEAPER_THAN_PCT, b.RECOMMENDATION, b.WEEKS_OBSERVED,
               IFF(d.EST_LBS > 0, p.CURRENT_PRICE / d.EST_LBS, NULL) AS PRICE_PER_LB
        FROM GROCERYDBTPROJECT.GROCERY_MARTS.DBT_DIM_PRODUCT_DIET d
        JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_PRODUCT_PRICE_SUMMARY p
             ON p.PRODUCT_KEY = d.PRODUCT_KEY AND p.STORE_ID = :sid AND p.IS_CURRENTLY_LISTED
        LEFT JOIN GROCERYDBTPROJECT.GROCERY_MARTS.DBT_FCT_BUY_RECOMMENDATION b ON b.PRODUCT_KEY = d.PRODUCT_KEY
        WHERE d.FOOD_GROUP IN ('vegetables', 'fruits', 'grains', 'dairy', 'protein')
          AND d.HEALTHY_STATUS IN ('whole_food', 'meets_limits')
          AND (d.IS_WHOLE_FOOD OR d.NUTRITIONAL_RATING IS NULL OR d.NUTRITIONAL_RATING >= 30)   -- data-quality floor, not guidance
          AND p.CURRENT_PRICE > 0
          AND (:diet_n = 'none'
               OR (:diet_n = 'vegetarian'   AND d.VEGETARIAN_STATUS   IN ('declared', 'whole_food', 'no_meat_ingredients_found'))
               OR (:diet_n = 'vegan'        AND d.VEGAN_STATUS        IN ('declared', 'whole_food_plant', 'no_animal_ingredients_found'))
               OR (:diet_n = 'kosher_halal' AND d.KOSHER_HALAL_STATUS IN ('declared_kosher', 'inherently_kosher_whole_food')))
    )
    SELECT c.*,
           -- value score 0..1: percentile rank (the basket-watch statistic), price per pound within the
           -- category (unknown sizes sit in the middle), Kroger's nutritional rating
           ROUND(0.5 * COALESCE(CHEAPER_THAN_PCT, 40) / 100
               + 0.3 * IFF(PRICE_PER_LB IS NULL, 0.5, 1 - PERCENT_RANK() OVER (PARTITION BY TFP_CATEGORY, (PRICE_PER_LB IS NULL) ORDER BY PRICE_PER_LB))
               + 0.2 * COALESCE(NUTRITIONAL_RATING, 50) / 100, 4) AS VALUE_SCORE
    FROM c;

    -- 3. Allocation: TFP cost share per subcategory (profile 'adult' = mean of the two tables),
    --    the misc share left unallocated; categories with no eligible item pass their dollars to
    --    the diet's alternatives (or, with none, to every category that has items).
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_APP.hw_alloc AS
    WITH prof_rows AS (
        SELECT FOOD_GROUP, TFP_CATEGORY, METRIC, AVG(VALUE) AS VALUE
        FROM GROCERYDBTPROJECT.GROCERY_RAW.DBT_DIET_GUIDELINE
        WHERE SOURCE_KEY = 'tfp2021' AND RULE_KEY IN ('subcategory_cost_share', 'subcategory_lbs')
          AND PROFILE IN (IFF(:prof = 'adult', 'adult_male', :prof), IFF(:prof = 'adult', 'adult_female', :prof))
        GROUP BY FOOD_GROUP, TFP_CATEGORY, METRIC
    ),
    share AS (
        SELECT FOOD_GROUP, TFP_CATEGORY,
               MAX(IFF(METRIC = 'cost_share_pct_of_total', VALUE, NULL)) AS TFP_SHARE_PCT,
               MAX(IFF(METRIC = 'lbs_per_week', VALUE, NULL)) AS TARGET_LBS
        FROM prof_rows WHERE FOOD_GROUP <> 'misc' GROUP BY FOOD_GROUP, TFP_CATEGORY
    ),
    avail AS (SELECT TFP_CATEGORY, COUNT(*) AS N_CANDIDATES FROM GROCERYDBTPROJECT.GROCERY_APP.hw_cand GROUP BY TFP_CATEGORY),
    base AS (
        SELECT s.*, COALESCE(a.N_CANDIDATES, 0) AS N_CANDIDATES,
               IFF(COALESCE(a.N_CANDIDATES, 0) > 0, s.TFP_SHARE_PCT, 0) AS KEPT_PCT,
               CASE WHEN COALESCE(a.N_CANDIDATES, 0) = 0 THEN 0
                    WHEN :diet_n = 'vegan'        AND s.TFP_CATEGORY IN ('veg_legumes', 'protein_nuts_seeds_soy', 'dairy_lowfat') THEN 1
                    WHEN :diet_n = 'vegetarian'   AND s.TFP_CATEGORY IN ('veg_legumes', 'protein_nuts_seeds_soy', 'protein_egg', 'dairy_lowfat') THEN 1
                    WHEN :diet_n = 'kosher_halal' AND s.TFP_CATEGORY IN ('veg_legumes', 'protein_nuts_seeds_soy', 'protein_egg', 'protein_seafood') THEN 1
                    ELSE 0 END AS IS_ALTERNATIVE
        FROM share s LEFT JOIN avail a ON a.TFP_CATEGORY = s.TFP_CATEGORY
    ),
    tot AS (
        SELECT SUM(TFP_SHARE_PCT - KEPT_PCT) AS MOVED_PCT,
               SUM(IFF(IS_ALTERNATIVE = 1, KEPT_PCT, 0)) AS ALT_PCT,
               SUM(KEPT_PCT) AS KEPT_TOTAL_PCT
        FROM base
    )
    SELECT b.FOOD_GROUP, b.TFP_CATEGORY, b.TFP_SHARE_PCT, b.TARGET_LBS, b.N_CANDIDATES,
           b.KEPT_PCT + CASE WHEN t.MOVED_PCT <= 0 OR b.KEPT_PCT = 0 THEN 0
                             WHEN t.ALT_PCT > 0 THEN IFF(b.IS_ALTERNATIVE = 1, t.MOVED_PCT * b.KEPT_PCT / t.ALT_PCT, 0)
                             ELSE t.MOVED_PCT * b.KEPT_PCT / NULLIF(t.KEPT_TOTAL_PCT, 0) END AS SHARE_PCT,
           ROUND(:budget_n * (b.KEPT_PCT + CASE WHEN t.MOVED_PCT <= 0 OR b.KEPT_PCT = 0 THEN 0
                             WHEN t.ALT_PCT > 0 THEN IFF(b.IS_ALTERNATIVE = 1, t.MOVED_PCT * b.KEPT_PCT / t.ALT_PCT, 0)
                             ELSE t.MOVED_PCT * b.KEPT_PCT / NULLIF(t.KEPT_TOTAL_PCT, 0) END) / 100, 2) AS TARGET_DOLLARS
    FROM base b CROSS JOIN tot t;

    -- 4. Pass 1: the best-value item of every category with dollars (one that fits 1.5x its
    --    target when there is one), largest categories first, while the running total fits.
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_APP.hw_pick (PRODUCT_KEY VARCHAR, TFP_CATEGORY VARCHAR, PASS NUMBER, PICK_ORDER NUMBER, QTY NUMBER DEFAULT 1);
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.hw_pick (PRODUCT_KEY, TFP_CATEGORY, PASS, PICK_ORDER)
    WITH best AS (
        SELECT c.PRODUCT_KEY, c.TFP_CATEGORY, c.PRICE, a.TARGET_DOLLARS,
               ROW_NUMBER() OVER (PARTITION BY c.TFP_CATEGORY
                                  ORDER BY IFF(c.PRICE <= a.TARGET_DOLLARS * 1.5, 0, 1), c.VALUE_SCORE DESC, c.PRICE, c.PRODUCT_KEY) AS RN
        FROM GROCERYDBTPROJECT.GROCERY_APP.hw_cand c
        JOIN GROCERYDBTPROJECT.GROCERY_APP.hw_alloc a ON a.TFP_CATEGORY = c.TFP_CATEGORY
        WHERE a.TARGET_DOLLARS > 0
    ),
    ordered AS (
        SELECT *, ROW_NUMBER() OVER (ORDER BY TARGET_DOLLARS DESC, TFP_CATEGORY) AS ORD,
               SUM(PRICE) OVER (ORDER BY TARGET_DOLLARS DESC, TFP_CATEGORY ROWS UNBOUNDED PRECEDING) AS RUN_TOTAL
        FROM best WHERE RN = 1
    )
    SELECT PRODUCT_KEY, TFP_CATEGORY, 1, ORD FROM ordered WHERE RUN_TOTAL <= :budget_n AND ORD <= :max_n;

    -- 5. Pass 2 (up to 3 rounds): fill what is left — items from categories still under target
    --    first, best value first, one product type once, at most 3 items per category.
    WHILE (round_n < 3 AND inserted > 0) DO
        INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.hw_pick (PRODUCT_KEY, TFP_CATEGORY, PASS, PICK_ORDER)
        WITH picked AS (
            SELECT p.PRODUCT_KEY, p.TFP_CATEGORY, c.PRICE, c.PRODUCT_TYPE
            FROM GROCERYDBTPROJECT.GROCERY_APP.hw_pick p JOIN GROCERYDBTPROJECT.GROCERY_APP.hw_cand c ON c.PRODUCT_KEY = p.PRODUCT_KEY
        ),
        state AS (SELECT :budget_n - COALESCE(SUM(PRICE), 0) AS LEFT_DOLLARS, COUNT(*) AS N_PICKED FROM picked),
        spent AS (
            SELECT a.TFP_CATEGORY, a.TARGET_DOLLARS, COALESCE(SUM(p.PRICE), 0) AS SPENT, COUNT(p.PRODUCT_KEY) AS N_IN_CAT
            FROM GROCERYDBTPROJECT.GROCERY_APP.hw_alloc a LEFT JOIN picked p ON p.TFP_CATEGORY = a.TFP_CATEGORY
            GROUP BY a.TFP_CATEGORY, a.TARGET_DOLLARS
        ),
        cands AS (
            SELECT c.PRODUCT_KEY, c.TFP_CATEGORY, c.PRICE,
                   ROW_NUMBER() OVER (ORDER BY IFF(s.SPENT + c.PRICE <= s.TARGET_DOLLARS * 1.25, 0, 1), c.VALUE_SCORE DESC, c.PRICE, c.PRODUCT_KEY) AS ORD
            FROM GROCERYDBTPROJECT.GROCERY_APP.hw_cand c
            JOIN spent s ON s.TFP_CATEGORY = c.TFP_CATEGORY
            CROSS JOIN state st
            WHERE s.TARGET_DOLLARS > 0 AND s.N_IN_CAT < 2
              AND c.PRICE <= st.LEFT_DOLLARS
              AND s.SPENT + c.PRICE <= s.TARGET_DOLLARS * 1.5
              AND c.PRODUCT_KEY NOT IN (SELECT PRODUCT_KEY FROM picked)
              AND COALESCE(c.PRODUCT_TYPE, '') NOT IN (SELECT COALESCE(PRODUCT_TYPE, '') FROM picked)
            QUALIFY ROW_NUMBER() OVER (PARTITION BY c.TFP_CATEGORY ORDER BY IFF(s.SPENT + c.PRICE <= s.TARGET_DOLLARS * 1.25, 0, 1), c.VALUE_SCORE DESC, c.PRICE) = 1
        ),
        run AS (SELECT *, SUM(PRICE) OVER (ORDER BY ORD ROWS UNBOUNDED PRECEDING) AS RUN_TOTAL FROM cands)
        SELECT r.PRODUCT_KEY, r.TFP_CATEGORY, 2 + :round_n, 100 * (:round_n + 1) + r.ORD
        FROM run r CROSS JOIN state st
        WHERE r.RUN_TOTAL <= st.LEFT_DOLLARS AND r.ORD <= :max_n - st.N_PICKED;
        inserted := SQLROWCOUNT;
        round_n := round_n + 1;
    END WHILE;

    -- 5b. Quantities: with the item cap reached and money left, buy more of the picks in the
    --     categories furthest under their target (up to 4 of an item, 1.15x a category's target),
    --     so a $75 week is a week's worth of food, not 15 single packs.
    round_n := 0; inserted := 1;
    WHILE (round_n < 15 AND inserted > 0) DO
        LET next_key VARCHAR := (
            WITH picked AS (
                SELECT p.PRODUCT_KEY, p.TFP_CATEGORY, p.QTY, c.PRICE, c.VALUE_SCORE
                FROM GROCERYDBTPROJECT.GROCERY_APP.hw_pick p JOIN GROCERYDBTPROJECT.GROCERY_APP.hw_cand c ON c.PRODUCT_KEY = p.PRODUCT_KEY
            ),
            st AS (SELECT :budget_n - COALESCE(SUM(PRICE * QTY), 0) AS LEFT_DOLLARS FROM picked),
            spent AS (
                SELECT a.TFP_CATEGORY, a.TARGET_DOLLARS, COALESCE(SUM(p.PRICE * p.QTY), 0) AS SPENT
                FROM GROCERYDBTPROJECT.GROCERY_APP.hw_alloc a LEFT JOIN picked p ON p.TFP_CATEGORY = a.TFP_CATEGORY
                GROUP BY a.TFP_CATEGORY, a.TARGET_DOLLARS
            )
            SELECT MAX(PRODUCT_KEY) FROM (
                SELECT p.PRODUCT_KEY
                FROM picked p JOIN spent s ON s.TFP_CATEGORY = p.TFP_CATEGORY CROSS JOIN st
                WHERE p.QTY < 4 AND p.PRICE <= st.LEFT_DOLLARS AND s.SPENT + p.PRICE <= s.TARGET_DOLLARS * 1.15
                ORDER BY (s.TARGET_DOLLARS - s.SPENT) DESC, p.VALUE_SCORE DESC, p.PRICE, p.PRODUCT_KEY
                LIMIT 1));
        IF (next_key IS NULL) THEN
            inserted := 0;
        ELSE
            UPDATE GROCERYDBTPROJECT.GROCERY_APP.hw_pick SET QTY = QTY + 1 WHERE PRODUCT_KEY = :next_key;
            inserted := SQLROWCOUNT;
        END IF;
        round_n := round_n + 1;
    END WHILE;

    SELECT COUNT(*), COALESCE(SUM(c.PRICE * p.QTY), 0)
      INTO :n_picks, :total
    FROM GROCERYDBTPROJECT.GROCERY_APP.hw_pick p JOIN GROCERYDBTPROJECT.GROCERY_APP.hw_cand c ON c.PRODUCT_KEY = p.PRODUCT_KEY;

    -- 6. The picks, numbered, with the reasons a shopper can check
    CREATE OR REPLACE TEMPORARY TABLE GROCERYDBTPROJECT.GROCERY_APP.hw_items AS
    SELECT ROW_NUMBER() OVER (ORDER BY DECODE(c.FOOD_GROUP, 'vegetables', 1, 'fruits', 2, 'grains', 3, 'dairy', 4, 'protein', 5, 9), c.TFP_CATEGORY, p.PICK_ORDER) AS N,
           c.*, p.PASS, p.QTY, ROUND(c.PRICE * p.QTY, 2) AS LINE_TOTAL, c.EST_LBS * p.QTY AS LINE_LBS,
           DECODE(c.TFP_CATEGORY,
               'veg_dark_green', 'Dark-green vegetables', 'veg_red_orange', 'Red and orange vegetables', 'veg_legumes', 'Beans, peas, lentils',
               'veg_starchy', 'Starchy vegetables', 'veg_other', 'Other vegetables', 'fruit_whole', 'Whole fruit', 'fruit_juice', '100% fruit juice',
               'grain_whole_staple', 'Whole-grain staples', 'grain_whole_cereal', 'Whole-grain cereal', 'grain_refined_staple', 'Refined-grain staples',
               'grain_refined_other', 'Other grains', 'dairy_lowfat', 'Low-fat milk, yogurt, soy alternatives', 'dairy_higherfat', 'Higher-fat milk and yogurt',
               'dairy_cheese', 'Cheese', 'protein_meat', 'Meats', 'protein_poultry', 'Poultry', 'protein_egg', 'Eggs', 'protein_seafood', 'Seafood',
               'protein_nuts_seeds_soy', 'Nuts, seeds, soy', c.TFP_CATEGORY) AS CATEGORY_LABEL,
           CASE WHEN c.IS_WHOLE_FOOD THEN 'plain whole food'
                ELSE 'meets FDA healthy limits per serving (sodium ' || COALESCE(c.SODIUM_MG, 0)::INT || ' mg, added sugar ' || COALESCE(c.ADDED_SUGAR_G, 0) || ' g, saturated fat ' || COALESCE(c.SATURATED_FAT_G, 0) || ' g)' END AS HEALTHY_LABEL,
           CASE :diet_n
               WHEN 'vegan' THEN DECODE(c.VEGAN_STATUS, 'declared', 'declared vegan by the maker' || IFF(c.VEGAN_DECLARED_CONFLICT, ' (allergen or ingredient data disagrees: check the pack)', ''),
                                        'whole_food_plant', 'plain plant food', 'no_animal_ingredients_found', 'no animal ingredient found in the ingredient list', c.VEGAN_STATUS)
               WHEN 'vegetarian' THEN DECODE(c.VEGETARIAN_STATUS, 'declared', 'declared vegetarian or vegan by the maker', 'whole_food', 'plain whole food',
                                             'no_meat_ingredients_found', 'no meat or fish ingredient found in the ingredient list', c.VEGETARIAN_STATUS)
               WHEN 'kosher_halal' THEN DECODE(c.KOSHER_HALAL_STATUS, 'declared_kosher', 'kosher symbol declared by the maker' || IFF(c.DECL_HALAL, '; also declared halal by the maker', ''),
                                               'inherently_kosher_whole_food', 'plain whole food, kosher and halal without a symbol', c.KOSHER_HALAL_STATUS)
               ELSE NULL END AS DIET_LABEL,
           CASE WHEN c.CHEAPER_THAN_PCT IS NULL THEN 'price history too short to rank'
                WHEN c.CHEAPER_THAN_PCT >= 75 THEN 'good time to buy: cheaper than ' || c.CHEAPER_THAN_PCT || '% of its last 12 weeks'
                WHEN c.CHEAPER_THAN_PCT >= 50 THEN 'cheaper than ' || c.CHEAPER_THAN_PCT || '% of its last 12 weeks'
                ELSE 'typical price (cheaper than ' || c.CHEAPER_THAN_PCT || '% of its last 12 weeks)' END
           || IFF(c.IS_ON_PROMO, '; on promotion', '')
           || IFF(c.NUTRITIONAL_RATING IS NOT NULL, '; Kroger nutrition rating ' || c.NUTRITIONAL_RATING::INT || '/100', '') AS VALUE_LABEL
    FROM GROCERYDBTPROJECT.GROCERY_APP.hw_pick p JOIN GROCERYDBTPROJECT.GROCERY_APP.hw_cand c ON c.PRODUCT_KEY = p.PRODUCT_KEY;

    -- 7. Narrative (Haiku), grounded by construction: items are referred to by [n] tags only and
    --    every returned line is checked for a valid tag.
    IF (COALESCE(:WITH_NARRATIVE, TRUE) AND n_picks > 0) THEN
        SELECT LISTAGG('[' || N || '] ' || PRODUCT_NAME || COALESCE(' (' || SIZE_TEXT || ')', '') || IFF(QTY > 1, ' x' || QTY, '') || ' - ' || CATEGORY_LABEL, '\n') WITHIN GROUP (ORDER BY N)
          INTO :items_text FROM GROCERYDBTPROJECT.GROCERY_APP.hw_items;
        prompt_sys := 'You write short, practical meal-prep notes for a home cook. You are given a numbered list of grocery items bought for one week. '
                   || 'Rules: (1) Write 8 to 12 lines, one idea per line, plain text, no heading, no markdown, no bullets other than a leading dash. '
                   || '(2) Every line must mention at least one item and refer to items ONLY by their tag, e.g. [3], never by a new name or an item not in the list. '
                   || '(3) You may assume only water, salt, pepper, cooking oil and dried spices beyond the list. '
                   || '(4) Do not invent items, quantities bought, prices, nutrition facts or health benefits; do not give medical, diet or weight advice. '
                   || '(5) Cover breakfasts, lunches, dinners and snacks across the week, and end with one line on what to prep on shopping day (wash, cook, portion). '
                   || 'Follow the diet named by the user exactly.';
        prompt_user := 'Diet: ' || DECODE(:diet_n, 'none', 'no restriction', 'vegetarian', 'vegetarian (no meat or fish)', 'vegan', 'vegan (no animal products)', 'kosher_halal', 'kosher / halal-friendly (no pork, shellfish or alcohol)')
                    || '. Weekly budget: $' || :budget_n || '. Items:\n' || :items_text;
        BEGIN
            -- max_tokens is generous on purpose: with a tight cap (400-700) Cortex returned an
            -- empty "messages" for Claude 5 models while still billing the tokens (2026-11-27);
            -- the model stops on its own at ~700 completion tokens.
            SELECT SNOWFLAKE.CORTEX.COMPLETE(:model,
                       ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('role', 'system', 'content', :prompt_sys),
                                       OBJECT_CONSTRUCT('role', 'user', 'content', :prompt_user)),
                       OBJECT_CONSTRUCT('temperature', 0, 'max_tokens', 2000))
              INTO :resp;
            raw_text := resp:choices[0]:messages::STRING;
            tokens := resp:usage:total_tokens::NUMBER;
            IF (raw_text IS NULL OR LENGTH(TRIM(raw_text)) = 0) THEN
                -- second try through the plain-string form, which has returned text when the
                -- message form came back empty; it reports no usage, so tokens are estimated
                SELECT SNOWFLAKE.CORTEX.COMPLETE(:model, :prompt_sys || '\n\n' || :prompt_user) INTO :raw_text;
                tokens := COALESCE(:tokens, 0) + CEIL(LENGTH(:prompt_sys || :prompt_user || COALESCE(:raw_text, '')) / 4);
            END IF;
            -- keep lines that carry at least one tag, every tag within 1..n_picks, and no health-claim words
            SELECT LISTAGG(LINE, '\n') WITHIN GROUP (ORDER BY IDX)
              INTO :narrative
            FROM (
                SELECT l.index AS IDX, TRIM(l.value::STRING) AS LINE,
                       REGEXP_SUBSTR_ALL(l.value::STRING, '\\[([0-9]+)\\]', 1, 1, 'e', 1) AS TAGS
                FROM TABLE(FLATTEN(INPUT => SPLIT(:raw_text, '\n'))) l
            )
            WHERE ARRAY_SIZE(TAGS) > 0
              AND ARRAY_SIZE(FILTER(TAGS, t -> TRY_TO_NUMBER(t::STRING) IS NULL OR TRY_TO_NUMBER(t::STRING) < 1 OR TRY_TO_NUMBER(t::STRING) > :n_picks)) = 0
              AND REGEXP_COUNT(LOWER(LINE), 'diagnos|cure|treat|lose weight|weight loss|calorie|medical|disease|cholesterol|blood pressure|detox') = 0
              AND IDX < 14;
        EXCEPTION WHEN OTHER THEN
            narrative := NULL; tokens := NULL;
        END;
    END IF;

    -- 8. Result
    RETURN OBJECT_CONSTRUCT(
        'ok', TRUE,
        'budget', :budget_n, 'diet', :diet_n, 'profile', :prof, 'max_items', :max_n,
        'store', (SELECT OBJECT_CONSTRUCT('store_id', STORE_ID, 'store', STORE_NAME, 'city', CITY, 'miles', MILES, 'retailer', 'kroger', 'as_of', AS_OF)
                  FROM GROCERYDBTPROJECT.GROCERY_APP.hw_store),
        'items_n', :n_picks, 'total', :total, 'remaining', ROUND(:budget_n - :total, 2),
        'unallocated', (SELECT ROUND(:budget_n - SUM(TARGET_DOLLARS), 2) FROM GROCERYDBTPROJECT.GROCERY_APP.hw_alloc),
        'items', (SELECT COALESCE(ARRAY_AGG(OBJECT_CONSTRUCT(
                      'n', N, 'product_key', PRODUCT_KEY, 'item', PRODUCT_NAME, 'product', PRODUCT_NAME, 'brand', BRAND, 'size', SIZE_TEXT,
                      'product_type', PRODUCT_TYPE, 'price', PRICE, 'qty', QTY, 'line_total', LINE_TOTAL, 'on_promo', IS_ON_PROMO, 'store_brand', IS_STORE_BRAND,
                      'food_group', FOOD_GROUP, 'category', TFP_CATEGORY, 'category_label', CATEGORY_LABEL,
                      'cheaper_than_pct', CHEAPER_THAN_PCT, 'weeks', WEEKS_OBSERVED, 'recommendation', RECOMMENDATION, 'value_score', VALUE_SCORE,
                      'est_lbs', EST_LBS, 'price_per_lb', ROUND(PRICE_PER_LB, 2),
                      'healthy_status', HEALTHY_STATUS, 'healthy', HEALTHY_LABEL, 'diet_status',
                          DECODE(:diet_n, 'vegan', VEGAN_STATUS, 'vegetarian', VEGETARIAN_STATUS, 'kosher_halal', KOSHER_HALAL_STATUS, NULL),
                      'diet', DIET_LABEL, 'value', VALUE_LABEL, 'allergens', CONTAINS_ALLERGENS,
                      'sodium_mg', SODIUM_MG, 'added_sugar_g', ADDED_SUGAR_G, 'saturated_fat_g', SATURATED_FAT_G, 'protein_g', PROTEIN_G, 'fiber_g', FIBER_G,
                      'nutrition_rating', NUTRITIONAL_RATING, 'pass', PASS)) WITHIN GROUP (ORDER BY N), ARRAY_CONSTRUCT())
                  FROM GROCERYDBTPROJECT.GROCERY_APP.hw_items),
        'groups', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('food_group', g.FOOD_GROUP, 'target_dollars', g.TARGET, 'spent', COALESCE(i.SPENT, 0), 'items', COALESCE(i.N, 0),
                                                     'target_lbs', g.LBS, 'est_lbs', i.LBS, 'lbs_known_items', COALESCE(i.LBS_N, 0)))
                          WITHIN GROUP (ORDER BY DECODE(g.FOOD_GROUP, 'vegetables', 1, 'fruits', 2, 'grains', 3, 'dairy', 4, 'protein', 5))
                   FROM (SELECT FOOD_GROUP, ROUND(SUM(TARGET_DOLLARS), 2) AS TARGET, ROUND(SUM(TARGET_LBS), 2) AS LBS FROM GROCERYDBTPROJECT.GROCERY_APP.hw_alloc GROUP BY FOOD_GROUP) g
                   LEFT JOIN (SELECT FOOD_GROUP, ROUND(SUM(LINE_TOTAL), 2) AS SPENT, COUNT(*) AS N, ROUND(SUM(LINE_LBS), 2) AS LBS, COUNT(EST_LBS) AS LBS_N FROM GROCERYDBTPROJECT.GROCERY_APP.hw_items GROUP BY FOOD_GROUP) i
                        ON i.FOOD_GROUP = g.FOOD_GROUP),
        'categories', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('food_group', a.FOOD_GROUP, 'category', a.TFP_CATEGORY, 'tfp_share_pct', a.TFP_SHARE_PCT, 'share_pct', ROUND(a.SHARE_PCT, 2),
                                                         'target_dollars', a.TARGET_DOLLARS, 'target_lbs', a.TARGET_LBS, 'candidates', a.N_CANDIDATES,
                                                         'spent', COALESCE(i.SPENT, 0), 'items', COALESCE(i.N, 0)))
                              WITHIN GROUP (ORDER BY a.TARGET_DOLLARS DESC)
                       FROM GROCERYDBTPROJECT.GROCERY_APP.hw_alloc a
                       LEFT JOIN (SELECT TFP_CATEGORY, ROUND(SUM(LINE_TOTAL), 2) AS SPENT, COUNT(*) AS N FROM GROCERYDBTPROJECT.GROCERY_APP.hw_items GROUP BY TFP_CATEGORY) i
                            ON i.TFP_CATEGORY = a.TFP_CATEGORY),
        'daily_pattern', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('food_group', FOOD_GROUP, 'servings_per_day', VALUE, 'note', NOTE)) WITHIN GROUP (ORDER BY FOOD_GROUP)
                          FROM GROCERYDBTPROJECT.GROCERY_RAW.DBT_DIET_GUIDELINE WHERE SOURCE_KEY = 'dga2025' AND METRIC = 'servings_per_day'),
        'sources', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('source', SOURCE_NAME, 'url', URL, 'used_for', USED_FOR)) WITHIN GROUP (ORDER BY ORD)
                    FROM (SELECT SOURCE_NAME, URL, MIN(ORD) AS ORD, MIN(USED_FOR) AS USED_FOR FROM (
                              SELECT SOURCE_NAME, URL,
                                     DECODE(SOURCE_KEY, 'tfp2021', 1, 'dga2025', 2, 'fda_healthy_2024', 3, 'vegan_society', 4, 'ou_kosher', 5, 'yale_halal', 6, 9) AS ORD,
                                     DECODE(SOURCE_KEY, 'tfp2021', 'how the budget is split across food groups and the pounds per week to aim for',
                                                        'dga2025', 'the daily pattern (servings of vegetables, fruit, whole grains, dairy)',
                                                        'fda_healthy_2024', 'the per-serving limits on sodium, added sugar and saturated fat an item must meet',
                                                        'vegan_society', 'what counts as vegan', 'ou_kosher', 'what counts as kosher', 'yale_halal', 'what counts as halal') AS USED_FOR
                              FROM GROCERYDBTPROJECT.GROCERY_RAW.DBT_DIET_GUIDELINE
                              WHERE SOURCE_KEY IN ('tfp2021', 'dga2025', 'fda_healthy_2024')
                                 OR (:diet_n = 'vegan' AND SOURCE_KEY = 'vegan_society')
                                 OR (:diet_n = 'kosher_halal' AND SOURCE_KEY IN ('ou_kosher', 'yale_halal'))
                                 OR (:diet_n = 'vegetarian' AND SOURCE_KEY = 'vegan_society'))
                          GROUP BY SOURCE_NAME, URL)),
        'notes', ARRAY_CONSTRUCT_COMPACT(
            'Kroger only: Walmart''s catalog carries no diet or nutrition data.',
            'Budget split by USDA Thrifty Food Plan cost shares; the plan''s "miscellaneous" share (oils, coffee, condiments, sweets) is left unallocated for you to spend.',
            'Each item meets the FDA "healthy" claim''s per-serving limits on sodium, added sugar and saturated fat, or is a plain whole food. The claim''s whole-grain test is not applied.',
            IFF(:diet_n = 'kosher_halal', 'Kosher / halal-friendly: kosher-declared items plus plain whole foods; pork, shellfish and alcohol excluded. No raw meat or poultry in the catalog is declared kosher, so this basket has none. Halal shoppers: confirm meat, poultry and cheese yourself — kosher slaughter is not zabiha.', NULL),
            IFF(:diet_n = 'vegan', 'Vegan: declared vegan, plain plant foods, or no animal ingredient found in the ingredient list. Read the label where the data was incomplete.', NULL),
            IFF(:diet_n = 'vegetarian', 'Vegetarian: declared, plain plant food, dairy or eggs, or no meat/fish ingredient found in the ingredient list.', NULL),
            'Diet and nutrition data are manufacturer-supplied and incomplete; every pick shows where its label came from.'),
        'disclaimer', 'General healthy-eating guidance from USDA and FDA sources, not medical or nutrition advice.',
        'narrative', :narrative, 'narrative_model', IFF(:narrative IS NULL, NULL, :model), 'prompt_version', :prompt_version, 'tokens', :tokens,
        'generated_at', CURRENT_TIMESTAMP()
    );
END;
$$;

-- PROD ONLY: the owner app's role calls it; guests go through 05_guest_healthy_week.sql
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_SUGGEST_WEEKLY_BASKET(NUMBER, VARCHAR, VARCHAR, VARCHAR, NUMBER, BOOLEAN) TO ROLE GROCERY_AGENT_USER;
