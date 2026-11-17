-- =============================================================================
-- 02_guest_login.sql — email-verified, passwordless login for guests
-- (plan: ~/.claude/plans/guest-app-enhancements.md, 2026-11-17)
--
-- Before: SP_GUEST_REGISTER upserted by email and resumed sessions, so anyone
-- who typed a registered address took over that guest; addresses were never
-- verified. Now:
--   sign-up  -> GUEST_USER.STATUS = 'pending' -> 6-digit code emailed by the app
--   verify   -> SP_GUEST_VERIFY_CODE: EMAIL_VERIFIED_AT, STATUS = 'active', session starts
--   return   -> "Log in": email -> new code -> SP_GUEST_VERIFY_CODE -> session
-- Codes: stored as SHA2(salt || code), 15-minute TTL, 5 attempts, 3 codes per
-- email per hour, 200 codes per day across all guests (Gmail sends 500/day).
-- Unknown emails get the same "sent" answer so sign-ups cannot be enumerated.
-- The plain code is returned ONLY to the calling app session so it can email it;
-- it is never written to GUEST_INTERACTION.
--
-- Run as ACCOUNTADMIN after 01_guest_access.sql. Sandbox variant:
--   sed -E 's/GROCERY_APP([^_A-Za-z0-9]|$)/GROCERY_DEV_APP\1/g; /^-- PROD ONLY/,$d'
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE SCHEMA GROCERYDBTPROJECT.GROCERY_APP;

------------------------------------------------------------------------------
-- 1. Schema changes
------------------------------------------------------------------------------
-- Hybrid tables error on a repeated ADD COLUMN even with IF NOT EXISTS ("ambiguous column name"), so check first.
EXECUTE IMMEDIATE $$
DECLARE
    cols ARRAY;
BEGIN
    cols := (SELECT ARRAY_AGG(COLUMN_NAME) FROM GROCERYDBTPROJECT.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'GROCERY_APP' AND TABLE_NAME = 'GUEST_USER');
    IF (NOT ARRAY_CONTAINS('EMAIL_VERIFIED_AT'::VARIANT, :cols)) THEN ALTER TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER ADD COLUMN EMAIL_VERIFIED_AT TIMESTAMP_TZ; END IF;
    IF (NOT ARRAY_CONTAINS('LAST_LOGIN_AT'::VARIANT, :cols))     THEN ALTER TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER ADD COLUMN LAST_LOGIN_AT TIMESTAMP_TZ; END IF;
    IF (NOT ARRAY_CONTAINS('REMINDER_COUNT'::VARIANT, :cols))    THEN ALTER TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER ADD COLUMN REMINDER_COUNT NUMBER DEFAULT 0; END IF;
    IF (NOT ARRAY_CONTAINS('LAST_REMINDED_AT'::VARIANT, :cols))  THEN ALTER TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER ADD COLUMN LAST_REMINDED_AT TIMESTAMP_TZ; END IF;
    RETURN 'columns ensured';
END;
$$;

-- Everyone who signed up before verification existed is 'pending' until they enter a code.
UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER
   SET STATUS = 'pending'
 WHERE STATUS = 'active' AND EMAIL_VERIFIED_AT IS NULL;

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE (
    CODE_ID     VARCHAR NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    GUEST_ID    VARCHAR NOT NULL,
    PURPOSE     VARCHAR NOT NULL COMMENT 'verify | login | reminder',
    SALT        VARCHAR NOT NULL,
    CODE_HASH   VARCHAR NOT NULL COMMENT 'SHA2(SALT || code)',
    CREATED_AT  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    EXPIRES_AT  TIMESTAMP_TZ NOT NULL,
    USED_AT     TIMESTAMP_TZ,
    ATTEMPTS    NUMBER DEFAULT 0,
    INDEX IDX_GUEST_LOGIN_CODE_GUEST (GUEST_ID)
);

MERGE INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING t
USING (SELECT * FROM VALUES
    ('code_ttl_minutes',          '15',  'Login / verification code lifetime'),
    ('code_max_attempts',         '5',   'Wrong tries before a code is locked and a new one is required'),
    ('codes_per_email_per_hour',  '3',   'Rate limit per guest'),
    ('codes_per_day_global',      '200', 'Rate limit across all guests (Gmail app-password sending cap is 500/day)'),
    ('reminder_max',              '2',   'Max complete-your-registration emails per pending guest')
) s (KEY, VALUE, DESCRIPTION)
ON t.KEY = s.KEY
WHEN NOT MATCHED THEN INSERT (KEY, VALUE, DESCRIPTION) VALUES (s.KEY, s.VALUE, s.DESCRIPTION);

