#!/usr/bin/env python3
import argparse
import json
import os
import shlex
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


LOCAL_TZ = datetime.now().astimezone().tzinfo
FAMILY_RULES = (
    "memory-daily",
    "monthly-highlights",
    "morning-briefing",
    "evening-digest",
    "event-reminder",
    "weekly-review",
)


def load_jobs_payload(path):
    raw = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    jobs = raw.get("jobs") if isinstance(raw, dict) else raw
    if not isinstance(jobs, list):
        raise ValueError("jobs.json must contain a top-level list or {jobs:[...]}")
    return raw, jobs


def load_jobs(path):
    _, jobs = load_jobs_payload(path)
    return jobs


def parse_iso_datetime(value):
    if not value or not isinstance(value, str):
        return None
    text = value
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text).astimezone(LOCAL_TZ)
    except ValueError:
        return None


def parse_epoch_ms(value):
    if value in (None, "", 0):
        return None
    try:
        return datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc).astimezone(LOCAL_TZ)
    except (TypeError, ValueError, OSError):
        return None


def format_dt(value):
    if value is None:
        return "-"
    return value.strftime("%Y-%m-%d %H:%M %Z")


def format_duration_ms(value):
    if value in (None, ""):
        return "-"
    try:
        remaining = int(value) // 1000
    except (TypeError, ValueError):
        return str(value)

    if remaining <= 0:
        return "0s"

    parts = []
    days, remaining = divmod(remaining, 86400)
    hours, remaining = divmod(remaining, 3600)
    minutes, seconds = divmod(remaining, 60)
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if minutes:
        parts.append(f"{minutes}m")
    if seconds or not parts:
        parts.append(f"{seconds}s")
    return " ".join(parts[:2])


def preview_text(value, limit=120):
    if not value:
        return ""
    flattened = " ".join(str(value).splitlines()).strip()
    if len(flattened) <= limit:
        return flattened
    if limit <= 3:
        return flattened[:limit]
    return flattened[: limit - 3].rstrip() + "..."


def classify_family(name):
    for rule in FAMILY_RULES:
        if name.startswith(rule) or rule in name:
            return rule
    return name


def classify_kind(job):
    schedule = job.get("schedule") or {}
    if schedule.get("kind") == "at" or job.get("deleteAfterRun") is True:
        return "one-shot"
    return "recurring"


def schedule_text(schedule):
    kind = schedule.get("kind", "<unknown>")
    if kind == "cron":
        expr = schedule.get("expr", "?")
        tz_name = schedule.get("tz", "UTC")
        return f"cron {expr} {tz_name}"
    if kind == "every":
        return f"every {format_duration_ms(schedule.get('everyMs'))}"
    if kind == "at":
        return f"at {schedule.get('at', '-')}"
    return json.dumps(schedule, ensure_ascii=False, sort_keys=True)


def agent_matches(agent_id, expected):
    if not expected:
        return True
    if agent_id == expected:
        return True
    if agent_id.endswith(expected):
        return True
    return agent_id.endswith(f"-{expected}")


def is_error_record(record):
    return record["consecutive_errors"] > 0 or record["last_status"] not in ("-", "ok", "success")


def build_job_record(job):
    state = job.get("state") or {}
    schedule = job.get("schedule") or {}
    payload = job.get("payload") or {}
    next_run = parse_epoch_ms(state.get("nextRunAtMs"))
    if next_run is None and schedule.get("kind") == "at":
        next_run = parse_iso_datetime(schedule.get("at"))

    last_run = parse_epoch_ms(state.get("lastRunAtMs"))
    name = job.get("name", "<unnamed>")
    last_status = state.get("lastStatus") or state.get("lastRunStatus") or "-"
    consecutive_errors = int(state.get("consecutiveErrors") or 0)
    payload_text = payload.get("text") or payload.get("message") or ""
    last_error = parse_epoch_ms(state.get("lastErrorAtMs"))
    if last_error is None and (consecutive_errors > 0 or last_status not in ("-", "ok", "success")):
        last_error = last_run

    return {
        "id": job.get("id", ""),
        "name": name,
        "agent": job.get("agentId") or job.get("agent") or "<unknown>",
        "family": classify_family(name),
        "kind": classify_kind(job),
        "enabled": bool(job.get("enabled", False)),
        "schedule_kind": schedule.get("kind", "<unknown>"),
        "schedule_text": schedule_text(schedule),
        "next_run_at": next_run,
        "last_run_at": last_run,
        "last_error_at": last_error,
        "last_status": last_status,
        "consecutive_errors": consecutive_errors,
        "last_duration_ms": state.get("lastDurationMs"),
        "last_delivery_status": state.get("lastDeliveryStatus") or "-",
        "session_target": job.get("sessionTarget", "-"),
        "wake_mode": job.get("wakeMode", "-"),
        "payload_kind": payload.get("kind", "-"),
        "payload_text": payload_text,
        "payload_preview": preview_text(payload_text),
        "raw": job,
    }


