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
    arg_sql = ", ".join("NULL" if a is None else lit(a) if isinstance(a, str) else ("TRUE" if a is True else "FALSE" if a is False else str(a)) for a in args)
    df = q(f"CALL {name}({arg_sql})")
    raw = df.iloc[0, 0]
    return json.loads(raw) if isinstance(raw, str) else raw


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


def sign_up_gate() -> None:
    st.title("Grocery Value")
    st.caption("Kroger (81 Atlanta-area stores) and Walmart prices, a buy-now-or-wait signal, and an AI agent that answers in plain English.")
    c1, c2 = st.columns([3, 2])
    with c1:
        st.markdown(
            "**Try it as a guest.** Sign up with your name, email and LinkedIn profile and you get one session: "
            f"**{SESSION_MINUTES} minutes or {SESSION_CREDIT_CAP:g} Snowflake credits**, whichever comes first (about two agent questions "
            "plus unlimited lookups and basket pricing). Everyone together shares a weekly budget of "
            f"{WEEKLY_CREDIT_CAP:g} credits; when it is spent, the door closes until Monday. The meter in the sidebar shows where you stand.")
        with st.form("guest_signup"):
            a, b = st.columns(2)
            first = a.text_input("First name", max_chars=60)
            last = b.text_input("Last name", max_chars=60)
            email = st.text_input("Email", max_chars=120)
            linkedin = st.text_input("LinkedIn profile URL", placeholder="https://www.linkedin.com/in/your-handle", max_chars=200)
            consent = st.checkbox("I agree that my name, email, LinkedIn URL and my questions and clicks in this app are stored in the owner's Snowflake account "
                                  "so the owner can see how the app is used and follow up. No data is sold or shared.")
            go = st.form_submit_button("Start my guest session", type="primary")
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
                with st.spinner("Setting up your session..."):
                    try:
                        reg = call_proc(f"{APP}.SP_GUEST_REGISTER", email.strip().lower(), first.strip(), last.strip(), linkedin.strip(), True)
                        start = call_proc(f"{APP}.SP_GUEST_START_SESSION", reg["guest_id"])
                    except Exception as e:
                        st.error(f"Could not start a session: {str(e)[:300]}")
                        st.stop()
                g = {"guest_id": reg["guest_id"], "guest_username": reg.get("guest_username"), "first_name": first.strip(),
                     "session_id": start.get("session_id"), "started_at": start.get("started_at"), "expires_at": start.get("expires_at")}
                refresh_status(g, start)
                st.session_state["guest"] = g
                st.session_state["pending_wh_seconds"] = 0.0
                st.rerun()
    with c2:
        st.markdown("**What it can answer**")
        for fam, desc in FAMILIES.items():
            st.markdown(f"- **{fam}** — {desc}")
        st.caption(NOT_COVERED)
    st.stop()


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
def deals_tables() -> tuple[pd.DataFrame, pd.DataFrame, list]:
    genuine = q(f"""
        SELECT p.RETAILER, p.PRODUCT_NAME, s.STORE_NAME, sp.CURRENT_PRICE, sp.CURRENT_REGULAR_PRICE, sp.CURRENT_DISCOUNT_PCT
        FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_SUMMARY sp
        JOIN {MARTS}.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = sp.PRODUCT_KEY
        JOIN {MARTS}.DBT_DIM_STORE s ON s.STORE_ID = sp.STORE_ID
        WHERE sp.IS_CURRENTLY_LISTED AND sp.DEAL_QUALITY = 'GENUINE' AND p.IS_FOOD
        ORDER BY sp.CURRENT_DISCOUNT_PCT DESC LIMIT 25""")
    drops = q(f"""
        SELECT p.RETAILER, p.PRODUCT_NAME, r.MEDIAN_CURRENT_PRICE, r.MEDIAN_CHANGE_4W_PCT, r.REF_WEEK_4W
        FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_ROLLUP r
        JOIN {MARTS}.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = r.PRODUCT_KEY
        WHERE p.IS_FOOD AND r.MEDIAN_CHANGE_4W_PCT IS NOT NULL
        ORDER BY r.MEDIAN_CHANGE_4W_PCT LIMIT 25""")
    cats = q(f"SELECT DISTINCT COMMON_CATEGORY FROM {MARTS}.DBT_FCT_CATEGORY_PRICE_INDEX_WEEKLY WHERE IS_FOOD_CATEGORY ORDER BY 1")["COMMON_CATEGORY"].tolist()
    return genuine, drops, cats


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
    st.write("Type items one per line, give a Georgia ZIP code, and price the basket at the nearest Kroger stores and at Walmart. (Saving lists and price watches are for signed-in shoppers; guests can price and compare.)")
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

# ---------------------------------------------------------------- Deals
with tab_deals:
    st.subheader("Deals & trends")
    genuine, drops, cats = deals_tables()
    d1, d2 = st.columns(2)
    with d1:
        st.markdown("**Genuine deals this week** (promo well below the usual regular price, not routine)")
        show_df(genuine)
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
