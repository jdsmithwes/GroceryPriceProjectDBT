-- =============================================================================
-- 05_guest_healthy_week.sql — "Plan my week" for signed-in guests
--
-- Wraps SP_SUGGEST_WEEKLY_BASKET (Snowflake Scripts/Agent/08_healthy_week.sql)
-- with the guest session check (SP_GUEST_BASKET_SHOPPER, 03_guest_basket_watch.sql)
-- and limits from GUEST_SETTING. The guest saves the result with
-- SP_GUEST_TRACK_BASKET, so the same 3-basket / 15-item caps apply, and the
-- app meters each call as kind 'suggestion' with the narrative's tokens.
--
--   healthy_week_enabled      kill switch (false refuses new suggestions)
--   healthy_week_max_budget   budget ceiling for guests (USD)
--
-- Run as ACCOUNTADMIN after 08_healthy_week.sql and 03_guest_basket_watch.sql.
-- Sandbox variant:
--   sed -E 's/GROCERY_APP([^_A-Za-z0-9]|$)/GROCERY_DEV_APP\1/g; /^-- PROD ONLY/,$d'
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE SCHEMA GROCERYDBTPROJECT.GROCERY_APP;

MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING t
USING (SELECT * FROM VALUES
    ('healthy_week_enabled',    'true', 'Guests may ask for a healthy-week basket suggestion'),
    ('healthy_week_max_budget', '300',  'Largest weekly budget a guest may plan (USD)')
) s (KEY, VALUE, DESCRIPTION) ON t.KEY = s.KEY
WHEN NOT MATCHED THEN INSERT (KEY, VALUE, DESCRIPTION) VALUES (s.KEY, s.VALUE, s.DESCRIPTION);

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_SUGGEST_WEEKLY_BASKET(
    SESSION_ID VARCHAR, BUDGET NUMBER, DIET VARCHAR, ZIP_CODE VARCHAR)
RETURNS VARIANT LANGUAGE SQL
COMMENT = 'Guest: propose a week of healthy groceries for a budget, a diet (none | vegetarian | vegan | kosher_halal) and a Georgia ZIP (SP_SUGGEST_WEEKLY_BASKET with guest limits). Save it with SP_GUEST_TRACK_BASKET.'
EXECUTE AS OWNER
AS
$$
DECLARE
    who VARIANT; enabled BOOLEAN; max_budget NUMBER; max_items NUMBER; r VARIANT;
BEGIN
    SELECT MAX(IFF(KEY = 'healthy_week_enabled', VALUE = 'true', NULL)),
           MAX(IFF(KEY = 'healthy_week_max_budget', VALUE::NUMBER, NULL)),
           MAX(IFF(KEY = 'basket_watch_max_items', VALUE::NUMBER, NULL))
      INTO :enabled, :max_budget, :max_items
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING;
    IF (NOT COALESCE(enabled, TRUE)) THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'healthy_week_disabled'); END IF;
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_BASKET_SHOPPER(:SESSION_ID) INTO :who;
    IF (NOT who:ok::BOOLEAN) THEN RETURN who; END IF;
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_SUGGEST_WEEKLY_BASKET(
             LEAST(COALESCE(:max_budget, 300), GREATEST(20, COALESCE(:BUDGET, 75))), :DIET, :ZIP_CODE, 'adult', COALESCE(:max_items, 15), TRUE) INTO :r;
    RETURN r;
END;
$$;

-- PROD ONLY ------------------------------------------------------------------
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_SUGGEST_WEEKLY_BASKET(VARCHAR, NUMBER, VARCHAR, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
