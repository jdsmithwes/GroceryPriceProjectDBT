"""Bounded ALDI live test — one page, then stop. Safe to run repeatedly."""
import asyncio, sys
from ingest import PoliteClient
from adapters import AldiAdapter

LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 10

async def main():
    async with PoliteClient(rate_per_sec=0.5, burst=1) as client:
        a = AldiAdapter(client)
        stores = await a.discover_stores("30080")
        s = stores[0]
        print(f"store: {s.store_id}  {s.name}  fallback={s.raw.get('_fallback', False)}\n")
        n = 0
        async for o in a.fetch_prices(s, []):
            print(f"  {o.price!s:>8}  {o.price_surface.value:<8} {o.brand or '-':<18} {o.name[:44]}")
            n += 1
            if n >= LIMIT:
                break
        print(f"\n{n} observations, surface={o.price_surface.value}, upc={o.upc}")

asyncio.run(main())
