# grocery-ingest — container image for the weekly Kroger + Walmart
# ingestion pipeline. Built to run as an ECS Fargate task, triggered by
# EventBridge Scheduler. See Orchestration/README.md.
#
# Build from the REPO ROOT (not this folder), so the COPY paths below match
# the real repo layout exactly:
#   docker build -f Orchestration/Dockerfile -t grocery-ingest .
#
# Preserving each script's real relative folder depth is deliberate, not
# cosmetic: Kroger_Pricing_2026-08-10.py computes PROJECT_ROOT as
# Path(__file__).resolve().parent.parent.parent.parent (see the
# "PROJECT_ROOT gotcha" in .claude/instructions.md) and tries to load a
# .env file from there. In this container that file doesn't exist and
# load_dotenv() silently no-ops — harmless, since ECS injects
# KROGER_CLIENT_ID/KROGER_CLIENT_SECRET/WALMART_*/AWS_* directly as
# environment variables (from Secrets Manager, see the task definition)
# rather than via .env. But it only stays harmless if PROJECT_ROOT's
# parent-count still lands somewhere that isn't a real, different .env —
# flattening this layout would be an easy way to reintroduce that exact
# gotcha silently.

FROM python:3.12-slim

WORKDIR /app

# Kroger pricing script — same relative depth as the real repo:
# API Scripts/Kroger Scripts/Product Pricing/<script>
# JSON-array form is required here, not shell form — paths contain spaces
# and shell-form COPY with backslash line continuation doesn't parse
# multiple independently-quoted arguments reliably.
COPY ["API Scripts/Kroger Scripts/Product Pricing/Kroger_Pricing_2026-08-10.py", \
      "API Scripts/Kroger Scripts/Product Pricing/"]

# Walmart catalog script — same relative depth as the real repo.
COPY ["API Scripts/Walmart Scripts/entire_productcatalog_walmart.py", \
      "API Scripts/Walmart Scripts/"]

# Dependencies. boto3 isn't in the top-level requirements.txt (an existing
# gap there, not new to this image) but the Kroger/Walmart scripts use it
# for S3 upload and record_run.py needs it too — installed explicitly here
# regardless. cryptography is required by the Walmart script's RSA
# request signing (removed httpx here 2026-08-31 — it was only ever used
# by the Aldi/Publix codebase, which no longer exists in this project).
RUN pip install --no-cache-dir \
      requests \
      pandas \
      boto3 \
      cryptography \
      python-dotenv

COPY Orchestration/entrypoint.sh /app/entrypoint.sh
COPY Orchestration/record_run.py /app/record_run.py
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
