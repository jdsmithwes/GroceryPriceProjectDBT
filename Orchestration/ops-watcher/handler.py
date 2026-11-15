"""
grocery-ops-watcher — the one watcher that lives outside Snowflake.

Every day it asks Snowflake one question — "has the ops supervisor run in the
last 26 hours?" — through the SQL API with a dedicated read-only key-pair user,
and emails Proton through SNS if the answer is no (or if Snowflake cannot be
reached). Snowflake watches AWS (expected ingestion runs); this watches
Snowflake. Neither is trusted to watch itself.

Deploy (owner, once):
  1. Snowflake, as ACCOUNTADMIN (see README.md next to this file): create user
     SVC_OPS_WATCHER with an RSA public key, role GROCERY_OPS_WATCHER with
     SELECT on GROCERY_OPS.V_WATCHER_HEARTBEAT only, and USAGE on GROCERY_OPS_WH.
  2. AWS: store the private key in Secrets Manager as `grocery/ops-watcher`
     (fields: account, user, private_key_pem, warehouse); create SNS topic
     `grocery-ops-alerts` with the Proton address subscribed; create this
     Lambda (python3.12, 256 MB, 60 s, env SECRET_ID + SNS_TOPIC_ARN) with
     a role that may read that secret and publish to that topic; schedule it
     with EventBridge Scheduler daily 09:00 America/New_York.
Dependencies: PyJWT + cryptography (Lambda layer or bundled), boto3 (built in).
"""

import base64
import hashlib
import json
import os
import time
import urllib.request

import boto3

SECRET_ID = os.environ.get("SECRET_ID", "grocery/ops-watcher")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
MAX_SILENCE_HOURS = float(os.environ.get("MAX_SILENCE_HOURS", "26"))
QUERY = "SELECT HOURS_SINCE_SUPERVISOR, LAST_SUPERVISOR_RUN, LAST_STATUS FROM GROCERYDBTPROJECT.GROCERY_OPS.V_WATCHER_HEARTBEAT"


def _jwt(account: str, user: str, private_key_pem: str) -> str:
    """Snowflake key-pair JWT: iss = ACCOUNT.USER.SHA256:<public key fingerprint>."""
    import jwt  # PyJWT
    from cryptography.hazmat.primitives import serialization

    key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    pub = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    fp = "SHA256:" + base64.b64encode(hashlib.sha256(pub).digest()).decode()
    acct, usr = account.upper(), user.upper()
    now = int(time.time())
    return jwt.encode({"iss": f"{acct}.{usr}.{fp}", "sub": f"{acct}.{usr}", "iat": now, "exp": now + 3000}, key, algorithm="RS256")


def _query(secret: dict) -> dict:
    token = _jwt(secret["account"], secret["user"], secret["private_key_pem"])
    url = f"https://{secret['account']}.snowflakecomputing.com/api/v2/statements"
    body = json.dumps({"statement": QUERY, "warehouse": secret.get("warehouse", "GROCERY_OPS_WH"), "timeout": 50}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json", "Accept": "application/json",
        "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT", "User-Agent": "grocery-ops-watcher/1.0",
    })
    with urllib.request.urlopen(req, timeout=55) as r:
        data = json.loads(r.read())
    row = data["data"][0]
    return {"hours_since": float(row[0]) if row[0] is not None else None, "last_run": row[1], "last_status": row[2]}


def _notify(subject: str, message: str) -> None:
    boto3.client("sns").publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)


def lambda_handler(event, context):
    sm = boto3.client("secretsmanager")
    secret = json.loads(sm.get_secret_value(SecretId=SECRET_ID)["SecretString"])
    try:
        hb = _query(secret)
    except Exception as e:  # unreachable Snowflake is itself the alert
        _notify("[grocery-ops][watcher][CRIT] cannot reach Snowflake", f"The independent watcher could not query GROCERY_OPS.V_WATCHER_HEARTBEAT: {e!r}")
        return {"ok": False, "error": repr(e)}
    if hb["hours_since"] is None or hb["hours_since"] > MAX_SILENCE_HOURS:
        _notify("[grocery-ops][watcher][CRIT] ops supervisor silent",
                f"No supervisor run in the last {MAX_SILENCE_HOURS:g} h. Last run: {hb['last_run']} ({hb['last_status']}). "
                "Check TASK_OPS_DAILY (suspended? failed?) and GROCERY_OPS_MONITOR (suspended at 100%?).")
        return {"ok": False, **hb}
    return {"ok": True, **hb}
