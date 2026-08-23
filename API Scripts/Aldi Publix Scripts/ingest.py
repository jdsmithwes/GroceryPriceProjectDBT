"""
grocery_ingest — polite, store-scoped grocery price ingestion.

Design notes
------------
1. Price is ALWAYS store-scoped. A record without a store_id is worthless for
   comparison, so store resolution happens before product fetching.
2. Land raw, normalize later. Adapters emit a thin normalized record plus the
   untouched source payload. NDJSON -> Snowflake VARIANT -> dbt does the rest.
   Never lose fidelity at ingest time; you cannot re-scrape yesterday.
3. Politeness is a first-class citizen, not a decorator. robots.txt, a per-host
   token bucket, backoff, and an honest User-Agent are baked into the client.
4. Adapters are dumb. Discovery + fetch + shallow parse. No business logic.

Deps: httpx, tenacity, pyarrow (optional), python-dateutil
    pip install httpx tenacity pyarrow
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import random
import sys
import time
import urllib.robotparser
from abc import ABC, abstractmethod
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from enum import Enum
from pathlib import Path
from typing import Any, AsyncIterator, Optional
from urllib.parse import urlparse

import httpx

if sys.version_info < (3, 10):  # dataclass(slots=True) landed in 3.10
    raise RuntimeError(
        f"grocery_ingest needs Python 3.10+, found {sys.version.split()[0]}. "
        "Create the venv with a newer interpreter: python3.12 -m venv .venv"
    )

log = logging.getLogger("grocery_ingest")

USER_AGENT = (
    "grocery-price-research/0.1 (+personal price comparison project; "
    "contact: you@example.com)"
)


# --------------------------------------------------------------------------
# Models
# --------------------------------------------------------------------------


class PriceSurface(str, Enum):
    """
    WHICH price you are looking at. This is not metadata — it is part of the
    grain, because the same SKU at the same store on the same day genuinely
    has different prices on different surfaces.

    SHELF     — in-store / pickup price set by the retailer. The real one.
    PICKUP    — retailer-operated pickup. Normally equals SHELF; kept separate
                because "normally" is not "always".
    THIRDPARTY— marketplace-fulfilled (Instacart et al). Marked up over shelf
                by a margin that varies BY ITEM. Not correctable. Comparable
                only against other THIRDPARTY prices.
    UNKNOWN   — surface could not be determined. Never mix these into an
                analysis; quarantine and go look at the raw payload.
    """

    SHELF = "shelf"
    PICKUP = "pickup"
    THIRDPARTY = "thirdparty"
    UNKNOWN = "unknown"

    @property
    def comparable(self) -> bool:
        """Safe to put in a cross-retailer basket comparison?"""
        return self in (PriceSurface.SHELF, PriceSurface.PICKUP)


@dataclass(slots=True)
class Store:
    """A physical store location. Pricing is scoped to one of these."""

    retailer: str
    store_id: str
    name: Optional[str] = None
    street: Optional[str] = None
    city: Optional[str] = None
    state: Optional[str] = None
    postal_code: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    raw: dict[str, Any] = field(default_factory=dict, repr=False)


@dataclass(slots=True)
class PriceObservation:
    """One (product, store, moment) price fact. This is the grain of the table."""

    retailer: str
    store_id: str
    sku: str                      # retailer-internal id
    name: str
    price: Optional[Decimal]      # what you'd pay today
    observed_at: datetime
    price_surface: "PriceSurface"  # REQUIRED. An unlabeled price is a liability.

    upc: Optional[str] = None     # the cross-retailer join key. Guard it jealously.
    brand: Optional[str] = None
    size_text: Optional[str] = None       # "12 oz", "2 ct" — parse downstream
    regular_price: Optional[Decimal] = None
    promo_text: Optional[str] = None      # "2 for $5", "BOGO"
    unit_price: Optional[Decimal] = None
    unit_of_measure: Optional[str] = None
    in_stock: Optional[bool] = None
    category_path: Optional[str] = None
    source_url: Optional[str] = None
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @property
    def observation_key(self) -> str:
        """Stable hash for idempotent loads / dedupe on re-runs."""
        # price_surface is IN the key on purpose. Without it, the shelf price
        # and the marked-up third-party price for the same SKU collide on the
        # same key, and whichever lands second silently wins. That is exactly
        # the corruption we are defending against.
        basis = (
            f"{self.retailer}|{self.store_id}|{self.sku}"
            f"|{self.price_surface.value}|{self.observed_at:%Y-%m-%d}"
        )
        return hashlib.sha256(basis.encode()).hexdigest()[:32]

    def to_json(self) -> str:
        d = asdict(self)
        d["observed_at"] = self.observed_at.isoformat()
        d["price_surface"] = self.price_surface.value
        d["is_comparable"] = self.price_surface.comparable
        d["observation_key"] = self.observation_key
        for k in ("price", "regular_price", "unit_price"):
            if d[k] is not None:
                d[k] = str(d[k])
        return json.dumps(d, default=str)


# --------------------------------------------------------------------------
# Polite HTTP layer
# --------------------------------------------------------------------------


class TokenBucket:
    """Per-host rate limiter. Async-safe, refills continuously."""

    def __init__(self, rate_per_sec: float, burst: int = 3):
        self.rate = rate_per_sec
        self.capacity = burst
        self._tokens = float(burst)
        self._last = time.monotonic()
        self._lock = asyncio.Lock()

    async def acquire(self) -> None:
        async with self._lock:
            now = time.monotonic()
            self._tokens = min(
                self.capacity, self._tokens + (now - self._last) * self.rate
            )
            self._last = now
            if self._tokens < 1:
                wait = (1 - self._tokens) / self.rate
                await asyncio.sleep(wait)
                self._tokens = 0.0
                self._last = time.monotonic()
            else:
                self._tokens -= 1


class PoliteClient:
    """
    httpx wrapper that:
      - checks and caches robots.txt per host, and honors Crawl-delay
      - rate limits per host
      - retries idempotent failures with exponential backoff + jitter
      - stops immediately on 403/429 rather than hammering
    """

    def __init__(
        self,
        rate_per_sec: float = 0.5,
        burst: int = 2,
        timeout: float = 20.0,
        respect_robots: bool = True,
    ):
        self._client = httpx.AsyncClient(
            timeout=timeout,
            follow_redirects=True,
            headers={
                "User-Agent": USER_AGENT,
                "Accept": "application/json, text/html;q=0.9",
                "Accept-Language": "en-US,en;q=0.9",
            },
        )
        self._default_rate = rate_per_sec
        self._burst = burst
        self._buckets: dict[str, TokenBucket] = {}
        self._robots: dict[str, urllib.robotparser.RobotFileParser] = {}
        self.respect_robots = respect_robots

    async def __aenter__(self) -> "PoliteClient":
        return self

    async def __aexit__(self, *exc) -> None:
        await self._client.aclose()

    def _bucket(self, host: str) -> TokenBucket:
        if host not in self._buckets:
            self._buckets[host] = TokenBucket(self._default_rate, self._burst)
        return self._buckets[host]

    async def _allowed(self, url: str) -> bool:
        if not self.respect_robots:
            return True
        parts = urlparse(url)
        host = parts.netloc
        if host not in self._robots:
            rp = urllib.robotparser.RobotFileParser()
            robots_url = f"{parts.scheme}://{host}/robots.txt"
            try:
                resp = await self._client.get(robots_url, timeout=10.0)
                rp.parse(resp.text.splitlines() if resp.status_code == 200 else [])
            except Exception:
                rp.parse([])  # unreachable robots.txt => treat as permissive but slow
            self._robots[host] = rp
            delay = rp.crawl_delay(USER_AGENT)
            if delay:
                log.info("%s advertises Crawl-delay=%ss; honoring it", host, delay)
                self._buckets[host] = TokenBucket(1.0 / float(delay), burst=1)
        return self._robots[host].can_fetch(USER_AGENT, url)

    async def request(
        self, method: str, url: str, *, attempts: int = 3, **kw
    ) -> httpx.Response:
        if not await self._allowed(url):
            raise PermissionError(f"robots.txt disallows {url}")

        host = urlparse(url).netloc
        last_exc: Optional[Exception] = None

        for i in range(attempts):
            await self._bucket(host).acquire()
            try:
                resp = await self._client.request(method, url, **kw)
            except (httpx.TimeoutException, httpx.TransportError) as exc:
                last_exc = exc
                await asyncio.sleep((2**i) + random.uniform(0, 1))
                continue

            if resp.status_code in (403, 401):
                # Bot protection or auth wall. Back off permanently — this is the
                # site telling you no. Switch to an official feed/API instead.
                raise BlockedError(f"{host} returned {resp.status_code} for {url}")
            if resp.status_code == 429:
                retry_after = float(resp.headers.get("Retry-After", 60))
                log.warning("%s rate limited us; sleeping %ss", host, retry_after)
                await asyncio.sleep(retry_after)
                continue
            if resp.status_code >= 500:
                last_exc = httpx.HTTPStatusError(
                    "server error", request=resp.request, response=resp
                )
                await asyncio.sleep((2**i) + random.uniform(0, 1))
                continue

            resp.raise_for_status()
            return resp

        raise last_exc or RuntimeError(f"exhausted attempts for {url}")

    async def get_json(self, url: str, **kw) -> Any:
        return (await self.request("GET", url, **kw)).json()

    async def get_text(self, url: str, **kw) -> str:
        return (await self.request("GET", url, **kw)).text


class BlockedError(RuntimeError):
    """The site actively refused us. Do not retry; do not evade."""


# --------------------------------------------------------------------------
# Adapter contract
# --------------------------------------------------------------------------


class RetailerAdapter(ABC):
    """
    One per retailer. Keep these thin: discover, fetch, shallow-parse.
    Anything clever (unit normalization, UPC matching, price history) belongs
    in dbt downstream, where it is testable and re-runnable.
    """

    retailer: str
    #  "api"      -> documented or stable JSON endpoint the site itself calls
    #  "html"     -> must parse markup; brittle, expect breakage
    #  "circular" -> only weekly-ad promo prices are public, not full catalog
    #  "platform" -> outsourced to a 3rd-party e-comm platform; per-store variance
    tier: str = "html"

    def __init__(self, client: PoliteClient):
        self.client = client

    @abstractmethod
    async def discover_stores(self, postal_code: str) -> list[Store]:
        """Resolve zip -> concrete store identifiers."""

    @abstractmethod
    async def fetch_prices(
        self, store: Store, categories: list[str]
    ) -> AsyncIterator[PriceObservation]:
        """Yield observations for a store. Should be a generator, not a list —
        these can be tens of thousands of rows per store."""

    @staticmethod
    def _money(value: Any) -> Optional[Decimal]:
        if value is None or value == "":
            return None
        try:
            return Decimal(str(value).replace("$", "").replace(",", "").strip())
        except Exception:
            return None

    @staticmethod
    def _now() -> datetime:
        return datetime.now(timezone.utc)


# --------------------------------------------------------------------------
# Adapters — see README for the reality check on each of these
# --------------------------------------------------------------------------


# Retailer implementations live in adapters.py — import them there.
# ingest.py stays transport + models + orchestration only.

try:
    from adapters import AldiAdapter, PublixAdapter  # noqa: E402
    ADAPTERS: dict[str, type[RetailerAdapter]] = {
        a.retailer: a for a in (PublixAdapter, AldiAdapter)
    }
except ImportError:  # core is usable standalone
    ADAPTERS = {}


# --------------------------------------------------------------------------
# Orchestration + landing
# --------------------------------------------------------------------------


class NDJSONSink:
    """
    Writes one file per (run_date, retailer, store). NDJSON because it maps
    cleanly to a Snowflake VARIANT stage load, and because a partial file from
    a crashed run is still fully parseable up to the last newline.

    Also tracks which local files have been written so the caller can upload
    each completed store's file to S3 as soon as that store is done, rather
    than batching every upload until the very end of the run — this project
    already learned that lesson the hard way with the Kroger pricing script:
    a crash mid-run with all persistence deferred to the end meant thousands
    of already-spent API calls produced zero durable output.
    """

    def __init__(self, root: Path):
        self.root = root
        self.counts: dict[str, int] = {}
        self.touched: set[Path] = set()

    def _path(self, obs: PriceObservation) -> Path:
        day = obs.observed_at.strftime("%Y-%m-%d")
        p = (
            self.root
            / f"dt={day}"
            / f"retailer={obs.retailer}"
            / f"surface={obs.price_surface.value}"
        )
        p.mkdir(parents=True, exist_ok=True)
        return p / f"store_{obs.store_id}.ndjson"

    @staticmethod
    def _s3_key(path: Path, retailer: str, root: Path) -> str:
        # Local layout is root/dt=X/retailer=Y/surface=Z/store_N.ndjson; S3
        # wants retailer as the top-level prefix, matching kroger/, walmart/,
        # etc. already in the bucket — so pull "retailer=Y" back out and
        # re-prepend just the retailer name in front of everything else.
        dt_part, _retailer_part, surface_part, filename = path.relative_to(root).parts
        return f"{retailer}/{dt_part}/{surface_part}/{filename}"

    def write(self, obs: PriceObservation) -> None:
        path = self._path(obs)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(obs.to_json() + "\n")
        self.counts[obs.retailer] = self.counts.get(obs.retailer, 0) + 1
        self.touched.add(path)

    def upload_new_to_s3(self, bucket: str, retailer: str, already_uploaded: set[Path]) -> set[Path]:
        """Upload any file touched since the last call that hasn't been
        uploaded yet. Returns the updated set of uploaded paths — the caller
        threads this through across calls so nothing gets uploaded twice."""
        import boto3

        s3 = boto3.client("s3")
        newly_uploaded = set()
        for path in self.touched - already_uploaded:
            key = self._s3_key(path, retailer, self.root)
            s3.upload_file(str(path), bucket, key)
            log.info("uploaded s3://%s/%s", bucket, key)
            newly_uploaded.add(path)
        return already_uploaded | newly_uploaded


S3_BUCKET = "grocerydbtprojectrawdata"


async def ingest_retailer(
    adapter: RetailerAdapter,
    postal_codes: list[str],
    categories: list[str],
    sink: NDJSONSink,
    max_stores_per_zip: int = 2,
    upload_to_s3: bool = True,
    uploaded: Optional[set[Path]] = None,
) -> set[Path]:
    """`uploaded` is threaded through across calls (and across retailers, via
    `run`) so a file already pushed to S3 never gets re-uploaded. Upload
    happens after each store finishes — success, handled error, or abort —
    not batched to the end of the whole run, so a crash partway through only
    costs the one store in flight, not every store already scraped."""
    uploaded = uploaded if uploaded is not None else set()

    for zipcode in postal_codes:
        try:
            stores = await adapter.discover_stores(zipcode)
        except (NotImplementedError, BlockedError) as exc:
            log.warning("[%s] store discovery unavailable: %s", adapter.retailer, exc)
            return uploaded
        except Exception:
            log.exception("[%s] store discovery failed for %s", adapter.retailer, zipcode)
            continue

        for store in stores[:max_stores_per_zip]:
            log.info("[%s] scraping store %s (%s)", adapter.retailer, store.store_id, store.city)
            blocked = False
            try:
                async for obs in adapter.fetch_prices(store, categories):
                    sink.write(obs)
            except BlockedError as exc:
                log.error("[%s] blocked, aborting retailer: %s", adapter.retailer, exc)
                blocked = True
            except NotImplementedError:
                log.warning("[%s] adapter not implemented yet", adapter.retailer)
                blocked = True
            except Exception:
                log.exception("[%s] store %s failed", adapter.retailer, store.store_id)
            finally:
                if upload_to_s3:
                    uploaded = sink.upload_new_to_s3(S3_BUCKET, adapter.retailer, uploaded)
            if blocked:
                return uploaded

    return uploaded


async def run(
    retailers: list[str],
    postal_codes: list[str],
    categories: list[str],
    out_dir: str = "./data/raw",
    upload_to_s3: bool = True,
) -> dict[str, int]:
    sink = NDJSONSink(Path(out_dir))
    uploaded: set[Path] = set()
    async with PoliteClient(rate_per_sec=0.5, burst=2) as client:
        # Sequential across retailers on purpose: concurrency belongs *within*
        # a retailer, bounded by its own bucket. Parallel retailers just makes
        # failures harder to read for zero wall-clock benefit at this volume.
        for name in retailers:
            cls = ADAPTERS.get(name)
            if cls is None:
                log.error("unknown retailer %s", name)
                continue
            uploaded = await ingest_retailer(
                cls(client), postal_codes, categories, sink,
                upload_to_s3=upload_to_s3, uploaded=uploaded,
            )
    return sink.counts


if __name__ == "__main__":
    import argparse

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s"
    )
    ap = argparse.ArgumentParser(description="Grocery price ingestion")
    ap.add_argument("--retailers", nargs="+", default=["publix"], choices=list(ADAPTERS))
    ap.add_argument("--zips", nargs="+", default=["30080"])
    ap.add_argument(
        "--categories",
        nargs="+",
        default=["milk", "eggs", "bread", "chicken breast", "bananas"],
        help="Start with a narrow basket. Full-catalog crawls come later.",
    )
    ap.add_argument("--out", default="./data/raw")
    ap.add_argument(
        "--no-s3-upload", action="store_true",
        help="Skip uploading to s3://grocerydbtprojectrawdata/ — local NDJSON only.",
    )
    args = ap.parse_args()

    counts = asyncio.run(
        run(args.retailers, args.zips, args.categories, args.out,
            upload_to_s3=not args.no_s3_upload)
    )
    log.info("wrote: %s", counts or "nothing")
