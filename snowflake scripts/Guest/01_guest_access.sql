-- =============================================================================
-- 01_guest_access.sql — public guest access for the Grocery Value app
-- (Streamlit Community Cloud edition: Streamlit/guest_app/streamlit_app.py)
--
-- People without a Snowflake account sign up (email, first/last name,
-- LinkedIn) and get a guest username and ONE session per week:
--   60 minutes or 0.25 credits, whichever comes first (SP_GUEST_RECORD meters
--   every interaction: agent tokens x observed rate + warehouse seconds).
-- All guests together: 5 credits per week (Mon 00:00 ET). When reached,
-- SP_GUEST_RECORD ends the active sessions and SP_GUEST_START_SESSION refuses
-- new ones until Monday. Three independent stops, in order of trust:
--   1. in-app meter (estimate, immediate)             -> GUEST_SESSION / GUEST_SETTING
--   2. ops sensor + hourly alert (reconciled against ACCOUNT_USAGE token and
--      warehouse credits for SVC_GUEST_APP, <= 3 h lag) -> SP_GUEST_SET_ACCESS(FALSE)
--   3. resource monitor GROCERY_GUEST_MONITOR (WEEKLY, 5 credits, suspend) on
--      the guest warehouse: Snowflake-enforced hard stop for warehouse spend
-- The app shows the visitor which limit was hit and when access returns.
--
-- Run as ACCOUNTADMIN. Sandbox variant (writes GROCERY_DEV_APP, no account objects):
--   sed -E 's/GROCERY_APP([^_A-Za-z0-9]|$)/GROCERY_DEV_APP\1/g; /^-- ACCOUNT-LEVEL/,/^-- END ACCOUNT-LEVEL/d; /^-- PROD ONLY/,$d'
-- Replace <PUBLIC_KEY> with the body of ~/.snowflake/guest_app_rsa_key.pub
-- (no BEGIN/END lines) before running the ACCOUNT-LEVEL section; the private
-- key goes into the Streamlit Cloud secrets, never into the repo.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE GROCERYDBTPROJECT;

-- ACCOUNT-LEVEL -----------------------------------------------------------------
CREATE ROLE IF NOT EXISTS GROCERY_GUEST_ROLE COMMENT = 'Public guest edition of the Grocery Value app: read marts, call the agent, write only through the SP_GUEST_* procedures';
GRANT ROLE GROCERY_GUEST_ROLE TO ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS GROCERY_GUEST_WH
    WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 120
    COMMENT = 'Guest app queries only; capped by GROCERY_GUEST_MONITOR (5 credits per week)';

-- Weekly quota, suspend immediately at 100%. Created on a Monday so the weekly
-- reset lands on Mondays (Snowflake resets at the creation time-of-day, UTC).
CREATE RESOURCE MONITOR IF NOT EXISTS GROCERY_GUEST_MONITOR
    WITH CREDIT_QUOTA = 5 FREQUENCY = WEEKLY START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 80 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND_IMMEDIATE;
ALTER WAREHOUSE GROCERY_GUEST_WH SET RESOURCE_MONITOR = GROCERY_GUEST_MONITOR;

CREATE USER IF NOT EXISTS SVC_GUEST_APP
    TYPE = SERVICE
    DEFAULT_ROLE = GROCERY_GUEST_ROLE
    DEFAULT_WAREHOUSE = GROCERY_GUEST_WH
    DEFAULT_NAMESPACE = GROCERYDBTPROJECT.GROCERY_APP
    COMMENT = 'Service user the public Streamlit Community Cloud guest app connects as (key-pair). Every guest shares this identity; guests are told apart by GUEST_SESSION and the per-session QUERY_TAG grocery:guest:<session_id>.';
ALTER USER SVC_GUEST_APP SET RSA_PUBLIC_KEY = '<PUBLIC_KEY>';
GRANT ROLE GROCERY_GUEST_ROLE TO USER SVC_GUEST_APP;

