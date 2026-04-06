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

ACCOUNTS = {
    "션_회사": "sean@syrs.kr",
    "묘_회사": "myo@syrs.kr",
    "ai": "ai@syrs.jp",
    "션_개인": "seanssoh@gmail.com",
}


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
    rows = []
    for account_name, gws_email in ACCOUNTS.items():
        rows.extend(fetch_and_sync(account_name, gws_email, agent_id=agent_id, hours=hours))

    if not rows:
        print("NO_NEW_MAIL")
        return

    print(json.dumps(rows, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
