{{ config(
    materialized="semantic_view",
    static_analysis="off"
) }}

{#-
  Semantic view over the grocery price marts (Kroger, 81 Atlanta-area stores,
  and Walmart national online prices). It is the business ontology
  (Agent/ONTOLOGY.md) made executable for Cortex Analyst and the grocery value
  agent: logical tables, how they join, what each column means, and verified
  example queries.

  Rules every answer must respect (also in AI_SQL_GENERATION below):
    - Current prices: STORE_PRICES rows with IS_CURRENTLY_LISTED = TRUE.
    - Kroger prices differ by store; Walmart has one national price
      (STORE_ID = 'walmart_national').
    - Kroger vs Walmart like-for-like only through RETAILER_COMPARISON
      (identical UPC at both).
    - Unit prices compare only within one UNIT_BASIS; caveat PARSE_CONFIDENCE
      'low'.
    - Price history has a gap (no collection Oct 12 - Nov 8, 2026); a missing
      week is missing, not "unchanged".

  Verified queries live in the jinja list below and are rendered into the
  Cortex Analyst extension JSON, so they stay readable here.
-#}

{%- set verified_queries = [
  {
    "name": "cheaper_retailer_shared_products",
    "question": "Which products are cheaper at Walmart than at Kroger right now?",
    "use_as_onboarding_question": true,
    "sql": "SELECT product_name, walmart_price, kroger_min_price, kroger_cheapest_store_name, savings_vs_kroger_min FROM __retailer_comparison WHERE is_priced_at_both AND cheaper_retailer = 'walmart' ORDER BY savings_vs_kroger_min DESC LIMIT 25"
  },
  {
    "name": "biggest_price_drops_4w",
    "question": "Which food items dropped the most in price over the last 4 weeks?",
    "use_as_onboarding_question": true,
    "sql": "SELECT p.retailer, p.product_name, r.median_current_price, r.median_change_4w_pct, r.ref_week_4w FROM __product_prices r JOIN __products p ON r.product_key = p.product_key WHERE p.is_food AND r.median_change_4w_pct IS NOT NULL ORDER BY r.median_change_4w_pct ASC LIMIT 20"
  },
  {
    "name": "good_time_to_buy",
    "question": "Is now a good time to buy coffee?",
    "use_as_onboarding_question": true,
    "sql": "SELECT p.retailer, p.product_name, b.current_price, b.history_median_price, b.history_low_price, b.rule_signal, b.recommendation, b.return_by_week, b.forecast_low_price_bounded, b.weeks_observed FROM __buy_signals b JOIN __products p ON b.product_key = p.product_key WHERE b.is_currently_listed AND p.is_food AND p.product_name ILIKE '%coffee%' ORDER BY b.recommendation, b.current_price LIMIT 25"
  },
  {
    "name": "genuine_deals_now",
    "question": "Which sales right now are genuinely good deals?",
    "sql": "SELECT p.product_name, s.store_name, sp.current_price, sp.current_regular_price, sp.current_discount_pct, sp.promo_week_share FROM __store_prices sp JOIN __products p ON sp.product_key = p.product_key JOIN __stores s ON sp.store_id = s.store_id WHERE sp.is_currently_listed AND sp.deal_quality = 'GENUINE' AND p.is_food ORDER BY sp.current_discount_pct DESC LIMIT 25"
  },
  {
    "name": "nearest_kroger_stores_to_zip",
    "question": "Which Kroger stores are closest to ZIP code 30318?",
    "sql": "SELECT s.store_name, s.address, s.city, s.zip_code, ROUND(HAVERSINE(z.latitude, z.longitude, s.latitude, s.longitude) * 0.621371, 1) AS miles FROM __stores s CROSS JOIN __zip_codes z WHERE z.zip_code = '30318' AND s.retailer = 'kroger' ORDER BY miles LIMIT 5"
  },
  {
    "name": "cheapest_per_ounce",
    "question": "What is the cheapest peanut butter per ounce?",
    "sql": "SELECT p.retailer, p.product_name, p.brand, p.package_quantity, p.unit_basis, r.min_current_price, r.min_unit_price, r.parse_confidence FROM __product_prices r JOIN __products p ON r.product_key = p.product_key WHERE p.product_type = 'peanut butter' AND r.unit_basis = 'oz' AND r.parse_confidence = 'high' ORDER BY r.min_unit_price ASC LIMIT 15"
  },
  {
    "name": "similar_items_by_type",
    "question": "What turkey products do you have prices for, grouped by type?",
    "sql": "SELECT p.product_type, p.retailer, COUNT(*) AS products, MIN(r.min_current_price) AS lowest_price, MEDIAN(r.median_current_price) AS typical_price FROM __product_prices r JOIN __products p ON r.product_key = p.product_key WHERE p.product_type ILIKE '%turkey%' AND p.is_food GROUP BY 1, 2 ORDER BY products DESC"
  },
  {
    "name": "stock_up_candidates",
    "question": "What shelf-stable items are worth stocking up on right now?",
    "sql": "SELECT p.retailer, p.product_name, b.current_price, b.history_median_price, b.history_low_price, b.weeks_observed FROM __buy_signals b JOIN __products p ON b.product_key = p.product_key WHERE b.is_stock_up_candidate AND p.is_food ORDER BY (b.history_median_price - b.current_price) / NULLIF(b.history_median_price, 0) DESC LIMIT 25"
  },
  {
    "name": "category_price_trend",
    "question": "Are dairy prices going up at Kroger?",
    "sql": "SELECT price_week, price_index, change_vs_previous_pct, weeks_since_previous, products_in_link FROM __category_trends WHERE retailer = 'kroger' AND common_category = 'Dairy' ORDER BY price_week"
  },
  {
    "name": "store_brand_vs_national_unit_price",
    "question": "How much cheaper are store brands than national brands per ounce, by category?",
    "sql": "SELECT p.retailer, p.primary_common_category, MEDIAN(IFF(p.is_store_brand, r.median_unit_price, NULL)) AS store_brand_median_unit_price, MEDIAN(IFF(NOT p.is_store_brand, r.median_unit_price, NULL)) AS national_brand_median_unit_price FROM __product_prices r JOIN __products p ON r.product_key = p.product_key WHERE p.is_food AND r.unit_basis = 'oz' AND r.parse_confidence = 'high' GROUP BY 1, 2 HAVING store_brand_median_unit_price IS NOT NULL AND national_brand_median_unit_price IS NOT NULL ORDER BY 1, 2"
  }
] -%}

tables (
    PRODUCTS as {{ ref('dim_product') }}
        primary key (PRODUCT_KEY)
        with synonyms = ('items', 'groceries', 'catalog')
        comment = 'One row per retailer product (Kroger or Walmart). Name, brand, package size, category, store-brand and food flags.',
    STORES as {{ ref('dim_store') }}
        primary key (STORE_ID)
        with synonyms = ('locations', 'shops')
        comment = 'Kroger stores in the Atlanta area plus one virtual Walmart national row (STORE_ID walmart_national).',
    STORE_PRICES as {{ ref('fct_product_price_summary') }}
        primary key (PRODUCT_KEY, STORE_ID)
        comment = 'Current price and price history per product per store: trailing low/median/high, 4/8/12-week changes, promo frequency and deal quality. Filter IS_CURRENTLY_LISTED for current prices.',
    PRODUCT_PRICES as {{ ref('fct_product_price_rollup') }}
        primary key (PRODUCT_KEY)
        comment = 'One row per product across all stores: lowest and typical current price, cheapest store, median price changes, unit prices. Use for rankings so a product is not repeated per store.',
    BUY_SIGNALS as {{ ref('fct_buy_recommendation') }}
        primary key (PRODUCT_KEY)
        with synonyms = ('buy recommendation', 'timing', 'should I buy')
        comment = 'Is now a good time to buy: a history rule decides, an ML forecast adds a return-by week. The forecast never overrides the rule.',
    RETAILER_COMPARISON as {{ ref('fct_cross_retailer_price_comparison') }}
        primary key (UPC_A)
        with synonyms = ('kroger vs walmart', 'price comparison')
        comment = 'Products carried by both retailers (identical UPC): Walmart price vs the cheapest and typical Kroger store. The only valid like-for-like retailer comparison.',
    AVAILABILITY as {{ ref('fct_product_availability_current') }}
        primary key (PRODUCT_KEY, STORE_ID)
        comment = 'Latest stock level and fulfillment options per product per store, as of DATA_AS_OF. Not a live in-store guarantee.',
    WEEKLY_PRICES as {{ ref('fct_price_weekly') }}
        primary key (PRODUCT_KEY, STORE_ID, PRICE_WEEK)
        comment = 'Price per product per store per observed collection week (Monday-start). Weeks with no collection are absent.',
    CATEGORY_TRENDS as {{ ref('fct_category_price_index_weekly') }}
        primary key (RETAILER, COMMON_CATEGORY, PRICE_WEEK)
        with synonyms = ('price index', 'inflation', 'category prices')
        comment = 'Weekly price index per retailer and category (base week = 100), chained over products priced in consecutive observed weeks.',
    ZIP_CODES as {{ ref('zip_centroids_ga') }}
        primary key (ZIP_CODE)
        comment = 'Georgia ZIP code centroids, used to find stores near a shopper ZIP with HAVERSINE (km; multiply by 0.621371 for miles).'
)

relationships (
    STORE_PRICES_TO_PRODUCTS as STORE_PRICES (PRODUCT_KEY) references PRODUCTS,
    STORE_PRICES_TO_STORES as STORE_PRICES (STORE_ID) references STORES,
    PRODUCT_PRICES_TO_PRODUCTS as PRODUCT_PRICES (PRODUCT_KEY) references PRODUCTS,
    PRODUCT_PRICES_TO_CHEAPEST_STORE as PRODUCT_PRICES (CHEAPEST_STORE_ID) references STORES,
    BUY_SIGNALS_TO_PRODUCTS as BUY_SIGNALS (PRODUCT_KEY) references PRODUCTS,
    AVAILABILITY_TO_PRODUCTS as AVAILABILITY (PRODUCT_KEY) references PRODUCTS,
    AVAILABILITY_TO_STORES as AVAILABILITY (STORE_ID) references STORES,
    WEEKLY_PRICES_TO_PRODUCTS as WEEKLY_PRICES (PRODUCT_KEY) references PRODUCTS,
    WEEKLY_PRICES_TO_STORES as WEEKLY_PRICES (STORE_ID) references STORES
)

facts (
    PRODUCTS.PACKAGE_QUANTITY as PACKAGE_QUANTITY comment = 'Package size in UNIT_BASIS units, multipacks multiplied out.',
    PRODUCTS.CUSTOMER_RATING as CUSTOMER_RATING comment = 'Walmart average customer rating, 0 to 5.',
    PRODUCTS.NUM_REVIEWS as NUM_REVIEWS comment = 'Walmart review count.',

    STORES.LATITUDE as LATITUDE comment = 'Store latitude (Kroger only).',
    STORES.LONGITUDE as LONGITUDE comment = 'Store longitude (Kroger only).',

    STORE_PRICES.CURRENT_PRICE as CURRENT_PRICE with synonyms = ('price', 'shelf price', 'what it costs') comment = 'Current effective price at this store: sale price if on promo, else regular.',
    STORE_PRICES.CURRENT_REGULAR_PRICE as CURRENT_REGULAR_PRICE comment = 'Current non-sale price.',
    STORE_PRICES.CURRENT_PROMO_PRICE as CURRENT_PROMO_PRICE with synonyms = ('sale price') comment = 'Current sale price; null when not on promo.',
    STORE_PRICES.CURRENT_DISCOUNT_PCT as CURRENT_DISCOUNT_PCT comment = 'Current promo discount as a fraction (0.25 = 25% off).',
    STORE_PRICES.WEEKS_OBSERVED as WEEKS_OBSERVED comment = 'Collection weeks this product was seen at this store. Say so when it is small.',
    STORE_PRICES.TRAILING_LOW_PRICE as TRAILING_LOW_PRICE comment = 'Lowest price in the trailing 12 observed weeks.',
    STORE_PRICES.TRAILING_MEDIAN_PRICE as TRAILING_MEDIAN_PRICE with synonyms = ('usual price', 'typical price') comment = 'Typical price in the trailing 12 observed weeks.',
    STORE_PRICES.TRAILING_HIGH_PRICE as TRAILING_HIGH_PRICE comment = 'Highest price in the trailing 12 observed weeks.',
    STORE_PRICES.PRICE_PERCENTILE as PRICE_PERCENTILE comment = 'Where today sits in its own recent range: 0 = cheapest seen, 1 = most expensive.',
    STORE_PRICES.ALL_TIME_LOW_PRICE as ALL_TIME_LOW_PRICE comment = 'Lowest price ever observed here (Kroger history from Aug 2026, Walmart from Sep 2026).',
    STORE_PRICES.ALL_TIME_HIGH_PRICE as ALL_TIME_HIGH_PRICE comment = 'Highest price ever observed here.',
    STORE_PRICES.CHANGE_4W as CHANGE_4W comment = 'Dollar change vs about 4 weeks ago (negative = cheaper). Cite REF_WEEK_4W.',
    STORE_PRICES.CHANGE_4W_PCT as CHANGE_4W_PCT comment = '4-week change as a fraction (-0.2 = 20% cheaper).',
    STORE_PRICES.CHANGE_8W_PCT as CHANGE_8W_PCT comment = '8-week change as a fraction. Cite REF_WEEK_8W.',
    STORE_PRICES.CHANGE_12W_PCT as CHANGE_12W_PCT comment = '12-week change as a fraction. Cite REF_WEEK_12W.',
    STORE_PRICES.PROMO_WEEK_SHARE as PROMO_WEEK_SHARE comment = 'Share of observed weeks on sale. High = the sale price is really the usual price.',
    STORE_PRICES.PROMO_EPISODES as PROMO_EPISODES comment = 'Separate sale runs observed.',
    STORE_PRICES.AVG_PROMO_DISCOUNT_PCT as AVG_PROMO_DISCOUNT_PCT comment = 'Average discount during sale weeks.',
    STORE_PRICES.WEEKS_PER_PROMO as WEEKS_PER_PROMO comment = 'Observed weeks per sale run: roughly how often it goes on sale.',
    STORE_PRICES.PROMO_FLAG as IFF(IS_ON_PROMO, 1, 0) comment = '1 when currently on sale, for promo-rate metrics.',

    PRODUCT_PRICES.MIN_CURRENT_PRICE as MIN_CURRENT_PRICE with synonyms = ('lowest price', 'cheapest price', 'best price') comment = 'Lowest current price across stores (Walmart: its one price).',
    PRODUCT_PRICES.MEDIAN_CURRENT_PRICE as MEDIAN_CURRENT_PRICE with synonyms = ('typical price') comment = 'Typical current price across Kroger stores.',
    PRODUCT_PRICES.MAX_CURRENT_PRICE as MAX_CURRENT_PRICE comment = 'Highest current price across stores.',
    PRODUCT_PRICES.STORES_LISTED as STORES_LISTED comment = 'Stores with a current price (Walmart: 1).',
    PRODUCT_PRICES.STORES_ON_PROMO as STORES_ON_PROMO comment = 'Stores where it is on sale now.',
    PRODUCT_PRICES.STORES_WITH_GENUINE_DEAL as STORES_WITH_GENUINE_DEAL comment = 'Stores where the current sale is a GENUINE deal.',
    PRODUCT_PRICES.STORES_AT_HISTORIC_LOW as STORES_AT_HISTORIC_LOW comment = 'Stores where today is the lowest price ever observed there.',
    PRODUCT_PRICES.MEDIAN_PRICE_PERCENTILE as MEDIAN_PRICE_PERCENTILE comment = 'Median across stores of PRICE_PERCENTILE (0 = cheapest seen recently).',
    PRODUCT_PRICES.ALL_TIME_LOW_PRICE as ALL_TIME_LOW_PRICE comment = 'Lowest price ever observed at any store.',
    PRODUCT_PRICES.MEDIAN_CHANGE_4W_PCT as MEDIAN_CHANGE_4W_PCT with synonyms = ('price drop', 'price change') comment = 'Typical store 4-week price change (-0.2 = 20% cheaper). Use for biggest drops; cite REF_WEEK_4W.',
    PRODUCT_PRICES.LARGEST_DROP_4W_PCT as LARGEST_DROP_4W_PCT comment = 'Biggest single-store 4-week drop.',
    PRODUCT_PRICES.MEDIAN_CHANGE_8W_PCT as MEDIAN_CHANGE_8W_PCT comment = 'Typical store 8-week change.',
    PRODUCT_PRICES.MEDIAN_CHANGE_12W_PCT as MEDIAN_CHANGE_12W_PCT comment = 'Typical store 12-week change.',
    PRODUCT_PRICES.MIN_UNIT_PRICE as MIN_UNIT_PRICE with synonyms = ('price per ounce', 'unit price', 'per oz') comment = 'Lowest current price per UNIT_BASIS unit. Compare only within the same UNIT_BASIS.',
    PRODUCT_PRICES.MEDIAN_UNIT_PRICE as MEDIAN_UNIT_PRICE comment = 'Typical current price per UNIT_BASIS unit.',

    BUY_SIGNALS.CURRENT_PRICE as CURRENT_PRICE comment = 'Current typical price (Kroger: median across stores).',
    BUY_SIGNALS.WEEKS_OBSERVED as WEEKS_OBSERVED comment = 'Observed weeks behind the signal. Disclose when fewer than about 8.',
    BUY_SIGNALS.HISTORY_LOW_PRICE as HISTORY_LOW_PRICE comment = 'Lowest weekly price in the history window.',
    BUY_SIGNALS.HISTORY_MEDIAN_PRICE as HISTORY_MEDIAN_PRICE comment = 'Typical weekly price in the history window.',
    BUY_SIGNALS.HISTORY_HIGH_PRICE as HISTORY_HIGH_PRICE comment = 'Highest weekly price in the history window.',
    BUY_SIGNALS.FORECAST_LOW_PRICE_BOUNDED as FORECAST_LOW_PRICE_BOUNDED comment = 'Expected low in the next 6 weeks, floored at the observed low. The forecast price to quote.',
    BUY_SIGNALS.FORECAST_INTERVAL_WIDTH_PCT as FORECAST_INTERVAL_WIDTH_PCT comment = 'Forecast uncertainty: higher = less confident.',

    RETAILER_COMPARISON.WALMART_PRICE as WALMART_PRICE comment = 'Walmart current price (national online).',
    RETAILER_COMPARISON.KROGER_MIN_PRICE as KROGER_MIN_PRICE comment = 'Cheapest current Kroger store price.',
    RETAILER_COMPARISON.KROGER_MEDIAN_PRICE as KROGER_MEDIAN_PRICE comment = 'Typical Kroger store price.',
    RETAILER_COMPARISON.KROGER_STORES_PRICED as KROGER_STORES_PRICED comment = 'Kroger stores with a current price.',
    RETAILER_COMPARISON.SAVINGS_VS_KROGER_MIN as SAVINGS_VS_KROGER_MIN comment = 'Dollar gap between Walmart and the cheapest Kroger store.',
    RETAILER_COMPARISON.SAVINGS_VS_KROGER_MIN_PCT as SAVINGS_VS_KROGER_MIN_PCT comment = 'That gap as a fraction.',
    RETAILER_COMPARISON.WALMART_MINUS_KROGER_MEDIAN as WALMART_MINUS_KROGER_MEDIAN comment = 'Walmart price minus a typical Kroger store price (negative = Walmart cheaper).',
    RETAILER_COMPARISON.WALMART_CHEAPER_FLAG as IFF(CHEAPER_RETAILER = 'walmart', 1, 0) comment = '1 when Walmart beats the cheapest Kroger store.',

    WEEKLY_PRICES.EFFECTIVE_PRICE as EFFECTIVE_PRICE comment = 'What a shopper paid that week: sale price if any, else regular.',
    WEEKLY_PRICES.REGULAR_PRICE as REGULAR_PRICE comment = 'Non-sale price that week.',
    WEEKLY_PRICES.DISCOUNT_PCT as DISCOUNT_PCT comment = 'Sale discount that week as a fraction.',

    CATEGORY_TRENDS.PRICE_INDEX as PRICE_INDEX comment = 'Category price level vs BASE_WEEK = 100 (105 = 5% pricier).',
    CATEGORY_TRENDS.CHANGE_VS_PREVIOUS_PCT as CHANGE_VS_PREVIOUS_PCT comment = 'Change since the previous observed week (0.02 = +2%).',
    CATEGORY_TRENDS.WEEKS_SINCE_PREVIOUS as WEEKS_SINCE_PREVIOUS comment = 'Calendar weeks the step covers; above 1 means a collection gap.',
    CATEGORY_TRENDS.PRODUCTS_IN_LINK as PRODUCTS_IN_LINK comment = 'Products priced in both weeks of the step.',

    ZIP_CODES.LATITUDE as LATITUDE comment = 'ZIP centroid latitude.',
    ZIP_CODES.LONGITUDE as LONGITUDE comment = 'ZIP centroid longitude.'
)

dimensions (
    PRODUCTS.PRODUCT_KEY as PRODUCT_KEY comment = 'RETAILER:PRODUCT_ID, unique across retailers.',
    PRODUCTS.RETAILER as RETAILER with synonyms = ('store chain', 'grocer') comment = 'kroger or walmart.',
    PRODUCTS.PRODUCT_ID as PRODUCT_ID comment = 'Kroger productId or Walmart itemId.',
    PRODUCTS.PRODUCT_NAME as PRODUCT_NAME with synonyms = ('item', 'product', 'description') comment = 'Product name as the retailer lists it. Match loosely with ILIKE.',
    PRODUCTS.BRAND as BRAND comment = 'Brand name.',
    PRODUCTS.PRODUCT_TYPE as PRODUCT_TYPE with synonyms = ('kind of product', 'type of item', 'what it is') comment = 'What the item is, as a short lowercase phrase: peanut butter, whole turkey, turkey lunch meat, cat food, ice cream. Food products only. Filter on it (ILIKE) to compare like with like: per-ounce rankings, store-brand savings, substitutes.',
    PRODUCTS.SIZE_TEXT as SIZE_TEXT with synonyms = ('size', 'package size') comment = 'Kroger package size text, e.g. 16 oz. Walmart sizes are in the product name.',
    PRODUCTS.UPC_A as UPC_A with synonyms = ('upc', 'barcode') comment = '12-digit UPC, set only for products carried by both retailers.',
    PRODUCTS.PRIMARY_COMMON_CATEGORY as PRIMARY_COMMON_CATEGORY with synonyms = ('category', 'department', 'aisle') comment = 'Retailer-neutral category, e.g. Dairy, Snacks, Beverages.',
    PRODUCTS.TEMPERATURE as TEMPERATURE comment = 'Kroger storage temperature: Ambient, Refrigerated, Frozen.',
    PRODUCTS.IS_SHELF_STABLE as IS_SHELF_STABLE with synonyms = ('pantry', 'non-perishable') comment = 'TRUE if it keeps at room temperature.',
    PRODUCTS.IS_FOOD as IS_FOOD comment = 'TRUE for food and drink. Filter on it for food questions and per-ounce rankings.',
    PRODUCTS.HAS_EXACT_MATCH as HAS_EXACT_MATCH comment = 'TRUE if the identical UPC is sold by the other retailer.',
    PRODUCTS.UNIT_BASIS as UNIT_BASIS comment = 'oz (weight), fl_oz (volume) or ct (count).',
    PRODUCTS.PARSE_CONFIDENCE as PARSE_CONFIDENCE comment = 'Package size confidence: high, low (caveat unit prices), none.',
    PRODUCTS.IS_STORE_BRAND as IS_STORE_BRAND with synonyms = ('private label', 'generic', 'house brand') comment = 'TRUE for the retailer own label (Kroger, Simple Truth, Private Selection, Great Value, Marketside, ...).',
    PRODUCTS.STORE_BRAND_TIER as STORE_BRAND_TIER comment = 'Store-brand tier: value, core, premium, organic, ...',
    PRODUCTS.DATA_AS_OF as DATA_AS_OF comment = 'When the catalog details were last collected.',

    STORES.STORE_ID as STORE_ID comment = 'Kroger locationId, or walmart_national.',
    STORES.RETAILER as RETAILER comment = 'kroger or walmart.',
    STORES.STORE_NAME as STORE_NAME with synonyms = ('store', 'location') comment = 'Store display name, e.g. Kroger - Georgetown.',
    STORES.ADDRESS as ADDRESS comment = 'Street address.',
    STORES.CITY as CITY with synonyms = ('town') comment = 'Store city (Kroger only).',
    STORES.ZIP_CODE as ZIP_CODE with synonyms = ('zip', 'postal code') comment = 'Store ZIP code (Kroger only).',
    STORES.IS_VIRTUAL_STORE as IS_VIRTUAL_STORE comment = 'TRUE for the Walmart national row.',

    STORE_PRICES.PRODUCT_KEY as PRODUCT_KEY comment = 'Product.',
    STORE_PRICES.STORE_ID as STORE_ID comment = 'Store.',
    STORE_PRICES.RETAILER as RETAILER comment = 'kroger or walmart.',
    STORE_PRICES.CURRENT_WEEK as CURRENT_WEEK comment = 'Latest week this product was seen at this store.',
    STORE_PRICES.IS_CURRENTLY_LISTED as IS_CURRENTLY_LISTED comment = 'TRUE if seen in the retailer latest collection week. Filter on it for current prices.',
    STORE_PRICES.IS_ON_PROMO as IS_ON_PROMO with synonyms = ('on sale', 'deal', 'discounted') comment = 'Currently on sale.',
    STORE_PRICES.IS_AT_HISTORIC_LOW as IS_AT_HISTORIC_LOW with synonyms = ('lowest ever', 'all-time low') comment = 'Current price ties or beats the lowest ever observed here.',
    STORE_PRICES.DEAL_QUALITY as DEAL_QUALITY with synonyms = ('real sale', 'good deal') comment = 'GENUINE (well below the usual regular price, not routine), ORDINARY (routine or shallow), INFLATED_REFERENCE (the regular price is inflated, e.g. a Walmart MSRP far above any price paid).',
    STORE_PRICES.REF_WEEK_4W as REF_WEEK_4W comment = 'Week the 4-week change compares against.',
    STORE_PRICES.REF_WEEK_8W as REF_WEEK_8W comment = 'Week the 8-week change compares against.',
    STORE_PRICES.REF_WEEK_12W as REF_WEEK_12W comment = 'Week the 12-week change compares against.',
    STORE_PRICES.DATA_AS_OF as DATA_AS_OF comment = 'Collection timestamp of the current price. Cite it.',

    PRODUCT_PRICES.PRODUCT_KEY as PRODUCT_KEY comment = 'Product.',
    PRODUCT_PRICES.RETAILER as RETAILER comment = 'kroger or walmart.',
    PRODUCT_PRICES.CHEAPEST_STORE_ID as CHEAPEST_STORE_ID comment = 'Store with the lowest current price.',
    PRODUCT_PRICES.PRICE_VARIES_BY_STORE as PRICE_VARIES_BY_STORE comment = 'TRUE if Kroger stores charge different prices.',
    PRODUCT_PRICES.REF_WEEK_4W as REF_WEEK_4W comment = 'Most common comparison week for the 4-week change.',
    PRODUCT_PRICES.UNIT_BASIS as UNIT_BASIS comment = 'Unit of the unit prices: oz, fl_oz or ct.',
    PRODUCT_PRICES.PARSE_CONFIDENCE as PARSE_CONFIDENCE comment = 'Confidence in the size behind the unit prices; caveat low.',
    PRODUCT_PRICES.DATA_AS_OF as DATA_AS_OF comment = 'Latest collection behind these prices.',

    BUY_SIGNALS.PRODUCT_KEY as PRODUCT_KEY comment = 'Product.',
    BUY_SIGNALS.RETAILER as RETAILER comment = 'kroger or walmart.',
    BUY_SIGNALS.IS_CURRENTLY_LISTED as IS_CURRENTLY_LISTED comment = 'TRUE if priced in the latest collection week.',
    BUY_SIGNALS.RULE_SIGNAL as RULE_SIGNAL comment = 'History rule: GOOD_PRICE, HIGH_PRICE, TYPICAL, STABLE_PRICE (never changes), INSUFFICIENT_HISTORY.',
    BUY_SIGNALS.RECOMMENDATION as RECOMMENDATION with synonyms = ('advice', 'verdict') comment = 'BUY_NOW, BUY_NOW_OR_WAIT (good now, forecast expects lower by RETURN_BY_WEEK), WAIT, NEUTRAL, INSUFFICIENT_HISTORY.',
    BUY_SIGNALS.FORECAST_DIRECTION as FORECAST_DIRECTION comment = 'Forecast vs today over 6 weeks: LOWER, HIGHER, FLAT, or NONE (no forecast).',
    BUY_SIGNALS.RETURN_BY_WEEK as RETURN_BY_WEEK with synonyms = ('when to buy', 'come back') comment = 'Week to check back when the forecast expects a lower price.',
    BUY_SIGNALS.FORECAST_LOW_WEEK as FORECAST_LOW_WEEK comment = 'Week the forecast low is expected.',
    BUY_SIGNALS.IS_FORECAST_BELOW_HISTORY as IS_FORECAST_BELOW_HISTORY comment = 'TRUE when the raw forecast went below any observed price: call it tentative.',
    BUY_SIGNALS.SIGNALS_AGREE as SIGNALS_AGREE comment = 'TRUE when rule and forecast agree, FALSE when they diverge, null without a forecast.',
    BUY_SIGNALS.IS_SHELF_STABLE as IS_SHELF_STABLE comment = 'Keeps at room temperature.',
    BUY_SIGNALS.IS_STOCK_UP_CANDIDATE as IS_STOCK_UP_CANDIDATE with synonyms = ('stock up', 'buy in bulk') comment = 'Shelf-stable AND a good price now.',
    BUY_SIGNALS.DATA_AS_OF_WEEK as DATA_AS_OF_WEEK comment = 'Week the signal is as of.',

    RETAILER_COMPARISON.UPC_A as UPC_A comment = 'Shared UPC.',
    RETAILER_COMPARISON.PRODUCT_NAME as PRODUCT_NAME comment = 'Product name including package size.',
    RETAILER_COMPARISON.BRAND as BRAND comment = 'Brand.',
    RETAILER_COMPARISON.COMMON_CATEGORY as COMMON_CATEGORY comment = 'Retailer-neutral category.',
    RETAILER_COMPARISON.KROGER_CHEAPEST_STORE_NAME as KROGER_CHEAPEST_STORE_NAME comment = 'Kroger store with the lowest price.',
    RETAILER_COMPARISON.KROGER_CHEAPEST_STORE_CITY as KROGER_CHEAPEST_STORE_CITY comment = 'Its city.',
    RETAILER_COMPARISON.IS_PRICED_AT_BOTH as IS_PRICED_AT_BOTH comment = 'TRUE when both retailers have a current price. Filter on it.',
    RETAILER_COMPARISON.CHEAPER_RETAILER as CHEAPER_RETAILER with synonyms = ('cheaper store', 'winner') comment = 'walmart, kroger or tie: Walmart vs the cheapest Kroger store.',
    RETAILER_COMPARISON.CHEAPER_RETAILER_VS_MEDIAN as CHEAPER_RETAILER_VS_MEDIAN comment = 'Cheaper retailer vs a typical Kroger store.',
    RETAILER_COMPARISON.KROGER_DATA_AS_OF as KROGER_DATA_AS_OF comment = 'Kroger price as-of.',
    RETAILER_COMPARISON.WALMART_DATA_AS_OF as WALMART_DATA_AS_OF comment = 'Walmart price as-of.',

    AVAILABILITY.PRODUCT_KEY as PRODUCT_KEY comment = 'Product.',
    AVAILABILITY.STORE_ID as STORE_ID comment = 'Store.',
    AVAILABILITY.AVAILABILITY_STATUS as AVAILABILITY_STATUS with synonyms = ('in stock', 'stock level') comment = 'in_stock, low_stock, out_of_stock, not_available_online (Walmart online flag, not out of stock), unknown.',
    AVAILABILITY.IS_CURBSIDE_AVAILABLE as IS_CURBSIDE_AVAILABLE with synonyms = ('pickup') comment = 'Kroger curbside pickup offered.',
    AVAILABILITY.IS_DELIVERY_AVAILABLE as IS_DELIVERY_AVAILABLE comment = 'Kroger delivery offered.',
    AVAILABILITY.IS_CLEARANCE as IS_CLEARANCE comment = 'Walmart clearance flag.',
    AVAILABILITY.DATA_AS_OF as DATA_AS_OF comment = 'Collection timestamp. Say as of this.',

    WEEKLY_PRICES.PRODUCT_KEY as PRODUCT_KEY comment = 'Product.',
    WEEKLY_PRICES.STORE_ID as STORE_ID comment = 'Store.',
    WEEKLY_PRICES.PRICE_WEEK as PRICE_WEEK with synonyms = ('week') comment = 'Monday of the collection week.',
    WEEKLY_PRICES.IS_ON_PROMO as IS_ON_PROMO comment = 'On sale that week.',

    CATEGORY_TRENDS.RETAILER as RETAILER comment = 'kroger or walmart.',
    CATEGORY_TRENDS.COMMON_CATEGORY as COMMON_CATEGORY comment = 'Retailer-neutral category.',
    CATEGORY_TRENDS.PRICE_WEEK as PRICE_WEEK comment = 'Monday of the collection week.',
    CATEGORY_TRENDS.BASE_WEEK as BASE_WEEK comment = 'Week the index equals 100.',
    CATEGORY_TRENDS.IS_FOOD_CATEGORY as IS_FOOD_CATEGORY comment = 'TRUE for food and drink categories.',

    ZIP_CODES.ZIP_CODE as ZIP_CODE comment = 'Georgia 5-digit ZIP code.'
)

metrics (
    PRODUCTS.PRODUCT_COUNT as COUNT(PRODUCTS.PRODUCT_KEY) comment = 'Number of products.',
    STORE_PRICES.LOWEST_PRICE as MIN(STORE_PRICES.CURRENT_PRICE) comment = 'Lowest current price in the selection.',
    STORE_PRICES.MEDIAN_PRICE as MEDIAN(STORE_PRICES.CURRENT_PRICE) comment = 'Typical current price in the selection.',
    STORE_PRICES.PROMO_RATE as AVG(STORE_PRICES.PROMO_FLAG) comment = 'Share of product-store prices currently on sale.',
    RETAILER_COMPARISON.SHARED_PRODUCTS as COUNT(RETAILER_COMPARISON.UPC_A) comment = 'Products carried by both retailers.',
    RETAILER_COMPARISON.WALMART_CHEAPER_SHARE as AVG(RETAILER_COMPARISON.WALMART_CHEAPER_FLAG) comment = 'Share of shared products where Walmart beats the cheapest Kroger store (filter IS_PRICED_AT_BOTH).',
    WEEKLY_PRICES.AVG_WEEKLY_PRICE as AVG(WEEKLY_PRICES.EFFECTIVE_PRICE) comment = 'Average effective price over the selected weeks.'
)

comment = 'Grocery prices for Kroger (81 Atlanta-area stores, prices vary by store) and Walmart (national online). Current prices, price history and changes, deal quality, unit prices, store brands, buy timing (rule plus ML forecast), Kroger vs Walmart for identical products, availability, and category price trends. Built by the grocery_price_project dbt project.'

ai_sql_generation 'Current prices: filter STORE_PRICES.IS_CURRENTLY_LISTED = TRUE (BUY_SIGNALS likewise). For rankings across products use PRODUCT_PRICES so a product is not repeated per store. Compare Kroger vs Walmart only through RETAILER_COMPARISON with IS_PRICED_AT_BOTH = TRUE. Compare unit prices only within one UNIT_BASIS and prefer PARSE_CONFIDENCE = high. For food questions filter PRODUCTS.IS_FOOD = TRUE. Match product names with ILIKE. Always return the as-of date or week column. Weeks with no collection are absent, never treat them as unchanged prices. Round dollars to 2 decimals.'

with extension (CA = '{{ tojson({"verified_queries": verified_queries}) | replace("'", "''") }}')