def inventory_rows(records):
    by_family = defaultdict(list)
    for record in records:
        by_family[record["family"]].append(record)

    rows = []
    for family, items in by_family.items():
        next_values = [item["next_run_at"] for item in items if item["next_run_at"] is not None]
        last_values = [item["last_run_at"] for item in items if item["last_run_at"] is not None]
        rows.append(
            {
                "family": family,
                "jobs": len(items),
                "recurring": sum(1 for item in items if item["kind"] == "recurring"),
                "one_shot": sum(1 for item in items if item["kind"] == "one-shot"),
                "agents": sorted({item["agent"] for item in items}),
                "next_run_at": min(next_values) if next_values else None,
                "last_run_at": max(last_values) if last_values else None,
            }
        )
    rows.sort(key=lambda row: (-row["jobs"], row["family"]))
    return rows


def summarize(records):
    now = datetime.now().astimezone()
    totals = {
        "total_jobs": len(records),
        "enabled_jobs": sum(1 for item in records if item["enabled"]),
        "disabled_jobs": sum(1 for item in records if not item["enabled"]),
        "recurring_jobs": sum(1 for item in records if item["kind"] == "recurring"),
        "one_shot_jobs": sum(1 for item in records if item["kind"] == "one-shot"),
        "future_one_shot_jobs": sum(
            1
            for item in records
            if item["kind"] == "one-shot" and item["next_run_at"] is not None and item["next_run_at"] >= now
        ),
        "expired_one_shot_jobs": sum(
            1
            for item in records
            if item["kind"] == "one-shot" and item["next_run_at"] is not None and item["next_run_at"] < now
        ),
        "error_jobs": sum(
            1
            for item in records
            if item["consecutive_errors"] > 0 or item["last_status"] not in ("-", "ok", "success")
        ),
        "schedule_kinds": dict(Counter(item["schedule_kind"] for item in records)),
        "payload_kinds": dict(Counter(item["payload_kind"] for item in records)),
    }
    return totals


def filter_records(records, args):
    filtered = []
    for record in records:
        if args.mode != "all" and record["kind"] != args.mode:
            continue
        if args.enabled != "all":
            expected_enabled = args.enabled == "yes"
            if record["enabled"] != expected_enabled:
                continue
        if args.family and record["family"] != args.family:
            continue
        if args.agent and not agent_matches(record["agent"], args.agent):
            continue
        filtered.append(record)
    return filtered


def record_sort_key(record):
    next_sort = record["next_run_at"].timestamp() if record["next_run_at"] else float("inf")
    last_sort = -record["last_run_at"].timestamp() if record["last_run_at"] else float("inf")
    return (next_sort, last_sort, record["agent"], record["name"])


def trimmed_jobs(records, limit):
    ordered = sorted(records, key=record_sort_key)
    if limit == 0:
        return ordered
    return ordered[:limit]


def serialize_record(record, include_payload=False):
    payload = {
        "id": record["id"],
        "name": record["name"],
        "agent": record["agent"],
        "family": record["family"],
        "kind": record["kind"],
        "enabled": record["enabled"],
        "schedule_kind": record["schedule_kind"],
        "schedule_text": record["schedule_text"],
        "next_run_at": record["next_run_at"].isoformat() if record["next_run_at"] else None,
        "last_run_at": record["last_run_at"].isoformat() if record["last_run_at"] else None,
        "last_error_at": record["last_error_at"].isoformat() if record["last_error_at"] else None,
        "last_status": record["last_status"],
        "consecutive_errors": record["consecutive_errors"],
        "last_duration_ms": record["last_duration_ms"],
        "last_delivery_status": record["last_delivery_status"],
        "session_target": record["session_target"],
        "wake_mode": record["wake_mode"],
        "payload_kind": record["payload_kind"],
        "payload_preview": record["payload_preview"],
    }
    if include_payload:
        payload["payload_text"] = record["payload_text"]
        payload["raw"] = record["raw"]
    return payload


