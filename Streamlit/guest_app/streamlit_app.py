"""
Grocery Value — public guest edition (Streamlit Community Cloud).

Same shopper experience as Streamlit/grocery_value_app.py (Ask, Look up an
item, My basket, Deals & trends), but reachable by people without a Snowflake
account. The app connects to Snowflake as the service user SVC_GUEST_APP
(role GROCERY_GUEST_ROLE, warehouse GROCERY_GUEST_WH) and gates everything
behind a guest sign-up:

  sign-up (email, first name, last name, LinkedIn)  -> GROCERY_APP.GUEST_USER
  session (60 minutes or 0.25 credits, one per week) -> GROCERY_APP.GUEST_SESSION
  every question / lookup / basket / deals view      -> GROCERY_APP.GUEST_INTERACTION

Cost controls (Snowflake Scripts/Guest/01_guest_access.sql):
  * per session: 0.25 credits, estimated in SP_GUEST_RECORD from agent tokens
    and warehouse seconds; the app stops the session at the cap
  * per week, all guests: 5 credits -> SP_GUEST_RECORD flips the kill switch;
    SP_GUEST_START_SESSION refuses new sessions; the resource monitor
    GROCERY_GUEST_MONITOR (weekly, 5 credits) is the hard stop for warehouse
    spend; the ops layer reconciles against ACCOUNT_USAGE hourly
  * the banner in the sidebar and the main pane tells the visitor which limit
    was reached and when access returns (Monday 00:00 ET)

Secrets (Streamlit Cloud -> app -> Settings -> Secrets), see README.md:
  [snowflake] account, user, role, warehouse, private_key
"""

import json
import re
import threading
import time
from datetime import datetime

import pandas as pd
import requests
import snowflake.connector
import streamlit as st
from cryptography.hazmat.primitives import serialization



def _allow_linkedin_id_token_without_nonce() -> None:
    """LinkedIn's OpenID Connect ID tokens omit the `nonce` claim even though st.login sends one,
    so Authlib rejects every LinkedIn sign-in ("MissingClaimError: nonce"). Skip only that one case:
    issuer is LinkedIn AND the claim is absent. A nonce that is present is still compared, and the
    ID token's signature (LinkedIn JWKS), issuer, audience and expiry are still verified; the code is
    exchanged server-side with the client secret and the OAuth `state` still guards against forgery.
    Applied when the script runs, i.e. before any sign-in callback (the user loads the app first)."""
    try:
        from authlib.oidc.core.claims import IDToken
    except ImportError:
        return
    if getattr(IDToken.validate_nonce, "_linkedin_relaxed", False):
        return
    original = IDToken.validate_nonce

    def validate_nonce(self):
        if self.get("iss") == "https://www.linkedin.com/oauth" and "nonce" not in self:
            return
        return original(self)

    validate_nonce._linkedin_relaxed = True
    IDToken.validate_nonce = validate_nonce


_allow_linkedin_id_token_without_nonce()

DB = "GROCERYDBTPROJECT"
MARTS = f"{DB}.GROCERY_MARTS"
SEM = f"{DB}.GROCERY_SEMANTIC"
APP = f"{DB}.GROCERY_APP"
AGENT = "GROCERY_VALUE_AGENT"
SESSION_CREDIT_CAP = 0.25
WEEKLY_CREDIT_CAP = 5.0
SESSION_MINUTES = 60

st.set_page_config(page_title="Grocery Value (guest)", page_icon="🛒", layout="wide")

FAMILIES = {
    "Compare retailers": "Kroger vs Walmart for identical products (same UPC): who is cheaper, by how much, which Kroger store.",
    "Price movers": "What dropped or rose the most over 4, 8 or 12 weeks; what is at its lowest price ever.",
    "Buy timing": "Is now a good time to buy? A rule on the item's own history decides; a 6-week forecast adds a return-by week.",
    "Deals & promos": "Which sales are genuine, how often an item goes on sale and how deep, inflated 'regular' prices.",
    "Stores & availability": "Nearest Kroger stores to a ZIP, how prices differ between stores, stock and curbside as of the last collection.",
    "Unit price & store brands": "Cheapest per ounce within a product type, store-brand vs national-brand savings, substitutes.",
    "Basket & stock-up": "Which store is cheapest for a list, whether splitting between Walmart and one Kroger store pays, what to stock up on.",
    "Trends": "Category price index per retailer (base week = 100).",
}
EXAMPLE_QUESTIONS = [
    "Which products are cheaper at Walmart than at Kroger right now?",
    "Which food items dropped the most in price over the last 4 weeks?",
    "Is now a good time to buy coffee?",
    "Which sales right now are genuinely good deals?",
    "Which Kroger stores are closest to ZIP code 30318?",
    "What is the cheapest peanut butter per ounce?",
]
NOT_COVERED = "Not covered: nutrition advice, other retailers, coupons and loyalty prices, delivery fees, forecasts beyond 6 weeks, live stock guarantees."


# --------------------------------------------------------------------------
# Snowflake connection (one per guest session, tagged so ACCOUNT_USAGE can
# attribute every query to the session)
# --------------------------------------------------------------------------
def _private_key_der() -> bytes:
    pem = st.secrets["snowflake"]["private_key"].strip()
    key = serialization.load_pem_private_key(pem.encode(), password=None)
    return key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def _connect(query_tag: str):
    s = st.secrets["snowflake"]
    return snowflake.connector.connect(
        account=s["account"], user=s["user"], private_key=_private_key_der(),
        role=s["role"], warehouse=s["warehouse"], database=DB, schema="GROCERY_APP",
        client_session_keep_alive=True, session_parameters={"QUERY_TAG": query_tag},
        login_timeout=30, network_timeout=60,
    )


@st.cache_resource(show_spinner=False)
def shared_conn():
    """Used before a guest session exists (sign-up, session start)."""
    return {"conn": _connect("grocery:guest:signup"), "lock": threading.Lock()}


@st.cache_resource(ttl=SESSION_MINUTES * 60 + 300, show_spinner=False)
def session_conn(session_id: str):
    return {"conn": _connect(f"grocery:guest:{session_id}"), "lock": threading.Lock()}


def _holder():
    sid = (st.session_state.get("guest") or {}).get("session_id")
    return session_conn(sid) if sid else shared_conn()


def q(sql: str, params=None) -> pd.DataFrame:
    """Run SQL and return a DataFrame; wall-clock seconds accumulate for the meter."""
    h = _holder()
    t0 = time.time()
    with h["lock"]:
        cur = h["conn"].cursor()
        try:
            cur.execute(sql, params)
            df = cur.fetch_pandas_all()
        finally:
            cur.close()
    st.session_state["pending_wh_seconds"] = st.session_state.get("pending_wh_seconds", 0.0) + (time.time() - t0)
    return df


def lit(s) -> str:
    return "'" + str(s).replace("'", "''") + "'"


def call_proc(name: str, *args) -> dict:
    """CALL a procedure and return its VARIANT as a dict. Uses fetchone, not pandas: Snowflake returns
    CALL results in JSON format, and connector 4.x fetch_pandas_all refuses non-Arrow results
    ("NotSupportedError: Unknown error", found 2026-11-27)."""
    arg_sql = ", ".join("NULL" if a is None else lit(a) if isinstance(a, str) else ("TRUE" if a is True else "FALSE" if a is False else str(a)) for a in args)
    h = _holder()
    t0 = time.time()
    with h["lock"]:
        cur = h["conn"].cursor()
        try:
            cur.execute(f"CALL {name}({arg_sql})")
            row = cur.fetchone()
        finally:
            cur.close()
    st.session_state["pending_wh_seconds"] = st.session_state.get("pending_wh_seconds", 0.0) + (time.time() - t0)
    raw = row[0] if row else None
    return json.loads(raw) if isinstance(raw, str) else (raw or {})


