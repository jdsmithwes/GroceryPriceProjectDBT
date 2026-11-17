"""
send_reminders.py — email pending guests a code to finish their registration.

Runs on the owner's machine with the owner's Snowflake connection (the `snow`
CLI default connection, ACCOUNTADMIN) and the Gmail app password from
~/.snowflake/guest_app_secrets.toml ([email] section, same shape as the
Streamlit Cloud secrets). The app itself cannot send these: it only knows a
guest after they type an email.

    python3 Streamlit/guest_app/send_reminders.py --dry-run   # list who would get one
    python3 Streamlit/guest_app/send_reminders.py             # send

Each guest gets at most GUEST_SETTING.reminder_max reminders (2). Test addresses
(@example.com) are excluded by SP_GUEST_PENDING_REMINDERS.
"""

import argparse
import json
import smtplib
import ssl
import sys
import tomllib
from email.message import EmailMessage
from pathlib import Path

import snowflake.connector

APP = "GROCERYDBTPROJECT.GROCERY_APP"
SECRETS = Path.home() / ".snowflake" / "guest_app_secrets.toml"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--connection", default=None, help="snow CLI connection name (default connection if omitted)")
    args = ap.parse_args()

    secrets = tomllib.load(open(SECRETS, "rb"))
    email_cfg = secrets.get("email") or {}
    if not args.dry_run and not (email_cfg.get("smtp_user") and email_cfg.get("smtp_app_password")):
        print(f"No [email] smtp_user/smtp_app_password in {SECRETS}; add them or use --dry-run.")
        return 2

    conn = snowflake.connector.connect(**({"connection_name": args.connection} if args.connection else {}))
    cur = conn.cursor()
    cur.execute(f"CALL {APP}.SP_GUEST_PENDING_REMINDERS()")
    pending = json.loads(cur.fetchone()[0]) or []
    print(f"{len(pending)} pending guest(s) due a reminder")
    for p in pending:
        print(f"  {p['email']:<40} signed up {str(p['created_at'])[:16]}  reminders so far: {p['reminder_count']}")
    if args.dry_run or not pending:
        return 0

    app_url = email_cfg.get("app_url", "")
    try:  # python.org builds on macOS ship without root CAs; certifi (installed with requests) has them
        import certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        ctx = ssl.create_default_context()
    sent = 0
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, context=ctx, timeout=30) as smtp:
        smtp.login(email_cfg["smtp_user"], email_cfg["smtp_app_password"])
        for p in pending:
            cur.execute(f"CALL {APP}.SP_GUEST_ISSUE_CODE('{p['email']}', 'reminder')")
            r = json.loads(cur.fetchone()[0])
            if not r.get("sent") or not r.get("code"):
                print(f"  skip {p['email']}: {r.get('reason')}")
                continue
            msg = EmailMessage()
            msg["Subject"] = f"Finish setting up your Grocery Value guest access (code {r['code']})"
            msg["From"] = f"{email_cfg.get('from_name', 'Grocery Value')} <{email_cfg['smtp_user']}>"
            msg["To"] = p["email"]
            msg.set_content(
                f"Hi {p.get('first_name') or 'there'},\n\n"
                "Thanks for signing up for the Grocery Value guest app. One step was added since you registered: "
                "confirming your email. Open the app, choose Log in, enter this email, and when asked for a code use:\n\n"
                f"    {r['code']}\n\n"
                f"It expires in {r.get('ttl_minutes', 15)} minutes; if it has, the Log in tab will send you a fresh one.\n\n"
                + (f"Open the app: {app_url}\n\n" if app_url else "")
                + "You get one session a week (60 minutes or a quarter of a Snowflake credit); all guests share a 5-credit weekly budget.\n\n"
                "If you did not sign up, ignore this email and nothing further happens.\n\nGrocery Value (guest edition)"
            )
            smtp.send_message(msg)
            sent += 1
            print(f"  sent to {p['email']}")
    print(f"done: {sent} reminder(s) sent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
