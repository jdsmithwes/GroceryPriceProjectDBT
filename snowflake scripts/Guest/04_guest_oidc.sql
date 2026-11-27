-- =============================================================================
-- 04_guest_oidc.sql — Sign in with LinkedIn (OpenID Connect) for guests
-- (plan: ~/.claude/plans/guest-linkedin-signin.md, 2026-11-27)
--
-- The guest app signs people in with Streamlit's st.login("linkedin"): Authlib
-- validates LinkedIn's ID token, and the app passes the verified claims (sub,
-- email, email_verified, given/family name) to SP_GUEST_OIDC_LOGIN. Only the
-- app's key-pair service user can call it, the same trust model as the
-- emailed-code procedures in 02_guest_login.sql, which stay as the fallback.
--
--   known (PROVIDER, SUBJECT)            -> that guest
--   verified email of an existing guest  -> link the identity to that guest
--                                           (a pending guest becomes active:
--                                           LinkedIn proved the address)
--   new person, no consent yet           -> need_consent (app shows one screen)
--   new person with consent              -> new active guest + identity
--   unverified LinkedIn email            -> refused; use the email code instead
-- Then SP_GUEST_START_SESSION: the same weekly session, caps and meter.
--
-- LinkedIn does not share a profile URL over OIDC, so LINKEDIN_URL is optional
-- here (typed on the consent screen). The photo claim is not stored.
--
-- Run as ACCOUNTADMIN after 02_guest_login.sql. Sandbox variant:
--   sed -E 's/GROCERY_APP([^_A-Za-z0-9]|$)/GROCERY_DEV_APP\1/g; /^-- PROD ONLY/,$d'
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE SCHEMA GROCERYDBTPROJECT.GROCERY_APP;

CREATE HYBRID TABLE IF NOT EXISTS GROCERYDBTPROJECT.GROCERY_APP.GUEST_IDENTITY (
    PROVIDER       VARCHAR NOT NULL COMMENT 'linkedin',
    SUBJECT        VARCHAR NOT NULL COMMENT 'OIDC sub claim (LinkedIn: pairwise, stable per app)',
    GUEST_ID       VARCHAR NOT NULL,
    EMAIL_AT_LINK  VARCHAR COMMENT 'Email the provider reported when the identity was linked',
    LINKED_AT      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_LOGIN_AT  TIMESTAMP_TZ,
    PRIMARY KEY (PROVIDER, SUBJECT),
    INDEX IDX_GUEST_IDENTITY_GUEST (GUEST_ID)
) COMMENT = 'External sign-in identities (Sign in with LinkedIn) linked to guests.';