------------------------------------------------------------------------------
-- 2. Procedures
------------------------------------------------------------------------------
-- Sign-up: new email -> pending guest. Verified email -> refuse (no overwrite, no session).
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_REGISTER(
    EMAIL VARCHAR, FIRST_NAME VARCHAR, LAST_NAME VARCHAR, LINKEDIN_URL VARCHAR, CONSENT BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Guest sign-up (consent required). New email -> pending guest awaiting a verification code. Pending email -> profile refreshed. Verified email -> already_registered (use Log in). Never starts a session.'
EXECUTE AS OWNER
AS
$$
DECLARE
    em VARCHAR := LOWER(TRIM(:EMAIL));
    gid VARCHAR; uname VARCHAR; status VARCHAR; verified TIMESTAMP_TZ;
BEGIN
    IF (NOT COALESCE(:CONSENT, FALSE)) THEN RETURN OBJECT_CONSTRUCT('error', 'consent_required'); END IF;
    IF (em IS NULL OR NOT REGEXP_LIKE(em, '^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]{2,}$')) THEN
        RETURN OBJECT_CONSTRUCT('error', 'invalid_email');
    END IF;
    SELECT GUEST_ID, GUEST_USERNAME, STATUS, EMAIL_VERIFIED_AT INTO :gid, :uname, :status, :verified
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE EMAIL = :em;
    IF (gid IS NULL) THEN
        gid := UUID_STRING();
        uname := 'guest_' || LOWER(RANDSTR(6, RANDOM()));
        INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER (GUEST_ID, GUEST_USERNAME, EMAIL, FIRST_NAME, LAST_NAME, LINKEDIN_URL, CONSENTED_AT, LAST_SEEN_AT, STATUS)
        VALUES (:gid, :uname, :em, TRIM(:FIRST_NAME), TRIM(:LAST_NAME), TRIM(:LINKEDIN_URL), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), 'pending');
        RETURN OBJECT_CONSTRUCT('guest_id', :gid, 'guest_username', :uname, 'new', TRUE, 'status', 'pending');
    END IF;
    IF (status = 'blocked') THEN RETURN OBJECT_CONSTRUCT('error', 'blocked'); END IF;
    IF (verified IS NOT NULL) THEN
        RETURN OBJECT_CONSTRUCT('already_registered', TRUE, 'status', :status);
    END IF;
    -- still pending: the address was never proven, so refreshing the profile harms nobody
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER
       SET FIRST_NAME = TRIM(:FIRST_NAME), LAST_NAME = TRIM(:LAST_NAME), LINKEDIN_URL = TRIM(:LINKEDIN_URL),
           CONSENTED_AT = CURRENT_TIMESTAMP(), LAST_SEEN_AT = CURRENT_TIMESTAMP(), SIGNUP_COUNT = SIGNUP_COUNT + 1
     WHERE GUEST_ID = :gid;
    RETURN OBJECT_CONSTRUCT('guest_id', :gid, 'guest_username', :uname, 'new', FALSE, 'status', 'pending');
END;
$$;

-- Issue a one-time code. Returns the plain code to the app (which emails it) or a reason not to.
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_ISSUE_CODE(EMAIL VARCHAR, PURPOSE VARCHAR DEFAULT 'login')
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Creates a 6-digit one-time code (hashed at rest, 15 min) for the guest with this email and returns it to the calling app to send. Rate-limited per email and per day. Unknown or blocked email -> sent:true with no code (no enumeration). PURPOSE reminder also counts a registration reminder.'
EXECUTE AS OWNER
AS
$$
DECLARE
    em VARCHAR := LOWER(TRIM(:EMAIL));
    gid VARCHAR; fname VARCHAR; status VARCHAR; rem NUMBER;
    ttl NUMBER; per_hour NUMBER; per_day NUMBER; rem_max NUMBER;
    recent NUMBER; today NUMBER;
    code VARCHAR; salt VARCHAR; hash VARCHAR;
