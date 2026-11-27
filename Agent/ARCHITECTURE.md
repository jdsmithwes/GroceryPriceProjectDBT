# Architecture review: is this design ready for many agent requests?

Written 2026-11-15 for the project owner, after Phases 1–5 of the grocery value
agent. The question asked: Databricks presents **Lakebase + LTAP** as the
architecture for agentic AI; what is the Snowflake equivalent, and does this
project match it?

## 1. What Databricks means by Lakebase and LTAP

- **LTAP** (Lake Transactional/Analytical Processing) is Databricks' name for
  putting transactional (OLTP) and analytical (OLAP) data on one storage layer
  with one catalog, so an agent can read analytical context and write
  transactional state without a pipeline between them
  ([Techzine](https://www.techzine.eu/news/analytics/142199/databricks-breaks-down-the-barrier-between-oltp-and-olap-with-ltap-architecture/),
  [Blocks & Files](https://www.blocksandfiles.com/data-management/2026/06/18/databricks-expands-lakehouse-to-unify-olap-and-oltp/5258373)).
- **Lakebase** is the transactional half: serverless Postgres with compute
  separated from storage, data and write-ahead log on object storage, cheap
  copy-on-write branches, synced with Delta tables and governed by Unity
  Catalog ([Databricks VLDB 2026 paper](https://www.vldb.org/pvldb/vol19/p4385-pandis.pdf),
  [Databricks blog](https://databricks.com/blog/operational-databases)).
- The agent story: analytics tables give the agent context; Lakebase holds the
  agent's own state (sessions, memory, actions) with ACID writes
  ([Capital One engineering](https://www.capitalone.com/software/blog/databricks-lakebase-unify-oltp-olap)).

So the pattern has four parts: **governed analytical context**, a
**transactional state store**, an **agent runtime**, and **one catalog and
security model over all of it**.

## 2. The Snowflake equivalents

| Role in LTAP | Databricks | Snowflake | Status in this project |
|---|---|---|---|
| Analytical context | Delta tables, materialized views | Dynamic tables (`GROCERY_MARTS`) | Built. 17 dynamic tables, 24h lag, self-refreshing |
| Business meaning for agents | Unity Catalog metric views | **Semantic views** (`GROCERY_SEMANTIC.DBT_SV_GROCERY_PRICING`) | Built. 10 logical tables, 9 verified queries, dbt-managed |
| Retrieval | Vector Search | **Cortex Search** (`PRODUCT_SEARCH`) | Built |
| Agent runtime | Mosaic AI Agent Framework / Genie | **Cortex Agents** + Snowflake Intelligence | Built (`GROCERY_VALUE_AGENT`) |
| Transactional state (Lakebase) | Lakebase (Postgres) | **Snowflake Postgres** (GA 2026-02-24, [release note](https://docs.snowflake.com/release-notes/2026/other/2026-02-24-snowflake-postgres-ga)) and **hybrid tables** (Unistore, row-store tables inside Snowflake SQL) | **Built 2026-11-15** as hybrid tables (`GROCERY_APP`, §4) |
| Agent memory | Lakebase tables | Hybrid tables; Snowflake's agent memory (public preview announced, [blog](https://www.snowflake.com/en/blog/building-reliable-applications/)); Redis Agent Memory on Marketplace ([Redis](https://redis.io/blog/how-redis-brings-persistent-memory-to-snowflake-cortex-agents/)) | Built: `SHOPPER_PREFERENCE`, lists, watches, feedback via agent tools |
| Catalog + security | Unity Catalog | Horizon: one RBAC model over tables, semantic views, search, agents | Built (`01_governance.sql`: 3 roles, agent warehouse, resource monitor) |
| Spend control | — | Resource monitors; **resource budgets for Cortex Agents** (2026-03-11, [release note](https://docs.snowflake.com/release-notes/2026/other/2026-03-11-cortex-agents-resource-budgets)) | Monitor built; agent budget not set |
| ML in the loop | Mosaic AI | `SNOWFLAKE.ML.FORECAST` (`GROCERY_ML`) | Built, scoped, weekly task |

Verdict: the **analytical and agent halves are in place and follow the same
shape**. The **transactional half is absent**: nothing in the design holds
state across agent requests.

## 3. How the current design behaves under many concurrent requests

What scales well today:

- **Reads never block on refreshes.** Dynamic tables refresh in the
  background; readers see the last complete version. Weekly loads do not
  slow the agent.
- **The data is small.** ~16k products, ~1.3M product-store-week rows, 81
  stores. Every verified query runs in under 2 s on X-Small. The result cache
  serves repeated questions for free.
- **LLM and search compute are serverless.** Cortex Analyst, the agent's
  orchestration model and Cortex Search serving do not run on the warehouse,
  so they scale separately from SQL.
- **The basket tool is session-safe.** Its temp tables are per session, so
  concurrent calls do not collide.
- **Spend is capped.** `GROCERY_AGENT_WH` and `GROCERY_ML_WH` sit under a
  10-credit monthly monitor.

Where it would strain, in order of likelihood:

1. **Warehouse queueing.** One X-Small cluster runs ~8 queries at once. A
   burst of agents each firing 2–3 SQL calls would queue. Multi-cluster
   scaling was tried on 2026-11-15 and is **not available on this account
   (Standard edition)**. On Standard, when `WAREHOUSE_LOAD_HISTORY` shows
   `AVG_QUEUED_LOAD > 0`: resize to SMALL (doubles concurrent slots at 2×
   the per-second rate, still auto-suspending in 60 s), or raise
   `MAX_CONCURRENCY_LEVEL`. Moving to Enterprise unlocks
   `MAX_CLUSTER_COUNT`, which is the right long-term answer if the agent
   gets more than one household of users.
2. **No state between requests.** A second request cannot see the first
   one's basket, ZIP code, preferred stores, or feedback. Every conversation
   starts cold. This is the Lakebase gap.
3. **Agent-side limits.** Cortex Agents have per-account request limits that
   Snowflake does not publish as fixed numbers; at the scale of a single
   household they will not matter. Set an agent resource budget so a runaway
   loop cannot spend beyond it.
4. **Freshness is weekly.** Fine for prices that change weekly; not a design
   for intraday questions. Dynamic tables could run at a 1-hour lag if
   ingestion became daily, with no model changes.

## 4. Recommendation: add the transactional layer with hybrid tables first

Snowflake has two candidates for the Lakebase role. Pick by whether a
separate application exists:

- **Hybrid tables** (Unistore): row-store tables inside the same database,
  same RBAC, same SQL, millisecond point reads/writes, agents read and write
  them through procedure tools. No new service, no sync. Right for **agent
  state used only by agents and Snowflake apps**. (Check current pricing: a
  2026-03-16 release note changed hybrid-table metering.)
- **Snowflake Postgres**: a full Postgres instance managed by Snowflake, for
  an application tier that needs Postgres drivers, ORMs, or extensions, and
  for branching dev copies the way Lakebase does. Right **only once a web or
  mobile app fronts the agent**. Adds an instance to run and pay for.

For this project the recommendation is **hybrid tables now, Postgres only if
an app arrives**. **Done 2026-11-15** as Phase 6 (`Snowflake Scripts/Agent/
06_state_layer.sql`), schema `GROCERY_APP`, exposed to the agent as seven
tools and used by the Streamlit app for saved lists and preferences:

| Hybrid table | Purpose | Written by |
|---|---|---|
| `SHOPPER_PREFERENCE` | home ZIP, preferred stores, dietary flags, unit-price basis | agent tool `SP_SET_PREFERENCE` |
| `SHOPPING_LIST` / `SHOPPING_LIST_ITEM` | named lists with resolved `PRODUCT_KEY`s; the basket tool reads a list by name | `SP_SAVE_LIST`, basket tool |
| `PRICE_WATCH` | products to alert on (target price or "at historic low") | `SP_WATCH_PRODUCT`; the Sunday task evaluates and writes `PRICE_ALERT` |
| `BASKET_WATCH` / `BASKET_ALERT` | tracked baskets (a list whose items carry the priced `PRODUCT_KEY`s) and their good-time-to-buy alerts for the basket, its items and look-alike swaps (`07_basket_watch.sql`) | `SP_TRACK_BASKET` (owner app); the Sunday task runs `SP_CHECK_BASKET_WATCHES`, which writes alerts and sends one email |
| (no new table) healthy week | `SP_SUGGEST_WEEKLY_BASKET` (`08_healthy_week.sql`) proposes a week of groceries for a budget and diet from the dbt mart `dim_product_diet` (USDA Thrifty Food Plan budget split, FDA "healthy" per-serving limits, diet statuses with provenance, percentile-rank value) and a Haiku meal-prep narrative; the result is saved as an ordinary tracked basket | both apps via `SP_TRACK_BASKET` / `SP_GUEST_TRACK_BASKET` (guests: `05_guest_healthy_week.sql`, metered as kind `suggestion`) |
| `AGENT_FEEDBACK` | thumbs up/down with the question, tool calls and answer | agent tool, Streamlit UI |
| `AGENT_RUN_LOG` | one row per request: question, tools, latency, credits | eval runner, UI |

What that buys: the agent remembers the shopper; questions like "my usual
list near home" work without re-typing; feedback and run logs feed the eval
loop (`Agent/evals/`) and the weekly cost review; and a later Streamlit or
Postgres-backed app reads the same tables. The analytical marts stay
read-only for agents, as they should.

## 4b. Operations layer (built 2026-11-15)

The agentic operations layer that watches all of the above lives in schema
`GROCERY_OPS` and runs as `GROCERY_OPS_ROLE` on its own X-Small warehouse under
a 2-credit monitor. Its rule: **sensors decide, agents explain, humans act.**

- **Sensors**: 25 SQL views (`V_CHECK_*`) with thresholds in `OPS_CHECK`, run
  by `SP_RUN_SENSORS`; findings land in `OPS_EVENT` (fingerprint dedup),
  metrics in `OPS_METRIC_DAILY`, every run in `OPS_RUN`. Hourly serverless
  alerts cover the three things that cannot wait (job missing/failed, task
  failed, monitor ≥ 75 %).
- **Six agents, one procedure**: `SP_RUN_AGENT(domain)` builds an inline
  `AGENT_RUN` request from `AGENT_REGISTRY` (instructions, tools) and
  `MODEL_POLICY` (Haiku 5.5 for pattern checks, Sonnet 5.5 for diagnosis,
  Opus 5.5 for weekly judgement). Agents see only sensor output, must cite
  `EVENT_ID`s, and may only *name* a runbook action.
- **Control plane**: `AGENT_REGISTRY` (every deployed component, model,
  schedule, last run, silence flag), `MODEL_POLICY` and `OPS_CHECK` edited
  through audited procedures. Surfaced natively since 2026-11-15: a Snowsight
  dashboard (tile SQL in `Agent/ops/dashboard_tiles.sql`), the semantic view
  `GROCERY_OPS.SV_OPS` with the Cortex Agent `GROCERY_OPS_AGENT` for Snowflake
  Intelligence (reads everything; writes only on explicit human request), and
  the six agents mirrored as objects on the Snowsight Agents page
  (`SP_SYNC_AGENT_OBJECTS`). The Streamlit Operations tab was retired; the
  weekly digest email remains the push channel. Runbook: `Agent/ops/README.md`.
- **Independence**: the AWS Lambda watcher (`Orchestration/ops-watcher/`,
  deployed 2026-11-15) reads one heartbeat view as a key-pair service user and
  emails through SNS if the supervisor is silent for 26 h or Snowflake is
  unreachable; a CloudWatch alarm on EventBridge Scheduler attempts covers the
  "job never started" case from the AWS side.

- **Public guests (2026-11-16)**: a second Streamlit front end on Streamlit
  Community Cloud (`Streamlit/guest_app/`) lets people without a Snowflake
  account use the shopper agent. It connects as a key-pair service user with
  a read-only role plus four `SP_GUEST_*` procedures; guests sign up (name,
  email, LinkedIn, consent) into hybrid tables, get one 60-minute /
  0.25-credit session per week, and share a 5-credit weekly budget. Three
  stops: the app's meter (estimate), the ops alert (billed credits from
  `CORTEX_AGENT_USAGE_HISTORY` + `QUERY_ATTRIBUTION_HISTORY`), and a weekly
  resource monitor on the guest warehouse. Snowflake-native embedding was
  considered and rejected for cost: it needs the container runtime, about
  0.06 credits per hour while the app server is up.

This is the Snowflake answer to "who runs the agents": the same platform
that holds the data runs the sensors, the models and the audit trail, with
one RBAC and one bill.

## 5. Governance checklist against the LTAP pattern

- One catalog: all objects in `GROCERYDBTPROJECT`, documented through dbt
  `persist_docs` and the ontology. Done.
- Least privilege: `GROCERY_AGENT_USER` reads marts, semantic view, search,
  procedures; no raw or staging. Done. dbt still runs as ACCOUNTADMIN
  (`01_governance.sql` section 5, pending).
- Cost: resource monitor done; add a Cortex Agent resource budget; review
  `ACCOUNT_USAGE.CORTEX_*_USAGE_HISTORY` weekly.
- Quality gates: dbt tests on every mart; golden questions in
  `Agent/evals/golden_questions.yml`, run with `run_evals.py` before any
  agent or semantic-view change ships.
- Change management: everything in git, sandbox first (`GROCERY_DEV_*`),
  then prod.

## Sources

- [Snowflake Postgres GA release note (2026-02-24)](https://docs.snowflake.com/release-notes/2026/other/2026-02-24-snowflake-postgres-ga)
- [Snowflake Postgres public preview (engineering blog)](https://www.snowflake.com/en/blog/engineering/postgres-public-preview/)
- [Resource budgets for Cortex Agents (2026-03-11)](https://docs.snowflake.com/release-notes/2026/other/2026-03-11-cortex-agents-resource-budgets)
- [Hybrid tables metering change (2026-03-16)](https://docs.snowflake.com/release-notes/2026/other/2026-03-16-hybrid-tables-metering-disabled)
- [Cortex Agents: unified data intelligence (Snowflake engineering)](https://snowflake.com/en/engineering-blog/cortex-agents-unified-data-intelligence)
- [Snowflake: building reliable applications (agent memory preview)](https://www.snowflake.com/en/blog/building-reliable-applications/)
- [Redis Agent Memory for Cortex Agents](https://redis.io/blog/how-redis-brings-persistent-memory-to-snowflake-cortex-agents/)
- [Databricks: Lakebase at VLDB 2026](https://databricks.com/blog/building-ai-era-lakebase-streaming-and-lakehouse-innovations-vldb-2026)
- [Databricks LTAP architecture (Techzine)](https://www.techzine.eu/news/analytics/142199/databricks-breaks-down-the-barrier-between-oltp-and-olap-with-ltap-architecture/)
- [Databricks expands Lakehouse to unify OLAP and OLTP (Blocks & Files)](https://www.blocksandfiles.com/data-management/2026/06/18/databricks-expands-lakehouse-to-unify-olap-and-oltp/5258373)
- [Capital One: Lakebase unifying OLTP and OLAP](https://www.capitalone.com/software/blog/databricks-lakebase-unify-oltp-olap)
