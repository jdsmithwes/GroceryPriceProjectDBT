"""
Grocery Value — Streamlit in Snowflake app over the grocery value agent.

Four tabs:
  Ask          chat with GROCERY_VALUE_AGENT (Cortex Agent REST API); example
               questions mirror the semantic view's verified queries
  Look up      find a product (Cortex Search) and see its price at every
               Kroger store and at Walmart, its history, and its buy signal
  My basket    build or load a list, price it at the nearest stores
               (SP_COMPARE_BASKET), save it, and dig into each item
  Deals & trends   genuine deals, biggest drops, category price index

Deploy: Streamlit/deploy_streamlit.sql. Runs on GROCERY_AGENT_WH as the
viewer's role (needs GROCERY_AGENT_USER grants from 01/04/06).
"""

import json
from datetime import date

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

try:  # only available inside Streamlit in Snowflake
    import _snowflake
except ImportError:  # local preview: chat is disabled, SQL tabs still work
    _snowflake = None

# The Streamlit runtime inside Snowflake predates st.chat_input/st.chat_message
# (1.24), st.dataframe(hide_index=) (1.23) and st.rerun (1.27), so the app
# uses only older APIs: a form for questions, markdown for the conversation,
# and the wrappers below.
def show_df(df, **kwargs):
    kwargs.setdefault("use_container_width", True)
    try:
        st.dataframe(df, hide_index=True, **kwargs)
    except TypeError:
        st.dataframe(df, **kwargs)


def rerun():
    (getattr(st, "rerun", None) or st.experimental_rerun)()


DB = "GROCERYDBTPROJECT"
MARTS = f"{DB}.GROCERY_MARTS"
SEM = f"{DB}.GROCERY_SEMANTIC"
APP = f"{DB}.GROCERY_APP"
AGENT = "GROCERY_VALUE_AGENT"

st.set_page_config(page_title="Grocery Value", page_icon="🛒", layout="wide")
session = get_active_session()

# What the app can answer — shown on every tab's sidebar, and the example
# questions come from the semantic view's verified queries.
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
    "What shelf-stable items are worth stocking up on right now?",
    "Are dairy prices going up at Kroger?",
    "How much cheaper are store brands than national brands per ounce, by category?",
    "What turkey products do you have prices for, grouped by type?",
]
NOT_COVERED = "Not covered: nutrition advice, other retailers, coupons and loyalty prices, delivery fees, forecasts beyond 6 weeks, live stock guarantees."