BEGIN
    SELECT MAX(IFF(KEY = 'code_ttl_minutes', VALUE::NUMBER, NULL)), MAX(IFF(KEY = 'codes_per_email_per_hour', VALUE::NUMBER, NULL)),
           MAX(IFF(KEY = 'codes_per_day_global', VALUE::NUMBER, NULL)), MAX(IFF(KEY = 'reminder_max', VALUE::NUMBER, NULL))
      INTO :ttl, :per_hour, :per_day, :rem_max
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING;
    SELECT GUEST_ID, FIRST_NAME, STATUS, COALESCE(REMINDER_COUNT, 0) INTO :gid, :fname, :status, :rem
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE EMAIL = :em;
    IF (gid IS NULL OR status = 'blocked') THEN
        RETURN OBJECT_CONSTRUCT('sent', TRUE, 'code', NULL, 'reason', 'unknown_or_blocked');
    END IF;
    IF (:PURPOSE = 'reminder' AND rem >= rem_max) THEN
        RETURN OBJECT_CONSTRUCT('sent', FALSE, 'reason', 'reminder_limit');
    END IF;
    SELECT COUNT(*) INTO :recent FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE
     WHERE GUEST_ID = :gid AND CREATED_AT >= DATEADD(hour, -1, CURRENT_TIMESTAMP());
    IF (recent >= per_hour) THEN
        RETURN OBJECT_CONSTRUCT('sent', FALSE, 'reason', 'rate_limited', 'retry_after_minutes', 60);
    END IF;
    SELECT COUNT(*) INTO :today FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE
     WHERE CREATED_AT >= DATEADD(hour, -24, CURRENT_TIMESTAMP());
    IF (today >= per_day) THEN
        RETURN OBJECT_CONSTRUCT('sent', FALSE, 'reason', 'daily_limit');
    END IF;

    -- Older unused codes stay valid until they expire (a reminder code must still work after
    -- the guest also clicks "Email me a login code"); the per-hour cap bounds how many are live.
    code := LPAD(UNIFORM(0, 999999, RANDOM())::VARCHAR, 6, '0');
    salt := UUID_STRING();
    hash := SHA2(:salt || :code);  -- functions are not allowed inside a VALUES clause
    INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE (GUEST_ID, PURPOSE, SALT, CODE_HASH, EXPIRES_AT)
    SELECT :gid, :PURPOSE, :salt, :hash, DATEADD(minute, :ttl, CURRENT_TIMESTAMP());
    IF (:PURPOSE = 'reminder') THEN
        UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER SET REMINDER_COUNT = COALESCE(REMINDER_COUNT, 0) + 1, LAST_REMINDED_AT = CURRENT_TIMESTAMP()
         WHERE GUEST_ID = :gid;
    END IF;
    RETURN OBJECT_CONSTRUCT('sent', TRUE, 'code', :code, 'first_name', :fname, 'guest_id', :gid, 'status', :status, 'ttl_minutes', :ttl);
END;
$$;

