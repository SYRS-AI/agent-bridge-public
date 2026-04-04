#!/usr/bin/env python3
import argparse
import json
import sys
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


def load_jobs(path):
    raw = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    jobs = raw.get("jobs") if isinstance(raw, dict) else raw
    if not isinstance(jobs, list):
        raise ValueError("jobs.json must contain a top-level list or {jobs:[...]}")
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


def build_job_record(job):
    state = job.get("state") or {}
    schedule = job.get("schedule") or {}
    payload = job.get("payload") or {}
    next_run = parse_epoch_ms(state.get("nextRunAtMs"))
    if next_run is None and schedule.get("kind") == "at":
        next_run = parse_iso_datetime(schedule.get("at"))

    last_run = parse_epoch_ms(state.get("lastRunAtMs"))
    name = job.get("name", "<unnamed>")

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
        "last_status": state.get("lastStatus") or state.get("lastRunStatus") or "-",
        "consecutive_errors": int(state.get("consecutiveErrors") or 0),
        "last_delivery_status": state.get("lastDeliveryStatus") or "-",
        "session_target": job.get("sessionTarget", "-"),
        "wake_mode": job.get("wakeMode", "-"),
        "payload_kind": payload.get("kind", "-"),
        "payload_text": payload.get("text") or payload.get("message") or "",
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
        "last_status": record["last_status"],
        "consecutive_errors": record["consecutive_errors"],
        "last_delivery_status": record["last_delivery_status"],
        "session_target": record["session_target"],
        "wake_mode": record["wake_mode"],
        "payload_kind": record["payload_kind"],
    }
    if include_payload:
        payload["payload_text"] = record["payload_text"]
        payload["raw"] = record["raw"]
    return payload


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

    if args.json:
        print(json.dumps(serialize_record(record, include_payload=True), ensure_ascii=False, indent=2))
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
    parser = argparse.ArgumentParser(description="Read-only OpenClaw cron inventory for Agent Bridge.")
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
    show_parser.add_argument("--json", action="store_true")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    try:
        records = [build_job_record(job) for job in load_jobs(args.jobs_file)]
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

    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