# --------------------------------------------------------------------------
# data helpers
# --------------------------------------------------------------------------
def q(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


def lit(s: str) -> str:
    """SQL string literal (Cortex Search needs a constant request)."""
    return "'" + str(s).replace("'", "''") + "'"


@st.cache_data(ttl=3600)
def data_as_of() -> str:
    df = q(f"SELECT MAX(DATA_AS_OF)::DATE AS D FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_ROLLUP")
    return str(df["D"].iloc[0]) if not df.empty else "unknown"


@st.cache_data(ttl=600)
def search_products(term: str, retailer: str | None, limit: int = 15) -> pd.DataFrame:
    req = {"query": term, "columns": ["PRODUCT_KEY", "PRODUCT_NAME", "BRAND", "SIZE_TEXT", "RETAILER", "PRODUCT_TYPE", "HAS_EXACT_MATCH"], "limit": limit}
    if retailer:
        req["filter"] = {"@eq": {"RETAILER": retailer}}
    df = q(f"SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('{SEM}.PRODUCT_SEARCH', {lit(json.dumps(req))}) AS R")
    hits = json.loads(df["R"].iloc[0]).get("results", []) if not df.empty else []
    return pd.DataFrame(hits)


@st.cache_data(ttl=600)
def prices_by_store(product_key: str) -> pd.DataFrame:
    return q(f"""
        SELECT s.STORE_NAME, s.CITY, s.ZIP_CODE, sp.CURRENT_PRICE, sp.CURRENT_REGULAR_PRICE, sp.IS_ON_PROMO,
               sp.DEAL_QUALITY, sp.TRAILING_LOW_PRICE, sp.TRAILING_MEDIAN_PRICE, sp.IS_AT_HISTORIC_LOW,
               sp.CHANGE_4W_PCT, sp.WEEKS_OBSERVED, sp.DATA_AS_OF
        FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_SUMMARY sp
        JOIN {MARTS}.DBT_DIM_STORE s ON s.STORE_ID = sp.STORE_ID
        WHERE sp.PRODUCT_KEY = {lit(product_key)} AND sp.IS_CURRENTLY_LISTED
        ORDER BY sp.CURRENT_PRICE, s.STORE_NAME
    """)


@st.cache_data(ttl=600)
def price_history(product_key: str) -> pd.DataFrame:
    return q(f"""
        SELECT PRICE_WEEK, MEDIAN(EFFECTIVE_PRICE) AS TYPICAL_PRICE, MIN(EFFECTIVE_PRICE) AS LOWEST_PRICE, COUNT(*) AS STORES
        FROM {MARTS}.DBT_FCT_PRICE_WEEKLY WHERE PRODUCT_KEY = {lit(product_key)}
        GROUP BY 1 ORDER BY 1
    """)


@st.cache_data(ttl=600)
def buy_signal(product_key: str) -> pd.DataFrame:
    return q(f"""
        SELECT RULE_SIGNAL, RECOMMENDATION, CURRENT_PRICE, HISTORY_LOW_PRICE, HISTORY_MEDIAN_PRICE, HISTORY_HIGH_PRICE,
               WEEKS_OBSERVED, FORECAST_DIRECTION, FORECAST_LOW_PRICE_BOUNDED, RETURN_BY_WEEK, FORECAST_INTERVAL_WIDTH_PCT,
               IS_STOCK_UP_CANDIDATE
        FROM {MARTS}.DBT_FCT_BUY_RECOMMENDATION WHERE PRODUCT_KEY = {lit(product_key)}
    """)


@st.cache_data(ttl=600)
def product_card(product_key: str) -> pd.DataFrame:
    return q(f"""
        SELECT PRODUCT_NAME, BRAND, SIZE_TEXT, RETAILER, PRODUCT_TYPE, PRIMARY_COMMON_CATEGORY, IMAGE_URL, PACKAGE_QUANTITY, UNIT_BASIS,
               PARSE_CONFIDENCE, IS_STORE_BRAND, HAS_EXACT_MATCH, UPC_A
        FROM {MARTS}.DBT_DIM_PRODUCT WHERE PRODUCT_KEY = {lit(product_key)}
    """)


@st.cache_data(ttl=600)
def cross_retailer(upc_a: str) -> pd.DataFrame:
    return q(f"""
        SELECT PRODUCT_NAME, WALMART_PRICE, KROGER_MIN_PRICE, KROGER_MEDIAN_PRICE, KROGER_CHEAPEST_STORE_NAME, CHEAPER_RETAILER, SAVINGS_VS_KROGER_MIN
        FROM {MARTS}.DBT_FCT_CROSS_RETAILER_PRICE_COMPARISON WHERE UPC_A = {lit(upc_a)}
    """)


def call_proc(name: str, *args) -> dict:
    arg_sql = ", ".join("NULL" if a is None else lit(a) if isinstance(a, str) else str(a) for a in args)
    df = q(f"CALL {name}({arg_sql})")
    raw = df.iloc[0, 0]
    return json.loads(raw) if isinstance(raw, str) else raw


def _text_from_json(obj) -> tuple[str, list[str]]:
    """Non-streaming agent response: {"content": [{"type": "text", ...}, {"type": "tool_use", ...}]}
    or a list of such messages."""
    texts, tools = [], []
    items = obj if isinstance(obj, list) else [obj]
    # a serialized event stream: [{"event": "response.text.delta", "data": {...}}, ...]
    if items and all(isinstance(it, dict) and "event" in it for it in items):
        deltas, fulls = [], []
        for it in items:
            ev, data = it.get("event"), it.get("data") or {}
            if isinstance(data, str):
                try:
                    data = json.loads(data)
                except ValueError:
                    data = {}
            if ev == "response.text.delta":
                deltas.append(data.get("text", ""))
            elif ev == "response.text":
                fulls.append(data.get("text", ""))
            elif ev and str(ev).startswith("response.tool_use"):
                name = data.get("name") or data.get("tool_name")
                if name and name not in tools:
                    tools.append(name)
        return ("".join(deltas).strip() or "".join(fulls).strip()), tools
    for it in items:
        if not isinstance(it, dict):
            continue
        content = it.get("content")
        if isinstance(content, str):
            texts.append(content)
        for c in content if isinstance(content, list) else []:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "text" and c.get("text"):
                texts.append(c["text"])
            elif c.get("type") == "tool_use":
                name = (c.get("tool_use") or {}).get("name") or c.get("name")
                if name and name not in tools:
                    tools.append(name)
        if it.get("type") == "text" and it.get("text"):
            texts.append(it["text"])
    return "\n".join(texts).strip(), tools


def _text_from_sse(body: str) -> tuple[str, list[str]]:
    deltas, fulls, tools, event = [], [], [], None  # text arrives as deltas AND a final full copy
    for raw in body.splitlines():
        if raw.startswith("event:"):
            event = raw[6:].strip()
        elif raw.startswith("data:"):
            payload = raw[5:].strip()
            if not payload or payload == "[DONE]":
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
            elif event is None and isinstance(data, dict):
                # some proxies drop the event lines; fall back on payload shape
                if data.get("type") == "text" and data.get("text"):
                    deltas.append(data["text"])
                elif "delta" in data:
                    for c in (data["delta"] or {}).get("content", []) or []:
                        if c.get("type") == "text":
                            deltas.append(c.get("text", ""))
    return ("".join(deltas).strip() or "".join(fulls).strip()), tools


def ask_agent(messages: list[dict]) -> tuple[str, list[str]]:
    """Call the Cortex Agent and return (answer text, tools used). Handles both
    the event-stream and the plain-JSON response shapes; shows the raw
    response when neither yields text so the cause is visible in the UI."""
    if _snowflake is None:
        return "Chat is only available when this app runs inside Snowflake.", []
    resp = _snowflake.send_snow_api_request(
        "POST", f"/api/v2/databases/{DB}/schemas/GROCERY_SEMANTIC/agents/{AGENT}:run",
        {}, {}, {"messages": messages}, None, 180000,
    )
    status = resp.get("status")
    content = resp.get("content", "")
    if status != 200:
        return f"The agent returned an error ({status}): {str(content)[:800]}", []
    text, tools = "", []
    parsed = None
    if isinstance(content, (dict, list)):
        parsed = content
    else:
        try:
            parsed = json.loads(content)
        except (TypeError, ValueError):
            parsed = None
    if parsed is not None:
        text, tools = _text_from_json(parsed)
    if not text:
        text, tools = _text_from_sse(str(content))
    if not text:
        with st.expander("The agent returned no text — raw response (for debugging)"):
            st.code(f"status={status} type={type(content).__name__}\n" + str(content)[:3000])
        text = "The agent returned no text."
    # every exchange goes to the run log (Phase 6), with the raw response head
    # when parsing failed, so failures can be diagnosed from SQL
    try:
        raw_head = "" if tools or not text.startswith("The agent returned") else f"status={status} type={type(content).__name__} " + str(content)[:6000]
        session.sql(
            f"INSERT INTO {APP}.AGENT_RUN_LOG (SHOPPER_ID, SOURCE, QUESTION, TOOLS) "
            f"SELECT CURRENT_USER(), 'app', {lit(messages[-1]['content'][0]['text'][:2000])}, {lit(json.dumps({'tools': tools, 'raw': raw_head}))}"
        ).collect()
    except Exception:
        pass
    return text, tools


# --------------------------------------------------------------------------
# layout
# --------------------------------------------------------------------------
st.title("Grocery Value")
st.caption(f"Kroger (81 Atlanta-area stores, prices differ by store) and Walmart (national online). Prices as of {data_as_of()}.")

with st.sidebar:
    st.header("What this app can answer")
    for fam, desc in FAMILIES.items():
        st.markdown(f"**{fam}** — {desc}")
    st.caption(NOT_COVERED)
    st.divider()
    st.caption("History has no data for Oct 12 – Nov 8, 2026. Walmart is a ~1,400-item catalog slice. Availability is as of the last collection, not live.")

tab_ask, tab_lookup, tab_basket, tab_deals = st.tabs(["Ask", "Look up an item", "My basket", "Deals & trends"])

# ---------------------------------------------------------------- Ask
with tab_ask:
    st.subheader("Ask the grocery value agent")
    st.write("Try one of these, or type your own. The agent states the as-of date, the store a Kroger price applies to, and whether a Kroger–Walmart comparison is the identical product.")
    cols = st.columns(2)
    for i, ex in enumerate(EXAMPLE_QUESTIONS):
        if cols[i % 2].button(ex, key=f"ex{i}", use_container_width=True):
            st.session_state["pending_question"] = ex

    if "chat" not in st.session_state:
        st.session_state["chat"] = []  # list of {"role", "text", "tools"}

    with st.form("ask_form", clear_on_submit=True):
        typed = st.text_input("Your question", placeholder="Ask about prices, deals, stores, timing, or a shopping list")
        submitted = st.form_submit_button("Ask")
    question = (typed.strip() if submitted and typed else None) or st.session_state.pop("pending_question", None)

    if question:
        st.session_state["chat"].append({"role": "user", "text": question})
        api_messages = [{"role": m["role"], "content": [{"type": "text", "text": m["text"]}]} for m in st.session_state["chat"]]
        with st.spinner("Checking prices..."):
            answer, tools = ask_agent(api_messages)
        st.session_state["chat"].append({"role": "assistant", "text": answer, "tools": tools})

    for m in st.session_state["chat"]:
        if m["role"] == "user":
            st.markdown(f"**You:** {m['text']}")
        else:
            st.markdown(m["text"])
            if m.get("tools"):
                st.caption("Tools used: " + ", ".join(m["tools"]))
            st.markdown("---")
    if st.session_state["chat"] and st.button("Clear conversation"):
        st.session_state["chat"] = []
        rerun()

# ---------------------------------------------------------------- Look up
with tab_lookup:
    st.subheader("Look up an item by store")
    st.write("Find a product, then see its price at every Kroger store and at Walmart, its history, and whether now is a good time to buy.")
    c1, c2 = st.columns([3, 1])
    term = c1.text_input("Product", placeholder="e.g. Jif creamy peanut butter, whole turkey, Kroger large eggs")
    retailer = c2.selectbox("Retailer", ["both", "kroger", "walmart"])
    if term:
        hits = search_products(term, None if retailer == "both" else retailer)
        if hits.empty:
            st.info("No matching products.")
        else:
            hits["label"] = hits.apply(lambda r: f"{r['RETAILER']} · {r['PRODUCT_NAME']}" + (f" · {r['SIZE_TEXT']}" if r.get("SIZE_TEXT") else "") + (f"  [{r['PRODUCT_TYPE']}]" if r.get("PRODUCT_TYPE") else ""), axis=1)
            choice = st.selectbox("Matches (best first)", hits["label"].tolist())
            key = hits.loc[hits["label"] == choice, "PRODUCT_KEY"].iloc[0]
            card = product_card(key)
            if not card.empty:
                c = card.iloc[0]
                a, b = st.columns([1, 3])
                if c.get("IMAGE_URL"):
                    a.image(c["IMAGE_URL"], width=160)
                b.markdown(f"**{c['PRODUCT_NAME']}**  \n{c.get('BRAND') or ''} · {c.get('SIZE_TEXT') or ''} · {c.get('PRIMARY_COMMON_CATEGORY') or ''}"
                           + (f" · type: {c['PRODUCT_TYPE']}" if c.get("PRODUCT_TYPE") else "")
                           + (" · store brand" if c.get("IS_STORE_BRAND") else "")
                           + (f"  \nAlso sold at the other retailer (UPC {c['UPC_A']})" if c.get("HAS_EXACT_MATCH") else ""))
                if c.get("PACKAGE_QUANTITY") and c.get("UNIT_BASIS"):
                    b.caption(f"Package: {c['PACKAGE_QUANTITY']:g} {c['UNIT_BASIS']} (size parse confidence: {c['PARSE_CONFIDENCE']})")

            sig = buy_signal(key)
            if not sig.empty:
                s = sig.iloc[0]
                m1, m2, m3, m4 = st.columns(4)
                m1.metric("Typical price now", f"${s['CURRENT_PRICE']:.2f}" if pd.notna(s["CURRENT_PRICE"]) else "—")
                m2.metric("Recommendation", str(s["RECOMMENDATION"]).replace("_", " ").title())
                m3.metric("Vs its own history", str(s["RULE_SIGNAL"]).replace("_", " ").title(), help=f"low ${s['HISTORY_LOW_PRICE']} · median ${s['HISTORY_MEDIAN_PRICE']} · high ${s['HISTORY_HIGH_PRICE']} over {s['WEEKS_OBSERVED']} observed weeks")
                fc = f"{s['FORECAST_DIRECTION']}" + (f", return by {s['RETURN_BY_WEEK']}" if pd.notna(s["RETURN_BY_WEEK"]) else "")
                m4.metric("6-week forecast", fc if s["FORECAST_DIRECTION"] != "NONE" else "none", help="Forecasts exist only for products carried by both retailers, floored at the observed low.")
                if s["WEEKS_OBSERVED"] is not None and s["WEEKS_OBSERVED"] < 8:
                    st.caption(f"Only {s['WEEKS_OBSERVED']} weeks of history — treat the signal as tentative.")

            if c.get("HAS_EXACT_MATCH") and c.get("UPC_A"):
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

# ---------------------------------------------------------------- Basket
with tab_basket:
    st.subheader("My basket")
    st.write("Type items one per line (or load a saved list), give a ZIP code, and price the basket at the nearest Kroger stores and at Walmart. Then dig into any item.")
    try:
        profile = call_proc(f"{APP}.SP_GET_PROFILE")
    except Exception:
        profile = {}
    prefs = profile.get("preferences") or {}
    saved_lists = [l["list_name"] for l in (profile.get("lists") or [])]

    c1, c2, c3 = st.columns([2, 1, 1])
    zip_code = c1.text_input("ZIP code (Georgia)", value=prefs.get("home_zip") or "", max_chars=5)
    max_stores = c2.number_input("Nearest Kroger stores to price", 1, 81, 10)
    loaded = c3.selectbox("Load a saved list", ["(none)"] + saved_lists)
    if loaded != "(none)" and st.session_state.get("loaded_list") != loaded:
        lst = call_proc(f"{APP}.SP_GET_LIST", loaded)
        st.session_state["basket_text"] = "\n".join(lst.get("items") or [])
        st.session_state["loaded_list"] = loaded
    basket_text = st.text_area("Items", key="basket_text", height=160, placeholder="whole milk gallon\nlarge eggs\nJif creamy peanut butter\nCheerios\nbananas")
    items = [x.strip() for x in (basket_text or "").splitlines() if x.strip()]

    b1, b2, b3 = st.columns([1, 1, 2])
    run = b1.button("Price this basket", type="primary", disabled=not items)
    list_name = b3.text_input("Save as", value=loaded if loaded != "(none)" else "", placeholder="list name, e.g. weekly")
    if b2.button("Save list", disabled=not (items and list_name)):
        call_proc(f"{APP}.SP_SAVE_LIST", list_name, json.dumps(items))
        if zip_code:
            call_proc(f"{APP}.SP_SET_PREFERENCE", zip_code, None, None)
        st.success(f"Saved '{list_name}' ({len(items)} items).")

    if run:
        with st.spinner("Matching items and pricing stores..."):
            res = call_proc(f"{SEM}.SP_COMPARE_BASKET", json.dumps(items), zip_code or None, int(max_stores))
        st.session_state["basket_result"] = res
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

        st.markdown("**What was matched** — check these; a match is the best search hit with a current price")
        rows = []
        for m in res.get("matches") or []:
            k, w = m.get("kroger") or {}, m.get("walmart") or {}
            rows.append({"item": m.get("item"), "Kroger match": k.get("product"), "Kroger size": k.get("size"), "Walmart match": w.get("product"),
                         "identical at both": bool(k.get("identical_at_walmart"))})
        show_df(pd.DataFrame(rows))
        if split.get("lines"):
            st.markdown("**Where to buy each item in the split**")
            show_df(pd.DataFrame(split["lines"]))
        if res.get("missing"):
            st.warning("Not priced: " + "; ".join(f"{m['item']} ({', '.join(v for k, v in m.items() if k != 'item' and v)})" for m in res["missing"]))

        st.markdown("**Analyze an item from this basket**")
        match_keys = {f"{m['item']} → {(m.get('kroger') or {}).get('product')}": (m.get("kroger") or {}).get("product_key") for m in res.get("matches") or [] if (m.get("kroger") or {}).get("product_key")}
        match_keys.update({f"{m['item']} → Walmart: {(m.get('walmart') or {}).get('product')}": (m.get("walmart") or {}).get("product_key") for m in res.get("matches") or [] if (m.get("walmart") or {}).get("product_key")})
        if match_keys:
            pick = st.selectbox("Item", list(match_keys))
            pk = match_keys[pick]
            sig = buy_signal(pk)
            if not sig.empty:
                s = sig.iloc[0]
                st.write(f"Recommendation: **{str(s['RECOMMENDATION']).replace('_', ' ').title()}** — {str(s['RULE_SIGNAL']).replace('_', ' ').lower()} vs its own {s['WEEKS_OBSERVED']}-week history "
                         f"(low ${s['HISTORY_LOW_PRICE']}, median ${s['HISTORY_MEDIAN_PRICE']}); forecast: {s['FORECAST_DIRECTION']}"
                         + (f", return by {s['RETURN_BY_WEEK']}" if pd.notna(s["RETURN_BY_WEEK"]) else "")
                         + ("; shelf-stable and a good price — stock up." if s["IS_STOCK_UP_CANDIDATE"] else "."))
            ps = prices_by_store(pk)
            if not ps.empty:
                show_df(ps[["STORE_NAME", "CITY", "CURRENT_PRICE", "IS_ON_PROMO", "DEAL_QUALITY", "TRAILING_MEDIAN_PRICE", "IS_AT_HISTORIC_LOW"]])
            hist = price_history(pk)
            if len(hist) > 1:
                st.line_chart(hist.set_index("PRICE_WEEK")[["TYPICAL_PRICE", "LOWEST_PRICE"]])
            if st.button("Watch this item's price"):
                r = call_proc(f"{APP}.SP_WATCH_PRODUCT", pk, None)
                st.success(f"Watching {r.get('product')}: you'll be alerted at a historic low (checked weekly).")

# ---------------------------------------------------------------- Deals
with tab_deals:
    st.subheader("Deals & trends")
    d1, d2 = st.columns(2)
    with d1:
        st.markdown("**Genuine deals this week** (promo well below the usual regular price, not routine)")
        show_df(q(f"""
            SELECT p.RETAILER, p.PRODUCT_NAME, s.STORE_NAME, sp.CURRENT_PRICE, sp.CURRENT_REGULAR_PRICE, sp.CURRENT_DISCOUNT_PCT
            FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_SUMMARY sp
            JOIN {MARTS}.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = sp.PRODUCT_KEY
            JOIN {MARTS}.DBT_DIM_STORE s ON s.STORE_ID = sp.STORE_ID
            WHERE sp.IS_CURRENTLY_LISTED AND sp.DEAL_QUALITY = 'GENUINE' AND p.IS_FOOD
            ORDER BY sp.CURRENT_DISCOUNT_PCT DESC LIMIT 25
        """))
    with d2:
        st.markdown("**Biggest 4-week price drops (food, typical store)**")
        show_df(q(f"""
            SELECT p.RETAILER, p.PRODUCT_NAME, r.MEDIAN_CURRENT_PRICE, r.MEDIAN_CHANGE_4W_PCT, r.REF_WEEK_4W
            FROM {MARTS}.DBT_FCT_PRODUCT_PRICE_ROLLUP r
            JOIN {MARTS}.DBT_DIM_PRODUCT p ON p.PRODUCT_KEY = r.PRODUCT_KEY
            WHERE p.IS_FOOD AND r.MEDIAN_CHANGE_4W_PCT IS NOT NULL
            ORDER BY r.MEDIAN_CHANGE_4W_PCT LIMIT 25
        """))
    st.markdown("**Category price index** (base week = 100; gaps are weeks with no collection)")
    cats = q(f"SELECT DISTINCT COMMON_CATEGORY FROM {MARTS}.DBT_FCT_CATEGORY_PRICE_INDEX_WEEKLY WHERE IS_FOOD_CATEGORY ORDER BY 1")["COMMON_CATEGORY"].tolist()
    cat = st.selectbox("Category", cats, index=cats.index("Dairy") if "Dairy" in cats else 0)
    idx = q(f"SELECT RETAILER, PRICE_WEEK, PRICE_INDEX FROM {MARTS}.DBT_FCT_CATEGORY_PRICE_INDEX_WEEKLY WHERE COMMON_CATEGORY = {lit(cat)} ORDER BY 2")
    if not idx.empty:
        st.line_chart(idx.pivot(index="PRICE_WEEK", columns="RETAILER", values="PRICE_INDEX"))