-- Verify a code: marks the email verified, activates the guest, logs the login, starts (or resumes) the week's session.
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_VERIFY_CODE(EMAIL VARCHAR, CODE VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Checks the latest unused code for this email (TTL, attempts). Success -> EMAIL_VERIFIED_AT, STATUS active, LAST_LOGIN_AT, then SP_GUEST_START_SESSION; returns its status plus guest id, username, first name.'
EXECUTE AS OWNER
AS
$$
DECLARE
    em VARCHAR := LOWER(TRIM(:EMAIL));
    code_in VARCHAR := TRIM(:CODE);
    gid VARCHAR; uname VARCHAR; fname VARCHAR; status VARCHAR;
    matched VARCHAR; live NUMBER; unlocked NUMBER; expired_unused NUMBER; latest_cid VARCHAR; latest_attempts NUMBER; max_attempts NUMBER;
    st VARIANT;
BEGIN
    SELECT VALUE::NUMBER INTO :max_attempts FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING WHERE KEY = 'code_max_attempts';
    SELECT GUEST_ID, GUEST_USERNAME, FIRST_NAME, STATUS INTO :gid, :uname, :fname, :status
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE EMAIL = :em;
    IF (gid IS NULL OR status = 'blocked') THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'wrong_code'); END IF;

    -- any unused, unexpired, unlocked code for this guest may match (reminder code or app code)
    SELECT MAX(CODE_ID) INTO :matched
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE
    WHERE GUEST_ID = :gid AND USED_AT IS NULL AND EXPIRES_AT > CURRENT_TIMESTAMP() AND ATTEMPTS < :max_attempts
      AND CODE_HASH = SHA2(SALT || :code_in);
    IF (matched IS NULL) THEN
        -- COALESCE: aggregates over zero rows came back NULL here (seen 2026-11-17)
        SELECT COALESCE(COUNT_IF(EXPIRES_AT > CURRENT_TIMESTAMP()), 0), COALESCE(COUNT_IF(EXPIRES_AT > CURRENT_TIMESTAMP() AND ATTEMPTS < :max_attempts), 0),
               COALESCE(COUNT_IF(EXPIRES_AT <= CURRENT_TIMESTAMP()), 0),
               MAX_BY(CODE_ID, CREATED_AT), COALESCE(MAX_BY(ATTEMPTS, CREATED_AT), 0)
          INTO :live, :unlocked, :expired_unused, :latest_cid, :latest_attempts
        FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE WHERE GUEST_ID = :gid AND USED_AT IS NULL;
        IF (live = 0) THEN
            UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE SET USED_AT = CURRENT_TIMESTAMP() WHERE GUEST_ID = :gid AND USED_AT IS NULL;
            RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', IFF(:expired_unused > 0, 'expired', 'no_code'));
        END IF;
        IF (unlocked = 0) THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'locked'); END IF;
        -- a wrong try counts against every live code, so guessing cannot be spread across them
        UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE SET ATTEMPTS = ATTEMPTS + 1
         WHERE GUEST_ID = :gid AND USED_AT IS NULL AND EXPIRES_AT > CURRENT_TIMESTAMP();
        RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', IFF(:latest_attempts + 1 >= :max_attempts, 'locked', 'wrong_code'),
                                'attempts_left', GREATEST(0, :max_attempts - :latest_attempts - 1));
    END IF;
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE SET USED_AT = CURRENT_TIMESTAMP() WHERE GUEST_ID = :gid AND USED_AT IS NULL;
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER
       SET EMAIL_VERIFIED_AT = COALESCE(EMAIL_VERIFIED_AT, CURRENT_TIMESTAMP()), STATUS = 'active',
           LAST_LOGIN_AT = CURRENT_TIMESTAMP(), LAST_SEEN_AT = CURRENT_TIMESTAMP()
     WHERE GUEST_ID = :gid;
    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_START_SESSION(:gid) INTO :st;
    RETURN OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(:st, 'ok', TRUE, TRUE), 'guest_id', :gid, TRUE), 'guest_username', :uname, TRUE), 'first_name', :fname, TRUE);
END;
$$;