# --------------------------------------------------------------------------
# guest gate and meter
# --------------------------------------------------------------------------
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$")
LINKEDIN_RE = re.compile(r"^(https?://)?([a-z]{2,3}\.)?linkedin\.com/in/[A-Za-z0-9\-_%]+/?$", re.I)


def guest() -> dict | None:
    return st.session_state.get("guest")


def refresh_status(g: dict, status: dict) -> None:
    g.update({
        "credits_used": float(status.get("session_credits") or 0),
        "allowed": bool(status.get("allowed")),
        "reason": status.get("reason"),
        "weekly_credits": float(status.get("weekly_credits") or 0),
        "expires_at": status.get("expires_at") or g.get("expires_at"),
        "rate_per_m": float(status.get("rate_credits_per_m_tokens") or g.get("rate_per_m") or 0),
        "fallback_per_question": float(status.get("fallback_credits_per_question") or g.get("fallback_per_question") or 0.11),
    })


def record(kind: str, input_text: str, output_text: str = "", tokens: int | None = None, model: str | None = None, ok: bool = True) -> bool:
    """Log one interaction and apply the meter. Returns whether the session may continue."""
    g = guest()
    if not g:
        return False
    wh = float(st.session_state.pop("pending_wh_seconds", 0.0) or 0.0)
    try:
        status = call_proc(f"{APP}.SP_GUEST_RECORD", g["session_id"], kind, (input_text or "")[:4000], (output_text or "")[:4000],
                           int(tokens) if tokens is not None else None, model, round(wh, 2), ok)
    except Exception as e:  # never let the meter take the app down; fail closed on the next action instead
        st.session_state["meter_error"] = str(e)[:300]
        return g.get("allowed", False)
    st.session_state.pop("pending_wh_seconds", None)  # the CALL's own time is included in the next record
    refresh_status(g, status)
    return g["allowed"]


