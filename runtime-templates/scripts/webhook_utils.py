#!/usr/bin/env python3
"""공통 유틸리티 — 웹훅 핸들러 공유 모듈.

DB 연결, 에이전트 알림, 로깅, 에러 래핑, 프롬프트 가드, 중복 방지.
"""
from __future__ import annotations

import json
import os
import secrets
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2

BRIDGE_HOME = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge"))).expanduser()
RUNTIME_ROOT = BRIDGE_HOME / "runtime"
LOG_FILE = BRIDGE_HOME / "logs" / "webhook-server.log"
NATIVE_CRON_JOBS_FILE = BRIDGE_HOME / "cron" / "jobs.json"


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


CS_DB_CONNSTR = os.environ.get("CS_DB_CONNSTR", "")


def get_cs_conn():
    """로컬 CRM/CS PostgreSQL 연결."""
    return psycopg2.connect(CS_DB_CONNSTR)


def _parse_delay_seconds(delay):
    text = (delay or "0s").strip().lower()
    if not text:
        return 0
    if text.isdigit():
        return int(text)
    unit = text[-1]
    value = int(text[:-1])
    if unit == "s":
        return value
    if unit == "m":
        return value * 60
    if unit == "h":
        return value * 3600
    if unit == "d":
        return value * 86400
    raise ValueError(f"unsupported delay format: {delay}")


def _load_jobs_payload(path: Path) -> dict:
    if not path.exists():
        return {
            "format": "agent-bridge-cron-v1",
            "updatedAt": datetime.now().astimezone().isoformat(),
            "jobs": [],
        }
    return json.loads(path.read_text(encoding="utf-8"))


def _atomic_write_jobs(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False, suffix=".jobs.tmp") as fh:
        json.dump(payload, fh, ensure_ascii=True, indent=2)
        fh.write("\n")
        temp_path = Path(fh.name)
    os.replace(temp_path, path)


def schedule_agent_cron(agent_id, session_key, message, name_prefix, delay="10s"):
    """브리지 one-shot cron으로 메시지를 전달한다."""
    try:
        delay_seconds = _parse_delay_seconds(delay)
        run_at = datetime.now(timezone.utc) + timedelta(seconds=delay_seconds)
        raw_payload = _load_jobs_payload(NATIVE_CRON_JOBS_FILE)
        jobs = raw_payload.get("jobs")
        if not isinstance(jobs, list):
            jobs = []
            raw_payload["jobs"] = jobs

        now_ms = int(time.time() * 1000)
        jobs.append(
            {
                "id": secrets.token_hex(8),
                "name": f"{name_prefix}-{int(time.time())}",
                "agentId": agent_id,
                "enabled": True,
                "sessionTarget": "isolated",
                "wakeMode": "queue-dispatch",
                "payload": {
                    "kind": "agentTurn",
                    "text": message,
                },
                "schedule": {
                    "kind": "at",
                    "at": run_at.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                },
                "deleteAfterRun": True,
                "createdAtMs": now_ms,
                "updatedAtMs": now_ms,
                "state": {},
                "metadata": {
                    "source": "webhook-utils",
                    "sessionKey": session_key,
                },
            }
        )
        raw_payload["updatedAt"] = datetime.now().astimezone().isoformat()
        _atomic_write_jobs(NATIVE_CRON_JOBS_FILE, raw_payload)
        log(f"  One-shot cron scheduled: {name_prefix} -> {agent_id} ({delay})")
        return True
    except Exception as e:
        log(f"  Cron schedule error ({name_prefix}): {e}")
        return False


def run_sync(script, args=None):
    """Run sync script in background thread."""

    def _run():
        script_path = Path(script)
        if not script_path.is_absolute():
            script_path = RUNTIME_ROOT / script
        cmd = ["python3", str(script_path)]
        if args:
            cmd.extend(args)
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120,
                cwd=str(RUNTIME_ROOT),
            )
            log(f"  Sync completed: {script_path} (exit={result.returncode})")
            if result.stdout.strip():
                log(f"  STDOUT: {result.stdout.strip()[:500]}")
            if result.returncode != 0 or result.stderr.strip():
                log(f"  STDERR: {result.stderr[:500]}")
        except Exception as e:
            log(f"  Sync error: {e}")

    threading.Thread(target=_run, daemon=True).start()


_guard_loaded = False
_scan_input = None


def guard_check(text):
    """프롬프트 인젝션 스캔. Returns (blocked, severity, reasons)."""
    global _guard_loaded, _scan_input
    if not _guard_loaded:
        import sys

        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from input_guard import scan_input as _si

        _scan_input = _si
        _guard_loaded = True
    return _scan_input(text)


_dedup_cache = {}


def is_duplicate(event_key, ttl_sec=300):
    """메모리 캐시 기반 중복 체크. True면 이미 처리된 이벤트."""
    now = time.time()
    expired = [k for k, t in _dedup_cache.items() if now - t > ttl_sec]
    for k in expired:
        del _dedup_cache[k]
    if event_key in _dedup_cache:
        return True
    _dedup_cache[event_key] = now
    return False