def render_shell(record):
    payload = serialize_record(record, include_payload=True)
    payload.pop("raw", None)
    lines = []
    for key, value in payload.items():
        shell_key = f"CRON_JOB_{key.upper()}"
        if isinstance(value, bool):
            text = "1" if value else "0"
        elif value is None:
            text = ""
        elif isinstance(value, (dict, list)):
            text = json.dumps(value, ensure_ascii=False, sort_keys=True)
        else:
            text = str(value)
        lines.append(f"{shell_key}={shlex.quote(text)}")
    return "\n".join(lines)


def job_prefix(name):
    if not name:
        return "<unnamed>"
    prefix = name.split("-", 1)[0].strip()
    return prefix or name.strip() or "<unnamed>"


def error_severity_bucket(record):
    if record["consecutive_errors"] >= 10:
        return "10+"
    if record["consecutive_errors"] >= 3:
        return "3-9"
    return "1-2"


def error_sort_key(record):
    last_error_sort = -record["last_error_at"].timestamp() if record["last_error_at"] else float("inf")
    return (-record["consecutive_errors"], last_error_sort, record["agent"], record["name"])


def error_records(records, args):
    filtered = []
    for record in records:
        if record["schedule_kind"] != "cron":
            continue
        if not is_error_record(record):
            continue
        if args.family and record["family"] != args.family:
            continue
        if args.agent and not agent_matches(record["agent"], args.agent):
            continue
        filtered.append(record)
    return filtered


def format_error_record(record):
    return (
        f"{record['agent']} | {record['name']} | "
        f"errors={record['consecutive_errors']} | "
        f"last_error={format_dt(record['last_error_at'])} | "
        f"duration={format_duration_ms(record['last_duration_ms'])} | "
        f"schedule={record['schedule_text']} | "
        f"payload={record['payload_preview'] or '-'}"
    )


def severity_summary(records):
    counts = Counter(error_severity_bucket(record) for record in records)
    return {
        "10+": counts.get("10+", 0),
        "3-9": counts.get("3-9", 0),
        "1-2": counts.get("1-2", 0),
    }


