# Grocery Value Ontology

The single source of business definitions for the grocery value agent. Semantic
view descriptions and synonyms, agent instructions, and dbt mart docs all copy
from here. Change a definition here first, then propagate.

## Entities

| Entity | Meaning | Grain / key | Mart |
|---|---|---|---|
| Retailer | A grocery chain whose prices are collected: `kroger` or `walmart`. | `RETAILER` | attribute on every mart |
| Store | Where a price applies. Kroger: one of 81 Atlanta-area stores. Walmart: one virtual store, `Walmart (national online)`, because its catalog prices are national. | `STORE_ID` | `dim_store` |
| Product | One retailer's listing of an item. The same physical item at two retailers is two Products. | `RETAILER` + `PRODUCT_ID` (Kroger productId / Walmart itemId) | `dim_product` |
| Shared Product | A physical item both retailers carry, proven by an identical UPC. The only basis for like-for-like cross-retailer comparison. | `UPC_A` (12-digit UPC-A) | `fct_cross_retailer_price_comparison` |
| Price Observation | The price of a Product at a Store in a given week. | Product × Store × week | `fct_price_weekly` |
| Promotion | A temporary reduced price: Kroger `promo` price, or a Walmart sale price below its MSRP. | Price Observation where `IS_ON_PROMO` | `fct_price_weekly` |
| Unit Price | Effective price divided by normalized package size. | Product × Store, per `UNIT_BASIS` | summary/comparison marts |
| Recommendation | Whether now is a good time to buy, from the rule and the forecast. | Product (Kroger rolled up across stores; Walmart item) | `fct_buy_recommendation` |
| Basket | A shopper's list of items priced at each store. | Request-time (not stored) | `SP_COMPARE_BASKET` tool |

## Relationships

- A Retailer has many Stores; a Store belongs to one Retailer.
- A Retailer lists many Products; a Product belongs to one Retailer.
- A Shared Product links exactly one Kroger Product to one Walmart Product via `UPC_A`.
- A Price Observation belongs to one Product and one Store.
- Every Product maps to zero or more Common Categories via the retailer category crosswalk.

## Definitions

**Regular price** — the non-sale shelf price (Kroger `regular`; Walmart MSRP when present).

**Effective price** — what a shopper pays that week: Kroger promo price if any, else
regular; Walmart sale price if any, else MSRP. Every "cheapest" answer uses this.

**Exact match vs comparable** — *exact match*: same UPC at both retailers, a true
like-for-like comparison. *Comparable*: same Common Category, possibly a different
brand or size; label it as such and compare unit prices, never sticker prices.

**Kroger price for a comparison** — by default the **lowest** effective price across
Kroger stores (with the store named) and the **median** across stores; a specific
store, ZIP, or city when the shopper asks.

**Common Category** — a retailer-neutral category (e.g. Dairy, Snacks) from the
hand-curated crosswalk seed `retailer_category_crosswalk.csv`.

**Unit price / unit basis** — effective price per ounce, fluid ounce, pound, or count,
from the parsed package size. Compare only within the same unit basis. Each parse
carries `PARSE_CONFIDENCE` (`high`, `low`, `none`); state it when it's not `high`.

**Store brand** — a retailer's own label (e.g. Kroger, Simple Truth, Private Selection;
Great Value, Marketside), listed in `private_label_brands.csv`. Store-brand savings =
its unit price vs the national-brand median in the same Common Category and unit basis.

**Price drop / mover** — change in effective price between the current week and N
weeks ago (4, 8, or 12), in dollars and percent, for the same Product at the same Store.

**Historic low** — the lowest effective price observed for that Product at that Store
in the collected history. "History" means only what this pipeline has collected
(Kroger since August 2026, Walmart since September 2026).

**Deal quality** — `GENUINE`: promo price at or below the item's own historic regular-price
median by a meaningful margin. `ORDINARY`: a routine promo the item gets often.
`INFLATED_REFERENCE`: the "was" price (e.g. Walmart MSRP) sits above anything this
item has actually sold for, so the advertised discount overstates the saving.

**Rule signal** — current effective price vs the item's own history:
`GOOD_PRICE` (at or below its 25th percentile, or a promo at/below its historic low),
`HIGH_PRICE` (at or above its 75th percentile), `TYPICAL` (between),
`INSUFFICIENT_HISTORY` (fewer than 6 weekly observations).

**Forecast** — a Snowflake ML projection of the next 6 weeks of effective price, with an
80% interval. A second opinion only; it never overrides the rule signal.

**Recommendation** — `BUY_NOW` (rule good, forecast flat or rising), `BUY_NOW_OR_WAIT`
(rule good, forecast expects lower; includes `RETURN_BY_WEEK`), `WAIT` (rule high,
forecast expects lower), `NEUTRAL`, `INSUFFICIENT_HISTORY`.

**Shelf-stable / stock-up candidate** — shelf-stable: Kroger temperature `ambient`, or a
Walmart item in a shelf-stable Common Category. Stock-up candidate: shelf-stable and
currently `GOOD_PRICE` or at its historic low.

**Category price index** — weekly chained Jevons index per Retailer × Common Category:
the geometric mean of week-over-week price ratios across products observed in both
weeks (the method behind CPI elementary aggregates). Base week = 100.

**Data as of** — the most recent collection date behind an answer. Prices are collected
weekly; stock levels are as of that collection, not live.

## Scope

In scope: Kroger (81 Atlanta-area stores) and Walmart (national online catalog, Food
department) prices, promotions, unit prices, store brands, availability as of the
last collection, history-based timing, baskets, and category trends.

Out of scope: nutrition or medical advice, other retailers, coupons, loyalty or
membership pricing, delivery fees, forecasts beyond 6 weeks, live in-store stock
guarantees.
