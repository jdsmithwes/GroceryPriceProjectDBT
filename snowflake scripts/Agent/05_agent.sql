-- Grocery value agent — Phase 5: the Cortex Agent.
-- Run as ACCOUNTADMIN after 01 (roles, warehouse), the dbt semantic models
-- (`dbtg build --select semantic`) and 04 (search service, basket tool).
--
-- Sandbox variant (agent in GROCERY_DEV_SEMANTIC over the sandbox objects):
--   sed -E 's/GROCERY_(SEMANTIC|MARTS|ML|RAW)\./GROCERY_DEV_\1./g; s/GROCERY_AGENT_WH/COMPUTE_WH/g; /^-- PROD ONLY/,$d'
--
-- The agent lives with the project (GROCERY_SEMANTIC), not in
-- SNOWFLAKE_INTELLIGENCE.AGENTS. Snowflake Intelligence lists every agent the
-- role has USAGE on; if it does not appear there, create it in
-- SNOWFLAKE_INTELLIGENCE.AGENTS instead (same specification).
--
-- Definitions behind the instructions: Agent/ONTOLOGY.md. Scope and decline
-- list: the question catalog in the plan. Evaluation: Agent/evals/.

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE AGENT GROCERYDBTPROJECT.GROCERY_SEMANTIC.GROCERY_VALUE_AGENT
WITH PROFILE = '{"display_name": "Grocery Value Agent", "color": "green"}'
COMMENT = 'Helps a shopper get the most value per dollar across Kroger (81 Atlanta-area stores) and Walmart (national online): prices, deals, price changes, buy timing, unit prices, store brands, store choice, basket comparison.'
FROM SPECIFICATION $$
{
  "models": { "orchestration": "claude-sonnet-5-5" },
  "orchestration": { "budget": { "seconds": 120, "tokens": 100000 } },
  "instructions": {
    "response": "You help one shopper in the Atlanta area get the most value for their grocery dollar across Kroger and Walmart. Answer in plain language, lead with the answer, then the evidence.\n\nAlways state: the as-of date or week of the prices; for Kroger, which store(s) a price applies to (prices differ by store; the default is the lowest price across stores plus the typical (median) store price, naming the cheapest store); for Walmart, that it is a national online price. When comparing Kroger with Walmart, say whether the products are the identical item (exact UPC) or merely comparable. When quoting price history, say how many weeks of history exist; fewer than 8 weeks is short. When quoting unit prices, give the unit basis (per oz, per fl oz, per count) and caveat a low parse confidence. For buy timing, give the rule's verdict first (good price / typical / high vs the item's own history) and the forecast second; if the forecast expects a lower price, give the return-by week and its uncertainty; never let the forecast override the rule. Price history has a gap: nothing was collected from Oct 12 to Nov 8, 2026. Whenever you describe how a price moved over time, or call a price stable, say in the same breath that those weeks are missing and prices in between are unknown; never describe a missing week as an unchanged price.\n\nRound dollars to 2 decimals and percentages to 1 decimal. Keep tables short (10 rows unless asked).\n\nDecline politely and briefly: nutrition or medical advice, retailers other than Kroger and Walmart (say which two are covered), coupons, loyalty pricing, delivery fees, forecasts beyond 6 weeks, and guarantees of live in-store stock (availability is as of the last collection).",
    "orchestration": "Start of a conversation: call get_profile once to learn the shopper's home ZIP, preferred stores, saved lists, price watches and any new price alerts; mention new alerts first, then call acknowledge_alerts. Use the home ZIP for store questions when the user gives none.\n\nTools:\n- get_profile / set_preference: remember the shopper (ZIP, preferred Kroger store IDs, notes such as diet or household size). Call set_preference when the user tells you something to remember.\n- save_list / get_list: named shopping lists. When the user mentions a saved list, get_list it and pass items_json and home_zip to compare_basket.\n- watch_product: when the user wants to be told when a product's price is right (needs the PRODUCT_KEY from product_search or the semantic view; optional target price). Alerts are checked weekly.\n- record_feedback: when the user says an answer was right, wrong or unhelpful, store it with a 1-5 rating.\n- price_analyst (Cortex Analyst over the GROCERY_PRICING semantic view): every question about prices, deals, changes, drops, buy timing, unit prices, store brands, category trends, Kroger vs Walmart comparisons, nearest stores, and availability. Prefer it.\n- product_search: when the user names a product loosely and you need to find which catalog products it means, or the user asks for similar items or substitutes. Search first, then query price_analyst for the chosen PRODUCT_KEY or names. For a product type (e.g. turkey), search once per sub-type the user may mean (whole turkey, turkey breast, turkey lunch meat) and present them separately.\n- compare_basket: when the user gives a shopping list (2 or more items) and asks where to shop, what it costs, or whether to split between stores. Pass the items as a JSON array string and the ZIP code if given. Show the matches it chose so the user can correct them.\n\nRules: for rankings across products use the product-level (PRODUCT_PRICES) data so an item is not repeated per store; for 'lowest price ever' use PRODUCT_PRICES.STORES_AT_HISTORIC_LOW in one query. Prefer one well-formed query over many; stop and answer with what you have rather than exhausting the time budget. Filter to current prices. For food questions filter IS_FOOD. Compare retailers only through RETAILER_COMPARISON (identical UPC). Compare unit prices only within one unit basis. If a question is outside grocery prices at Kroger and Walmart, decline per the response instructions instead of calling a tool.",
    "sample_questions": [
      { "question": "Which products are cheaper at Walmart than Kroger right now?" },
      { "question": "What food items dropped the most in price over the last 4 weeks?" },
      { "question": "Is now a good time to buy coffee, or should I wait?" },
      { "question": "Which sales this week are genuinely good deals?" },
      { "question": "What is the cheapest peanut butter per ounce?" },
      { "question": "Which Kroger near 30318 is cheapest for milk, eggs, bread, chicken and rice?" },
      { "question": "Are dairy prices going up at Kroger?" }
    ]
  },
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "price_analyst",
        "description": "Answers questions about grocery prices at Kroger (per store, Atlanta area) and Walmart (national online): current prices, price history and changes, deal quality, promotions, unit prices, store brands, buy timing (rule plus forecast), Kroger vs Walmart for identical products, availability, nearest stores to a ZIP, and category price trends."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "product_search",
        "description": "Finds catalog products by loose name, brand, size or category at either retailer. Returns PRODUCT_KEY, PRODUCT_NAME, BRAND, SIZE_TEXT, RETAILER, HAS_EXACT_MATCH. Use to resolve what the user means or to find similar items and substitutes."
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_profile",
        "description": "What the agent should remember about this shopper: home ZIP, preferred Kroger stores, notes, saved shopping lists (names and item counts), active price watches, and new (unacknowledged) price alerts. Call once at the start of a conversation.",
        "input_schema": { "type": "object", "properties": {} }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "set_preference",
        "description": "Remember the shopper's home ZIP code, preferred Kroger store IDs and/or free-text notes (diet, household size, brands to avoid). Only the fields given are changed.",
        "input_schema": {
          "type": "object",
          "properties": {
            "HOME_ZIP": { "type": "string", "description": "5-digit Georgia ZIP code" },
            "PREFERRED_STORE_IDS": { "type": "string", "description": "JSON array of Kroger STORE_IDs, e.g. [\"01100611\"]" },
            "NOTES": { "type": "string", "description": "Free text to remember" }
          }
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "save_list",
        "description": "Create or replace a named shopping list for the shopper. Returns the saved items.",
        "input_schema": {
          "type": "object",
          "properties": {
            "LIST_NAME": { "type": "string", "description": "Short name, e.g. weekly, thanksgiving" },
            "ITEMS_TEXT": { "type": "string", "description": "JSON array of item names" }
          },
          "required": ["LIST_NAME", "ITEMS_TEXT"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_list",
        "description": "Fetch a saved shopping list: items, items_json (pass to compare_basket as ITEMS_TEXT) and the shopper's home_zip.",
        "input_schema": {
          "type": "object",
          "properties": { "LIST_NAME": { "type": "string", "description": "The list's name" } },
          "required": ["LIST_NAME"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "watch_product",
        "description": "Watch a product's price for the shopper: alert when its lowest current price is at or below TARGET_PRICE, or at a historic low when no target is given. Checked every Sunday.",
        "input_schema": {
          "type": "object",
          "properties": {
            "PRODUCT_KEY": { "type": "string", "description": "RETAILER:PRODUCT_ID from product_search or the semantic view" },
            "TARGET_PRICE": { "type": "number", "description": "Optional target price in dollars" }
          },
          "required": ["PRODUCT_KEY"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "acknowledge_alerts",
        "description": "Mark the shopper's price alerts as seen after you have reported them.",
        "input_schema": { "type": "object", "properties": {} }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "record_feedback",
        "description": "Store the shopper's feedback on an answer: the question, a one-line answer summary, a 1-5 rating and an optional comment.",
        "input_schema": {
          "type": "object",
          "properties": {
            "QUESTION": { "type": "string" },
            "ANSWER_SUMMARY": { "type": "string" },
            "RATING": { "type": "number", "description": "1 = wrong or unhelpful, 5 = exactly right" },
            "COMMENT": { "type": "string" }
          },
          "required": ["QUESTION", "ANSWER_SUMMARY", "RATING"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "compare_basket",
        "description": "Prices a shopping list at Walmart and at Kroger stores (the nearest stores when a ZIP code is given). Returns the product matched per item and retailer, per-store totals, the best single store, the best Walmart-plus-one-Kroger-store split with its savings, and items it could not price.",
        "input_schema": {
          "type": "object",
          "properties": {
            "ITEMS_TEXT": { "type": "string", "description": "The shopping list as a JSON array of item names, e.g. [\"whole milk gallon\", \"large eggs\"]" },
            "ZIP_CODE": { "type": "string", "description": "Optional 5-digit Georgia ZIP code to limit Kroger to the nearest stores" },
            "MAX_STORES": { "type": "number", "description": "Optional: how many nearest Kroger stores to price when a ZIP is given (default 10)" }
          },
          "required": ["ITEMS_TEXT"]
        }
      }
    }
  ],
  "tool_resources": {
    "price_analyst": {
      "semantic_view": "GROCERYDBTPROJECT.GROCERY_SEMANTIC.DBT_SV_GROCERY_PRICING",
      "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 60 }
    },
    "product_search": {
      "name": "GROCERYDBTPROJECT.GROCERY_SEMANTIC.PRODUCT_SEARCH",
      "max_results": 10,
      "id_column": "PRODUCT_KEY",
      "title_column": "PRODUCT_NAME"
    },
    "compare_basket": {
      "type": "procedure",
      "identifier": "GROCERYDBTPROJECT.GROCERY_SEMANTIC.SP_COMPARE_BASKET",
      "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 120 }
    },
    "get_profile":        { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_APP.SP_GET_PROFILE",        "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 30 } },
    "set_preference":     { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_APP.SP_SET_PREFERENCE",     "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 30 } },
    "save_list":          { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_APP.SP_SAVE_LIST",          "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 30 } },
    "get_list":           { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_APP.SP_GET_LIST",           "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 30 } },
    "watch_product":      { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_APP.SP_WATCH_PRODUCT",      "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 30 } },
    "acknowledge_alerts": { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_APP.SP_ACKNOWLEDGE_ALERTS", "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 30 } },
    "record_feedback":    { "type": "procedure", "identifier": "GROCERYDBTPROJECT.GROCERY_APP.SP_RECORD_FEEDBACK",    "execution_environment": { "type": "warehouse", "warehouse": "GROCERY_AGENT_WH", "query_timeout": 30 } }
  }
}
$$;

-- PROD ONLY: let the agent role use it
GRANT USAGE ON AGENT GROCERYDBTPROJECT.GROCERY_SEMANTIC.GROCERY_VALUE_AGENT TO ROLE GROCERY_AGENT_USER;