CREATE OR REPLACE PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_OIDC_LOGIN(
    PROVIDER VARCHAR, SUBJECT VARCHAR, EMAIL VARCHAR, EMAIL_VERIFIED BOOLEAN,
    FIRST_NAME VARCHAR, LAST_NAME VARCHAR, LINKEDIN_URL VARCHAR, CONSENT BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Sign in with an external identity (claims already validated by the app). Finds or links the guest, or creates one when CONSENT; then starts or resumes the week''s session. Returns the SP_GUEST_VERIFY_CODE shape, or ok:false with need_consent / email_unverified / blocked.'
EXECUTE AS OWNER
AS
$$
DECLARE
    prov VARCHAR := LOWER(TRIM(:PROVIDER));
    sub VARCHAR := TRIM(:SUBJECT);
    em VARCHAR := LOWER(TRIM(:EMAIL));
    gid VARCHAR; uname VARCHAR; fname VARCHAR; status VARCHAR;
    st VARIANT;
BEGIN
    IF (prov IS NULL OR sub IS NULL OR sub = '') THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'bad_identity'); END IF;

    -- 1. a known identity
    SELECT MAX(GUEST_ID) INTO :gid FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_IDENTITY WHERE PROVIDER = :prov AND SUBJECT = :sub;

    IF (gid IS NULL) THEN
        IF (NOT COALESCE(:EMAIL_VERIFIED, FALSE) OR em IS NULL OR em = '') THEN
            RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'email_unverified');
        END IF;
        -- 2. link to an existing guest with this (provider-verified) email
        SELECT MAX(GUEST_ID) INTO :gid FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE EMAIL = :em;
        IF (gid IS NULL) THEN
            -- 3. a new person: consent first
            IF (NOT COALESCE(:CONSENT, FALSE)) THEN
                RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'need_consent', 'email', :em,
                                        'first_name', TRIM(:FIRST_NAME), 'last_name', TRIM(:LAST_NAME));
            END IF;
            -- 4. create the guest, already verified by the provider
            gid := UUID_STRING();
            uname := 'guest_' || LOWER(RANDSTR(6, RANDOM()));
            INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER
                (GUEST_ID, GUEST_USERNAME, EMAIL, FIRST_NAME, LAST_NAME, LINKEDIN_URL, CONSENTED_AT, LAST_SEEN_AT, STATUS, EMAIL_VERIFIED_AT)
            SELECT :gid, :uname, :em, TRIM(:FIRST_NAME), TRIM(:LAST_NAME), NULLIF(TRIM(:LINKEDIN_URL), ''),
                   CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), 'active', CURRENT_TIMESTAMP();
        END IF;
        INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.GUEST_IDENTITY (PROVIDER, SUBJECT, GUEST_ID, EMAIL_AT_LINK)
        SELECT :prov, :sub, :gid, :em;
    END IF;

    SELECT GUEST_USERNAME, FIRST_NAME, STATUS INTO :uname, :fname, :status
    FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE GUEST_ID = :gid;
    IF (status = 'blocked') THEN RETURN OBJECT_CONSTRUCT('ok', FALSE, 'reason', 'blocked'); END IF;

    -- the provider proved the address: a pending guest becomes active; fill names it lacks
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER
       SET STATUS = 'active', EMAIL_VERIFIED_AT = COALESCE(EMAIL_VERIFIED_AT, CURRENT_TIMESTAMP()),
           FIRST_NAME = COALESCE(NULLIF(FIRST_NAME, ''), TRIM(:FIRST_NAME)),
           LAST_NAME = COALESCE(NULLIF(LAST_NAME, ''), TRIM(:LAST_NAME)),
           LINKEDIN_URL = COALESCE(NULLIF(LINKEDIN_URL, ''), NULLIF(TRIM(:LINKEDIN_URL), '')),
           CONSENTED_AT = COALESCE(CONSENTED_AT, IFF(COALESCE(:CONSENT, FALSE), CURRENT_TIMESTAMP(), NULL)),
           LAST_LOGIN_AT = CURRENT_TIMESTAMP(), LAST_SEEN_AT = CURRENT_TIMESTAMP()
     WHERE GUEST_ID = :gid;
    UPDATE GROCERYDBTPROJECT.GROCERY_APP.GUEST_IDENTITY SET LAST_LOGIN_AT = CURRENT_TIMESTAMP() WHERE PROVIDER = :prov AND SUBJECT = :sub;
    SELECT FIRST_NAME INTO :fname FROM GROCERYDBTPROJECT.GROCERY_APP.GUEST_USER WHERE GUEST_ID = :gid;

    CALL GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_START_SESSION(:gid) INTO :st;
    RETURN OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(:st,
               'ok', TRUE, TRUE), 'guest_id', :gid, TRUE), 'guest_username', :uname, TRUE), 'first_name', :fname, TRUE), 'provider', :prov, TRUE);
END;
$$;

-- PROD ONLY ------------------------------------------------------------------
GRANT USAGE ON PROCEDURE GROCERYDBTPROJECT.GROCERY_APP.SP_GUEST_OIDC_LOGIN(VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, BOOLEAN) TO ROLE GROCERY_GUEST_ROLE;