-- Read what the app and the agent need (mirror of GROCERY_AGENT_USER, minus the Streamlit object)
GRANT USAGE ON DATABASE GROCERYDBTPROJECT TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_MARTS    TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_SEMANTIC TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_APP      TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON SCHEMA GROCERYDBTPROJECT.GROCERY_RAW      TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA GROCERYDBTPROJECT.GROCERY_MARTS TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT ON TABLE GROCERYDBTPROJECT.GROCERY_RAW.DBT_ZIP_CENTROIDS_GA TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT ON VIEW  GROCERYDBTPROJECT.GROCERY_SEMANTIC.DBT_SEARCH_PRODUCT_INDEX TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT ON SEMANTIC VIEW GROCERYDBTPROJECT.GROCERY_SEMANTIC.DBT_SV_GROCERY_PRICING TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON CORTEX SEARCH SERVICE GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON AGENT GROCERYDBTPROJECT.GROCERY_SEMANTIC.GROCERY_VALUE_AGENT TO ROLE GROCERY_GUEST_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_SEMANTIC.SP_COMPARE_BASKET(VARCHAR, VARCHAR, NUMBER) TO ROLE GROCERY_GUEST_ROLE;
-- The agent's tools run as the caller on GROCERY_AGENT_WH (05_agent.sql), so the
-- guest role needs that warehouse and the state-layer procedures the tools call.
-- State written through them belongs to the shared service user (documented in
-- the app: guests can price baskets but not keep lists or watches).
GRANT USAGE ON WAREHOUSE GROCERY_GUEST_WH TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON WAREHOUSE GROCERY_AGENT_WH TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GET_PROFILE() TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_SET_PREFERENCE(VARCHAR, VARCHAR, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_SAVE_LIST(VARCHAR, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GET_LIST(VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_WATCH_PRODUCT(VARCHAR, NUMBER) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_ACKNOWLEDGE_ALERTS() TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_RECORD_FEEDBACK(VARCHAR, VARCHAR, NUMBER, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.SHOPPER_PREFERENCE  TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST       TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.SHOPPING_LIST_ITEM  TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.PRICE_WATCH         TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.PRICE_ALERT         TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.AGENT_FEEDBACK      TO ROLE GROCERY_GUEST_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GROCERYDBTPROJECT.GROCERY_APP.AGENT_RUN_LOG       TO ROLE GROCERY_GUEST_ROLE;
-- END ACCOUNT-LEVEL -------------------------------------------------------------

USE SCHEMA GROCERYDBTPROJECT.GROCERY_APP;

------------------------------------------------------------------------------
-- 1. Guest tables (hybrid: point lookups and writes from the app)
------------------------------------------------------------------------------
CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER (
    GUEST_ID        VARCHAR NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    GUEST_USERNAME  VARCHAR NOT NULL,
    EMAIL           VARCHAR NOT NULL,
    FIRST_NAME      VARCHAR,
    LAST_NAME       VARCHAR,
    LINKEDIN_URL    VARCHAR,
    CONSENTED_AT    TIMESTAMP_TZ,
    CREATED_AT      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_SEEN_AT    TIMESTAMP_TZ,
    SIGNUP_COUNT    NUMBER DEFAULT 1,
    STATUS          VARCHAR DEFAULT 'active' COMMENT 'active | blocked',
    UNIQUE (EMAIL),
    UNIQUE (GUEST_USERNAME)
);

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION (
    SESSION_ID      VARCHAR NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    GUEST_ID        VARCHAR NOT NULL,
    WEEK_START      DATE    NOT NULL COMMENT 'Monday of the ET week the session belongs to',
    STARTED_AT      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    EXPIRES_AT      TIMESTAMP_TZ,
    ENDED_AT        TIMESTAMP_TZ,
    END_REASON      VARCHAR COMMENT 'session_cap | expired | weekly_cap | disabled | closed',
    EST_CREDITS     FLOAT  DEFAULT 0,
    INTERACTIONS    NUMBER DEFAULT 0,
    AGENT_QUESTIONS NUMBER DEFAULT 0,
    AGENT_TOKENS    NUMBER DEFAULT 0,
    WH_SECONDS      FLOAT  DEFAULT 0,
    INDEX IDX_GUEST_SESSION_GUEST (GUEST_ID),
    INDEX IDX_GUEST_SESSION_WEEK  (WEEK_START)
);

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.GUEST_INTERACTION (
    INTERACTION_ID  VARCHAR NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    SESSION_ID      VARCHAR NOT NULL,
    GUEST_ID        VARCHAR NOT NULL,
    TS              TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    KIND            VARCHAR COMMENT 'question | lookup | basket | deals_view | session_end',
    INPUT_TEXT      VARCHAR,
    OUTPUT_TEXT     VARCHAR,
    TOKENS          NUMBER,
    MODEL           VARCHAR,
    WH_SECONDS      FLOAT,
    EST_CREDITS     FLOAT,
    SUCCESS         BOOLEAN,
    INDEX IDX_GUEST_INTERACTION_SESSION (SESSION_ID),
    INDEX IDX_GUEST_INTERACTION_GUEST   (GUEST_ID)
);

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING (
    KEY         VARCHAR NOT NULL PRIMARY KEY,
    VALUE       VARCHAR,
    DESCRIPTION VARCHAR,
    UPDATED_AT  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_BY  VARCHAR DEFAULT CURRENT_USER()
);

MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING t
USING (SELECT * FROM VALUES
    ('guest_access_enabled',           'true',  'Manual kill switch. false = nobody can start a session (SP_GUEST_SET_ACCESS)'),
    ('access_disabled_until',          NULL,    'Set by the reconciliation alert when ACCOUNT_USAGE shows >= weekly cap; sessions refused until this timestamp'),
    ('access_disabled_reason',         NULL,    'Why access_disabled_until was set'),
    ('session_credit_cap',             '0.25',  'Credits per guest session (estimated)'),
    ('weekly_credit_cap',              '5',     'Credits per ET week across all guests (estimated; the resource monitor and the ops alert enforce the same number)'),
    ('session_minutes',                '60',    'Session length'),
    ('rate_credits_per_m_tokens',      '0.57',  'Observed blended rate for GROCERY_VALUE_AGENT (CORTEX_AGENT_USAGE_HISTORY, 30 days to 2026-11-16: 9.13 credits / 16.0M tokens). Re-derive monthly.'),
    ('fallback_credits_per_question',  '0.10',  'Used when the agent stream reports no token usage (observed mean 0.1003 credits per request)'),
    ('wh_credits_per_hour',            '1.0',   'GROCERY_GUEST_WH is X-Small: 1 credit per hour of wall-clock query time'),
    ('per_interaction_overhead_credits','0.0005','Covers warehouse resume minimums and cloud services per interaction')
) s (KEY, VALUE, DESCRIPTION)
ON t.KEY = s.KEY
WHEN NOT MATCHED THEN INSERT (KEY, VALUE, DESCRIPTION) VALUES (s.KEY, s.VALUE, s.DESCRIPTION);

-- Current ET week and its totals (estimate side)
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK AS
WITH w AS (SELECT DATE_TRUNC(week, CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())::DATE) AS WEEK_START)
SELECT w.WEEK_START,
       CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ(DATEADD(day, 7, w.WEEK_START) || ' 00:00:00'))::TIMESTAMP_TZ AS NEXT_WEEK_START_UTC,
       COALESCE(SUM(s.EST_CREDITS), 0)            AS WEEK_EST_CREDITS,
       COUNT(s.SESSION_ID)                         AS WEEK_SESSIONS,
       COUNT_IF(s.ENDED_AT IS NULL)                AS WEEK_OPEN_SESSIONS,
       COALESCE(SUM(s.AGENT_QUESTIONS), 0)         AS WEEK_QUESTIONS,
       (SELECT VALUE::FLOAT FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING WHERE KEY = 'weekly_credit_cap') AS WEEKLY_CAP
FROM w LEFT JOIN GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION s ON s.WEEK_START = w.WEEK_START
GROUP BY w.WEEK_START;

------------------------------------------------------------------------------
-- 2. Procedures (EXECUTE AS OWNER: the guest role gets USAGE on these and nothing on the tables)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_REGISTER(
    EMAIL VARCHAR, FIRST_NAME VARCHAR, LAST_NAME VARCHAR, LINKEDIN_URL VARCHAR, CONSENT BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Guest sign-up: upserts GUEST_USER by email (consent required) and returns the guest id and username.'
EXECUTE AS OWNER
AS
$$
DECLARE
    em        VARCHAR := LOWER(TRIM(:EMAIL));
    gid       VARCHAR;
    uname     VARCHAR;
    is_new    BOOLEAN := FALSE;
    status    VARCHAR;
BEGIN
    IF (NOT COALESCE(:CONSENT, FALSE)) THEN
        RETURN OBJECT_CONSTRUCT('error', 'consent_required');
    END IF;
    IF (em IS NULL OR NOT REGEXP_LIKE(em, '^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]{2,}$')) THEN
        RETURN OBJECT_CONSTRUCT('error', 'invalid_email');
    END IF;
    SELECT GUEST_ID, GUEST_USERNAME, STATUS INTO :gid, :uname, :status
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE EMAIL = :em;
    IF (gid IS NULL) THEN
        gid := UUID_STRING();
        uname := 'guest_' || LOWER(RANDSTR(6, RANDOM()));
        INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER (GUEST_ID, GUEST_USERNAME, EMAIL, FIRST_NAME, LAST_NAME, LINKEDIN_URL, CONSENTED_AT, LAST_SEEN_AT)
        VALUES (:gid, :uname, :em, TRIM(:FIRST_NAME), TRIM(:LAST_NAME), TRIM(:LINKEDIN_URL), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
        is_new := TRUE;
        status := 'active';
    ELSE
        UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER
           SET FIRST_NAME = TRIM(:FIRST_NAME), LAST_NAME = TRIM(:LAST_NAME), LINKEDIN_URL = TRIM(:LINKEDIN_URL),
               CONSENTED_AT = CURRENT_TIMESTAMP(), LAST_SEEN_AT = CURRENT_TIMESTAMP(), SIGNUP_COUNT = SIGNUP_COUNT + 1
         WHERE GUEST_ID = :gid;
    END IF;
    RETURN OBJECT_CONSTRUCT('guest_id', :gid, 'guest_username', :uname, 'new', :is_new, 'status', :status);
END;
$$;

-- Status object shared by start/record/status
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_STATUS(SESSION_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Current state of one guest session: allowed, reason, credits used, minutes left, weekly total; also applies time expiry.'
EXECUTE AS OWNER
AS
$$
DECLARE
    s_guest VARCHAR; s_started TIMESTAMP_TZ; s_expires TIMESTAMP_TZ; s_ended TIMESTAMP_TZ; s_reason VARCHAR;
    s_credits FLOAT; s_inter NUMBER; s_q NUMBER;
    cap FLOAT; wcap FLOAT; week_credits FLOAT; next_week TIMESTAMP_TZ;
    enabled BOOLEAN; disabled_until TIMESTAMP_TZ;
    allowed BOOLEAN := TRUE; reason VARCHAR := NULL;
BEGIN
    SELECT GUEST_ID, STARTED_AT, EXPIRES_AT, ENDED_AT, END_REASON, EST_CREDITS, INTERACTIONS, AGENT_QUESTIONS
      INTO :s_guest, :s_started, :s_expires, :s_ended, :s_reason, :s_credits, :s_inter, :s_q
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION WHERE SESSION_ID = :SESSION_ID;
    IF (s_guest IS NULL) THEN RETURN OBJECT_CONSTRUCT('allowed', FALSE, 'reason', 'no_session'); END IF;

    SELECT MAX(IFF(KEY = 'session_credit_cap', VALUE::FLOAT, NULL)), MAX(IFF(KEY = 'weekly_credit_cap', VALUE::FLOAT, NULL)),
           MAX(IFF(KEY = 'guest_access_enabled', VALUE = 'true', NULL)), MAX(IFF(KEY = 'access_disabled_until', TRY_TO_TIMESTAMP_TZ(VALUE), NULL))
      INTO :cap, :wcap, :enabled, :disabled_until
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING;
    SELECT WEEK_EST_CREDITS, NEXT_WEEK_START_UTC INTO :week_credits, :next_week FROM GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK;

    -- time expiry is applied here so a stale session cannot keep spending
    IF (s_ended IS NULL AND CURRENT_TIMESTAMP() >= s_expires) THEN
        UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION SET ENDED_AT = CURRENT_TIMESTAMP(), END_REASON = 'expired' WHERE SESSION_ID = :SESSION_ID;
        s_ended := CURRENT_TIMESTAMP(); s_reason := 'expired';
    END IF;
    IF (s_ended IS NOT NULL) THEN
        allowed := FALSE; reason := s_reason;
    ELSEIF (NOT COALESCE(enabled, TRUE) OR (disabled_until IS NOT NULL AND disabled_until > CURRENT_TIMESTAMP())) THEN
        allowed := FALSE; reason := 'disabled';
    ELSEIF (week_credits >= wcap) THEN
        allowed := FALSE; reason := 'weekly_cap';
    ELSEIF (s_credits >= cap) THEN
        allowed := FALSE; reason := 'session_cap';
    END IF;
    RETURN OBJECT_CONSTRUCT(
        'allowed', :allowed, 'reason', :reason, 'session_id', :SESSION_ID, 'guest_id', :s_guest,
        'started_at', :s_started, 'expires_at', :s_expires, 'ended_at', :s_ended,
        'minutes_left', GREATEST(0, TIMESTAMPDIFF(minute, CURRENT_TIMESTAMP(), :s_expires)),
        'session_credits', ROUND(:s_credits, 4), 'session_credit_cap', :cap,
        'interactions', :s_inter, 'agent_questions', :s_q,
        'weekly_credits', ROUND(:week_credits, 3), 'weekly_credit_cap', :wcap, 'access_returns_at', :next_week,
        'rate_credits_per_m_tokens', (SELECT VALUE::FLOAT FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING WHERE KEY = 'rate_credits_per_m_tokens'),
        'fallback_credits_per_question', (SELECT VALUE::FLOAT FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING WHERE KEY = 'fallback_credits_per_question'));
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_START_SESSION(GUEST_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Starts (or resumes) the guest''s one session for the current ET week, unless access is disabled, the weekly cap is reached, or the guest already used this week''s session.'
EXECUTE AS OWNER
AS
$$
DECLARE
    g_status VARCHAR; wk DATE; sid VARCHAR; s_ended TIMESTAMP_TZ; s_reason VARCHAR; s_credits FLOAT;
    cap FLOAT; wcap FLOAT; mins NUMBER; week_credits FLOAT; next_week TIMESTAMP_TZ;
    enabled BOOLEAN; disabled_until TIMESTAMP_TZ;
    st VARIANT;
BEGIN
    SELECT STATUS INTO :g_status FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE GUEST_ID = :GUEST_ID;
    IF (g_status IS NULL) THEN RETURN OBJECT_CONSTRUCT('allowed', FALSE, 'reason', 'unknown_guest'); END IF;
    IF (g_status <> 'active') THEN RETURN OBJECT_CONSTRUCT('allowed', FALSE, 'reason', 'blocked'); END IF;

    SELECT MAX(IFF(KEY = 'session_credit_cap', VALUE::FLOAT, NULL)), MAX(IFF(KEY = 'weekly_credit_cap', VALUE::FLOAT, NULL)),
           MAX(IFF(KEY = 'session_minutes', VALUE::NUMBER, NULL)),
           MAX(IFF(KEY = 'guest_access_enabled', VALUE = 'true', NULL)), MAX(IFF(KEY = 'access_disabled_until', TRY_TO_TIMESTAMP_TZ(VALUE), NULL))
      INTO :cap, :wcap, :mins, :enabled, :disabled_until
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING;
    SELECT WEEK_START, WEEK_EST_CREDITS, NEXT_WEEK_START_UTC INTO :wk, :week_credits, :next_week FROM GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK;

    IF (NOT COALESCE(enabled, TRUE) OR (disabled_until IS NOT NULL AND disabled_until > CURRENT_TIMESTAMP())) THEN
        RETURN OBJECT_CONSTRUCT('allowed', FALSE, 'reason', 'disabled', 'weekly_credits', ROUND(:week_credits, 3), 'weekly_credit_cap', :wcap, 'access_returns_at', COALESCE(:disabled_until, :next_week));
    END IF;
    IF (week_credits >= wcap) THEN
        RETURN OBJECT_CONSTRUCT('allowed', FALSE, 'reason', 'weekly_cap', 'weekly_credits', ROUND(:week_credits, 3), 'weekly_credit_cap', :wcap, 'access_returns_at', :next_week);
    END IF;

    -- one session per guest per week: resume if still open, refuse if used up
    SELECT SESSION_ID, ENDED_AT, END_REASON, EST_CREDITS INTO :sid, :s_ended, :s_reason, :s_credits
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION WHERE GUEST_ID = :GUEST_ID AND WEEK_START = :wk
    ORDER BY STARTED_AT DESC LIMIT 1;
    IF (sid IS NOT NULL) THEN
        IF (s_ended IS NOT NULL OR s_credits >= cap) THEN
            RETURN OBJECT_CONSTRUCT('allowed', FALSE, 'reason', 'already_used', 'session_id', :sid, 'weekly_credits', ROUND(:week_credits, 3), 'weekly_credit_cap', :wcap, 'access_returns_at', :next_week);
        END IF;
        CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_STATUS(:sid) INTO :st;
        RETURN OBJECT_INSERT(:st, 'resumed', TRUE);
    END IF;

    sid := UUID_STRING();
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION (SESSION_ID, GUEST_ID, WEEK_START, STARTED_AT, EXPIRES_AT)
    VALUES (:sid, :GUEST_ID, :wk, CURRENT_TIMESTAMP(), DATEADD(minute, :mins, CURRENT_TIMESTAMP()));
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER SET LAST_SEEN_AT = CURRENT_TIMESTAMP() WHERE GUEST_ID = :GUEST_ID;
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_STATUS(:sid) INTO :st;
    RETURN OBJECT_INSERT(:st, 'resumed', FALSE);
END;
$$;

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_RECORD(
    SESSION_ID VARCHAR, KIND VARCHAR, INPUT_TEXT VARCHAR, OUTPUT_TEXT VARCHAR,
    TOKENS NUMBER, MODEL VARCHAR, WH_SECONDS FLOAT, SUCCESS BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Logs one guest interaction, estimates its credits (tokens x rate, or the per-question fallback; plus warehouse seconds and overhead), updates the session, ends it at the session cap, and returns the status object.'
EXECUTE AS OWNER
AS
$$
DECLARE
    gid VARCHAR; s_ended TIMESTAMP_TZ;
    rate FLOAT; fallback FLOAT; wh_rate FLOAT; overhead FLOAT; cap FLOAT; wcap FLOAT;
    est FLOAT; week_credits FLOAT; st VARIANT;
BEGIN
    SELECT GUEST_ID, ENDED_AT INTO :gid, :s_ended FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION WHERE SESSION_ID = :SESSION_ID;
    IF (gid IS NULL) THEN RETURN OBJECT_CONSTRUCT('allowed', FALSE, 'reason', 'no_session'); END IF;

    SELECT MAX(IFF(KEY = 'rate_credits_per_m_tokens', VALUE::FLOAT, NULL)), MAX(IFF(KEY = 'fallback_credits_per_question', VALUE::FLOAT, NULL)),
           MAX(IFF(KEY = 'wh_credits_per_hour', VALUE::FLOAT, NULL)), MAX(IFF(KEY = 'per_interaction_overhead_credits', VALUE::FLOAT, NULL)),
           MAX(IFF(KEY = 'session_credit_cap', VALUE::FLOAT, NULL)), MAX(IFF(KEY = 'weekly_credit_cap', VALUE::FLOAT, NULL))
      INTO :rate, :fallback, :wh_rate, :overhead, :cap, :wcap
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING;

    est := COALESCE(:TOKENS * :rate / 1e6, IFF(:KIND = 'question', :fallback, 0))
         + COALESCE(:WH_SECONDS, 0) / 3600.0 * :wh_rate
         + IFF(:KIND = 'session_end', 0, :overhead);

    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_INTERACTION (SESSION_ID, GUEST_ID, KIND, INPUT_TEXT, OUTPUT_TEXT, TOKENS, MODEL, WH_SECONDS, EST_CREDITS, SUCCESS)
    VALUES (:SESSION_ID, :gid, :KIND, LEFT(:INPUT_TEXT, 4000), LEFT(:OUTPUT_TEXT, 4000), :TOKENS, :MODEL, :WH_SECONDS, :est, COALESCE(:SUCCESS, TRUE));

    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION
       SET EST_CREDITS = EST_CREDITS + :est,
           INTERACTIONS = INTERACTIONS + 1,
           AGENT_QUESTIONS = AGENT_QUESTIONS + IFF(:KIND = 'question', 1, 0),
           AGENT_TOKENS = AGENT_TOKENS + COALESCE(:TOKENS, 0),
           WH_SECONDS = WH_SECONDS + COALESCE(:WH_SECONDS, 0)
     WHERE SESSION_ID = :SESSION_ID;
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER SET LAST_SEEN_AT = CURRENT_TIMESTAMP() WHERE GUEST_ID = :gid;

    -- end the session at its cap; end every open session when the week's cap is reached
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION SET ENDED_AT = CURRENT_TIMESTAMP(), END_REASON = 'session_cap'
     WHERE SESSION_ID = :SESSION_ID AND ENDED_AT IS NULL AND EST_CREDITS >= :cap;
    SELECT WEEK_EST_CREDITS INTO :week_credits FROM GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK;
    IF (week_credits >= wcap) THEN
        UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION SET ENDED_AT = CURRENT_TIMESTAMP(), END_REASON = 'weekly_cap'
         WHERE ENDED_AT IS NULL AND WEEK_START = (SELECT WEEK_START FROM GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK);
    END IF;
    IF (:KIND = 'session_end') THEN
        UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION SET ENDED_AT = COALESCE(ENDED_AT, CURRENT_TIMESTAMP()), END_REASON = COALESCE(END_REASON, LEFT(:INPUT_TEXT, 40))
         WHERE SESSION_ID = :SESSION_ID;
    END IF;

    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_STATUS(:SESSION_ID) INTO :st;
    RETURN OBJECT_INSERT(:st, 'interaction_credits', ROUND(:est, 5));
END;
$$;

-- Owner / ops kill switch. FALSE disables until next Monday 00:00 ET (or a given timestamp); TRUE re-enables now.
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_SET_ACCESS(ENABLED BOOLEAN, REASON VARCHAR, UNTIL TIMESTAMP_TZ DEFAULT NULL)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Guest access switch. ENABLED=FALSE refuses new sessions and ends open ones until UNTIL (default: next Monday 00:00 ET); ENABLED=TRUE clears the block.'
EXECUTE AS OWNER
AS
$$
DECLARE
    until_ts TIMESTAMP_TZ;
BEGIN
    IF (:ENABLED) THEN
        UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING SET VALUE = IFF(KEY = 'guest_access_enabled', 'true', NULL), UPDATED_AT = CURRENT_TIMESTAMP(), UPDATED_BY = CURRENT_USER()
         WHERE KEY IN ('guest_access_enabled', 'access_disabled_until', 'access_disabled_reason');
        RETURN OBJECT_CONSTRUCT('enabled', TRUE, 'reason', :REASON);
    END IF;
    until_ts := COALESCE(:UNTIL, (SELECT NEXT_WEEK_START_UTC FROM GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK));
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING SET VALUE = :until_ts::VARCHAR, UPDATED_AT = CURRENT_TIMESTAMP(), UPDATED_BY = CURRENT_USER() WHERE KEY = 'access_disabled_until';
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING SET VALUE = LEFT(:REASON, 500), UPDATED_AT = CURRENT_TIMESTAMP(), UPDATED_BY = CURRENT_USER() WHERE KEY = 'access_disabled_reason';
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION SET ENDED_AT = CURRENT_TIMESTAMP(), END_REASON = 'disabled' WHERE ENDED_AT IS NULL;
    RETURN OBJECT_CONSTRUCT('enabled', FALSE, 'until', :until_ts, 'reason', :REASON);
END;
$$;

------------------------------------------------------------------------------
-- 3. Grants for the guest role: the four procedures only
------------------------------------------------------------------------------
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_REGISTER(VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_START_SESSION(VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_RECORD(VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMBER, VARCHAR, FLOAT, BOOLEAN) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_STATUS(VARCHAR) TO ROLE GROCERY_GUEST_ROLE;

-- Functional test (sandbox): scratchpad guest_test.sql exercised register/start/record/caps/kill switch on 2026-11-16.

-- PROD ONLY ------------------------------------------------------------------
------------------------------------------------------------------------------
-- 4. Ops layer: reconciliation sensor, hourly alert, registry, runbook
------------------------------------------------------------------------------
GRANT SELECT ON TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER        TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SESSION     TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_INTERACTION TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING     TO ROLE GROCERY_OPS_ROLE;
GRANT SELECT ON VIEW  GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK      TO ROLE GROCERY_OPS_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_SET_ACCESS(BOOLEAN, VARCHAR, TIMESTAMP_TZ) TO ROLE GROCERY_OPS_ROLE;

-- Reconciled weekly guest spend: what Snowflake actually billed the service user
-- (agent tokens + attributed warehouse compute, <= 3 h lag) next to the app's estimate.
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_GUEST_SPEND AS
WITH w AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_APP.V_GUEST_WEEK),
c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'guest_weekly_spend'),
tok AS (
    SELECT COALESCE(SUM(TOKEN_CREDITS), 0) AS credits, COUNT(*) AS requests
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY a, w
    WHERE a.USER_NAME = 'SVC_GUEST_APP' AND a.START_TIME >= CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ(w.WEEK_START || ' 00:00:00'))
),
wh AS (
    SELECT COALESCE(SUM(CREDITS_ATTRIBUTED_COMPUTE), 0) AS credits, COUNT(*) AS queries
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qa, w
    WHERE qa.USER_NAME = 'SVC_GUEST_APP' AND qa.START_TIME >= CONVERT_TIMEZONE('America/New_York', 'UTC', TO_TIMESTAMP_NTZ(w.WEEK_START || ' 00:00:00'))
)
SELECT 'guest_weekly_spend' AS CHECK_NAME, 'guests' AS SUBJECT, w.WEEK_START::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       ROUND(tok.credits + wh.credits, 3) AS METRIC_VALUE,
       OBJECT_CONSTRUCT('reconciled_credits', ROUND(tok.credits + wh.credits, 3), 'agent_token_credits', ROUND(tok.credits, 3), 'warehouse_credits', ROUND(wh.credits, 3),
                        'agent_requests', tok.requests, 'queries', wh.queries,
                        'app_estimate_credits', ROUND(w.WEEK_EST_CREDITS, 3), 'sessions', w.WEEK_SESSIONS, 'open_sessions', w.WEEK_OPEN_SESSIONS,
                        'unit', 'credits this ET week; ACCOUNT_USAGE lags up to 3 h') AS OBSERVED,
       OBJECT_CONSTRUCT('weekly_cap_credits', w.WEEKLY_CAP, 'warn_at', c.WARN_THRESHOLD, 'crit_at', c.CRIT_THRESHOLD) AS EXPECTED,
       CASE WHEN tok.credits + wh.credits >= c.CRIT_THRESHOLD THEN 'CRIT'
            WHEN tok.credits + wh.credits >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       'Guest spend this week: ' || ROUND(tok.credits + wh.credits, 2) || ' credits billed (' || ROUND(tok.credits, 2) || ' agent tokens + ' || ROUND(wh.credits, 2)
       || ' warehouse) vs ' || ROUND(w.WEEK_EST_CREDITS, 2) || ' estimated by the app, cap ' || w.WEEKLY_CAP || '; ' || w.WEEK_SESSIONS || ' sessions' AS MESSAGE
FROM w, c, tok, wh;

MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK t
USING (SELECT 'guest_weekly_spend' AS CHECK_NAME, 'cost' AS DOMAIN, 'V_CHECK_GUEST_SPEND' AS VIEW_NAME, 4 AS WARN_THRESHOLD, 5 AS CRIT_THRESHOLD, 24 AS SUPPRESS_HOURS,
              NULL AS SLO_NAME, 'guest_budget' AS RUNBOOK_TOPIC,
              'Credits billed to SVC_GUEST_APP this ET week (agent tokens + attributed warehouse compute) against the 5-credit guest cap; the app estimate is in OBSERVED for comparison' AS DESCRIPTION) s
ON t.CHECK_NAME = s.CHECK_NAME
WHEN MATCHED THEN UPDATE SET DESCRIPTION = s.DESCRIPTION
WHEN NOT MATCHED THEN INSERT (CHECK_NAME, DOMAIN, VIEW_NAME, WARN_THRESHOLD, CRIT_THRESHOLD, SUPPRESS_HOURS, SLO_NAME, RUNBOOK_TOPIC, DESCRIPTION)
    VALUES (s.CHECK_NAME, s.DOMAIN, s.VIEW_NAME, s.WARN_THRESHOLD, s.CRIT_THRESHOLD, s.SUPPRESS_HOURS, s.SLO_NAME, s.RUNBOOK_TOPIC, s.DESCRIPTION);

MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_RUNBOOK t
USING (SELECT 'guest_budget' AS TOPIC,
              'V_CHECK_GUEST_SPEND WARN/CRIT, or guests report "weekly limit reached" early, or the app estimate and the billed credits diverge by more than 30%' AS SYMPTOM,
              'Public guests share one 5-credit weekly budget. The app meters an estimate (tokens x rate + warehouse seconds); ACCOUNT_USAGE is the truth with up to 3 h lag. Divergence usually means the token rate in GUEST_SETTING is stale or a question looped through many tool calls.' AS KNOWN_CAUSE,
              'Nothing to fix for a plain cap: access returns Monday 00:00 ET automatically (ALERT_GUEST_BUDGET sets access_disabled_until). To close early: CALL GROCERY_APP.SP_GUEST_SET_ACCESS(FALSE, ''why''). To reopen: SP_GUEST_SET_ACCESS(TRUE, ''why''). Re-derive rate_credits_per_m_tokens monthly from CORTEX_AGENT_USAGE_HISTORY. If GROCERY_GUEST_WH is suspended by its monitor, leave it until Monday.' AS FIX,
              'human' AS ACTION_NAME, 'Snowflake Scripts/Guest/01_guest_access.sql, Streamlit/guest_app/README.md' AS SOURCE_DOC) s
ON t.TOPIC = s.TOPIC
WHEN MATCHED THEN UPDATE SET SYMPTOM = s.SYMPTOM, KNOWN_CAUSE = s.KNOWN_CAUSE, FIX = s.FIX, SOURCE_DOC = s.SOURCE_DOC
WHEN NOT MATCHED THEN INSERT (TOPIC, SYMPTOM, KNOWN_CAUSE, FIX, ACTION_NAME, SOURCE_DOC) VALUES (s.TOPIC, s.SYMPTOM, s.KNOWN_CAUSE, s.FIX, s.ACTION_NAME, s.SOURCE_DOC);

MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.AGENT_REGISTRY t
USING (SELECT * FROM VALUES
    ('guest_app',          'app',      'product', 'streamlit_cloud', 'Streamlit Community Cloud: Streamlit/guest_app/streamlit_app.py as SVC_GUEST_APP / GROCERY_GUEST_ROLE on GROCERY_GUEST_WH', 'on demand', NULL, 'value_agent', 'Public guest edition: sign-up, one 60-min / 0.25-credit session per guest per week, 5 credits per week for all guests'),
    ('guest_budget_guard', 'alert',    'cost',    'snowflake',       'GROCERY_OPS.ALERT_GUEST_BUDGET (hourly) + GROCERY_GUEST_MONITOR (weekly 5 credits, suspend)', 'hourly', 2, NULL, 'Reconciles guest spend against ACCOUNT_USAGE and closes guest access at the weekly cap')
) s (AGENT_NAME, KIND, DOMAIN, PLATFORM, RUNTIME_OBJECT, SCHEDULE_TEXT, EXPECTED_INTERVAL_HOURS, MODEL_TASK, DESCRIPTION)
ON t.AGENT_NAME = s.AGENT_NAME
WHEN MATCHED THEN UPDATE SET RUNTIME_OBJECT = s.RUNTIME_OBJECT, DESCRIPTION = s.DESCRIPTION, UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (AGENT_NAME, KIND, DOMAIN, PLATFORM, RUNTIME_OBJECT, SCHEDULE_TEXT, EXPECTED_INTERVAL_HOURS, MODEL_TASK, DESCRIPTION)
    VALUES (s.AGENT_NAME, s.KIND, s.DOMAIN, s.PLATFORM, s.RUNTIME_OBJECT, s.SCHEDULE_TEXT, s.EXPECTED_INTERVAL_HOURS, s.MODEL_TASK, s.DESCRIPTION);

-- The alert's action: close guest access until Monday and email the owner once.
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_GUEST_BUDGET_TRIP()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Called by ALERT_GUEST_BUDGET when billed guest spend reaches the weekly cap: SP_GUEST_SET_ACCESS(FALSE) + one OPS_EVENT/email via SP_RAISE_ALERT.'
EXECUTE AS OWNER
AS
$$
DECLARE
    msg VARCHAR; r VARIANT; a VARCHAR;
BEGIN
    SELECT MESSAGE INTO :msg FROM GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_GUEST_SPEND;
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_SET_ACCESS(FALSE, 'ALERT_GUEST_BUDGET: billed guest spend reached the weekly cap') INTO :r;
    CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_RAISE_ALERT('guest_weekly_spend', 'cost', 'guests', :msg || '. Guest access closed until Monday 00:00 ET.') INTO :a;
    RETURN 'closed guest access; ' || COALESCE(:a, '');
END;
$$;

-- Hourly, serverless like the other alerts: billed guest spend at/over the cap and access not yet closed
CREATE OR REPLACE ALERT GROCERYDBTPROJECT.GROCERY_OPS.ALERT_GUEST_BUDGET
    SCHEDULE = '60 minute'
    IF (EXISTS (SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_GUEST_SPEND WHERE SEVERITY = 'CRIT'
                  AND NOT EXISTS (SELECT 1 FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING
                                  WHERE KEY = 'access_disabled_until' AND TRY_TO_TIMESTAMP_TZ(VALUE) > CURRENT_TIMESTAMP())))
    THEN CALL GROCERYDBTPROJECT.GROCERY_OPS.SP_GUEST_BUDGET_TRIP();

GRANT OWNERSHIP ON VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_GUEST_SPEND TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON PROCEDURE GROCERYDBTPROJECT.GROCERY_OPS.SP_GUEST_BUDGET_TRIP() TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALERT GROCERYDBTPROJECT.GROCERY_OPS.ALERT_GUEST_BUDGET TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;
ALTER ALERT GROCERYDBTPROJECT.GROCERY_OPS.ALERT_GUEST_BUDGET RESUME;

SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_GUEST_SPEND;