-- Session start now requires a verified (active) guest.
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_START_SESSION(GUEST_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Starts (or resumes) the guest''s one session for the current ET week. Requires STATUS active (email verified); refuses when access is disabled, the weekly cap is reached, or the week''s session is used up.'
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
    IF (g_status = 'pending') THEN RETURN OBJECT_CONSTRUCT('allowed', FALSE, 'reason', 'not_verified'); END IF;
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

-- Pending guests who should get a "finish your registration" email (owner-side script).
CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_PENDING_REMINDERS()
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Pending (unverified) guests with consent, signed up more than 10 minutes ago, fewer than reminder_max reminders, no test addresses. Used by Streamlit/guest_app/send_reminders.py (runs as the owner).'
EXECUTE AS OWNER
AS
$$
DECLARE
    rem_max NUMBER; out VARIANT;
BEGIN
    SELECT VALUE::NUMBER INTO :rem_max FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING WHERE KEY = 'reminder_max';
    out := (SELECT COALESCE(ARRAY_AGG(OBJECT_CONSTRUCT('guest_id', GUEST_ID, 'email', EMAIL, 'first_name', FIRST_NAME, 'created_at', CREATED_AT, 'reminder_count', COALESCE(REMINDER_COUNT, 0)))
                               WITHIN GROUP (ORDER BY CREATED_AT), ARRAY_CONSTRUCT())
            FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER
            WHERE STATUS = 'pending' AND CONSENTED_AT IS NOT NULL
              AND CREATED_AT < DATEADD(minute, -10, CURRENT_TIMESTAMP())
              AND COALESCE(REMINDER_COUNT, 0) < :rem_max
              AND EMAIL NOT LIKE '%@example.com');
    RETURN :out;
END;
$$;

------------------------------------------------------------------------------
-- 3. Grants: the app may issue and verify codes; reminders run as the owner
------------------------------------------------------------------------------
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_REGISTER(VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_ISSUE_CODE(VARCHAR, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_VERIFY_CODE(VARCHAR, VARCHAR) TO ROLE GROCERY_GUEST_ROLE;
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_START_SESSION(VARCHAR) TO ROLE GROCERY_GUEST_ROLE;

-- PROD ONLY ------------------------------------------------------------------
-- Ops: codes issued in the last 24 h (abuse / Gmail cap), as a performance-domain sensor
GRANT SELECT ON TABLE GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE TO ROLE GROCERY_OPS_ROLE;
CREATE OR REPLACE VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_GUEST_LOGIN_CODES AS
WITH c AS (SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK WHERE CHECK_NAME = 'guest_login_codes'),
k AS (
    SELECT COUNT(*) AS codes_24h, COUNT(DISTINCT GUEST_ID) AS guests_24h,
           COALESCE(SUM(IFF(ATTEMPTS >= 5, 1, 0)), 0) AS locked
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_LOGIN_CODE WHERE CREATED_AT >= DATEADD(hour, -24, CURRENT_TIMESTAMP())
),
p AS (SELECT COUNT(*) AS pending FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE STATUS = 'pending' AND EMAIL NOT LIKE '%@example.com')
SELECT 'guest_login_codes' AS CHECK_NAME, 'guests' AS SUBJECT, CURRENT_DATE()::VARCHAR AS PERIOD_KEY, CURRENT_TIMESTAMP() AS PERIOD_TS,
       k.codes_24h AS METRIC_VALUE,
       OBJECT_CONSTRUCT('codes_24h', k.codes_24h, 'guests_24h', k.guests_24h, 'locked_codes', k.locked, 'pending_guests', p.pending, 'unit', 'login/verification codes issued in 24 h') AS OBSERVED,
       OBJECT_CONSTRUCT('warn_at', c.WARN_THRESHOLD, 'crit_at', c.CRIT_THRESHOLD, 'daily_cap', (SELECT VALUE::NUMBER FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_SETTING WHERE KEY = 'codes_per_day_global')) AS EXPECTED,
       CASE WHEN k.codes_24h >= c.CRIT_THRESHOLD THEN 'CRIT' WHEN k.codes_24h >= c.WARN_THRESHOLD THEN 'WARN' ELSE 'OK' END AS SEVERITY,
       k.codes_24h || ' guest login codes in 24 h for ' || k.guests_24h || ' guests (' || k.locked || ' locked); ' || p.pending || ' sign-ups still unverified' AS MESSAGE
FROM k, p, c;
GRANT OWNERSHIP ON VIEW GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_GUEST_LOGIN_CODES TO ROLE GROCERY_OPS_ROLE COPY CURRENT GRANTS;

MERGE INTO GROCERYDBTPROJECT.GROCERY_OPS.OPS_CHECK t
USING (SELECT 'guest_login_codes' AS CHECK_NAME, 'performance' AS DOMAIN, 'V_CHECK_GUEST_LOGIN_CODES' AS VIEW_NAME, 100 AS WARN_THRESHOLD, 180 AS CRIT_THRESHOLD, 24 AS SUPPRESS_HOURS,
              NULL AS SLO_NAME, 'guest_budget' AS RUNBOOK_TOPIC,
              'Guest login / verification codes issued in the last 24 h (count). The app caps at 200/day because Gmail sends 500/day; a spike means abuse or a bot hitting the Log in tab' AS DESCRIPTION) s
ON t.CHECK_NAME = s.CHECK_NAME
WHEN MATCHED THEN UPDATE SET DESCRIPTION = s.DESCRIPTION
WHEN NOT MATCHED THEN INSERT (CHECK_NAME, DOMAIN, VIEW_NAME, WARN_THRESHOLD, CRIT_THRESHOLD, SUPPRESS_HOURS, SLO_NAME, RUNBOOK_TOPIC, DESCRIPTION)
    VALUES (s.CHECK_NAME, s.DOMAIN, s.VIEW_NAME, s.WARN_THRESHOLD, s.CRIT_THRESHOLD, s.SUPPRESS_HOURS, s.SLO_NAME, s.RUNBOOK_TOPIC, s.DESCRIPTION);

SELECT * FROM GROCERYDBTPROJECT.GROCERY_OPS.V_CHECK_GUEST_LOGIN_CODES;
