# Project Architecture

**GroceryPriceProject (SalePredictor)** — a data pipeline that collects grocery pricing, inventory, and store-location data from Kroger and Walmart, lands it in Snowflake via event-driven ingestion, and (in later phases) transforms it with dbt to forecast when items will go on sale.

## Data Flow

```mermaid
flowchart TD
    subgraph EXT["External APIs"]
        KAPI["Kroger API<br/>Products + Locations"]
        WAPI["Walmart Affiliate API<br/>(blocked — no Prod access yet)"]
    end

    subgraph ING["Ingestion Layer — Python, concurrent + rate-limited"]
        KCAT["Catalog script"]
        KLOC["Location script"]
        KPRC["Pricing script"]
        KINV["Inventory script"]
        WCAT["Walmart catalog script"]
    end

    subgraph S3["S3 Landing Zone — grocerydbtprojectrawdata"]
        S3K[("kroger/ prefix<br/>4 filename patterns")]
        S3W[("walmart/ prefix<br/>(empty, blocked)")]
    end

    EVTNOTE["S3 Event Notifications<br/>(ObjectCreated, fan-out per prefix)"]

    subgraph QUEUES["SQS — one queue per pipe"]
        Q1[["catalog queue"]]
        Q2[["locations queue"]]
        Q3[["pricing queue"]]
        Q4[["inventory queue"]]
    end

    subgraph SF["Snowflake — GROCERYDBTPROJECT database"]
        subgraph AWSRES["AWS_RESOURCES schema"]
            SI["Storage Integration + Stage + File Formats"]
            P1["Pipe: catalog<br/>PATTERN filter"]
            P2["Pipe: locations<br/>PATTERN filter"]
            P3["Pipe: pricing<br/>PATTERN filter"]
            P4["Pipe: inventory<br/>PATTERN filter"]
        end
        subgraph RAWS["RAW schema"]
            T1[("KROGER_PRODUCT_CATALOG")]
            T2[("KROGER_LOCATIONS")]
            T3[("KROGER_PRICING")]
            T4[("KROGER_INVENTORY")]
        end
    end

    subgraph FUTURE["Planned — Phase 4 / 5"]
        DBT["dbt staging + marts<br/>parses raw_data JSON, joins sources"]
        ML["Forecasting model<br/>sale-timing prediction"]
    end

    KAPI --> KCAT & KLOC & KPRC & KINV
    WAPI -.-> WCAT
    KCAT --> S3K
    KLOC --> S3K
    KPRC --> S3K
    KINV --> S3K
    WCAT -.-> S3W

    S3K --> EVTNOTE
    EVTNOTE --> Q1 & Q2 & Q3 & Q4
    Q1 --> P1
    Q2 --> P2
    Q3 --> P3
    Q4 --> P4
    SI -. grants access .-> P1
    SI -. grants access .-> P2
    SI -. grants access .-> P3
    SI -. grants access .-> P4
    P1 --> T1
    P2 --> T2
    P3 --> T3
    P4 --> T4

    T1 --> DBT
    T2 --> DBT
    T3 --> DBT
    T4 --> DBT
    DBT --> ML
```

## How It Works

**Ingestion.** Four Python scripts pull from Kroger's Products and Locations APIs: one for the full product catalog (crawled by search term, since Kroger exposes no bulk "list everything" endpoint), one for store locations (searched by region — e.g. Metro Atlanta by ZIP + radius), and two for per-store pricing and inventory (batched by known product ID, 50 IDs/call, against a target list of store `locationId`s). All four use the same pattern: a thread pool for concurrent requests, a shared rate limiter, and a daily call-budget guard, since Kroger caps usage at 10,000 calls/day. A parallel Walmart catalog script exists but is currently blocked — the Walmart developer account only has a Stage API credential, and provisioning a Production one is stuck on a portal bug.

**Landing zone.** Every script uploads its output as a timestamped CSV directly to S3 (`grocerydbtprojectrawdata`), under a `kroger/` or `walmart/` prefix. Deliberately, the ingestion scripts apply minimal transformation: the catalog script flattens Kroger's product JSON into named columns (its shape is wide and relatively stable), but the location, pricing, and inventory scripts do the opposite — they extract only the join keys needed downstream (`productId`, `locationId`, `region`, `collected_at`) and preserve the rest of each API response untouched as a JSON string in a `raw_data` column. This is a deliberate ELT choice: parsing, joining, and business logic belong in dbt, not in the ingestion layer, so the raw layer stays a faithful, replayable copy of what the API actually returned.

**Event-driven load into Snowflake.** Rather than polling, loading is push-driven: an S3 `ObjectCreated` event fires whenever a script uploads a new file, and Snowflake's Snowpipe picks it up automatically — typically within about a minute, with no manual `COPY INTO` required. The nuance is that all four Kroger file types land in the *same* `kroger/` prefix, and each Snowpipe (`AUTO_INGEST` pipe) provisions its own dedicated SQS queue. So the S3 bucket is configured to fan the same event out to all four queues, and each pipe's own `COPY INTO ... PATTERN` clause (matching on filename, e.g. `.*kroger_pricing_.*\.csv`) decides whether that particular file is actually its concern. One shared stage and file format serve all four pipes; only the `PATTERN` differs.

**Snowflake object layout.** Everything AWS-facing — the storage integration, the shared stage, file formats, and the four pipes — lives in the `AWS_RESOURCES` schema. The landing tables themselves live in `RAW`. Access from Snowflake to S3 goes through an IAM role (`GroceryPriceProjectSnowflakeRole`) whose trust policy is scoped to Snowflake's specific IAM user and an external ID, both generated when the storage integration is created — a two-way handshake configured once and left alone, since recreating the integration invalidates it.

**What's not built yet.** There's no scheduler — every script currently runs manually, so the pipeline is push-driven for *loading* but not yet for *collection*. dbt hasn't been started: today the `RAW` tables are the end of the line, with `raw_data` sitting as unparsed JSON text. Walmart's entire pipeline is blocked upstream at the API-access stage, so `walmart/` remains empty and its Snowpipe has nothing to load. The forecasting model itself (Phase 5) is not yet designed — it depends on having enough historical pricing snapshots accumulated in `KROGER_PRICING` to detect sale patterns, which in turn depends on this pipeline actually running on a recurring schedule rather than ad hoc.

**Why this shape.** The core bet is that an event-driven, source-per-table landing pattern scales cleanly as more data types and retailers are added — each new source is a new script, a new pipe with its own `PATTERN`, and a new `RAW` table, without touching what already works. Keeping the landing layer close to raw (rather than pre-joining or reshaping in Python) means schema decisions and business logic live in one place — dbt — instead of being split across ingestion code and transformation code where they're easy to lose track of.
