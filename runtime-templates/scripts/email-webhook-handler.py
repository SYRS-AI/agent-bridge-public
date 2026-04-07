#!/usr/bin/env python3
"""통합 이메일 웹훅 핸들러.

Gmail Pub/Sub 웹훅 수신 시:
1. 전 계정 새 메일을 emails 테이블로 동기화
2. status='new' 메일이 있으면 mailbot durable queue task 생성
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

import psycopg2

BRIDGE_HOME = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge"))).expanduser()
RUNTIME_ROOT = BRIDGE_HOME / "runtime"
LOG_FILE = BRIDGE_HOME / "logs" / "email-webhook-handler.log"
AGENT_BRIDGE = BRIDGE_HOME / "agent-bridge"
QUEUE_HELPER = BRIDGE_HOME / "bridge-queue.py"

sys.path.insert(0, str(RUNTIME_ROOT / "scripts"))
from creds import load_creds
from gws_helper import gws_api

DEFAULT_GMAIL_ACCOUNTS_FILE = RUNTIME_ROOT / "credentials" / "gmail-accounts.json"


def load_accounts() -> dict[str, str]:
    raw_json = os.environ.get("BRIDGE_GMAIL_ACCOUNTS_JSON", "").strip()
    if raw_json:
        try:
            payload = json.loads(raw_json)
        except json.JSONDecodeError as exc:
            raise RuntimeError("BRIDGE_GMAIL_ACCOUNTS_JSON must be valid JSON") from exc
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

TRIAGE_TITLE = "[MAIL] Gmail webhook triage"


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def get_supabase_db():
    creds = load_creds("railway-db.json")
    return psycopg2.connect(
        host=creds["db_host"],
        port=creds["db_port"],
        dbname=creds["db_name"],
        user=creds["db_user"],
        password=creds["db_password"],
    )


def parse_date(date_str):
    try:
        return parsedate_to_datetime(date_str)
    except Exception:
        return datetime.now(timezone.utc)


def sync_account(gws_email, account_name, conn):
    try:
        data = gws_api(
            "gmail",
            "users messages list",
            account=gws_email,
            params={"userId": "me", "maxResults": 30, "q": "newer_than:1h"},
        )
    except RuntimeError as e:
        log(f"  ERROR fetching {account_name}: {e}")
        return []

    if "messages" not in data:
        return []

    cur = conn.cursor()
    new_emails = []
    for msg_ref in data["messages"]:
        msg_id = msg_ref["id"]
        cur.execute("SELECT id FROM emails WHERE message_id = %s", (msg_id,))
        if cur.fetchone():
            continue

        try:
            msg_data = gws_api(
                "gmail",
                "users messages get",
                account=gws_email,
                params={"userId": "me", "id": msg_id, "format": "metadata"},
            )
        except RuntimeError:
            continue

        headers = msg_data.get("payload", {}).get("headers", [])
        subject = next((h["value"] for h in headers if h["name"] == "Subject"), "")
        sender = next((h["value"] for h in headers if h["name"] == "From"), "")
        date_str = next((h["value"] for h in headers if h["name"] == "Date"), "")
        snippet = msg_data.get("snippet", "")
        labels = msg_data.get("labelIds", [])
        thread_id = msg_data.get("threadId", "")
        is_unread = "UNREAD" in labels
        is_sent = "SENT" in labels
        is_inbox = "INBOX" in labels
        direction = "outbound" if (is_sent and not is_inbox) else "inbound"
        received_at = parse_date(date_str)

        if direction == "outbound":
            initial_status = "sent"
        elif is_unread:
            initial_status = "new"
        else:
            initial_status = "ignored"

        cur.execute(
            """
            INSERT INTO emails (
              account, message_id, sender, subject, snippet,
              received_at, status, direction, thread_id
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (message_id) DO NOTHING
            RETURNING id
            """,
            (
                account_name,
                msg_id,
                sender,
                subject,
                snippet,
                received_at,
                initial_status,
                direction,
                thread_id,
            ),
        )

        created = cur.fetchone()
        if created and initial_status == "new":
            new_emails.append(
                {
                    "db_id": created[0],
                    "message_id": msg_id,
                    "account": account_name,
                    "sender": sender,
                    "subject": subject,
                    "snippet": snippet,
                }
            )

    conn.commit()
    cur.close()
    return new_emails


def find_open_triage_task():
    result = subprocess.run(
        [
            sys.executable,
            str(QUEUE_HELPER),
            "find-open",
            "--agent",
            "mailbot",
            "--title-prefix",
            TRIAGE_TITLE,
            "--format",
            "id",
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def build_body_file(new_emails):
    handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".md")
    with handle as fh:
        fh.write("# Gmail webhook triage\n\n")
        fh.write(f"- new_email_count: {len(new_emails)}\n")
        fh.write("- queue DB is source of truth. Use `~/.agent-bridge/agb inbox|claim|done`.\n")
        fh.write("- 다른 에이전트 handoff는 `~/.agent-bridge/agent-bridge task create --to <agent>`를 사용한다.\n")
        fh.write("- 사람 직접 알림은 보내지 말고 필요 시 follow-up 초안만 남긴다.\n\n")
        fh.write("## Work\n\n")
        fh.write("1. MEMORY.md 읽고 발신자별 중요도/운영 방침 확인\n")
        fh.write("2. emails 테이블에서 status='new' AND direction='inbound' 메일 최대 50건 조회\n")
        fh.write("3. gmail-ai로 본문을 읽고 importance/category/reply_needed/status 판단\n")
        fh.write("4. 업무 메일은 담당 에이전트에게 durable task로 라우팅\n")
        fh.write("5. 처리 결과에 맞게 emails.status, routed_to, agent_note 갱신\n")
        fh.write("6. direct-send legacy primitive는 사용하지 않는다\n\n")
        fh.write("## New Email Sample\n\n")
        for email in new_emails[:10]:
            fh.write(f"- [{email['account']}] {email['sender']} | {email['subject']} | {email['snippet'][:120]}\n")
    return fh.name


def queue_mailbot_triage(new_emails):
    existing_task = find_open_triage_task()
    if existing_task:
        log(f"  Existing mailbot triage task #{existing_task} found — batching into current queue work")
        return

    body_file = build_body_file(new_emails)
    try:
        result = subprocess.run(
            [
                str(AGENT_BRIDGE),
                "task",
                "create",
                "--to",
                "mailbot",
                "--from",
                "bridge",
                "--priority",
                "high",
                "--title",
                TRIAGE_TITLE,
                "--body-file",
                body_file,
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            log(f"  Queued mailbot triage task ({len(new_emails)} new emails)")
        else:
            log(f"  ERROR: task create failed: {(result.stderr or result.stdout)[:300]}")
    finally:
        try:
            os.unlink(body_file)
        except OSError:
            pass


def main():
    log("Email webhook handler started")
    if not ACCOUNTS:
        log("No configured Gmail accounts; skipping webhook sync.")
        return
    conn = get_supabase_db()
    all_new = []
    try:
        for account_name, gws_email in ACCOUNTS.items():
            try:
                new = sync_account(gws_email, account_name, conn)
                if new:
                    log(f"  {account_name}: {len(new)} new emails")
                    all_new.extend(new)
            except Exception as e:
                log(f"  {account_name} sync error: {e}")
    finally:
        conn.close()

    if not all_new:
        log("  No new emails")
        return

    log(f"  Total: {len(all_new)} new emails")
    queue_mailbot_triage(all_new)
    log("Email webhook handler done")


if __name__ == "__main__":
    main()
