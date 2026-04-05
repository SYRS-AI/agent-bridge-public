#!/usr/bin/env python3
"""Recurring OpenClaw cron scheduler for Agent Bridge."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None  # type: ignore[assignment]


LOCAL_TZ = datetime.now().astimezone().tzinfo
FAMILY_RULES = (
    "memory-daily",
    "monthly-highlights",
    "morning-briefing",
    "evening-digest",
    "event-reminder",
    "weekly-review",
)
STATUS_CREATED = "created"
STATUS_ALREADY = "already_enqueued"
STATUS_SKIPPED = "skipped"
STATUS_ERROR = "error"


@dataclass(frozen=True)
class DueRun:
    job_id: str
    job_name: str
    family: str
    openclaw_agent: str
    schedule_kind: str
    occurrence_at: datetime
    slot: str


def classify_family(name: str) -> str:
    for rule in FAMILY_RULES:
        if name.startswith(rule) or rule in name:
            return rule
    return name


def load_jobs(path: Path) -> list[dict[str, Any]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    jobs = raw.get("jobs") if isinstance(raw, dict) else raw
    if not isinstance(jobs, list):
        raise ValueError("jobs.json must contain a top-level list or {jobs:[...]}")
    return jobs


def parse_epoch_ms(value: Any) -> datetime | None:
    if value in (None, "", 0):
        return None
    try:
        return datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc).astimezone(LOCAL_TZ)
    except (TypeError, ValueError, OSError):
        return None


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text).astimezone(LOCAL_TZ)
    except ValueError:
        return None


def now_local() -> datetime:
    return datetime.now(timezone.utc).astimezone(LOCAL_TZ)


def now_iso() -> str:
    return now_local().isoformat(timespec="seconds")


def state_path(path_value: str) -> Path:
    return Path(path_value).expanduser().resolve()


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def job_enabled(job: dict[str, Any]) -> bool:
    return bool(job.get("enabled", False))


def job_is_recurring(job: dict[str, Any]) -> bool:
    schedule = job.get("schedule") or {}
    if schedule.get("kind") == "at" or job.get("deleteAfterRun") is True:
        return False
    return schedule.get("kind") in {"cron", "every"}


def load_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        return read_json(path)
    except Exception:
        return {}


def select_cursor(state: dict[str, Any], now_dt: datetime, bootstrap_seconds: int) -> datetime:
    cursor = parse_iso(state.get("last_sync_at"))
    if cursor is not None:
        if cursor > now_dt:
            return now_dt
        return cursor
    return now_dt - timedelta(seconds=max(0, bootstrap_seconds))


def normalize_tz(name: str | None):
    if not name:
        return LOCAL_TZ
    if ZoneInfo is None:
        return timezone.utc if name.upper() == "UTC" else LOCAL_TZ
    try:
        return ZoneInfo(name)
    except Exception:
        return LOCAL_TZ


def cron_dow(dt_value: datetime) -> int:
    return (dt_value.weekday() + 1) % 7


def field_is_any(expr: str) -> bool:
    return expr.strip() == "*"


def expand_atom(atom: str, minimum: int, maximum: int) -> set[int]:
    step = 1
    base = atom
    if "/" in atom:
        base, step_text = atom.split("/", 1)
        step = int(step_text)
        if step <= 0:
          raise ValueError(f"invalid cron step: {atom}")

    if base == "*":
        start = minimum
        end = maximum
    elif "-" in base:
        start_text, end_text = base.split("-", 1)
        start = int(start_text)
        end = int(end_text)
    else:
        start = int(base)
        end = int(base)

    values = set()
    for value in range(start, end + 1, step):
        normalized = value
        if maximum == 6 and value == 7:
            normalized = 0
        if minimum <= normalized <= maximum:
            values.add(normalized)
    return values


def field_matches(expr: str, value: int, minimum: int, maximum: int) -> bool:
    allowed: set[int] = set()
    for atom in expr.split(","):
        atom = atom.strip()
        if not atom:
            continue
        allowed |= expand_atom(atom, minimum, maximum)
    return value in allowed


def cron_matches(expr: str, dt_value: datetime) -> bool:
    minute_expr, hour_expr, dom_expr, month_expr, dow_expr = expr.split()
    if not field_matches(minute_expr, dt_value.minute, 0, 59):
        return False
    if not field_matches(hour_expr, dt_value.hour, 0, 23):
        return False
    if not field_matches(month_expr, dt_value.month, 1, 12):
        return False

    dom_match = field_matches(dom_expr, dt_value.day, 1, 31)
    dow_match = field_matches(dow_expr, cron_dow(dt_value), 0, 6)
    dom_any = field_is_any(dom_expr)
    dow_any = field_is_any(dow_expr)
    if dom_any and dow_any:
        return True
    if dom_any:
        return dow_match
    if dow_any:
        return dom_match
    return dom_match or dow_match


def enumerate_cron_occurrences(job: dict[str, Any], start_dt: datetime, end_dt: datetime) -> list[datetime]:
    schedule = job.get("schedule") or {}
    expr = schedule.get("expr", "")
    if not expr:
        return []
    fields = expr.split()
    if len(fields) != 5:
        raise ValueError(f"unsupported cron expression for {job.get('name')}: {expr}")

    schedule_tz = normalize_tz(schedule.get("tz"))
    start_local = start_dt.astimezone(schedule_tz)
    end_local = end_dt.astimezone(schedule_tz)
    current = start_local.replace(second=0, microsecond=0)
    occurrences: list[datetime] = []

    while current <= end_local:
        if current > start_local and cron_matches(expr, current):
            occurrences.append(current.astimezone(LOCAL_TZ))
        current += timedelta(minutes=1)
    return occurrences


def enumerate_every_occurrences(job: dict[str, Any], start_dt: datetime, end_dt: datetime) -> list[datetime]:
    schedule = job.get("schedule") or {}
    state = job.get("state") or {}
    every_ms = int(schedule.get("everyMs") or 0)
    if every_ms <= 0:
        return []

    anchor_ms = (
        schedule.get("anchorMs")
        or state.get("lastRunAtMs")
        or job.get("createdAtMs")
        or int(end_dt.timestamp() * 1000)
    )
    try:
        anchor_ms = int(anchor_ms)
    except (TypeError, ValueError):
        anchor_ms = int(end_dt.timestamp() * 1000)

    start_ms = int(start_dt.timestamp() * 1000)
    end_ms = int(end_dt.timestamp() * 1000)
    if anchor_ms > end_ms:
        return []

    index = max(0, math.floor((start_ms - anchor_ms) / every_ms))
    candidate_ms = anchor_ms + (index * every_ms)
    if candidate_ms <= start_ms:
        candidate_ms += every_ms

    occurrences: list[datetime] = []
    while candidate_ms <= end_ms:
        occurrences.append(datetime.fromtimestamp(candidate_ms / 1000, tz=timezone.utc).astimezone(LOCAL_TZ))
        candidate_ms += every_ms
    return occurrences


def derive_slot(family: str, occurrence_at: datetime, job: dict[str, Any]) -> str:
    schedule = job.get("schedule") or {}
    schedule_tz = normalize_tz(schedule.get("tz"))
    local_occurrence = occurrence_at.astimezone(schedule_tz)
    if family == "monthly-highlights":
        return local_occurrence.strftime("%Y-%m")
    if family == "memory-daily":
        return local_occurrence.strftime("%Y-%m-%d")
    return local_occurrence.isoformat(timespec="minutes")


def enumerate_due_runs(
    jobs: list[dict[str, Any]],
    start_dt: datetime,
    end_dt: datetime,
    per_job_limit: int,
) -> tuple[list[DueRun], dict[str, int]]:
    due_runs: list[DueRun] = []
    counters = Counter()

    for job in jobs:
        if not job_enabled(job):
            counters["disabled"] += 1
            continue
        if not job_is_recurring(job):
            counters["non_recurring"] += 1
            continue

        schedule = job.get("schedule") or {}
        kind = schedule.get("kind")
        if kind == "cron":
            occurrences = enumerate_cron_occurrences(job, start_dt, end_dt)
        elif kind == "every":
            occurrences = enumerate_every_occurrences(job, start_dt, end_dt)
        else:
            counters["unsupported"] += 1
            continue

        counters["eligible"] += 1
        if per_job_limit > 0 and len(occurrences) > per_job_limit:
            counters["truncated_jobs"] += 1
            counters["truncated_occurrences"] += len(occurrences) - per_job_limit
            occurrences = occurrences[-per_job_limit:]

        family = classify_family(job.get("name", ""))
        for occurrence in occurrences:
            due_runs.append(
                DueRun(
                    job_id=job.get("id", ""),
                    job_name=job.get("name", "<unnamed>"),
                    family=family,
                    openclaw_agent=job.get("agentId") or job.get("agent") or "<unknown>",
                    schedule_kind=kind,
                    occurrence_at=occurrence,
                    slot=derive_slot(family, occurrence, job),
                )
            )
    due_runs.sort(key=lambda item: (item.occurrence_at, item.openclaw_agent, item.job_name, item.slot))
    counters["due_occurrences"] = len(due_runs)
    return due_runs, dict(counters)


def enqueue_due_runs(args: argparse.Namespace, due_runs: list[DueRun]) -> tuple[list[dict[str, Any]], int]:
    results: list[dict[str, Any]] = []
    failures = 0
    bash_bin = os.environ.get("BRIDGE_BASH_BIN") or os.environ.get("BASH") or "bash"

    for run in due_runs:
        command = [
            bash_bin,
            args.bridge_cron,
            "enqueue",
            run.job_id,
            "--slot",
            run.slot,
        ]
        if args.dry_run:
            command.append("--dry-run")

        completed = subprocess.run(
            command,
            cwd=args.repo_root,
            text=True,
            capture_output=True,
            check=False,
        )
        stdout_text = completed.stdout.strip()
        stderr_text = completed.stderr.strip()
        status = STATUS_ERROR
        task_id = None
        run_id = None
        request_file = None
        manifest = None

        for raw_line in stdout_text.splitlines():
            line = raw_line.strip()
            if line == "status: dry_run":
                status = "dry_run"
            elif line == "status: already_enqueued":
                status = STATUS_ALREADY
            elif line.startswith("run_id: "):
                run_id = line.split(": ", 1)[1]
            elif line.startswith("request_file: "):
                request_file = line.split(": ", 1)[1]
            elif line.startswith("manifest: "):
                manifest = line.split(": ", 1)[1]
            elif line.startswith("created task #"):
                status = STATUS_CREATED
                match = re.search(r"created task #(\d+)", line)
                if match:
                    task_id = int(match.group(1))

        if completed.returncode != 0:
            failures += 1

        results.append(
            {
                "job_id": run.job_id,
                "job_name": run.job_name,
                "family": run.family,
                "agent": run.openclaw_agent,
                "schedule_kind": run.schedule_kind,
                "slot": run.slot,
                "occurrence_at": run.occurrence_at.isoformat(timespec="seconds"),
                "status": status,
                "task_id": task_id,
                "run_id": run_id,
                "request_file": request_file,
                "manifest": manifest,
                "exit_code": completed.returncode,
                "stdout": stdout_text,
                "stderr": stderr_text,
            }
        )
    return results, failures


def print_human_summary(
    *,
    start_dt: datetime,
    end_dt: datetime,
    status: str,
    state_file: Path,
    counters: dict[str, int],
    results: list[dict[str, Any]],
) -> None:
    result_counts = Counter(item["status"] for item in results)
    print(f"status: {status}")
    print(f"cursor_start: {start_dt.isoformat(timespec='seconds')}")
    print(f"cursor_end: {end_dt.isoformat(timespec='seconds')}")
    print(f"state_file: {state_file}")
    print(f"eligible_jobs: {counters.get('eligible', 0)}")
    print(f"due_occurrences: {counters.get('due_occurrences', 0)}")
    print(f"truncated_jobs: {counters.get('truncated_jobs', 0)}")
    print(f"truncated_occurrences: {counters.get('truncated_occurrences', 0)}")
    print(f"created: {result_counts.get(STATUS_CREATED, 0)}")
    print(f"dry_run_items: {result_counts.get('dry_run', 0)}")
    print(f"already_enqueued: {result_counts.get(STATUS_ALREADY, 0)}")
    print(f"errors: {result_counts.get(STATUS_ERROR, 0)}")
    for item in results[:20]:
        print(
            "job: {job_name} | agent={agent} | slot={slot} | status={status}".format(
                **item
            )
        )
    if len(results) > 20:
        print(f"… ({len(results) - 20} more)")


def cmd_sync(args: argparse.Namespace) -> int:
    jobs_file = state_path(args.jobs_file)
    state_file = state_path(args.state_file)
    repo_root = state_path(args.repo_root)
    now_dt = parse_iso(args.now) if args.now else now_local()
    if now_dt is None:
        raise ValueError(f"invalid --now value: {args.now}")
    state = load_state(state_file)
    start_dt = parse_iso(args.since) if args.since else select_cursor(state, now_dt, args.bootstrap_lookback)
    if start_dt is None:
        start_dt = now_dt
    if start_dt > now_dt:
        start_dt = now_dt

    jobs = load_jobs(jobs_file)
    due_runs, counters = enumerate_due_runs(jobs, start_dt, now_dt, args.max_occurrences_per_job)
    results, failures = enqueue_due_runs(args, due_runs)

    if args.json:
        status_value = "dry_run" if args.dry_run else ("error" if failures else "ok")
        payload = {
            "status": status_value,
            "cursor_start": start_dt.isoformat(timespec="seconds"),
            "cursor_end": now_dt.isoformat(timespec="seconds"),
            "state_file": str(state_file),
            "summary": counters,
            "results": results,
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        status_value = "dry_run" if args.dry_run else ("error" if failures else "ok")
        print_human_summary(
            start_dt=start_dt,
            end_dt=now_dt,
            status=status_value,
            state_file=state_file,
            counters=counters,
            results=results,
        )

    if not args.dry_run and failures == 0:
        write_json(
            state_file,
            {
                "last_sync_at": now_dt.isoformat(timespec="seconds"),
                "updated_at": now_iso(),
                "bootstrap_lookback_seconds": args.bootstrap_lookback,
                "max_occurrences_per_job": args.max_occurrences_per_job,
                "last_run_summary": {
                    "due_occurrences": counters.get("due_occurrences", 0),
                    "created": sum(1 for item in results if item["status"] == STATUS_CREATED),
                    "already_enqueued": sum(1 for item in results if item["status"] == STATUS_ALREADY),
                },
            },
        )

    return 1 if failures else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync_parser = subparsers.add_parser("sync", help="enqueue due recurring OpenClaw cron jobs")
    sync_parser.add_argument("--jobs-file", required=True)
    sync_parser.add_argument("--state-file", required=True)
    sync_parser.add_argument("--bridge-cron", required=True)
    sync_parser.add_argument("--repo-root", required=True)
    sync_parser.add_argument("--bootstrap-lookback", type=int, default=int(os.environ.get("BRIDGE_CRON_BOOTSTRAP_LOOKBACK_SECONDS", "3600")))
    sync_parser.add_argument("--max-occurrences-per-job", type=int, default=int(os.environ.get("BRIDGE_CRON_MAX_CATCHUP_OCCURRENCES_PER_JOB", "12")))
    sync_parser.add_argument("--since")
    sync_parser.add_argument("--now")
    sync_parser.add_argument("--dry-run", action="store_true")
    sync_parser.add_argument("--json", action="store_true")
    sync_parser.set_defaults(func=cmd_sync)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
