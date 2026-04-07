#!/usr/bin/env python3
"""bridge-supervisor.py — AI supervisor for Agent Bridge task completion quality.

Polls done events from the task queue, applies a deterministic prefilter,
and sends ambiguous cases to an LLM for verdict.  Actions: log, followup
task, patch urgent, or human alert.

Usage:
    python3 bridge-supervisor.py run [--dry-run] [--once]
    python3 bridge-supervisor.py status
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

BRIDGE_HOME = Path(os.environ.get("BRIDGE_HOME", Path.home() / ".agent-bridge"))
BRIDGE_QUEUE_PY = Path(os.environ.get(
    "BRIDGE_QUEUE_PY",
    Path(__file__).resolve().parent / "bridge-queue.py",
))
CHECKPOINT_FILE = BRIDGE_HOME / "state" / "supervisor-checkpoint.json"
LOG_FILE = BRIDGE_HOME / "logs" / "supervisor.jsonl"
POLL_INTERVAL = int(os.environ.get("BRIDGE_SUPERVISOR_POLL_SECONDS", "300"))
MODEL = os.environ.get("BRIDGE_SUPERVISOR_MODEL", "claude-haiku-4-5-20251001")
ADMIN_AGENT = os.environ.get("BRIDGE_ADMIN_AGENT_ID", "patch")
HUMAN_RELAY_AGENT = os.environ.get("BRIDGE_SUPERVISOR_HUMAN_RELAY", ADMIN_AGENT)
CONFIDENCE_THRESHOLD = float(os.environ.get("BRIDGE_SUPERVISOR_CONFIDENCE", "0.8"))
LOG_ONLY = os.environ.get("BRIDGE_SUPERVISOR_LOG_ONLY", "1") == "1"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
)
log = logging.getLogger("supervisor")

# ---- Prefilter keywords ----

FAILURE_KEYWORDS = (
    "error", "Error", "failed", "Failed", "FAILED", "exception", "Exception",
    "timeout", "Timeout", "crash", "Crash", "[Errno",
    "No such file", "Permission denied", "Connection refused",
)

INTERNAL_TASK_PREFIXES = (
    "[cron-dispatch]",
    "[task-complete]",
    "memory-daily",
    "google-watch-renewal",
)

SKIP_FAMILIES = {
    "memory-daily", "google-watch-renewal", "session-maintenance",
}


@dataclass
class DoneEvent:
    event_id: int
    task_id: int
    actor: str
    created_ts: int
    note_text: str | None
    note_file_content: str | None
    task_title: str
    task_body: str | None
    assigned_to: str
    task_created_by: str | None


@dataclass
class Verdict:
    verdict: str  # PASS, UNDELIVERED, ERROR, ESCALATE
    confidence: float
    reason: str
    action: str | None  # None, followup_task, patch_urgent, human_alert
    source: str  # prefilter or model


# ---- Checkpoint ----

def load_checkpoint() -> int:
    if CHECKPOINT_FILE.exists():
        try:
            data = json.loads(CHECKPOINT_FILE.read_text())
            return int(data.get("last_event_id", 0))
        except (json.JSONDecodeError, ValueError):
            pass
    return 0


def save_checkpoint(event_id: int) -> None:
    CHECKPOINT_FILE.parent.mkdir(parents=True, exist_ok=True)
    CHECKPOINT_FILE.write_text(json.dumps({
        "last_event_id": event_id,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }))


# ---- Event fetching ----

def fetch_done_events(after_id: int, limit: int = 50) -> list[DoneEvent]:
    result = subprocess.run(
        [
            sys.executable, str(BRIDGE_QUEUE_PY),
            "events", "--type", "done",
            "--after-id", str(after_id),
            "--limit", str(limit),
            "--format", "json",
        ],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        log.error("events fetch failed: %s", result.stderr.strip())
        return []
    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError:
        log.error("events JSON parse failed")
        return []
    events = []
    for item in raw:
        events.append(DoneEvent(
            event_id=item["event_id"],
            task_id=item["task_id"],
            actor=item["actor"],
            created_ts=item["created_ts"],
            note_text=item.get("note_text"),
            note_file_content=item.get("note_file_content"),
            task_title=item.get("task_title", ""),
            task_body=item.get("task_body"),
            assigned_to=item.get("assigned_to", ""),
            task_created_by=item.get("task_created_by"),
        ))
    return events


# ---- Deterministic prefilter ----

def prefilter(event: DoneEvent) -> Verdict | None:
    title = event.task_title or ""
    note = event.note_text or ""
    file_content = event.note_file_content or ""
    combined = f"{note} {file_content}"

    # Skip internal/housekeeping tasks
    for prefix in INTERNAL_TASK_PREFIXES:
        if title.startswith(prefix):
            # But check cron-dispatch for errors
            if title.startswith("[cron-dispatch]"):
                if "state: error" in file_content or "child_status: error" in file_content:
                    return Verdict("ERROR", 1.0, f"cron-dispatch error: {title}", "patch_urgent", "prefilter")
                # Check for routine no-ops (no action needed)
                if any(kw in file_content for kw in ("routine no-op", "스킵", "업무 시간 외")):
                    return Verdict("PASS", 1.0, "routine cron no-op", None, "prefilter")
            else:
                return Verdict("PASS", 1.0, f"internal task: {title[:60]}", None, "prefilter")

    # Skip tasks from housekeeping families
    created_by = event.task_created_by or ""
    for family in SKIP_FAMILIES:
        if family in created_by:
            return Verdict("PASS", 1.0, f"housekeeping family: {family}", None, "prefilter")

    # Detect explicit errors
    for kw in FAILURE_KEYWORDS:
        if kw in combined:
            return Verdict("ERROR", 0.9, f"failure keyword '{kw}' in done note", "patch_urgent", "prefilter")

    # Detect empty/missing notes
    if not note and not file_content.strip():
        return Verdict("UNDELIVERED", 0.85, "empty done note — no evidence of delivery", "followup_task", "prefilter")

    # Cron-followup without channel delivery evidence
    if "[cron-followup]" in title:
        delivery_evidence = any(kw in combined for kw in (
            "채널", "channel", "posted", "전달", "DM", "Telegram", "Discord",
            "보고", "report", "sent", "발송",
        ))
        if not delivery_evidence:
            return None  # Ambiguous — send to model

    # If note is very short and task had substantial body, might be suspicious
    if note and len(note) < 20 and event.task_body and len(event.task_body) > 200:
        return None  # Ambiguous — send to model

    return None  # Ambiguous — send to model


# ---- LLM verdict ----

SUPERVISOR_PROMPT = """너는 Agent Bridge 시스템의 감독자다. 에이전트가 task를 완료(done)했을 때 결과를 분석해서 판단해야 한다.

