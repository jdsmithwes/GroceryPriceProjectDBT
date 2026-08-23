"""
adapters.py — Publix + ALDI.

These two are written differently ON PURPOSE, because I know very different
amounts about each:

  ALDI   — endpoint shape is VERIFIED against a working open-source collector
           (github.com/stiles/aldi, MIT). Paths and field names are hardcoded
           because they are known good. Only store discovery is unverified.

  PUBLIX — endpoint shape is UNVERIFIED. I have no working reference. So the
           adapter is config-driven: URLs, JSON paths and field names live in
           a dict you edit, and there is a `probe` mode that dumps raw payloads
           so you can fill that dict in from DevTools in about ten minutes.
           Guessing field names in code and letting you discover the guesses
           were wrong at 2am is the worse option.

Run `python adapters.py probe publix --zip 30080` first. Fix ENDPOINTS. Then run.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable, Optional

from ingest import (
    BlockedError,
    PriceSurface,
    PoliteClient,
    PriceObservation,
    RetailerAdapter,
    Store,
)

log = logging.getLogger("grocery_ingest.adapters")


# --------------------------------------------------------------------------
# Tolerant extraction — so a renamed upstream field is a config edit, not a bug
# --------------------------------------------------------------------------


def pathget(obj: Any, path: str, default: Any = None) -> Any:
    """
    Resolve a dotted path with list indexing: "data[0].attributes.pagination.maxPage".
    Returns default on any miss instead of raising — upstream payloads are not
    a contract and half a record beats a stack trace.
    """
    cur = obj
    for part in path.replace("]", "").replace("[", ".").split("."):
        if part == "" or cur is None:
            continue
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return default
        elif isinstance(cur, dict):
            if part not in cur:
                return default
            cur = cur[part]
        else:
            return default
    return default if cur is None else cur


def first_present(obj: Any, paths: Iterable[str], default: Any = None) -> Any:
    """Try several candidate paths, take the first that resolves. This is how
    you survive a retailer renaming `price` to `currentPrice` mid-quarter."""
    for p in paths:
        val = pathget(obj, p)
        if val not in (None, "", []):
            return val
    return default


# --------------------------------------------------------------------------
# ALDI — verified
# --------------------------------------------------------------------------


class AldiAdapter(RetailerAdapter):
    """
    ALDI US runs Spryker. Two things follow from that and both matter:

      1. The JSON:API envelope is `data[0].attributes.<payload>`, NOT a bare
         list. Every response unwraps through that.
      2. The store handle is `merchantReference` (a service point, format
         "NNN-NNN", e.g. "479-022"). Pass a different one and you get different
         prices. This is your store_id.

    Catalog is ~7,800 SKUs. At 48/page that is ~163 requests — a full sweep is
    ~6 minutes at 0.5 req/s. Cheap. Run it daily without guilt.

    The detail endpoint is the expensive one: 7,800 more requests, ~4.5 hours.
    Do NOT hydrate every SKU every day. Hydrate only SKUs you have not seen
    (see SkuCache below) — the descriptive fields are near-static, only price
    moves, and price is already in the catalog response.

    Known gap: the catalog response carries NO UPC/GTIN. ALDI is ~90% private
    label so there is often no UPC to match on anyway. Cross-retailer joins to
    Publix will need fuzzy name+size matching, not a clean key. Plan for that.
    """

    retailer = "aldi"
    tier = "api"

    CATALOG_URL = "https://api.aldi.us/v1/catalog-search-product-offers"
    PRODUCT_URL = "https://api.aldi.us/v1/products/{sku}"
    STORE_URL = "https://api.aldi.us/v1/service-points"  # UNVERIFIED — probe it

    PAGE_SIZE = 48
    ITEMS_PATH = "data[0].attributes.catalogSearchProductOfferResults"
    MAXPAGE_PATH = "data[0].attributes.pagination.maxPage"

    # ALDI's origin check is real; without these you get an empty envelope.
    EXTRA_HEADERS = {
        "accept": "application/json, text/plain, */*",
        "origin": "https://new.aldi.us",
        "referer": "https://new.aldi.us/",
    }

    def __init__(self, client: PoliteClient, default_service_point: str = "479-022"):
        super().__init__(client)
        self.default_service_point = default_service_point

    # -- stores ------------------------------------------------------------

    async def discover_stores(self, postal_code: str) -> list[Store]:
        """
        UNVERIFIED endpoint. Falls back to the configured service point so the
        pipeline still runs end-to-end while you work out the real lookup.
        Probe the store selector on new.aldi.us to find the true path.
        """
        try:
            payload = await self.client.get_json(
                self.STORE_URL,
                params={"postalCode": postal_code, "serviceType": "pickup"},
                headers=self.EXTRA_HEADERS,
            )
            points = pathget(payload, "data", []) or []
            stores = [
                Store(
                    retailer=self.retailer,
                    store_id=str(
                        first_present(p, ["attributes.merchantReference", "id"])
                    ),
                    name=pathget(p, "attributes.name"),
                    city=pathget(p, "attributes.city"),
                    state=pathget(p, "attributes.state"),
                    postal_code=pathget(p, "attributes.zipCode", postal_code),
                    raw=p,
                )
                for p in points
            ]
            if stores:
                return stores
        except Exception as exc:
            log.warning("[aldi] store lookup unverified/failed (%s); using fallback", exc)

        return [
            Store(
                retailer=self.retailer,
                store_id=self.default_service_point,
                name=f"ALDI service point {self.default_service_point}",
                postal_code=postal_code,
                raw={"_fallback": True},
            )
        ]

    # -- prices ------------------------------------------------------------

    @staticmethod
    def _price_from(product: dict) -> tuple[Optional[Decimal], Optional[Decimal]]:
        """
        Spryker exposes prices two ways: `grossAmount` as integer CENTS, and
        `formattedPrice` as a display string. Prefer the integer — parsing
        "$2.75" is fine until you meet "2/$5.00" or "$1.29/lb".
        """
        gross = first_present(
            product, ["prices[0].grossAmount", "price.grossAmount", "grossAmount"]
        )
        if isinstance(gross, int):
            current = Decimal(gross) / 100
        else:
            current = RetailerAdapter._money(
                first_present(
                    product, ["prices[0].formattedPrice", "formattedPrice", "price"]
                )
            )

        was = first_present(
            product,
            ["prices[0].originalGrossAmount", "prices[1].grossAmount", "wasPrice"],
        )
        regular = Decimal(was) / 100 if isinstance(was, int) else None
        return current, regular

    async def fetch_prices(self, store: Store, categories: list[str]):
        """
        Sweeps the FULL catalog and ignores `categories` — for ALDI a whole-
        catalog crawl is cheaper than N keyword searches, and it gives you
        assortment/delisting signal for free. Category comes back on each row
        (categoryName/mainCategoryName), so filter downstream in dbt.
        """
        offset = 0
        max_page: Optional[int] = None
        page_num = 0

        while True:
            payload = await self.client.get_json(
                self.CATALOG_URL,
                params={
                    "currency": "USD",
                    "serviceType": "pickup",
                    "page[limit]": self.PAGE_SIZE,
                    "page[offset]": offset,
                    "sort": "relevance",
                    "merchantReference": store.store_id,
                },
                headers=self.EXTRA_HEADERS,
            )

            if max_page is None:
                max_page = pathget(payload, self.MAXPAGE_PATH)
                log.info("[aldi] store %s: %s pages", store.store_id, max_page)

            items = pathget(payload, self.ITEMS_PATH, []) or []
            if not items:
                break

            observed = self._now()
            for item in items:
                current, regular = self._price_from(item)
                sku = str(
                    first_present(item, ["productConcreteSku", "sku", "abstractSku"], "")
                )
                if not sku:
                    continue
                slug = pathget(item, "urlSlugText")
                yield PriceObservation(
                    retailer=self.retailer,
                    store_id=store.store_id,
                    sku=sku,
                    upc=None,  # not exposed; see class docstring
                    name=pathget(item, "name", ""),
                    brand=pathget(item, "brandName"),
                    size_text=pathget(item, "preFormattedUnitContent"),
                    price=current,
                    regular_price=regular,
                    unit_of_measure=pathget(item, "comparisonPriceUnit"),
                    unit_price=RetailerAdapter._money(
                        pathget(item, "comparisonPrice")
                    ),
                    in_stock=pathget(item, "isAvailable"),
                    category_path=" > ".join(
                        x for x in (
                            pathget(item, "mainCategoryName"),
                            pathget(item, "categoryName"),
                        ) if x
                    ) or None,
                    observed_at=observed,
                    # ALDI is read at serviceType=pickup, which is shelf price.
                    # Declared explicitly so it can never be silently compared
                    # against a marked-up Publix row.
                    price_surface=PriceSurface.PICKUP,
                    source_url=f"https://new.aldi.us/product/{slug}" if slug else None,
                    raw=item,
                )

            page_num += 1
            offset += self.PAGE_SIZE
            if max_page and page_num >= max_page:
                break
            if page_num > 500:  # runaway guard
                log.warning("[aldi] page guard tripped")
                break

    async def hydrate(self, sku: str, service_point: str) -> dict:
        """Descriptive fields only. Call sparingly — see class docstring."""
        payload = await self.client.get_json(
            self.PRODUCT_URL.format(sku=sku),
            params={"servicePoint": service_point, "serviceType": "pickup"},
            headers=self.EXTRA_HEADERS,
        )
        d = pathget(payload, "data", {}) or {}
        return {
            "sku": pathget(d, "sku", sku),
            "description": pathget(d, "description"),
            "categories": [c.get("name") for c in (pathget(d, "categories", []) or [])],
            "country_origin": pathget(d, "countryOrigin"),
            "image_url": pathget(d, "assets[0].url"),
            "warning_code": pathget(d, "warnings[0].key"),
            "warning_desc": pathget(d, "warnings[0].message"),
        }


class SkuCache:
    """
    Tracks which SKUs have already been hydrated, so daily runs only pay the
    detail-endpoint cost for genuinely new products. Turns a 4.5-hour job into
    a 2-minute one after day one.
    """

    def __init__(self, path: Path):
        self.path = path
        self.seen: set[str] = set()
        if path.exists():
            self.seen = set(json.loads(path.read_text()))

    def unseen(self, skus: Iterable[str]) -> list[str]:
        return [s for s in skus if s not in self.seen]

    def mark(self, skus: Iterable[str]) -> None:
        self.seen.update(skus)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(sorted(self.seen)))


# --------------------------------------------------------------------------
# PUBLIX — config-driven, because I have not verified any of this
# --------------------------------------------------------------------------


PUBLIX_CONFIG: dict[str, Any] = {
    # ---- EDIT ME after running: python adapters.py probe publix --zip 30080 ----
    # Everything below is a HYPOTHESIS. Confirm each against DevTools.
    "store": {
        "url": "https://services.publix.com/api/v1/storelocation",
        "params": {"types": "R", "count": 10},
        "zip_param": "zipCode",
        "items_path": "Stores",
        "fields": {
            "store_id": ["StoreNumber", "KEY", "storeNumber", "id"],
            "name": ["Name", "name"],
            "street": ["Address1", "addressLine1"],
            "city": ["City", "city"],
            "state": ["State", "state"],
            "postal_code": ["ZipCode", "postalCode"],
            "latitude": ["Latitude", "latitude"],
            "longitude": ["Longitude", "longitude"],
        },
    },
    "search": {
        "url": "https://services.publix.com/api/v4/product/search",
        # serviceType pins the fulfillment context. Getting this wrong is how
        # you silently ingest Instacart prices. Assert, do not assume.
        "params": {"count": 50, "serviceType": "instore"},
        "query_param": "query",
        "store_param": "storeNumber",
        "page_param": "page",
        "page_starts_at": 1,
        "items_path": "Products",
        "expected_surface": PriceSurface.SHELF,
        "fields": {
            "sku": ["ItemId", "Id", "productId", "id"],
            "upc": ["Upc", "upc", "gtin"],
            "name": ["Title", "Name", "name", "displayName"],
            "brand": ["Brand", "brand", "brandName"],
            "size_text": ["Size", "size", "packageSize"],
            "price": ["SalePrice", "CurrentPrice", "price", "pricing.current"],
            "regular_price": ["Price", "RegularPrice", "pricing.regular"],
            "promo_text": ["PromotionText", "SavingsText", "promotion.description"],
            "unit_price": ["UnitPrice", "pricing.unitPrice"],
            "unit_of_measure": ["UnitOfMeasure", "unitOfMeasure"],
            "in_stock": ["IsAvailable", "inStock", "available"],
        },
    },
}


class SurfaceDetector:
    """
    Works out whether a payload is Publix shelf pricing or a marketplace
    (Instacart) surface, by looking for tells that only one of them has.

    Deliberately NOT a markup estimator. Instacart's margin varies per item and
    per retailer agreement, so any correction factor you apply is wrong in a way
    that is invisible in the output. Label the price; never adjust it.

    Evidence is returned alongside the verdict so a wrong call is debuggable
    from the landed data instead of requiring a re-scrape.
    """

    # Substrings that betray a marketplace-fulfilled payload.
    THIRDPARTY_KEYS = {
        "retailer_id", "legacy_id", "instacart", "service_fee", "markup",
        "retailer_sku", "fulfillment_partner", "delivery_fee", "item_uuid",
    }
    THIRDPARTY_HOSTS = ("instacart.com", "instacart-", "cdn.instacart")

    # Publix's own catalog uses prefixed ids, e.g. "BMO-DSB-100017".
    PUBLIX_SKU_SHAPE = re.compile(r"^[A-Z]{2,4}-[A-Z]{2,4}-\d+$")

    @classmethod
    def detect(
        cls, payload: Any, sample_item: Optional[dict], expected: PriceSurface
    ) -> tuple[PriceSurface, float, list[str]]:
        blob = json.dumps(payload)[:200_000].lower()
        evidence: list[str] = []

        for key in cls.THIRDPARTY_KEYS:
            if f'"{key}"' in blob:
                evidence.append(f"thirdparty key {key!r}")
        for host in cls.THIRDPARTY_HOSTS:
            if host in blob:
                evidence.append(f"thirdparty host {host!r}")

        if evidence:
            return PriceSurface.THIRDPARTY, 0.9, evidence

        if sample_item:
            sku = str(
                first_present(sample_item, ["ItemId", "Id", "productId", "id"], "")
            )
            if cls.PUBLIX_SKU_SHAPE.match(sku):
                return expected, 0.8, [f"publix-native sku shape {sku!r}"]
            if sku.isdigit() and len(sku) > 8:
                return (
                    PriceSurface.UNKNOWN,
                    0.4,
                    [f"numeric sku {sku!r} — marketplace id shape, verify"],
                )

        return PriceSurface.UNKNOWN, 0.2, ["no distinguishing signal found"]


class PublixAdapter(RetailerAdapter):
    """
    Config-driven, because none of the endpoints are verified. When Publix
    renames a field you edit PUBLIX_CONFIG, not this class.

    THE INSTACART PROBLEM
    ---------------------
    Publix delivery/curbside is Instacart-powered and those prices carry a
    per-item markup over shelf price. Both surfaces return well-formed JSON
    with plausible numbers, so a mix-up does not look like an error — it looks
    like Publix got expensive. Against ALDI (which we read at pickup pricing)
    that would show up as a real-looking competitive gap that is pure artifact.

    Defense, in order:
      1. Pin `serviceType` in the request so we ASK for one surface.
      2. Detect the surface in the response; do not trust the request.
      3. If detected != expected, or detection is UNKNOWN, QUARANTINE rather
         than emit. Quarantined rows still land (surface=unknown partition) so
         nothing is lost, but they carry is_comparable=false and are excluded
         from baskets downstream.
      4. Never adjust a price. Labeling is the whole strategy.

    Set strict=False only to explore; leave it True for anything you will
    actually analyze.
    """

    retailer = "publix"
    tier = "api"

    def __init__(
        self,
        client: PoliteClient,
        config: Optional[dict] = None,
        strict: bool = True,
    ):
        super().__init__(client)
        self.cfg = config or PUBLIX_CONFIG
        self.strict = strict
        self.surface_report: dict[str, int] = {}

    def _map(self, item: dict, fields: dict[str, list[str]]) -> dict:
        return {k: first_present(item, paths) for k, paths in fields.items()}

    async def discover_stores(self, postal_code: str) -> list[Store]:
        c = self.cfg["store"]
        payload = await self.client.get_json(
            c["url"], params={**c["params"], c["zip_param"]: postal_code}
        )
        items = pathget(payload, c["items_path"], []) or []
        if not items:
            log.warning(
                "[publix] no stores at path %r — run `probe publix` and fix "
                "PUBLIX_CONFIG['store']['items_path']", c["items_path"]
            )
        out = []
        for it in items:
            m = self._map(it, c["fields"])
            if not m.get("store_id"):
                continue
            out.append(
                Store(
                    retailer=self.retailer,
                    store_id=str(m["store_id"]),
                    name=m.get("name"),
                    street=m.get("street"),
                    city=m.get("city"),
                    state=m.get("state"),
                    postal_code=m.get("postal_code") or postal_code,
                    latitude=m.get("latitude"),
                    longitude=m.get("longitude"),
                    raw=it,
                )
            )
        return out

    async def fetch_prices(self, store: Store, categories: list[str]):
        c = self.cfg["search"]
        expected: PriceSurface = c.get("expected_surface", PriceSurface.SHELF)

        for term in categories:
            page = c["page_starts_at"]
            seen_on_prev_page: set[str] = set()

            while True:
                payload = await self.client.get_json(
                    c["url"],
                    params={
                        **c["params"],
                        c["store_param"]: store.store_id,
                        c["query_param"]: term,
                        c["page_param"]: page,
                    },
                )
                items = pathget(payload, c["items_path"], []) or []
                if not items:
                    break

                surface, confidence, evidence = SurfaceDetector.detect(
                    payload, items[0], expected
                )
                self.surface_report[surface.value] = (
                    self.surface_report.get(surface.value, 0) + len(items)
                )

                if surface != expected:
                    log.warning(
                        "[publix] '%s' p%s: expected %s, detected %s (%.0f%%) — %s",
                        term, page, expected.value, surface.value,
                        confidence * 100, "; ".join(evidence),
                    )
                    if self.strict and surface is PriceSurface.THIRDPARTY:
                        # Marked-up prices. Landing them mixed in is worse than
                        # having no Publix data at all, because it poisons every
                        # comparison quietly. Stop this term.
                        log.error(
                            "[publix] marketplace pricing detected for '%s'; "
                            "skipping. Fix serviceType in PUBLIX_CONFIG.", term
                        )
                        break

                observed = self._now()
                page_skus: set[str] = set()
                for it in items:
                    m = self._map(it, c["fields"])
                    sku = m.get("sku")
                    if not sku:
                        continue
                    page_skus.add(str(sku))
                    yield PriceObservation(
                        retailer=self.retailer,
                        store_id=store.store_id,
                        sku=str(sku),
                        upc=str(m["upc"]) if m.get("upc") else None,
                        name=m.get("name") or "",
                        brand=m.get("brand"),
                        size_text=m.get("size_text"),
                        price=self._money(m.get("price"))
                        or self._money(m.get("regular_price")),
                        regular_price=self._money(m.get("regular_price")),
                        promo_text=m.get("promo_text"),
                        unit_price=self._money(m.get("unit_price")),
                        unit_of_measure=m.get("unit_of_measure"),
                        in_stock=m.get("in_stock"),
                        category_path=term,
                        observed_at=observed,
                        price_surface=surface,
                        source_url=c["url"],
                        raw={
                            **it,
                            "_surface_confidence": confidence,
                            "_surface_evidence": evidence,
                        },
                    )

                if page_skus and page_skus == seen_on_prev_page:
                    log.debug("[publix] '%s' page %s repeated; stopping", term, page)
                    break
                seen_on_prev_page = page_skus

                page += 1
                if page > c["page_starts_at"] + 39:
                    break


async def calibrate(
    zipcode: str, terms: list[str], service_types: list[str]
) -> None:
    """
    Empirically measure the gap between fulfillment surfaces instead of assuming
    one. Runs the same basket under each serviceType and reports the per-item
    price ratio.

    Read the SPREAD, not the average. A tight spread means the two surfaces
    differ by a near-constant factor. A wide one means the markup is per-item —
    in which case no correction is possible and surface separation is the only
    valid approach. Expect the latter.
    """
    from statistics import median

    by_service: dict[str, dict[str, Decimal]] = {}

    async with PoliteClient(rate_per_sec=0.5) as client:
        for svc in service_types:
            cfg = json.loads(json.dumps(PUBLIX_CONFIG, default=str))
            cfg["search"]["params"]["serviceType"] = svc
            cfg["search"]["expected_surface"] = PriceSurface.UNKNOWN
            adapter = PublixAdapter(client, cfg, strict=False)

            stores = await adapter.discover_stores(zipcode)
            if not stores:
                print(f"no stores for {zipcode}; fix PUBLIX_CONFIG first")
                return

            prices: dict[str, Decimal] = {}
            async for obs in adapter.fetch_prices(stores[0], terms):
                if obs.price is not None:
                    prices.setdefault(obs.sku, obs.price)
            by_service[svc] = prices
            print(f"{svc:>12}: {len(prices)} priced SKUs  "
                  f"surfaces={adapter.surface_report}")

    if len(by_service) < 2:
        return
    a, b = service_types[0], service_types[1]
    common = set(by_service[a]) & set(by_service[b])
    if not common:
        print("\nno overlapping SKUs — cannot compare surfaces")
        return

    ratios = [float(by_service[b][s] / by_service[a][s]) for s in common
              if by_service[a][s] > 0]
    ratios.sort()
    print(f"\n{len(common)} overlapping SKUs, {b} vs {a}")
    print(f"  median ratio : {median(ratios):.3f}")
    print(f"  p10 / p90    : {ratios[len(ratios)//10]:.3f} / "
          f"{ratios[-max(1,len(ratios)//10)]:.3f}")
    spread = ratios[-max(1,len(ratios)//10)] - ratios[len(ratios)//10]
    print(f"  spread       : {spread:.3f}")
    if spread > 0.05:
        print("\n  => Markup is PER-ITEM. No correction factor is valid.")
        print("     Keep surfaces separate; compare like to like only.")
    else:
        print("\n  => Near-constant offset, but still do not 'correct' it.")
        print("     Label the surface and filter downstream.")


# --------------------------------------------------------------------------
# Probe — run this BEFORE trusting any config above
# --------------------------------------------------------------------------


async def probe(retailer: str, zipcode: str, term: str, out: Path) -> None:
    """
    Fires one request at each configured endpoint and dumps the raw JSON plus a
    flattened key inventory. Diff that against the `fields` maps to see exactly
    which paths are real. This is the ten minutes that saves the afternoon.
    """
    out.mkdir(parents=True, exist_ok=True)

    def keys_of(obj: Any, prefix: str = "", depth: int = 0) -> list[str]:
        if depth > 4:
            return []
        found = []
        if isinstance(obj, dict):
            for k, v in obj.items():
                p = f"{prefix}.{k}" if prefix else k
                found.append(f"{p}  ({type(v).__name__})")
                found += keys_of(v, p, depth + 1)
        elif isinstance(obj, list) and obj:
            found += keys_of(obj[0], f"{prefix}[0]", depth + 1)
        return found

    async with PoliteClient(rate_per_sec=0.5) as client:
        targets = []
        if retailer == "publix":
            s, q = PUBLIX_CONFIG["store"], PUBLIX_CONFIG["search"]
            targets = [
                ("store", s["url"], {**s["params"], s["zip_param"]: zipcode}, {}),
                ("search", q["url"],
                 {**q["params"], q["store_param"]: "00024", q["query_param"]: term}, {}),
            ]
        elif retailer == "aldi":
            a = AldiAdapter(client)
            targets = [
                ("store", a.STORE_URL,
                 {"postalCode": zipcode, "serviceType": "pickup"}, a.EXTRA_HEADERS),
                ("catalog", a.CATALOG_URL,
                 {"currency": "USD", "serviceType": "pickup", "page[limit]": 5,
                  "page[offset]": 0, "sort": "relevance",
                  "merchantReference": a.default_service_point}, a.EXTRA_HEADERS),
            ]

        for label, url, params, headers in targets:
            try:
                resp = await client.request("GET", url, params=params, headers=headers)
                body = resp.json()
            except BlockedError as exc:
                print(f"\n### {label}: BLOCKED — {exc}")
                print("    This endpoint refuses automated access. Do not work "
                      "around it; find an official feed or drop this source.")
                continue
            except Exception as exc:
                print(f"\n### {label}: FAILED — {type(exc).__name__}: {exc}")
                continue

            path = out / f"{retailer}_{label}.json"
            path.write_text(json.dumps(body, indent=2)[:400_000])
            print(f"\n### {label}: OK -> {path}")
            for k in keys_of(body)[:60]:
                print("   ", k)


if __name__ == "__main__":
    import argparse

    logging.basicConfig(level=logging.INFO, format="%(levelname)-7s %(message)s")
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("probe", help="dump raw payloads + key inventory")
    p.add_argument("retailer", choices=["publix", "aldi"])
    p.add_argument("--zip", default="30080")
    p.add_argument("--term", default="milk")
    p.add_argument("--out", type=Path, default=Path("./data/probe"))

    c = sub.add_parser("calibrate",
                       help="measure the real gap between fulfillment surfaces")
    c.add_argument("--zip", default="30080")
    c.add_argument("--terms", nargs="+",
                   default=["milk", "eggs", "bread", "bananas", "orange juice"])
    c.add_argument("--service-types", nargs="+",
                   default=["instore", "delivery"])

    args = ap.parse_args()
    if args.cmd == "probe":
        asyncio.run(probe(args.retailer, args.zip, args.term, args.out))
    elif args.cmd == "calibrate":
        asyncio.run(calibrate(args.zip, args.terms, args.service_types))
