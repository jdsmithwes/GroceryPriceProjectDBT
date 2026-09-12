import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Kroger Product Catalog", layout="wide")
st.title("Kroger Product Catalog")

session = get_active_session()

STOCK_LABELS = {
    "HIGH": "In stock",
    "LOW": "Low stock",
    "TEMPORARILY_OUT_OF_STOCK": "Out of stock",
}


@st.cache_data(ttl=600)
def load_stores():
    # Only list stores that actually have current pricing data — the
    # locations table covers all 81 Kroger stores, but the pricing/
    # inventory pipeline has so far only ever been run against a subset
    # of them. Without this filter the dropdown could default to a store
    # with zero data and make the app look broken.
    return session.sql("""
        SELECT
            l.LOCATION_ID,
            l.NAME,
            l.ADDRESS_LINE1,
            l.CITY,
            l.STATE,
            l.ZIP_CODE
        FROM GROCERYDBTPROJECT.GROCERY_INTERMEDIATE.DBT_INT_KROGER_LOCATIONS_CURRENT l
        WHERE l.LOCATION_ID IS NOT NULL AND l.NAME IS NOT NULL
          AND l.LOCATION_ID IN (
              SELECT DISTINCT LOCATION_ID
              FROM GROCERYDBTPROJECT.GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRICE_HISTORY
              WHERE IS_CURRENT = TRUE
          )
        ORDER BY l.CITY, l.NAME
        LIMIT 200
    """).to_pandas()


@st.cache_data(ttl=600)
def load_products(search_term, brand_filter, limit, location_id, price_only):
    query = """
        SELECT
            p.PRODUCT_ID,
            p.BRAND,
            p.DESCRIPTION,
            p.CATEGORIES,
            p.SIZE,
            p.IMAGE_URL,
            ph.PRICE_REGULAR,
            ph.PRICE_PROMO,
            s.STOCK_LEVEL,
            s.CURBSIDE,
            s.DELIVERY,
            s.IN_STORE,
            s.SHIP_TO_HOME
        FROM GROCERYDBTPROJECT.GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRODUCT_CATALOG_CURRENT p
        LEFT JOIN GROCERYDBTPROJECT.GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRICE_HISTORY ph
            ON p.PRODUCT_ID = ph.PRODUCT_ID
            AND ph.LOCATION_ID = ?
            AND ph.IS_CURRENT = TRUE
        LEFT JOIN GROCERYDBTPROJECT.GROCERY_INTERMEDIATE.DBT_INT_KROGER_ITEMS_CURRENT s
            ON p.PRODUCT_ID = s.PRODUCT_ID
            AND s.LOCATION_ID = ?
        WHERE p.IMAGE_URL IS NOT NULL
    """
    params = [location_id, location_id]
    if search_term:
        query += " AND LOWER(p.DESCRIPTION) LIKE ?"
        params.append(f"%{search_term.lower()}%")
    if brand_filter and brand_filter != "All":
        query += " AND p.BRAND = ?"
        params.append(brand_filter)
    if price_only:
        query += " AND ph.PRICE_REGULAR IS NOT NULL"
    query += " LIMIT ?"
    params.append(int(limit))
    return session.sql(query, params=params).to_pandas()


@st.cache_data(ttl=600)
def load_brands():
    df = session.sql("""
        SELECT DISTINCT BRAND
        FROM GROCERYDBTPROJECT.GROCERY_INTERMEDIATE.DBT_INT_KROGER_PRODUCT_CATALOG_CURRENT
        WHERE BRAND IS NOT NULL
        ORDER BY BRAND
        LIMIT 200
    """).to_pandas()
    return ["All"] + df["BRAND"].tolist()


stores = load_stores()

if stores.empty:
    st.error("No store locations found. Pricing and inventory cannot be shown.")
    st.stop()

stores = stores.copy()
stores["LABEL"] = (
    stores["NAME"] + " — " + stores["CITY"] + ", " + stores["STATE"] + " " + stores["ZIP_CODE"]
)

store_col, search_col, brand_col, limit_col = st.columns([3, 3, 2, 1])
with store_col:
    store_label = st.selectbox("Store location", stores["LABEL"].tolist())
with search_col:
    search = st.text_input("Search products", placeholder="e.g. milk, bread, chicken")
with brand_col:
    brands = load_brands()
    brand = st.selectbox("Filter by brand", brands)
with limit_col:
    limit = st.selectbox("Results", [25, 50, 100], index=0)

selected_store = stores[stores["LABEL"] == store_label].iloc[0]
location_id = selected_store["LOCATION_ID"]

st.caption(
    f"Pricing & inventory shown for **{selected_store['NAME']}** — "
    f"{selected_store['ADDRESS_LINE1']}, {selected_store['CITY']}, "
    f"{selected_store['STATE']} {selected_store['ZIP_CODE']}"
)

price_only = st.checkbox("Only show products with a current price at this store", value=False)

products = load_products(search, brand, limit, location_id, price_only)

if products.empty:
    st.info("No products found matching your criteria.")
else:
    st.caption(f"Showing {len(products)} products")

    cols_per_row = 4
    for i in range(0, len(products), cols_per_row):
        cols = st.columns(cols_per_row)
        for j, col in enumerate(cols):
            idx = i + j
            if idx < len(products):
                row = products.iloc[idx]
                with col:
                    if row["IMAGE_URL"]:
                        st.image(row["IMAGE_URL"], use_column_width=True)
                    st.markdown(f"**{row['DESCRIPTION']}**")
                    st.caption(f"{row['BRAND'] or 'Unknown brand'} · {row['SIZE'] or ''}")

                    if row["PRICE_REGULAR"] is not None:
                        if row["PRICE_PROMO"] is not None:
                            st.markdown(
                                f"~~${row['PRICE_REGULAR']:.2f}~~ **${row['PRICE_PROMO']:.2f}** (promo)"
                            )
                        else:
                            st.markdown(f"**${row['PRICE_REGULAR']:.2f}**")

                        stock_label = STOCK_LABELS.get(row["STOCK_LEVEL"], "Stock unknown")
                        st.caption(f"Stock: {stock_label}")

                        fulfillment = []
                        if row["IN_STORE"]:
                            fulfillment.append("In-store")
                        if row["CURBSIDE"]:
                            fulfillment.append("Pickup")
                        if row["DELIVERY"]:
                            fulfillment.append("Delivery")
                        if row["SHIP_TO_HOME"]:
                            fulfillment.append("Ship to home")
                        if fulfillment:
                            st.caption(" · ".join(fulfillment))
                    else:
                        st.caption("Not available at this store")