def minutes_left(g: dict) -> int:
    try:
        exp = pd.Timestamp(g["expires_at"])
        now = pd.Timestamp.now(tz=exp.tz) if exp.tzinfo else pd.Timestamp.now()
        return max(0, int((exp - now).total_seconds() // 60))
    except Exception:
        return 0


def limit_banner(g: dict) -> None:
    reason = g.get("reason") or ""
    if reason == "weekly_cap" or reason == "disabled":
        st.error(f"**Guest access has reached this week's limit.** All visitors together get {WEEKLY_CREDIT_CAP:g} Snowflake credits a week, "
                 "and this week's allowance is used up. Guest access reopens Monday at 00:00 ET. Thanks for trying it, and please come back then.")
    elif reason == "session_cap":
        st.warning(f"**You've reached this session's limit of {SESSION_CREDIT_CAP:g} Snowflake credits.** Each guest gets one session a week, "
                   "so the tabs below are read-only until next Monday. The Deals & trends tab still shows this week's data.")
    elif reason == "expired":
        st.warning(f"**Your {SESSION_MINUTES}-minute session has ended.** Each guest gets one session a week; come back next Monday for another.")
    elif reason == "already_used":
        st.warning("**You've already used your guest session this week.** Sessions reset Monday 00:00 ET.")
    b1, b2, _ = st.columns([1, 1, 4])
    if b1.button("Check again", help="Re-reads your session from Snowflake (for example after the owner reset it)"):
        try:
            status = call_proc(f"{APP}.SP_GUEST_STATUS", g["session_id"]) if g.get("session_id") else {"allowed": False, "reason": "no_session"}
            if not status.get("allowed") and status.get("reason") in ("no_session", "expired", "session_cap", "already_used") and g.get("guest_id"):
                fresh = call_proc(f"{APP}.SP_GUEST_START_SESSION", g["guest_id"])
                if fresh.get("session_id"):
                    g.update({"session_id": fresh.get("session_id"), "started_at": fresh.get("started_at"), "expires_at": fresh.get("expires_at")})
                    status = fresh
            refresh_status(g, status)
        except Exception as ex:
            st.error(f"Could not refresh: {str(ex)[:200]}")
        st.rerun()
    if b2.button("Log out"):
        for k in list(st.session_state.keys()):
            del st.session_state[k]
        if oidc_logged_in():
            st.logout()  # removes the 30-day identity cookie and reruns
        st.rerun()


# --------------------------------------------------------------------------
# email (one-time codes) — Gmail SMTP with an app password from st.secrets["email"]
# --------------------------------------------------------------------------
def email_configured() -> bool:
    try:
        e = st.secrets["email"]
        return bool(e.get("smtp_user") and e.get("smtp_app_password"))
    except Exception:
        return False


def send_code_email(to: str, first_name: str | None, code: str, purpose: str, ttl_minutes: int = 15) -> tuple[bool, str]:
    """Send the 6-digit code. Returns (ok, error). The code is never shown on screen or logged."""
    import smtplib
    import ssl
    from email.message import EmailMessage

    e = st.secrets["email"]
    app_url = e.get("app_url", "")
    msg = EmailMessage()
    msg["Subject"] = f"Your Grocery Value code: {code}"
    msg["From"] = f"{e.get('from_name', 'Grocery Value')} <{e['smtp_user']}>"
    msg["To"] = to
    if purpose in ("verify", "reminder"):
        intro = "Welcome! Enter this code in the app to finish setting up your guest access."
    else:
        intro = "Here is your login code for the Grocery Value guest app."
    msg.set_content(
        f"Hi {first_name or 'there'},\n\n{intro}\n\n    {code}\n\nIt expires in {ttl_minutes} minutes."
        + (f"\n\nOpen the app: {app_url}" if app_url else "")
        + "\n\nIf you did not request this, you can ignore this email.\n\nGrocery Value (guest edition)"
    )
    try:
        try:
            import certifi
            ctx = ssl.create_default_context(cafile=certifi.where())
        except ImportError:
            ctx = ssl.create_default_context()
        with smtplib.SMTP_SSL("smtp.gmail.com", 465, context=ctx, timeout=20) as s:
            s.login(e["smtp_user"], e["smtp_app_password"])
            s.send_message(msg)
        return True, ""
    except Exception as ex:
        return False, str(ex)[:200]


def issue_and_send(email: str, purpose: str) -> tuple[bool, str]:
    """Ask Snowflake for a code and email it. Unknown emails get the same 'sent' answer (no enumeration)."""
    try:
        r = call_proc(f"{APP}.SP_GUEST_ISSUE_CODE", email, purpose)
    except Exception as ex:
        return False, f"Could not create a code: {str(ex)[:200]}"
    if not r.get("sent"):
        reason = r.get("reason")
        if reason == "rate_limited":
            return False, "You have requested a few codes already. Please use the last one, or try again in an hour."
        if reason == "daily_limit":
            return False, "The app has sent its daily share of codes. Please try again tomorrow."
        if reason == "reminder_limit":
            return False, "Reminder limit reached."
        return False, "Could not send a code right now."
    code = r.get("code")
    if code:
        if not email_configured():
            return False, "Email sending is not configured on this deployment yet; the owner has been told."
        ok, err = send_code_email(email, r.get("first_name"), code, purpose, int(r.get("ttl_minutes") or 15))
        if not ok:
            return False, f"Could not send the email ({err}). Please try again in a minute."
    return True, ""


def finish_login(email: str, code: str) -> None:
    """Verify the code; on success install the guest session (even when the week's session is used up, so the banner can explain)."""
    try:
        v = call_proc(f"{APP}.SP_GUEST_VERIFY_CODE", email, code)
    except Exception as ex:
        st.error(f"Could not verify the code: {str(ex)[:200]}")
        return
    if not v.get("ok"):
        reason = v.get("reason")
        msgs = {
            "wrong_code": f"That code is not right. {v.get('attempts_left', 0)} tries left.",
            "locked": "Too many wrong tries. Request a new code.",
            "expired": "That code has expired. Request a new one.",
            "no_code": "No active code for this email. Request a new one.",
        }
        st.error(msgs.get(reason, "Could not verify that code."))
        return
    install_guest(v)


def install_guest(v: dict) -> None:
    """Put a verified guest (code or LinkedIn) into the session and start the app."""
    g = {"guest_id": v.get("guest_id"), "guest_username": v.get("guest_username"), "first_name": v.get("first_name"),
         "session_id": v.get("session_id"), "started_at": v.get("started_at"), "expires_at": v.get("expires_at"),
         "provider": v.get("provider")}
    refresh_status(g, v)
    st.session_state["guest"] = g
    st.session_state["pending_wh_seconds"] = 0.0
    for k in ("code_stage", "pending_email", "code_purpose", "code_note", "oidc_need_consent", "oidc_error"):
        st.session_state.pop(k, None)
    st.rerun()


# --------------------------------------------------------------------------
# Sign in with LinkedIn (OpenID Connect via st.login; Snowflake Scripts/Guest/04_guest_oidc.sql)
# --------------------------------------------------------------------------
def linkedin_configured() -> bool:
    """True when [auth] and [auth.linkedin] hold real values. When not, the reason (key names only,
    never values) goes to the server log once per process, so a Cloud deploy shows why."""
    missing = []
    try:
        a = st.secrets.get("auth") or {}
        li = a.get("linkedin") or {}
        for name, v in (("auth.redirect_uri", a.get("redirect_uri")), ("auth.cookie_secret", a.get("cookie_secret")),
                        ("auth.linkedin.client_id", li.get("client_id")), ("auth.linkedin.client_secret", li.get("client_secret")),
                        ("auth.linkedin.server_metadata_url", li.get("server_metadata_url"))):
            if not v or str(v).startswith("PASTE_"):
                missing.append(name)
    except Exception as ex:
        missing.append(f"secrets unreadable ({type(ex).__name__})")
    if missing and not _AUTH_DIAG_LOGGED:
        _AUTH_DIAG_LOGGED.append(True)
        top = sorted(st.secrets.keys()) if hasattr(st.secrets, "keys") else []
        print(f"[grocery-guest] LinkedIn sign-in off; missing or placeholder: {', '.join(missing)}; top-level secret sections: {top}", flush=True)
    return not missing


_AUTH_DIAG_LOGGED: list = []


def oidc_logged_in() -> bool:
    try:
        return bool(st.user.is_logged_in)
    except Exception:
        return False


def linkedin_finish(consent: bool = False, linkedin_url: str | None = None) -> None:
    """Hand the ID-token claims (validated by Authlib inside st.login) to Snowflake; install the guest or ask for consent."""
    u = st.user
    verified = u.get("email_verified") in (True, "true", "True")
    try:
        v = call_proc(f"{APP}.SP_GUEST_OIDC_LOGIN", "linkedin", str(u.get("sub") or ""), str(u.get("email") or ""), verified,
                      u.get("given_name"), u.get("family_name"), (linkedin_url or "").strip() or None, bool(consent))
    except Exception as ex:
        st.session_state["oidc_error"] = f"Could not sign you in: {str(ex)[:200]}"
        return
    if v.get("ok"):
        install_guest(v)
    reason = v.get("reason")
    if reason == "need_consent":
        st.session_state["oidc_need_consent"] = v
    elif reason == "email_unverified":
        st.session_state["oidc_error"] = "LinkedIn did not confirm an email address for this account. Please use the email option below instead."
    elif reason == "blocked":
        st.session_state["oidc_error"] = "This account cannot be used for guest access."
    else:
        st.session_state["oidc_error"] = "Could not sign you in with LinkedIn. Please try again or use your email."


def sign_up_gate() -> None:
    st.title("Grocery Value")
    st.caption("Kroger (81 Atlanta-area stores) and Walmart prices, a buy-now-or-wait signal, and an AI agent that answers in plain English.")
    c1, c2 = st.columns([3, 2])
    with c1:
        if st.session_state.get("code_stage"):
            email = st.session_state["pending_email"]
            st.markdown(f"**Check your email.** We sent a 6-digit code to **{email}**. It expires in 15 minutes.")
            if st.session_state.get("code_note"):
                st.info(st.session_state["code_note"])
            with st.form("code_form"):
                code = st.text_input("6-digit code", max_chars=6)
                ok = st.form_submit_button("Continue", type="primary")
            if ok and code.strip():
                finish_login(email, code.strip())
            b1, b2 = st.columns(2)
            if b1.button("Resend code"):
                sent, err = issue_and_send(email, st.session_state.get("code_purpose", "login"))
                st.success("Sent again. Check spam if it is not there in a minute.") if sent else st.error(err)
            if b2.button("Use a different email"):
                for k in ("code_stage", "pending_email", "code_purpose", "code_note"):
                    st.session_state.pop(k, None)
                st.rerun()
            st.caption("Codes come from the owner's Gmail address. If nothing arrives, check spam or try again in a minute.")
        elif linkedin_configured() and oidc_logged_in() and st.session_state.get("oidc_need_consent"):
            nc = st.session_state["oidc_need_consent"]
            st.markdown(f"**Welcome, {nc.get('first_name') or 'there'}.** You're signed in with LinkedIn as **{nc.get('email')}**. One step before your first session:")
            with st.form("oidc_consent"):
                li_url = st.text_input("Your LinkedIn profile URL (optional)", placeholder="https://www.linkedin.com/in/your-handle", max_chars=200,
                                       help="LinkedIn doesn't share your profile link with apps, so add it if you'd like the owner to connect.")
                agree = st.checkbox("I agree that my name, email (and LinkedIn URL, if given) and my questions and clicks in this app are stored in the owner's "
                                    "Snowflake account so the owner can see how the app is used and follow up. No data is sold or shared. "
                                    "LinkedIn also shares your photo; it is not stored.")
                go = st.form_submit_button("Continue", type="primary")
            if go:
                if li_url.strip() and not LINKEDIN_RE.match(li_url.strip()):
                    st.error("The LinkedIn URL should look like https://www.linkedin.com/in/your-handle, or leave it blank.")
                elif not agree:
                    st.error("Please tick the consent box; without it nothing is stored and the session cannot start.")
                else:
                    with st.spinner("Starting your session..."):
                        linkedin_finish(consent=True, linkedin_url=li_url)
            if st.session_state.get("oidc_error"):
                st.error(st.session_state.pop("oidc_error"))
            if st.button("Not you? Sign out of LinkedIn"):
                st.session_state.clear()
                st.logout()
        else:
            if linkedin_configured() and oidc_logged_in() and not st.session_state.get("oidc_tried"):
                # returning visitor (30-day identity cookie) or just back from LinkedIn: no form needed
                st.session_state["oidc_tried"] = True
                with st.spinner("Signing you in..."):
                    linkedin_finish()
                if st.session_state.get("oidc_need_consent"):
                    st.rerun()
            if st.session_state.get("oidc_error"):
                st.error(st.session_state.pop("oidc_error"))
            if linkedin_configured() and not oidc_logged_in():
                st.markdown("**Try it as a guest.** One click with your LinkedIn account, no password and no code to wait for. "
                            f"You get one session a week: **{SESSION_MINUTES} minutes or {SESSION_CREDIT_CAP:g} Snowflake credits**, whichever comes first.")
                if st.button("Sign in with LinkedIn", type="primary"):
                    st.login("linkedin")
                st.caption("LinkedIn shares your name, email and photo with this app; the photo is not stored.")
            email_box = st.expander("Or use your email instead", expanded=False) if linkedin_configured() else st.container()
            with email_box:
                _email_gate()
    with c2:
        st.markdown("**What it can answer**")
        for fam, desc in FAMILIES.items():
            st.markdown(f"- **{fam}** — {desc}")
        st.caption(NOT_COVERED)
    st.stop()


def _email_gate() -> None:
    """The emailed-code sign-up / log-in (the fallback when LinkedIn is configured)."""
    st.markdown(
        "**Try it as a guest.** Sign up once with your name, email and LinkedIn profile; we email you a code to confirm the address. "
        f"You get one session a week: **{SESSION_MINUTES} minutes or {SESSION_CREDIT_CAP:g} Snowflake credits**, whichever comes first "
        "(about two agent questions plus unlimited lookups and basket pricing). Everyone together shares a weekly budget of "
        f"{WEEKLY_CREDIT_CAP:g} credits; when it is spent, the door closes until Monday. Already registered? Use **Log in**.")
    t_signup, t_login = st.tabs(["Sign up", "Log in"])
    with t_signup:
        with st.form("guest_signup"):
            a, b = st.columns(2)
            first = a.text_input("First name", max_chars=60)
            last = b.text_input("Last name", max_chars=60)
            email = st.text_input("Email", max_chars=120)
            linkedin = st.text_input("LinkedIn profile URL", placeholder="https://www.linkedin.com/in/your-handle", max_chars=200)
            consent = st.checkbox("I agree that my name, email, LinkedIn URL and my questions and clicks in this app are stored in the owner's Snowflake account "
                                  "so the owner can see how the app is used and follow up. No data is sold or shared.")
            go = st.form_submit_button("Sign up and email me a code", type="primary")
        if go:
            errs = []
            if not first.strip() or not last.strip():
                errs.append("First and last name are required.")
            if not EMAIL_RE.match(email.strip()):
                errs.append("That email address does not look valid.")
            if not LINKEDIN_RE.match(linkedin.strip()):
                errs.append("The LinkedIn URL should look like https://www.linkedin.com/in/your-handle.")
            if not consent:
                errs.append("Please tick the consent box; without it nothing is stored and the session cannot start.")
            if errs:
                for e in errs:
                    st.error(e)
            else:
                em = email.strip().lower()
                with st.spinner("Sending your code..."):
                    try:
                        reg = call_proc(f"{APP}.SP_GUEST_REGISTER", em, first.strip(), last.strip(), linkedin.strip(), True)
                    except Exception as ex:
                        st.error(f"Could not sign you up: {str(ex)[:200]}")
                        st.stop()
                    if reg.get("error") == "blocked":
                        st.error("This email cannot be used for guest access.")
                        st.stop()
                    purpose = "login" if reg.get("already_registered") else "verify"
                    sent, err = issue_and_send(em, purpose)
                if not sent:
                    st.error(err)
                else:
                    st.session_state.update({"code_stage": True, "pending_email": em, "code_purpose": purpose,
                                             "code_note": "That email is already registered, so we sent a login code instead." if purpose == "login" else None})
                    st.rerun()
    with t_login:
        st.caption("Step 1: ask for a code. Step 2: enter it here (codes from a reminder email work here too).")
        with st.form("guest_login"):
            lemail = st.text_input("Email you registered with", max_chars=120)
            lcode = st.text_input("6-digit code (leave blank to request one)", max_chars=6)
            b1, b2 = st.columns(2)
            lgo = b1.form_submit_button("Email me a login code")
            lverify = b2.form_submit_button("Log in with my code", type="primary")
        em = lemail.strip().lower()
        if (lgo or lverify) and not EMAIL_RE.match(em):
            st.error("That email address does not look valid.")
        elif lverify:
            if not lcode.strip():
                st.error("Enter the 6-digit code from your email, or ask for a new one.")
            else:
                finish_login(em, lcode.strip())
        elif lgo:
            with st.spinner("Sending your code..."):
                sent, err = issue_and_send(em, "login")
            if not sent:
                st.error(err)
            else:
                st.session_state.update({"code_stage": True, "pending_email": em, "code_purpose": "login", "code_note": None})
                st.rerun()


# --------------------------------------------------------------------------
# data helpers (shared cache across guests: cheap, read-only)
# --------------------------------------------------------------------------
@st.cache_data(ttl=3600, show_spinner=False)
def data_as_of() -> str:
    df = q(f"SELECT MAX(DATA_AS_OF)::DATE AS D FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_ROLLUP")
    return str(df["D"].iloc[0]) if not df.empty else "unknown"


@st.cache_data(ttl=1800, show_spinner=False)
def search_products(term: str, retailer: str | None, limit: int = 15) -> pd.DataFrame:
    req = {"query": term, "columns": ["PRODUCT_KEY", "PRODUCT_NAME", "BRAND", "SIZE_TEXT", "RETAILER", "PRODUCT_TYPE", "HAS_EXACT_MATCH"], "limit": limit}
    if retailer:
        req["filter"] = {"@eq": {"RETAILER": retailer}}
    df = q(f"SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('{SEM}.PRODUCT_SEARCH', {lit(json.dumps(req))}) AS R")
    hits = json.loads(df["R"].iloc[0]).get("results", []) if not df.empty else []
    return pd.DataFrame(hits)


@st.cache_data(ttl=1800, show_spinner=False)
def prices_by_store(product_key: str) -> pd.DataFrame:
    return q(f"""
        SELECT s.STORE_NAME, s.CITY, s.ZIP_CODE, sp.CURRENT_PRICE, sp.CURRENT_REGULAR_PRICE, sp.IS_ON_PROMO,
               sp.DEAL_QUALITY, sp.TRAILING_LOW_PRICE, sp.TRAILING_MEDIAN_PRICE, sp.IS_AT_HISTORIC_LOW,
               sp.CHANGE_4W_PCT, sp.WEEKS_OBSERVED, sp.DATA_AS_OF
        FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_SUMMARY sp
        JOIN {MARTS}.DBT_DIM_STORE s ON s.STORE_ID = sp.STORE_ID
        WHERE sp.PRODUCT_KEY = {lit(product_key)} AND sp.IS_CURRENTLY_LISTED
        ORDER BY sp.CURRENT_PRICE, s.STORE_NAME""")


@st.cache_data(ttl=1800, show_spinner=False)
def price_history(product_key: str) -> pd.DataFrame:
    return q(f"""
        SELECT PRICE_WEEK, MEDIAN(EFFECTIVE_PRICE) AS TYPICAL_PRICE, MIN(EFFECTIVE_PRICE) AS LOWEST_PRICE, COUNT(*) AS STORES
        FROM {MARTS}.DBT_FCT_PRICE_WEEKLY WHERE PRODUCT_KEY = {lit(product_key)} GROUP BY 1 ORDER BY 1""")


@st.cache_data(ttl=1800, show_spinner=False)
def buy_signal(product_key: str) -> pd.DataFrame:
    return q(f"""
        SELECT RULE_SIGNAL, RECOMMENDATION, CURRENT_PRICE, HISTORY_LOW_PRICE, HISTORY_MEDIAN_PRICE, HISTORY_HIGH_PRICE,
               WEEKS_OBSERVED, FORECAST_DIRECTION, FORECAST_LOW_PRICE_BOUNDED, RETURN_BY_WEEK, FORECAST_INTERVAL_WIDTH_PCT, IS_STOCK_UP_CANDIDATE
        FROM {MARTS}.DBT_FCT_BUY_RECOMMENDATION WHERE PRODUCT_KEY = {lit(product_key)}""")


@st.cache_data(ttl=1800, show_spinner=False)
def product_card(product_key: str) -> pd.DataFrame:
    return q(f"""
        SELECT PRODUCT_NAME, BRAND, SIZE_TEXT, RETAILER, PRODUCT_TYPE, PRIMARY_COMMON_CATEGORY, IMAGE_URL, PACKAGE_QUANTITY, UNIT_BASIS,
               PARSE_CONFIDENCE, IS_STORE_BRAND, HAS_EXACT_MATCH, UPC_A
        FROM {MARTS}.DBT_DIM_PRODUCT WHERE PRODUCT_KEY = {lit(product_key)}""")


@st.cache_data(ttl=1800, show_spinner=False)
def cross_retailer(upc_a: str) -> pd.DataFrame:
    return q(f"""
        SELECT PRODUCT_NAME, WALMART_PRICE, KROGER_MIN_PRICE, KROGER_MEDIAN_PRICE, KROGER_CHEAPEST_STORE_NAME, CHEAPER_RETAILER, SAVINGS_VS_KROGER_MIN
        FROM {MARTS}.DBT_FCT_CROSS_RETAILER_PRICE_COMPARISON WHERE UPC_A = {lit(upc_a)}""")


@st.cache_data(ttl=3600, show_spinner=False)
def deals_by_product(retailer: str | None = None, limit: int = 25) -> pd.DataFrame:
    """Genuine deals, one row per product (not per store); the stores ride along as a JSON array."""
    rfilter = f"AND p.RETAILER = {lit(retailer)}" if retailer else ""
    return q(f"""
        WITH d AS (
            SELECT sp.PRODUCT_KEY, s.STORE_NAME, s.CITY, s.ZIP_CODE, sp.CURRENT_PRICE, sp.CURRENT_REGULAR_PRICE, sp.CURRENT_DISCOUNT_PCT
            FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_SUMMARY sp
            JOIN {MARTS}.DBT_DIM_STORE s ON s.STORE_ID = sp.STORE_ID
            JOIN {MARTS}.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = sp.PRODUCT_KEY
            WHERE sp.IS_CURRENTLY_LISTED AND sp.DEAL_QUALITY = 'GENUINE' AND p.IS_FOOD {rfilter}
        )
        SELECT p.RETAILER, p.PRODUCT_NAME, p.BRAND, p.SIZE_TEXT, p.IMAGE_URL, d.PRODUCT_KEY,
               MIN(d.CURRENT_PRICE) AS BEST_PRICE, MEDIAN(d.CURRENT_REGULAR_PRICE) AS REGULAR_PRICE,
               MAX(d.CURRENT_DISCOUNT_PCT) AS BEST_DISCOUNT_PCT, COUNT(*) AS STORES_ON_DEAL,
               ARRAY_AGG(OBJECT_CONSTRUCT('store', d.STORE_NAME, 'city', d.CITY, 'zip', d.ZIP_CODE, 'price', d.CURRENT_PRICE, 'regular', d.CURRENT_REGULAR_PRICE))
                   WITHIN GROUP (ORDER BY d.CURRENT_PRICE, d.STORE_NAME) AS LOCATIONS
        FROM d JOIN {MARTS}.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = d.PRODUCT_KEY
        GROUP BY 1, 2, 3, 4, 5, 6
        ORDER BY BEST_DISCOUNT_PCT DESC, STORES_ON_DEAL DESC
        LIMIT {int(limit)}""")


def render_deals(deals: pd.DataFrame) -> None:
    """One compact row per product with a pull-down listing the stores on deal."""
    if deals.empty:
        st.info("No genuine deals in the latest collection.")
        return
    def _txt(v) -> str:  # NULLs arrive as NaN (float), which is truthy and breaks str joins
        return v.strip() if isinstance(v, str) else ""

    for _, r in deals.iterrows():
        c1, c2, c3 = st.columns([1, 6, 3])
        if _txt(r.get("IMAGE_URL")).startswith("http"):
            c1.image(r["IMAGE_URL"], width=56)
        meta = " · ".join(x for x in [_txt(r.get("BRAND")), _txt(r.get("SIZE_TEXT")), _txt(r.get("RETAILER")).title()] if x)
        c2.markdown(f"**{r['PRODUCT_NAME']}**  \n{meta}".replace("$", "\\$"))
        best, reg, disc = r.get("BEST_PRICE"), r.get("REGULAR_PRICE"), r.get("BEST_DISCOUNT_PCT")
        price_md = f"**\\${best:.2f}**" if pd.notna(best) else "—"
        if pd.notna(reg) and reg and reg > (best or 0):
            price_md += f" ~~\\${reg:.2f}~~"
        if pd.notna(disc):
            price_md += f"  \nsave {disc:.0%}"
        c3.markdown(price_md)
        locs = r.get("LOCATIONS")
        if isinstance(locs, str):
            try:
                locs = json.loads(locs)
            except ValueError:
                locs = []
        n = int(r.get("STORES_ON_DEAL") or len(locs or []))
        if str(r.get("RETAILER")).lower() == "walmart":
            st.caption("Walmart.com (national online price)")
        else:
            with st.expander(f"On deal at {n} Kroger store{'s' if n != 1 else ''}: where"):
                ldf = pd.DataFrame(locs or [])
                if not ldf.empty:
                    ldf = ldf.rename(columns={"store": "Store", "city": "City", "zip": "ZIP", "price": "Price", "regular": "Regular"})
                    show_df(ldf.style.format({"Price": "${:.2f}", "Regular": "${:.2f}"}, na_rep="—"))
        st.markdown("---")


@st.cache_data(ttl=3600, show_spinner=False)
def deals_tables() -> tuple[pd.DataFrame, list]:
    drops = q(f"""
        SELECT p.RETAILER, p.PRODUCT_NAME, r.MEDIAN_CURRENT_PRICE, r.MEDIAN_CHANGE_4W_PCT, r.REF_WEEK_4W
        FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_ROLLUP r
        JOIN {MARTS}.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = r.PRODUCT_KEY
        WHERE p.IS_FOOD AND r.MEDIAN_CHANGE_4W_PCT IS NOT NULL
        ORDER BY r.MEDIAN_CHANGE_4W_PCT LIMIT 25""")
    cats = q(f"SELECT DISTINCT COMMON_CATEGORY FROM {MARTS}.DBT_FCT_CATEGORY_PRICE_INDEX_WEEKLY WHERE IS_FOOD_CATEGORY ORDER BY 1")["COMMON_CATEGORY"].tolist()
    return drops, cats


@st.cache_data(ttl=3600, show_spinner=False)
def category_index(cat: str) -> pd.DataFrame:
    return q(f"SELECT RETAILER, PRICE_WEEK, PRICE_INDEX FROM {MARTS}.DBT_FCT_CATEGORY_PRICE_INDEX_WEEKLY WHERE COMMON_CATEGORY = {lit(cat)} ORDER BY 2")


# --------------------------------------------------------------------------
# agent (Cortex Agent REST API with the connection's session token)
# --------------------------------------------------------------------------
def ask_agent(messages: list[dict]) -> tuple[str, list[str], int | None, str | None]:
    """Returns (answer, tools used, tokens if the stream reported usage, model)."""
    h = _holder()
    conn = h["conn"]
    url = f"https://{conn.host}/api/v2/databases/{DB}/schemas/GROCERY_SEMANTIC/agents/{AGENT}:run"
    headers = {"Authorization": f'Snowflake Token="{conn.rest.token}"', "Content-Type": "application/json", "Accept": "text/event-stream"}
    deltas, fulls, tools, tokens, model, event = [], [], [], None, None, None
    try:
        with requests.post(url, headers=headers, json={"messages": messages}, stream=True, timeout=180) as r:
            if r.status_code != 200:
                return f"The agent returned an error ({r.status_code}): {r.text[:600]}", [], None, None
            for raw in r.iter_lines(decode_unicode=True):
                if not raw:
                    continue
                if raw.startswith("event:"):
                    event = raw[6:].strip()
                elif raw.startswith("data:"):
                    payload = raw[5:].strip()
                    if payload in ("", "[DONE]"):
                        continue
                    try:
                        data = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    if event == "response.text.delta":
                        deltas.append(data.get("text", ""))
                    elif event == "response.text":
                        fulls.append(data.get("text", ""))
                    elif event and event.startswith("response.tool_use"):
                        name = data.get("name") or data.get("tool_name")
                        if name and name not in tools:
                            tools.append(name)
                    elif event == "error":
                        fulls.append(f"[agent error] {data}")
                    usage = (data.get("usage") if isinstance(data, dict) else None) or ((data.get("metadata") or {}).get("usage") if isinstance(data, dict) else None)
                    if isinstance(usage, dict):
                        total = 0
                        for u in usage.get("tokens_consumed") or []:
                            total += int(((u.get("input_tokens") or {}).get("total") or 0) + ((u.get("output_tokens") or {}).get("total") or 0))
                            model = model or u.get("model_name")
                        if total:
                            tokens = (tokens or 0) + total
    except requests.RequestException as e:
        return f"The agent could not be reached: {str(e)[:300]}", [], None, None
    return ("".join(deltas).strip() or "".join(fulls).strip() or "The agent returned no text."), tools, tokens, model


# --------------------------------------------------------------------------
# page
# --------------------------------------------------------------------------
def show_df(df, **kwargs):
    kwargs.setdefault("use_container_width", True)
    st.dataframe(df, hide_index=True, **kwargs)


g = guest()
if not g:
    sign_up_gate()

# time-based expiry is enforced locally too, so a sleeping tab cannot run on
if g.get("allowed") and minutes_left(g) <= 0:
    g["allowed"], g["reason"] = False, "expired"
    record("session_end", "expired")
active = bool(g.get("allowed"))

with st.sidebar:
    st.header(f"Hi {g.get('first_name', 'there')}")
    st.caption(f"Guest `{g.get('guest_username') or g['guest_id']}`")
    used = float(g.get("credits_used") or 0)
    st.progress(min(1.0, used / SESSION_CREDIT_CAP), text=f"Session: {used:.3f} of {SESSION_CREDIT_CAP:g} credits")
    st.caption(f"{minutes_left(g)} minutes left · one session per guest per week")
    wk = float(g.get("weekly_credits") or 0)
    st.progress(min(1.0, wk / WEEKLY_CREDIT_CAP), text=f"All guests this week: {wk:.2f} of {WEEKLY_CREDIT_CAP:g} credits")
    if st.session_state.get("meter_error"):
        st.caption("Meter sync hiccup; limits still apply on the next action.")
    st.divider()
    st.markdown("**What this app can answer**")
    for fam, desc in FAMILIES.items():
        st.markdown(f"**{fam}** — {desc}")
    st.caption(NOT_COVERED)
    st.caption("History has no data for Oct 12 – Nov 8, 2026. Walmart is a ~1,400-item catalog slice. Availability is as of the last collection, not live.")

st.title("Grocery Value")
st.caption(f"Kroger (81 Atlanta-area stores, prices differ by store) and Walmart (national online). Prices as of {data_as_of()}.")
if not active:
    limit_banner(g)

tab_ask, tab_lookup, tab_basket, tab_deals = st.tabs(["Ask", "Look up an item", "My basket", "Deals & trends"])

# ---------------------------------------------------------------- Ask
with tab_ask:
    st.subheader("Ask the grocery value agent")
    st.write("Each question costs roughly a tenth of a credit of your session budget. The agent states the as-of date, the store a Kroger price applies to, and whether a Kroger–Walmart comparison is the identical product.")
    cols = st.columns(2)
    for i, ex in enumerate(EXAMPLE_QUESTIONS):
        if cols[i % 2].button(ex, key=f"ex{i}", use_container_width=True, disabled=not active):
            st.session_state["pending_question"] = ex
    st.session_state.setdefault("chat", [])
    typed = st.chat_input("Ask about prices, deals, stores, timing, or a shopping list", disabled=not active)
    question = typed or st.session_state.pop("pending_question", None)
    if question and active:
        st.session_state["chat"].append({"role": "user", "text": question})
        api_messages = [{"role": m["role"], "content": [{"type": "text", "text": m["text"]}]} for m in st.session_state["chat"]]
        with st.spinner("Checking prices..."):
            answer, tools, tokens, model = ask_agent(api_messages)
        st.session_state["chat"].append({"role": "assistant", "text": answer, "tools": tools})
        ok = not answer.startswith("The agent")
        if record("question", question, answer, tokens, model, ok) is False:
            st.rerun()
    for m in st.session_state["chat"]:
        with st.chat_message("user" if m["role"] == "user" else "assistant"):
            st.markdown(m["text"].replace("$", "\\$"))
            if m.get("tools"):
                st.caption("Tools used: " + ", ".join(m["tools"]))
    if st.session_state["chat"] and st.button("Clear conversation"):
        st.session_state["chat"] = []
        st.rerun()

# ---------------------------------------------------------------- Look up
with tab_lookup:
    st.subheader("Look up an item by store")
    st.write("Find a product, then see its price at every Kroger store and at Walmart, its history, and whether now is a good time to buy.")
    c1, c2 = st.columns([3, 1])
    term = c1.text_input("Product", placeholder="e.g. Jif creamy peanut butter, whole turkey, Kroger large eggs", disabled=not active)
    retailer = c2.selectbox("Retailer", ["both", "kroger", "walmart"], disabled=not active)
    if term and active:
        hits = search_products(term, None if retailer == "both" else retailer)
        if hits.empty:
            st.info("No matching products.")
        else:
            hits["label"] = hits.apply(lambda r: f"{r['RETAILER']} · {r['PRODUCT_NAME']}" + (f" · {r['SIZE_TEXT']}" if r.get("SIZE_TEXT") else "") + (f"  [{r['PRODUCT_TYPE']}]" if r.get("PRODUCT_TYPE") else ""), axis=1)
            choice = st.selectbox("Matches (best first)", hits["label"].tolist())
            key = hits.loc[hits["label"] == choice, "PRODUCT_KEY"].iloc[0]
            card = product_card(key)
            c = card.iloc[0] if not card.empty else {}
            if len(card):
                a, b = st.columns([1, 3])
                if c.get("IMAGE_URL"):
                    a.image(c["IMAGE_URL"], width=160)
                b.markdown(f"**{c['PRODUCT_NAME']}**  \n{c.get('BRAND') or ''} · {c.get('SIZE_TEXT') or ''} · {c.get('PRIMARY_COMMON_CATEGORY') or ''}"
                           + (f" · type: {c['PRODUCT_TYPE']}" if c.get("PRODUCT_TYPE") else "")
                           + (" · store brand" if c.get("IS_STORE_BRAND") else "")
                           + (f"  \nAlso sold at the other retailer (UPC {c['UPC_A']})" if c.get("HAS_EXACT_MATCH") else ""))
            sig = buy_signal(key)
            if not sig.empty:
                s = sig.iloc[0]
                m1, m2, m3, m4 = st.columns(4)
                m1.metric("Typical price now", f"${s['CURRENT_PRICE']:.2f}" if pd.notna(s["CURRENT_PRICE"]) else "—")
                m2.metric("Recommendation", str(s["RECOMMENDATION"]).replace("_", " ").title())
                m3.metric("Vs its own history", str(s["RULE_SIGNAL"]).replace("_", " ").title(), help=f"low ${s['HISTORY_LOW_PRICE']} · median ${s['HISTORY_MEDIAN_PRICE']} · high ${s['HISTORY_HIGH_PRICE']} over {s['WEEKS_OBSERVED']} observed weeks")
                fc = f"{s['FORECAST_DIRECTION']}" + (f", return by {s['RETURN_BY_WEEK']}" if pd.notna(s["RETURN_BY_WEEK"]) else "")
                m4.metric("6-week forecast", fc if s["FORECAST_DIRECTION"] != "NONE" else "none")
            if len(card) and c.get("HAS_EXACT_MATCH") and c.get("UPC_A"):
                x = cross_retailer(c["UPC_A"])
                if not x.empty:
                    st.markdown("**Kroger vs Walmart (identical product)**")
                    show_df(x)
            st.markdown("**Price by store**")
            ps = prices_by_store(key)
            if ps.empty:
                st.info("No current price at any store (not listed in the latest collection).")
            else:
                show_df(ps.style.format({"CURRENT_PRICE": "${:.2f}", "CURRENT_REGULAR_PRICE": "${:.2f}", "TRAILING_LOW_PRICE": "${:.2f}", "TRAILING_MEDIAN_PRICE": "${:.2f}", "CHANGE_4W_PCT": "{:+.1%}"}, na_rep="—"))
            hist = price_history(key)
            if len(hist) > 1:
                st.markdown("**Price history (weekly; missing weeks were not collected)**")
                st.line_chart(hist.set_index("PRICE_WEEK")[["TYPICAL_PRICE", "LOWEST_PRICE"]])
            if st.session_state.get("last_lookup") != key:
                st.session_state["last_lookup"] = key
                if record("lookup", f"{term} [{retailer}]", f"{key}: {c.get('PRODUCT_NAME', '')}") is False:
                    st.rerun()

# ---------------------------------------------------------------- Basket
with tab_basket:
    st.subheader("My basket")
    st.write("Type items one per line, give a Georgia ZIP code, and price the basket at the nearest Kroger stores and at Walmart. Then track it: every Sunday you'll see whether this is a good week to buy it.")
    c1, c2 = st.columns([2, 1])
    zip_code = c1.text_input("ZIP code (Georgia)", value="30318", max_chars=5, disabled=not active)
    max_stores = c2.number_input("Nearest Kroger stores to price", 1, 81, 10, disabled=not active)
    basket_text = st.text_area("Items", key="basket_text", height=160, placeholder="whole milk gallon\nlarge eggs\nJif creamy peanut butter\nCheerios\nbananas", disabled=not active)
    items = [x.strip() for x in (basket_text or "").splitlines() if x.strip()]
    if st.button("Price this basket", type="primary", disabled=not (items and active)):
        with st.spinner("Matching items and pricing stores..."):
            res = call_proc(f"{SEM}.SP_COMPARE_BASKET", json.dumps(items), zip_code or None, int(max_stores))
        st.session_state["basket_result"] = res
        best = (res or {}).get("best_single_store") or {}
        if record("basket", "\n".join(items) + f"\nZIP {zip_code}", json.dumps({"best": best, "items": res.get("items_requested")})) is False:
            st.rerun()
    res = st.session_state.get("basket_result")
    if res:
        st.caption(f"Prices as of {str(res.get('as_of'))[:10]}. {res.get('notes')}")
        best = res.get("best_single_store") or {}
        wal = res.get("walmart") or {}
        split = res.get("split") or {}
        m1, m2, m3 = st.columns(3)
        m1.metric("Best single store", f"{best.get('store', '—')}", f"${best.get('total', 0):.2f} for {best.get('items_found', 0)} of {res.get('items_requested')} items" if best else None)
        m2.metric("Walmart", f"${wal['total']:.2f}" if wal.get("total") is not None else "—", f"{wal.get('items_found', 0)} of {res.get('items_requested')} items" if wal else "no items priced")
        m3.metric("Split (Walmart + one Kroger)", f"${split['total']:.2f}" if split.get("total") is not None else "—", f"saves ${split.get('savings_vs_best_single_store') or 0:.2f}" if split else None)
        st.markdown("**Store totals** (compare only rows with the same items found)")
        show_df(pd.DataFrame(res.get("store_totals") or []))
        st.markdown("**What was matched** — a match is the best search hit with a current price")
        rows = [{"item": m.get("item"), "Kroger match": (m.get("kroger") or {}).get("product"), "Kroger size": (m.get("kroger") or {}).get("size"),
                 "Walmart match": (m.get("walmart") or {}).get("product"), "identical at both": bool((m.get("kroger") or {}).get("identical_at_walmart"))}
                for m in res.get("matches") or []]
        show_df(pd.DataFrame(rows))
        if split.get("lines"):
            st.markdown("**Where to buy each item in the split**")
            show_df(pd.DataFrame(split["lines"]))
        if res.get("missing"):
            st.warning("Not priced: " + "; ".join(f"{m['item']} ({', '.join(v for k, v in m.items() if k != 'item' and v)})" for m in res["missing"]))

        # ---- track this basket (Snowflake Scripts/Guest/03_guest_basket_watch.sql)
        st.markdown("**Track this basket's price**")
        track_ret = best.get("retailer") or "kroger"
        track_other = "walmart" if track_ret == "kroger" else "kroger"
        track_items = [{"item": m.get("item"), "product_key": (m.get(track_ret) or m.get(track_other) or {}).get("product_key")}
                       for m in res.get("matches") or []]
        n_keyed = sum(1 for t in track_items if t["product_key"])
        t1, t2, t3 = st.columns([2, 1, 1])
        track_name = t1.text_input("Basket name", key="track_name", placeholder="e.g. weekly", max_chars=60, disabled=not active)
        good_pct = t2.slider("Good time = cheaper than this % of weeks", 60, 90, 75, step=5, disabled=not active)
        incl_sim = t3.checkbox("Suggest look-alikes", value=True, disabled=not active)
        st.caption(f"Tracks the {n_keyed} matched products. Checked every Sunday; next time you sign in you'll see whether the basket, "
                   f"an item, or a look-alike that is cheaper per unit is cheaper than {good_pct}% of its last 12 weeks. Up to 3 baskets, 15 items each.")
        if st.button("Track this basket", disabled=not (active and track_name and n_keyed)):
            r = call_proc(f"{APP}.SP_GUEST_TRACK_BASKET", g["session_id"], track_name, json.dumps(track_items), int(good_pct), bool(incl_sim))
            ok = record("basket_watch", f"track {track_name}", json.dumps(r)[:500])
            if r.get("ok"):
                st.session_state["watch_pick"] = r.get("list_name")
                st.session_state.pop("basket_watches", None)
                st.session_state.pop("basket_status", None)
                st.success(f"Tracking '{r.get('list_name')}': {r.get('items_tracked')} of {r.get('items')} items, checked every Sunday.")
            else:
                msg = {"too_many_baskets": f"You can track up to {r.get('max_baskets')} baskets. Stop tracking one below first.",
                       "too_many_items": f"A tracked basket can have up to {r.get('max_items')} items.",
                       "guest_capacity": "Basket tracking for guests is full right now. Pricing still works.",
                       "basket_watch_disabled": "Basket tracking is paused for guests right now."}.get(r.get("reason"), "Couldn't track this basket right now.")
                st.warning(msg)
            if ok is False:
                st.rerun()

    # ---- tracked baskets (loaded once per session; refreshed on changes, so reruns cost nothing)
    if active:
        st.divider()
        st.subheader("Tracked baskets")
        if "basket_watches" not in st.session_state:
            lw = call_proc(f"{APP}.SP_GUEST_LIST_BASKET_WATCHES", g["session_id"]) or {}
            st.session_state["basket_watches"] = lw.get("baskets") or []
            record("basket_watch", "list", str(len(st.session_state["basket_watches"])))
        watches = st.session_state["basket_watches"]
        if not watches:
            st.caption("No tracked baskets yet. Price a basket above, then use Track this basket.")
        else:
            def _num(v):  # NULLs arrive as None or NaN
                return None if v is None or (isinstance(v, float) and pd.isna(v)) else v

            names = [w["list_name"] for w in watches]
            by_name = {w["list_name"]: w for w in watches}
            pick_default = names.index(st.session_state["watch_pick"]) if st.session_state.get("watch_pick") in names else 0
            wpick = st.selectbox("Basket", names, index=pick_default,
                                 format_func=lambda n: n + (f"  ·  {by_name[n]['new_alerts']} new" if by_name[n].get("new_alerts") else ""))
            cached = st.session_state.get("basket_status") or {}
            if cached.get("list_name") != wpick:
                cached = call_proc(f"{APP}.SP_GUEST_BASKET_STATUS", g["session_id"], wpick) or {}
                st.session_state["basket_status"] = cached
                if record("basket_watch", f"status {wpick}", json.dumps(cached.get("basket") or {})[:500]) is False:
                    st.rerun()
            stat = cached
            if not stat.get("ok", True):
                st.info("Basket tracking isn't available in this session.")
            else:
                alerts = stat.get("alerts") or []
                if alerts:
                    st.info("**Good time to buy**\n\n" + "\n".join(f"- {a['detail']}" for a in alerts))
                    if st.button("Mark seen", key="ack_basket"):
                        call_proc(f"{APP}.SP_GUEST_ACK_BASKET_ALERTS", g["session_id"], wpick)
                        record("basket_watch", f"ack {wpick}")
                        st.session_state.pop("basket_status", None)
                        st.session_state.pop("basket_watches", None)
                        st.rerun()
                b = stat.get("basket") or {}
                pct, weeks = _num(b.get("cheaper_than_pct")), _num(b.get("weeks")) or 0
                if b and pct is not None:
                    ranked_n, all_n = b.get("ranked_items") or b.get("items"), b.get("items")
                    scope = "this week" if ranked_n == all_n else f"for the {ranked_n} of {all_n} items with enough history"
                    headline = f"${b['current_total']:.2f} {scope}: cheaper than {pct:.0f}% of the last {weeks} weeks"
                    if b.get("is_good_time"):
                        st.success(f"{headline}. Good time to buy.")
                    elif weeks < 6:
                        st.info(f"{headline}. Too little history to call it yet (needs 6 weeks).")
                    else:
                        st.info(f"{headline}. Typical week (good time = {b.get('good_pct')}% or more).")
                    k1, k2, k3 = st.columns(3)
                    k1.metric("Low", f"${b['low_total']:.2f}")
                    k2.metric("Typical (median)", f"${b['median_total']:.2f}")
                    k3.metric("High", f"${b['high_total']:.2f}")
                    if ranked_n != all_n:
                        new_items = [it.get("item") for it in stat.get("items") or [] if not it.get("ranked")]
                        st.caption(f"Not ranked yet, too new in the data (needs 6 weeks of prices): {', '.join(new_items)}. "
                                   + (f"Whole basket this week: ${b['full_total']:.2f}." if b.get("full_total") is not None else ""))
                else:
                    st.caption("No complete week of prices for this basket yet.")
                trend = pd.DataFrame(stat.get("trend") or [])
                if not trend.empty and "complete" in trend:
                    trend = trend[trend["complete"]]
                if len(trend) > 1:
                    trend["week"] = pd.to_datetime(trend["week"])
                    trend = trend.set_index("week")[["total"]].rename(columns={"total": "Basket total"})
                    if b.get("median_total") is not None:
                        trend["Typical (median)"] = b["median_total"]
                    st.line_chart(trend)
                    st.caption("Weekly total of the ranked products (Kroger: median across stores; Walmart: national price). "
                               "An item's last price carries over a week it was not collected.")
                irows = [{"item": it.get("item"), "product": it.get("product"), "retailer": str(it.get("retailer") or "").title(),
                          "price": _num(it.get("price")), "cheaper than % of weeks": _num(it.get("cheaper_than_pct")), "weeks": _num(it.get("weeks")),
                          "signal": str(it.get("recommendation") or "").replace("_", " ").title(),
                          "good time": "yes" if it.get("is_good_time") else "", "stock up": "yes" if it.get("stock_up") else ""}
                         for it in stat.get("items") or []]
                if irows:
                    st.markdown("**Items**")
                    show_df(pd.DataFrame(irows))
                srows = [{"instead of": s_.get("for_item"), "look-alike": s_.get("product"), "size": s_.get("size"),
                          "price": _num(s_.get("price")), "less per unit": f"{s_.get('unit_saving_pct')}% per {s_.get('unit_basis')}",
                          "cheaper than % of weeks": _num(s_.get("cheaper_than_pct"))} for s_ in stat.get("similar") or []]
                if srows:
                    st.markdown("**Look-alike better buys** (same product type and retailer, cheaper per unit, at a good price now)")
                    show_df(pd.DataFrame(srows))
                if st.button("Stop tracking this basket", key="untrack_basket"):
                    call_proc(f"{APP}.SP_GUEST_UNTRACK_BASKET", g["session_id"], wpick)
                    record("basket_watch", f"untrack {wpick}")
                    for k in ("watch_pick", "basket_status", "basket_watches"):
                        st.session_state.pop(k, None)
                    st.rerun()

# ---------------------------------------------------------------- Deals
with tab_deals:
    st.subheader("Deals & trends")
    drops, cats = deals_tables()
    d1, d2 = st.columns([3, 2])
    with d1:
        h, f = st.columns([3, 1])
        h.markdown("**Genuine deals this week** (promo well below the usual regular price, not routine). One row per product; open a row to see which stores.")
        deal_retailer = f.selectbox("Retailer", ["both", "kroger", "walmart"], key="deal_retailer", label_visibility="collapsed")
        render_deals(deals_by_product(None if deal_retailer == "both" else deal_retailer))
    with d2:
        st.markdown("**Biggest 4-week price drops (food, typical store)**")
        show_df(drops)
    st.markdown("**Category price index** (base week = 100; gaps are weeks with no collection)")
    cat = st.selectbox("Category", cats, index=cats.index("Dairy") if "Dairy" in cats else 0)
    idx = category_index(cat)
    if not idx.empty:
        st.line_chart(idx.pivot(index="PRICE_WEEK", columns="RETAILER", values="PRICE_INDEX"))
    if active and st.session_state.get("last_deals_cat") != cat:
        st.session_state["last_deals_cat"] = cat
        record("deals_view", cat)

st.caption("Guest edition · prices are observations from the retailers' public APIs, not offers · built by the owner as a portfolio project.")
