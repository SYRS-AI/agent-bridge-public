#!/usr/bin/env python3
"""Gmail -> Railway PostgreSQL email sync via gws."""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

import psycopg2

BRIDGE_HOME = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge"))).expanduser()
RUNTIME_ROOT = BRIDGE_HOME / "runtime"

sys.path.insert(0, str(RUNTIME_ROOT / "scripts"))
from creds import load_creds
from gws_helper import gws_api

DEFAULT_GMAIL_ACCOUNTS_FILE = RUNTIME_ROOT / "credentials" / "gmail-accounts.json"


def load_accounts():
    raw_json = os.environ.get("BRIDGE_GMAIL_ACCOUNTS_JSON", "").strip()
    if raw_json:
        payload = json.loads(raw_json)
    else:
        config_path = Path(
            os.environ.get("BRIDGE_GMAIL_ACCOUNTS_FILE", str(DEFAULT_GMAIL_ACCOUNTS_FILE))
        ).expanduser()
        if not config_path.exists():
            return {}
        payload = json.loads(config_path.read_text(encoding="utf-8"))

    if isinstance(payload, dict) and isinstance(payload.get("accounts"), dict):
        payload = payload["accounts"]
    if not isinstance(payload, dict):
        raise RuntimeError("gmail account config must be a JSON object")

    return {
        str(name): str(address).strip()
        for name, address in payload.items()
        if str(name).strip() and str(address).strip()
    }


ACCOUNTS = load_accounts()


def get_db():
    c = load_creds("railway-db.json")
    return psycopg2.connect(
        host=c["db_host"],
        port=c["db_port"],
        dbname=c["db_name"],
        user=c["db_user"],
        password=c["db_password"],
    )


def parse_date(date_str):
    try:
        return parsedate_to_datetime(date_str)
    except Exception:
        return datetime.now(timezone.utc)


def fetch_and_sync(account_name, gws_email, agent_id="main", hours=2):
    try:
        data = gws_api(
            "gmail",
            "users messages list",
            account=gws_email,
            params={"userId": "me", "maxResults": 50, "q": f"newer_than:{hours}h"},
        )
    except RuntimeError as exc:
        print(f"ERROR fetching {account_name}: {exc}", file=sys.stderr)
        return []

    if "messages" not in data:
        return []

    conn = get_db()
    cur = conn.cursor()
    synced = []
    try:
        for ref in data["messages"]:
            msg_id = ref["id"]
            cur.execute("SELECT id FROM emails WHERE message_id = %s", (msg_id,))
            if cur.fetchone():
                continue

            try:
                msg = gws_api(
                    "gmail",
                    "users messages get",
                    account=gws_email,
                    params={"userId": "me", "id": msg_id, "format": "metadata"},
                )
            except RuntimeError:
                continue

            headers = msg.get("payload", {}).get("headers", [])
            subject = next((h["value"] for h in headers if h["name"] == "Subject"), "")
            sender = next((h["value"] for h in headers if h["name"] == "From"), "")
            recipient = next((h["value"] for h in headers if h["name"] == "To"), "")
            date_str = next((h["value"] for h in headers if h["name"] == "Date"), "")
            snippet = msg.get("snippet", "")
            labels = msg.get("labelIds", [])
            thread_id = msg.get("threadId", "")
            is_unread = "UNREAD" in labels
            is_sent = "SENT" in labels
            is_inbox = "INBOX" in labels
            direction = "outbound" if (is_sent and not is_inbox) else "inbound"
            received_at = parse_date(date_str)

            if direction == "outbound":
                status = "sent"
            elif is_unread:
                status = "new"
            else:
                status = "ignored"

            cur.execute(
                """
                INSERT INTO emails (
                  agent_id, account, message_id, sender, subject, snippet,
                  received_at, status, direction, thread_id, recipient
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (message_id) DO NOTHING
                RETURNING id
                """,
                (
                    agent_id,
                    account_name,
                    msg_id,
                    sender,
                    subject,
                    snippet,
                    received_at,
                    status,
                    direction,
                    thread_id,
                    recipient,
                ),
            )
            created = cur.fetchone()
            if created:
                synced.append(
                    {
                        "id": created[0],
                        "agent_id": agent_id,
                        "account": account_name,
                        "message_id": msg_id,
                        "sender": sender,
                        "subject": subject,
                        "snippet": snippet,
                        "received_at": received_at.isoformat(),
                        "status": status,
                        "direction": direction,
                    }
                )
        conn.commit()
    finally:
        cur.close()
        conn.close()

    return synced


def main():
    hours = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    agent_id = sys.argv[2] if len(sys.argv) > 2 else "main"
    if not ACCOUNTS:
        print("NO_CONFIGURED_ACCOUNTS")
        return
    rows = []
    for account_name, gws_email in ACCOUNTS.items():
        rows.extend(fetch_and_sync(account_name, gws_email, agent_id=agent_id, hours=hours))

    if not rows:
        print("NO_NEW_MAIL")
        return

    print(json.dumps(rows, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