## 입력
- task_title: {task_title}
- task_body (첫 500자): {task_body}
- agent: {agent}
- done_note: {done_note}
- done_note_file (첫 1000자): {done_note_file}

## 판단 기준

### PASS (정상)
- task 내용에 부합하는 작업을 수행했고
- 결과가 적절한 surface(채널/다른 에이전트)에 전달되었거나
- 전달이 불필요한 내부 작업(memory cleanup, sync 등)인 경우

### UNDELIVERED (미전달)
- task에 사람에게 전달할 정보가 있었는데 전달 흔적이 없는 경우
- cron-followup에서 needs_human_followup=true인데 채널 전달 없이 done한 경우
- "acknowledge" / "확인" / "처리 완료" 수준의 빈 응답으로 done한 경우

### ERROR (장애)
- done note에 에러, 실패, 연결 불가 등 장애 증상이 있는 경우

### ESCALATE (에스컬레이션)
- 사람의 즉시 판단이 필요한 내용이 묻혀 있는 경우
- 보안, 재정, 고객 긴급 이슈 관련 내용

## 출력 형식 (JSON만, 다른 텍스트 없이)
{{"verdict": "PASS|UNDELIVERED|ERROR|ESCALATE", "confidence": 0.0~1.0, "reason": "판단 이유 1줄", "action": null|"followup_task"|"patch_urgent"|"human_alert"}}"""


def llm_verdict(event: DoneEvent) -> Verdict | None:
    try:
        import anthropic
    except ImportError:
        log.error("anthropic SDK not installed — skipping LLM verdict")
        return None

    prompt = SUPERVISOR_PROMPT.format(
        task_title=event.task_title or "",
        task_body=(event.task_body or "")[:500],
        agent=event.actor,
        done_note=event.note_text or "(empty)",
        done_note_file=(event.note_file_content or "")[:1000],
    )

    try:
        client = anthropic.Anthropic()
        response = client.messages.create(
            model=MODEL,
            max_tokens=300,
            messages=[{"role": "user", "content": prompt}],
        )
        text = response.content[0].text.strip()
        # Extract JSON from response
        if text.startswith("{"):
            data = json.loads(text)
        else:
            # Try to find JSON in the response
            start = text.find("{")
            end = text.rfind("}") + 1
            if start >= 0 and end > start:
                data = json.loads(text[start:end])
            else:
                log.warning("LLM returned non-JSON: %s", text[:200])
                return None

        return Verdict(
            verdict=data.get("verdict", "PASS"),
            confidence=float(data.get("confidence", 0.5)),
            reason=data.get("reason", ""),
            action=data.get("action"),
            source="model",
        )
    except Exception as e:
        log.error("LLM call failed: %s", e)
        return None


# ---- Actions ----

def execute_action(verdict: Verdict, event: DoneEvent, dry_run: bool) -> bool:
    """Execute the action for a verdict. Returns True on success, False on failure."""
    if verdict.action is None:
        return True
    if verdict.confidence < CONFIDENCE_THRESHOLD:
        log.info(
            "action suppressed (confidence %.2f < %.2f): %s for task #%d",
            verdict.confidence, CONFIDENCE_THRESHOLD, verdict.action, event.task_id,
        )
        return True
    if LOG_ONLY:
        log.info(
            "LOG_ONLY — would execute %s for task #%d (%s)",
            verdict.action, event.task_id, verdict.reason,
        )
        return True

    agb = str(BRIDGE_HOME / "agent-bridge")

    if verdict.action == "followup_task":
        title = f"[SUPERVISOR] 미전달 결과 재전달 필요 (원본 task #{event.task_id})"
        body = f"감독자가 task #{event.task_id} ({event.task_title})의 done 처리를 검토한 결과, 결과가 요청자에게 전달되지 않은 것으로 판단됩니다.\n\n사유: {verdict.reason}\n\n원본 task의 결과를 적절한 채널로 전달해주세요."
        if not dry_run:
            result = subprocess.run(
                [agb, "task", "create",
                 "--to", event.assigned_to,
                 "--from", "supervisor",
                 "--priority", "high",
                 "--title", title,
                 "--body", body],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode != 0:
                log.error("followup task create failed for task #%d: %s", event.task_id, result.stderr.strip())
                return False
        log.info("created followup task for %s (task #%d)", event.assigned_to, event.task_id)

    elif verdict.action == "patch_urgent":
        message = f"[SUPERVISOR] {event.actor} task #{event.task_id} error: {verdict.reason}"
        if not dry_run:
            result = subprocess.run(
                [agb, "urgent", ADMIN_AGENT, message],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode != 0:
                log.error("urgent send failed for task #%d: %s", event.task_id, result.stderr.strip())
                return False
        log.info("sent urgent to %s for task #%d", ADMIN_AGENT, event.task_id)

    elif verdict.action == "human_alert":
        title = f"[SUPERVISOR] 사람 확인 필요 — task #{event.task_id}"
        body = f"감독자가 task #{event.task_id} ({event.task_title})에서 사람의 확인이 필요한 내용을 감지했습니다.\n\n사유: {verdict.reason}\n\n에이전트: {event.actor}"
        if not dry_run:
            result = subprocess.run(
                [agb, "task", "create",
                 "--to", HUMAN_RELAY_AGENT,
                 "--from", "supervisor",
                 "--priority", "urgent",
                 "--title", title,
                 "--body", body],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode != 0:
                log.error("human alert create failed for task #%d: %s", event.task_id, result.stderr.strip())
                return False
        log.info("created human alert via %s for task #%d", HUMAN_RELAY_AGENT, event.task_id)

    return True


# ---- Logging ----

def log_verdict(event: DoneEvent, verdict: Verdict) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event_id": event.event_id,
        "task_id": event.task_id,
        "agent": event.actor,
        "task_title": event.task_title,
        "verdict": verdict.verdict,
        "confidence": verdict.confidence,
        "reason": verdict.reason,
        "action": verdict.action,
        "source": verdict.source,
    }
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


# ---- Main loop ----

def run_once(dry_run: bool) -> int:
    last_id = load_checkpoint()
    events = fetch_done_events(last_id)
    if not events:
        log.debug("no new done events after #%d", last_id)
        return 0

    processed = 0
    for event in events:
        verdict = prefilter(event)
        if verdict is None:
            verdict = llm_verdict(event)
        if verdict is None:
            # LLM unavailable — do NOT advance checkpoint; retry next cycle
            log.warning(
                "skipping event #%d (task #%d) — LLM unavailable, will retry",
                event.event_id, event.task_id,
            )
            break

        log_verdict(event, verdict)

        action_ok = True
        if verdict.verdict != "PASS":
            log.info(
                "task #%d (%s) → %s [%.2f] %s",
                event.task_id, event.actor, verdict.verdict,
                verdict.confidence, verdict.reason,
            )
            action_ok = execute_action(verdict, event, dry_run)

        if not action_ok:
            # Action failed — do NOT advance checkpoint; retry next cycle
            log.warning(
                "stopping at event #%d (task #%d) — action execution failed, will retry",
                event.event_id, event.task_id,
            )
            break

        processed += 1
        save_checkpoint(event.event_id)

    if processed:
        log.info("processed %d done events (last_id: %d → %d)", processed, last_id, events[processed - 1].event_id)
    return processed


def cmd_run(args: argparse.Namespace) -> int:
    dry_run = args.dry_run
    once = args.once

    if once:
        run_once(dry_run)
        return 0

    log.info("supervisor started (poll=%ds, model=%s, log_only=%s)", POLL_INTERVAL, MODEL, LOG_ONLY)
    while True:
        try:
            run_once(dry_run)
        except Exception as e:
            log.error("supervisor cycle error: %s", e)
        time.sleep(POLL_INTERVAL)


def cmd_status(args: argparse.Namespace) -> int:
    last_id = load_checkpoint()
    print(f"checkpoint: last_event_id={last_id}")
    if CHECKPOINT_FILE.exists():
        data = json.loads(CHECKPOINT_FILE.read_text())
        print(f"updated_at: {data.get('updated_at', 'unknown')}")
    print(f"log_file: {LOG_FILE}")
    if LOG_FILE.exists():
        lines = LOG_FILE.read_text().strip().split("\n")
        print(f"log_entries: {len(lines)}")
        if lines:
            last = json.loads(lines[-1])
            print(f"last_verdict: task #{last['task_id']} → {last['verdict']} ({last['source']})")
    else:
        print("log_entries: 0")
    print(f"model: {MODEL}")
    print(f"poll_interval: {POLL_INTERVAL}s")
    print(f"log_only: {LOG_ONLY}")
    print(f"confidence_threshold: {CONFIDENCE_THRESHOLD}")
    print(f"admin_agent: {ADMIN_AGENT}")
    print(f"human_relay: {HUMAN_RELAY_AGENT}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="bridge-supervisor.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--dry-run", action="store_true")
    run_parser.add_argument("--once", action="store_true")
    run_parser.set_defaults(handler=cmd_run)

    status_parser = subparsers.add_parser("status")
    status_parser.set_defaults(handler=cmd_status)

    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    sys.exit(main())