def print_errors_report(args, records):
    errors = sorted(error_records(records, args), key=error_sort_key)
    recurring_total = sum(1 for record in records if record["schedule_kind"] == "cron")
    severity_counts = severity_summary(errors)
    agent_counts = Counter(record["agent"] for record in errors)
    family_counts = Counter(record["family"] for record in errors)
    prefix_counts = Counter(job_prefix(record["name"]) for record in errors)
    limit = args.limit if args.limit is not None else (0 if args.json else 20)
    display_records = errors if limit == 0 else errors[:limit]

    if args.json:
        payload = {
            "source_file": str(Path(args.jobs_file).expanduser()),
            "generated_at": datetime.now().astimezone().isoformat(),
            "filters": {
                "agent": args.agent,
                "family": args.family,
                "limit": 0 if limit == 0 else limit,
            },
            "total_recurring_jobs": recurring_total,
            "error_jobs": len(errors),
            "by_severity": severity_counts,
            "by_agent": dict(agent_counts),
            "by_family": dict(family_counts),
            "by_job_prefix": dict(prefix_counts),
            "jobs": [serialize_record(record) for record in display_records],
            "jobs_total": len(errors),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    print(f"source_file: {Path(args.jobs_file).expanduser()}")
    print(f"generated_at: {datetime.now().astimezone().isoformat()}")
    print(f"filters: agent={args.agent or '-'} family={args.family or '-'} limit={limit}")
    print(f"total_recurring_jobs: {recurring_total}")
    print(f"error_jobs: {len(errors)}")
    print()
    print("by_severity:")
    for bucket, count in severity_counts.items():
        print(f"- {bucket}: {count}")
    print()
    print("by_agent:")
    if not agent_counts:
        print("- none")
    else:
        for agent, count in agent_counts.most_common():
            print(f"- {agent}: {count}")
    print()
    print("by_family:")
    if not family_counts:
        print("- none")
    else:
        for family, count in family_counts.most_common():
            print(f"- {family}: {count}")
    print()
    print("by_job_prefix:")
    if not prefix_counts:
        print("- none")
    else:
        for prefix, count in prefix_counts.most_common():
            print(f"- {prefix}: {count}")
    print()
    print("jobs:")
    if not display_records:
        print("- none")
    else:
        for record in display_records:
            print(f"- {format_error_record(record)}")
        if limit != 0 and len(errors) > len(display_records):
            print(f"- ... ({len(errors) - len(display_records)} more jobs)")
    return 0


def cleanup_candidates(records, mode):
    now = datetime.now().astimezone()
    if mode != "expired-one-shot":
        raise ValueError(f"unsupported cleanup mode: {mode}")
    return [
        record
        for record in records
        if record["schedule_kind"] == "at"
        and record["next_run_at"] is not None
        and record["next_run_at"] < now
        and record["raw"].get("deleteAfterRun") is True
        and record["enabled"] is False
    ]


def format_cleanup_candidate(record):
    return (
        f"{record['agent']} | {record['name']} | "
        f"scheduled={format_dt(record['next_run_at'])} | "
        f"last={format_dt(record['last_run_at'])} | "
        f"status={record['last_status']}"
    )


def print_cleanup_report(args, records):
    candidates = sorted(cleanup_candidates(records, args.mode), key=record_sort_key)
    agent_counts = Counter(record["agent"] for record in candidates)
    prefix_counts = Counter(job_prefix(record["name"]) for record in candidates)
    sample_limit = args.limit if args.limit is not None else 20
    samples = candidates if sample_limit == 0 else candidates[:sample_limit]
    criteria = {
        "schedule_kind": "at",
        "scheduled_before_now": True,
        "delete_after_run": True,
        "enabled": False,
    }

    if args.json:
        payload = {
            "source_file": str(Path(args.jobs_file).expanduser()),
            "generated_at": datetime.now().astimezone().isoformat(),
            "mode": args.mode,
            "criteria": criteria,
            "candidate_count": len(candidates),
            "total_jobs": len(records),
            "by_agent": dict(agent_counts),
            "by_prefix": dict(prefix_counts),
            "samples": [serialize_record(record) for record in samples],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    print(f"source_file: {Path(args.jobs_file).expanduser()}")
    print(f"generated_at: {datetime.now().astimezone().isoformat()}")
    print(f"mode: {args.mode}")
    print("criteria: schedule.kind=at, at<now, deleteAfterRun=true, enabled=false")
    print(f"candidate_jobs: {len(candidates)}")
    print(f"total_jobs: {len(records)}")
    print()
    print("by_agent:")
    if not agent_counts:
        print("- none")
    else:
        for agent, count in agent_counts.most_common():
            print(f"- {agent}: {count}")
    print()
    print("by_prefix:")
    if not prefix_counts:
        print("- none")
    else:
        for prefix, count in prefix_counts.most_common():
            print(f"- {prefix}: {count}")
    print()
    print("sample_jobs:")
    if not samples:
        print("- none")
    else:
        for record in samples:
            print(f"- {format_cleanup_candidate(record)}")
        if sample_limit != 0 and len(candidates) > len(samples):
            print(f"- ... ({len(candidates) - len(samples)} more candidates)")
    return 0


def backup_path_for(jobs_path):
    timestamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    return jobs_path.with_name(f"{jobs_path.name}.bak-{timestamp}")


def atomic_write_jobs(jobs_path, raw_payload):
    suffix = f".{jobs_path.name}.tmp"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=jobs_path.parent, delete=False, suffix=suffix) as fh:
        json.dump(raw_payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
        temp_path = Path(fh.name)
    os.replace(temp_path, jobs_path)


def run_cleanup_prune(args, raw_payload, records):
    candidates = sorted(cleanup_candidates(records, args.mode), key=record_sort_key)
    candidate_ids = {record["id"] for record in candidates}
    jobs_path = Path(args.jobs_file).expanduser()
    remaining_jobs = [job for job in (raw_payload.get("jobs") if isinstance(raw_payload, dict) else raw_payload) if job.get("id") not in candidate_ids]
    remaining_count = len(remaining_jobs)

    print("warning: cleanup prune rewrites gateway jobs.json directly.")
    print("warning: run it between gateway cron ticks to reduce write collision risk.")
    print(f"mode: {args.mode}")
    print(f"candidate_jobs: {len(candidates)}")
    print(f"remaining_jobs_after_prune: {remaining_count}")

    if not candidates:
        print("status: nothing_to_prune")
        return 0

    print("candidate_sample:")
    for record in candidates[:10]:
        print(f"- {format_cleanup_candidate(record)}")
    if len(candidates) > 10:
        print(f"- ... ({len(candidates) - 10} more candidates)")

    if args.dry_run:
        print("status: dry_run")
        return 0

    backup_path = backup_path_for(jobs_path)
    backup_path.write_text(jobs_path.read_text(encoding="utf-8"), encoding="utf-8")
    if isinstance(raw_payload, dict):
        next_payload = dict(raw_payload)
        next_payload["jobs"] = remaining_jobs
    else:
        next_payload = remaining_jobs
    atomic_write_jobs(jobs_path, next_payload)
    print("status: pruned")
    print(f"deleted_jobs: {len(candidates)}")
    print(f"remaining_jobs: {remaining_count}")
    print(f"backup_file: {backup_path}")
    return 0


def print_inventory(args, all_records, filtered_records):
    source_file = str(Path(args.jobs_file).expanduser())
    family_rows = inventory_rows(filtered_records)
    limit = args.limit if args.limit is not None else (0 if args.json else 30)
    display_records = trimmed_jobs(filtered_records, limit)

    if args.json:
        payload = {
            "source_file": source_file,
            "generated_at": datetime.now().astimezone().isoformat(),
            "filters": {
                "agent": args.agent,
                "family": args.family,
                "mode": args.mode,
                "enabled": args.enabled,
                "limit": 0 if limit == 0 else limit,
            },
            "totals": summarize(all_records),
            "filtered_totals": summarize(filtered_records),
            "families": [
                {
                    "family": row["family"],
                    "jobs": row["jobs"],
                    "recurring": row["recurring"],
                    "one_shot": row["one_shot"],
                    "agents": row["agents"],
                    "next_run_at": row["next_run_at"].isoformat() if row["next_run_at"] else None,
                    "last_run_at": row["last_run_at"].isoformat() if row["last_run_at"] else None,
                }
                for row in family_rows
            ],
            "jobs": [serialize_record(record) for record in display_records],
            "jobs_total": len(filtered_records),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    totals = summarize(all_records)
    filtered_totals = summarize(filtered_records)
    print(f"source_file: {source_file}")
    print(f"generated_at: {datetime.now().astimezone().isoformat()}")
    print(
        "filters: "
        f"mode={args.mode} "
        f"enabled={args.enabled} "
        f"agent={args.agent or '-'} "
        f"family={args.family or '-'} "
        f"limit={limit}"
    )
    print(f"total_jobs: {totals['total_jobs']}")
    print(f"enabled_jobs: {totals['enabled_jobs']}")
    print(f"recurring_jobs: {totals['recurring_jobs']}")
    print(f"one_shot_jobs: {totals['one_shot_jobs']}")
    print(f"future_one_shot_jobs: {totals['future_one_shot_jobs']}")
    print(f"expired_one_shot_jobs: {totals['expired_one_shot_jobs']}")
    print(f"error_jobs: {totals['error_jobs']}")
    print(f"filtered_jobs: {len(display_records)} of {filtered_totals['total_jobs']}")
    print()
    print("families:")
    family_limit = 12
    if not family_rows:
        print("- none")
    else:
        for row in family_rows[:family_limit]:
            print(
                "- "
                f"{row['family']} | jobs={row['jobs']} "
                f"recurring={row['recurring']} one_shot={row['one_shot']} "
                f"agents={len(row['agents'])} "
                f"next={format_dt(row['next_run_at'])} "
                f"last={format_dt(row['last_run_at'])}"
            )
        if len(family_rows) > family_limit:
            print(f"- ... ({len(family_rows) - family_limit} more families)")
    print()
    print("jobs:")
    if not display_records:
        print("- none")
    else:
        for record in display_records:
            print(
                "- "
                f"{record['kind']} | agent={record['agent']} | family={record['family']} "
                f"| name={record['name']} | schedule={record['schedule_text']} "
                f"| next={format_dt(record['next_run_at'])} "
                f"| last={format_dt(record['last_run_at'])} "
                f"| status={record['last_status']}"
            )
        if limit != 0 and len(filtered_records) > len(display_records):
            print(f"- ... ({len(filtered_records) - len(display_records)} more jobs)")
    return 0


def resolve_show_record(records, ref):
    exact = [record for record in records if record["id"] == ref or record["name"] == ref]
    if len(exact) == 1:
        return exact[0]
    if len(exact) > 1:
        raise ValueError(f"multiple jobs matched exactly for {ref!r}")

    partial = [record for record in records if ref in record["id"] or ref in record["name"]]
    if len(partial) == 1:
        return partial[0]
    if not partial:
        raise ValueError(f"no job matched {ref!r}")
    raise ValueError(f"{len(partial)} jobs matched {ref!r}; use the full id or exact name")


def print_show(args, records):
    try:
        record = resolve_show_record(records, args.job_ref)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.format == "json" or args.json:
        print(json.dumps(serialize_record(record, include_payload=True), ensure_ascii=False, indent=2))
        return 0

    if args.format == "shell":
        print(render_shell(record))
        return 0

    print(f"source_file: {Path(args.jobs_file).expanduser()}")
    print(f"id: {record['id']}")
    print(f"name: {record['name']}")
    print(f"agent: {record['agent']}")
    print(f"family: {record['family']}")
    print(f"kind: {record['kind']}")
    print(f"enabled: {'yes' if record['enabled'] else 'no'}")
    print(f"session_target: {record['session_target']}")
    print(f"wake_mode: {record['wake_mode']}")
    print(f"payload_kind: {record['payload_kind']}")
    print(f"schedule: {record['schedule_text']}")
    print(f"next_run: {format_dt(record['next_run_at'])}")
    print(f"last_run: {format_dt(record['last_run_at'])}")
    print(f"last_status: {record['last_status']}")
    print(f"consecutive_errors: {record['consecutive_errors']}")
    print(f"last_delivery_status: {record['last_delivery_status']}")
    print()
    print("payload:")
    if record["payload_text"]:
        print(record["payload_text"])
    else:
        print("(empty)")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description="OpenClaw cron inventory, enqueue metadata, and cleanup helpers for Agent Bridge.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory_parser = subparsers.add_parser("inventory", help="Summarize and filter cron jobs.")
    inventory_parser.add_argument("--jobs-file", required=True)
    inventory_parser.add_argument("--agent")
    inventory_parser.add_argument("--family")
    inventory_parser.add_argument("--mode", choices=("all", "recurring", "one-shot"), default="all")
    inventory_parser.add_argument("--enabled", choices=("all", "yes", "no"), default="all")
    inventory_parser.add_argument("--limit", type=int, default=None)
    inventory_parser.add_argument("--json", action="store_true")

    show_parser = subparsers.add_parser("show", help="Show one cron job in detail.")
    show_parser.add_argument("--jobs-file", required=True)
    show_parser.add_argument("job_ref")
    show_parser.add_argument("--format", choices=("text", "json", "shell"), default="text")
    show_parser.add_argument("--json", action="store_true")

    errors_report_parser = subparsers.add_parser("errors-report", help="Report recurring cron jobs that are currently in error.")
    errors_report_parser.add_argument("--jobs-file", required=True)
    errors_report_parser.add_argument("--agent")
    errors_report_parser.add_argument("--family")
    errors_report_parser.add_argument("--limit", type=int, default=None)
    errors_report_parser.add_argument("--json", action="store_true")

    cleanup_report_parser = subparsers.add_parser("cleanup-report", help="Report prune candidates for stale one-shot cron jobs.")
    cleanup_report_parser.add_argument("--jobs-file", required=True)
    cleanup_report_parser.add_argument("--mode", choices=("expired-one-shot",), default="expired-one-shot")
    cleanup_report_parser.add_argument("--limit", type=int, default=None)
    cleanup_report_parser.add_argument("--json", action="store_true")

    cleanup_prune_parser = subparsers.add_parser("cleanup-prune", help="Prune stale one-shot cron jobs from jobs.json.")
    cleanup_prune_parser.add_argument("--jobs-file", required=True)
    cleanup_prune_parser.add_argument("--mode", choices=("expired-one-shot",), default="expired-one-shot")
    cleanup_prune_parser.add_argument("--dry-run", action="store_true")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    try:
        raw_payload, jobs = load_jobs_payload(args.jobs_file)
        records = [build_job_record(job) for job in jobs]
    except FileNotFoundError:
        print(f"error: jobs file not found: {args.jobs_file}", file=sys.stderr)
        return 2
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"error: failed to read jobs file: {exc}", file=sys.stderr)
        return 2

    if args.command == "inventory":
        filtered = filter_records(records, args)
        if args.limit is not None and args.limit < 0:
            print("error: --limit must be >= 0", file=sys.stderr)
            return 2
        return print_inventory(args, records, filtered)

    if args.command == "show":
        return print_show(args, records)

    if args.command == "errors-report":
        if args.limit is not None and args.limit < 0:
            print("error: --limit must be >= 0", file=sys.stderr)
            return 2
        return print_errors_report(args, records)

    if args.command == "cleanup-report":
        if args.limit is not None and args.limit < 0:
            print("error: --limit must be >= 0", file=sys.stderr)
            return 2
        return print_cleanup_report(args, records)

    if args.command == "cleanup-prune":
        return run_cleanup_prune(args, raw_payload, records)

    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
