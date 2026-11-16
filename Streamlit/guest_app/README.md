# Grocery Value — public guest edition

A copy of the shopper app that people **without a Snowflake account** can use.
It runs on Streamlit Community Cloud (free), connects to Snowflake as the
service user `SVC_GUEST_APP` (role `GROCERY_GUEST_ROLE`, warehouse
`GROCERY_GUEST_WH`), and gates everything behind a guest sign-up.

| | |
|---|---|
| App code | `Streamlit/guest_app/streamlit_app.py` (+ `requirements.txt`) |
| Snowflake side | `Snowflake Scripts/Guest/01_guest_access.sql` |
| Guest data | `GROCERY_APP.GUEST_USER`, `GUEST_SESSION`, `GUEST_INTERACTION`, `GUEST_SETTING` (hybrid tables) |
| Limits | one session per guest per ET week: **60 minutes or 0.25 credits**; **5 credits per week** for all guests together |
| Stops | app meter (estimate) → ops alert `ALERT_GUEST_BUDGET` (billed credits, ≤ 3 h lag) → resource monitor `GROCERY_GUEST_MONITOR` (weekly 5, suspends the warehouse) |
| Visitor message | sidebar meter; banner on session cap, time expiry, weekly cap, or manual close, with the Monday 00:00 ET return time |

## What a visitor sees

1. Sign-up form: first name, last name, email, LinkedIn profile URL, consent
   checkbox (what is stored and why). All four fields are required and
   validated; without consent nothing is stored.
2. `SP_GUEST_REGISTER` upserts the guest by email and returns a guest
   username (`guest_xxxxxx`); `SP_GUEST_START_SESSION` opens the week's one
   session (or refuses with a reason). The username and the meter sit in the
   sidebar.
3. The four tabs. Every question, lookup, basket pricing and deals view calls
   `SP_GUEST_RECORD`, which logs the interaction (input, output head, tokens,
   model, warehouse seconds, estimated credits) and returns the new status.
   The app disables inputs and shows the banner the moment a limit is hit.
4. Guests cannot save lists or set price watches (that state would belong to
   the shared service user); they can price baskets and compare.

## How credits are estimated

`SP_GUEST_RECORD`: `tokens × rate_credits_per_m_tokens / 1e6` (or
`fallback_credits_per_question` when the agent stream reports no usage) +
`warehouse seconds / 3600 × wh_credits_per_hour` + a small per-interaction
overhead. Rates live in `GUEST_SETTING`; the observed blended agent rate was
0.57 credits per million tokens and 0.10 credits per question (30 days to
2026-11-16). Re-derive monthly:

```sql
SELECT SUM(TOKEN_CREDITS)/SUM(TOKENS)*1e6 AS credits_per_m, AVG(TOKEN_CREDITS) AS per_request
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
WHERE AGENT_NAME = 'GROCERY_VALUE_AGENT' AND START_TIME >= DATEADD(day, -30, CURRENT_TIMESTAMP());
```

The truth is `GROCERY_OPS.V_CHECK_GUEST_SPEND` (billed agent tokens +
attributed warehouse compute for `SVC_GUEST_APP` this week, next to the app's
estimate). It is a cost-domain sensor, so the daily cost agent sees it, and
the hourly alert closes guest access when billed spend reaches 5.

## Deploy on Streamlit Community Cloud (owner, once)

1. Run the Snowflake script (ACCOUNT-LEVEL section needs the public key from
   `~/.snowflake/guest_app_rsa_key.pub` pasted over `<PUBLIC_KEY>`). Done 2026-11-16.
2. https://share.streamlit.io → **Create app** → **Deploy a public app from GitHub**:
   repository `jdsmithwes/GroceryPriceProjectDBT`, branch `main`, main file
   `Streamlit/guest_app/streamlit_app.py`. Pick a URL such as
   `grocery-value.streamlit.app`.
3. **Advanced settings → Secrets**: paste the contents of
   `~/.snowflake/guest_app_secrets.toml` (written by the deploy session; holds
   the private key, never in the repo). Shape:

   ```toml
   [snowflake]
   account   = "<org-account>"
   user      = "SVC_GUEST_APP"
   role      = "GROCERY_GUEST_ROLE"
   warehouse = "GROCERY_GUEST_WH"
   private_key = """
   -----BEGIN PRIVATE KEY-----
   ...
   -----END PRIVATE KEY-----
   """
   ```
4. Deploy. First load installs `requirements.txt` (about two minutes). Sign up
   once yourself to confirm the meter moves and `GUEST_INTERACTION` fills.
5. Share the `*.streamlit.app` link. Nothing else to open: the Snowflake side
   is reachable only through the four `SP_GUEST_*` procedures and read-only marts.

Community Cloud puts an app to sleep after inactivity; the first visitor
wakes it (about 30 seconds). Streamlit's free tier is the only non-Snowflake
component and costs nothing.

## Operate

- Close early: `CALL GROCERY_APP.SP_GUEST_SET_ACCESS(FALSE, 'why');` reopen:
  `SP_GUEST_SET_ACCESS(TRUE, 'why')`. The hourly alert does the first
  automatically at the billed cap, until Monday 00:00 ET.
- Block a guest: `UPDATE GROCERY_APP.GUEST_USER SET STATUS = 'blocked' WHERE EMAIL = '…';`
- Who signed up, what they asked: `GUEST_USER`, `GUEST_SESSION`, `GUEST_INTERACTION`;
  the week's totals: `GROCERY_APP.V_GUEST_WEEK`.
- Change limits: `UPDATE GROCERY_APP.GUEST_SETTING SET VALUE = … WHERE KEY = …`
  (session cap, weekly cap, minutes, rates). The resource monitor's quota is
  separate: `ALTER RESOURCE MONITOR GROCERY_GUEST_MONITOR SET CREDIT_QUOTA = …`.
- Rotate the key: new pair → `ALTER USER SVC_GUEST_APP SET RSA_PUBLIC_KEY_2 = …`,
  update the Streamlit secret, then unset the old key.

## Privacy

Stored: name, email, LinkedIn URL, consent time, and the visitor's questions
and clicks with the answers' first 4,000 characters, in the owner's Snowflake
account. Not shared or sold. Delete a guest: `DELETE FROM GUEST_INTERACTION /
GUEST_SESSION / GUEST_USER WHERE GUEST_ID = …`.
