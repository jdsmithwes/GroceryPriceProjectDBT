# grocery-ingest — container image for the weekly Kroger + Aldi (+ Publix,
# once verified) ingestion pipeline. Built to run as an ECS Fargate task,
# triggered by EventBridge Scheduler. See Orchestration/README.md.
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
# KROGER_CLIENT_ID/KROGER_CLIENT_SECRET/AWS_* directly as environment
# variables (from Secrets Manager, see the task definition) rather than
# via .env. But it only stays harmless if PROJECT_ROOT's parent-count still
# lands somewhere that isn't a real, different .env — flattening this
# layout would be an easy way to reintroduce that exact gotcha silently.

FROM python:3.12-slim

WORKDIR /app

# Kroger pricing script — same relative depth as the real repo:
# API Scripts/Kroger Scripts/Product Pricing/<script>
# JSON-array form is required here, not shell form — paths contain spaces
# and shell-form COPY with backslash line continuation doesn't parse
# multiple independently-quoted arguments reliably.
COPY ["API Scripts/Kroger Scripts/Product Pricing/Kroger_Pricing_2026-08-10.py", \
      "API Scripts/Kroger Scripts/Product Pricing/"]

# Aldi/Publix ingestion — same relative depth as the real repo.
COPY ["API Scripts/Aldi Publix Scripts/ingest.py", \
      "API Scripts/Aldi Publix Scripts/adapters.py", \
      "API Scripts/Aldi Publix Scripts/"]

# Dependencies for both codebases. boto3 isn't in the top-level
# requirements.txt (an existing gap there, not new to this image) but both
# codebases use it for S3 upload — installed explicitly here regardless.
RUN pip install --no-cache-dir \
      requests \
      pandas \
      boto3 \
      httpx \
      python-dotenv

COPY Orchestration/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
