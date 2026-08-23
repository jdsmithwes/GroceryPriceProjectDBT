---
description: Resume the Publix + ALDI adapter work from current state
---

Resume work on the grocery price ingestion adapters in
`API Scripts/Aldi Publix Scripts/`.

Do this before proposing any code:

1. Read `API Scripts/Aldi Publix Scripts/DECISIONS.md` (open threads section)
   and the README "Picking up from here" list.
2. Check whether `API Scripts/Aldi Publix Scripts/data/probe/` or
   `.../data/raw/` contain output from a real run, and whether anything has
   landed under `s3://grocerydbtprojectrawdata/aldi/` or `.../publix/`.
   Their absence means no endpoint has been verified live yet — say so
   plainly rather than assuming the config is correct.
3. Report which of these is the first unresolved step:
   - ALDI store discovery endpoint confirmed?
   - `PUBLIX_CONFIG` paths confirmed against a real payload?
   - Shelf-pricing `serviceType` confirmed via `calibrate`?
   - First live run completed and surface partitions inspected (locally and
     in S3)?
   - dbt normalization layer started (mirroring the Kroger staging layer in
     `DBT Transformations/grocery_price_project/`)?

Then start on that step, not a later one.

Constraints that override any convenience:

- Do not invent endpoint paths or field names. If something is unverified, run
  the probe or ask — a plausible guess that silently returns wrong data is the
  worst outcome here.
- Do not apply a markup correction factor to any price (see D5).
- Do not remove `price_surface` from `observation_key` (see D1).
- Do not soften the 403 handling (see D3).
- Do not batch S3 uploads to the end of a run (see D11) — this project has
  already hit that exact bug once with the Kroger pricing script.

If a probe reveals the real payload differs from `PUBLIX_CONFIG`, update the
config and note what changed in `DECISIONS.md` under D4.
