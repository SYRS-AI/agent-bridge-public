#!/usr/bin/env python3
"""bridge-usage.py - collect and monitor Claude/Codex usage windows."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def parse_iso(text: str | None) -> datetime | None:
    if not text:
        return None
    raw = text
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    return datetime.fromisoformat(raw)


def iso_from_epoch(epoch: Any) -> str | None:
    if epoch in (None, ""):
        return None
    try:
        value = int(epoch)
    except (TypeError, ValueError):
        return None
    return datetime.fromtimestamp(value, tz=timezone.utc).astimezone().isoformat(timespec="seconds")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def classify_health(used_percent: float | None, warn: float, critical: float) -> str:
    if used_percent is None:
        return "unknown"
    if used_percent >= critical:
        return "crit"
    if used_percent >= warn:
        return "warn"
    return "ok"


def format_reset(reset_at: str | None) -> str:
    if not reset_at:
        return "unknown"
    try:
        reset_dt = parse_iso(reset_at)
    except Exception:
        return reset_at
    if reset_dt is None:
        return "unknown"
    delta = int((reset_dt - datetime.now(timezone.utc).astimezone()).total_seconds())
    if delta <= 0:
        return "resetting now"
    minutes = delta // 60
    hours, minutes = divmod(minutes, 60)
    if hours > 0:
        return f"in {hours}h {minutes}m"
    return f"in {minutes}m"


def normalize_window(name: str, minutes: Any) -> str:
    try:
        value = int(minutes)
    except (TypeError, ValueError):
        return name
    if value == 300:
        return "5h"
    if value == 10080:
        return "weekly"
    return f"{value}m"


def claude_snapshots(path: Path, warn: float, critical: float) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    try:
        payload = load_json(path)
    except Exception:
        return []
    if not isinstance(payload, dict):
        return []
    data = payload.get("data") or payload.get("lastGoodData") or {}
    if not isinstance(data, dict):
        return []

    snapshots: list[dict[str, Any]] = []
    plan = data.get("planName") or "subscription"
    windows = [
        ("5h", data.get("fiveHour"), data.get("fiveHourResetAt")),
        ("weekly", data.get("sevenDay"), data.get("sevenDayResetAt")),
    ]
    for window, used_percent, reset_at in windows:
        try:
            percent = float(used_percent)
        except (TypeError, ValueError):
            percent = None  # type: ignore[assignment]
        snapshots.append(
            {
                "provider": "claude",
                "account": plan,
                "window": window,
                "used_percent": percent,
                "reset_at": reset_at,
                "health": classify_health(percent, warn, critical),
                "source": str(path),
            }
        )
    return snapshots


def iter_codex_rate_limits(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return records
    for line in reversed(lines):
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        entry = payload.get("payload")
        if not isinstance(entry, dict):
            continue
        rate_limits = entry.get("rate_limits")
        if not isinstance(rate_limits, dict):
            continue
        record = dict(rate_limits)
        record["_source_file"] = str(path)
        record["_timestamp"] = payload.get("timestamp")
        records.append(record)
    return records


def codex_snapshots(root: Path, warn: float, critical: float) -> list[dict[str, Any]]:
    if not root.is_dir():
        return []

    files = sorted(root.rglob("*.jsonl"), reverse=True)
    latest: dict[str, dict[str, Any]] = {}
    for path in files[:200]:
        for record in iter_codex_rate_limits(path):
            limit_id = str(record.get("limit_id") or "codex")
            # The global codex window is the actionable subscription limit.
            if limit_id != "codex":
                continue
            if limit_id in latest:
                continue
            latest[limit_id] = record
        if "codex" in latest:
            break

    snapshots: list[dict[str, Any]] = []
    for limit_id, record in latest.items():
        for field_name, default_name in (("primary", "5h"), ("secondary", "weekly")):
            window_payload = record.get(field_name)
            if not isinstance(window_payload, dict):
                continue
            try:
                used_percent = float(window_payload.get("used_percent"))
            except (TypeError, ValueError):
                used_percent = None  # type: ignore[assignment]
            window_name = normalize_window(default_name, window_payload.get("window_minutes"))
            snapshots.append(
                {
                    "provider": "codex",
                    "account": limit_id,
                    "window": window_name,
                    "used_percent": used_percent,
                    "reset_at": iso_from_epoch(window_payload.get("resets_at")),
                    "health": classify_health(used_percent, warn, critical),
                    "source": record.get("_source_file"),
                }
            )
    return snapshots


def collect_snapshots(args: argparse.Namespace) -> list[dict[str, Any]]:
    warn = float(args.warn_threshold)
    critical = float(args.critical_threshold)
    snapshots = []
    snapshots.extend(claude_snapshots(Path(args.claude_usage_cache).expanduser(), warn, critical))
    snapshots.extend(codex_snapshots(Path(args.codex_sessions_dir).expanduser(), warn, critical))
    return snapshots


def bucket_for_snapshot(snapshot: dict[str, Any], warn: float, critical: float) -> str:
    used_percent = snapshot.get("used_percent")
    if not isinstance(used_percent, (int, float)):
        return "unknown"
    if used_percent >= critical:
        return "crit"
    if used_percent >= warn:
        return "warn"
    return "ok"


def alert_message(snapshot: dict[str, Any], bucket: str) -> str:
    provider = str(snapshot.get("provider", "")).capitalize()
    window = snapshot.get("window") or "unknown"
    used_percent = snapshot.get("used_percent")
    reset_at = snapshot.get("reset_at")
    if isinstance(used_percent, (int, float)):
        percent_text = f"{used_percent:.0f}%"
    else:
        percent_text = "unknown"
    level = "critical" if bucket == "crit" else "warning"
    return (
        f"{provider} usage {level}: {window} window at {percent_text}, "
        f"resets {format_reset(reset_at)}. Consider switching the active subscription account."
    )


def load_monitor_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {"entries": {}}
    try:
        payload = load_json(path)
    except Exception:
        return {"entries": {}}
    if not isinstance(payload, dict):
        return {"entries": {}}
    entries = payload.get("entries")
    if not isinstance(entries, dict):
        payload["entries"] = {}
    return payload


def save_monitor_state(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def cmd_status(args: argparse.Namespace) -> int:
    snapshots = collect_snapshots(args)
    result = {"generated_at": now_iso(), "snapshots": snapshots}
    if args.json:
        print(json.dumps(result, ensure_ascii=True, indent=2))
        return 0
    for snapshot in snapshots:
        print(
            "\t".join(
                [
                    str(snapshot.get("provider", "")),
                    str(snapshot.get("account", "")),
                    str(snapshot.get("window", "")),
                    str(snapshot.get("used_percent", "")),
                    str(snapshot.get("reset_at", "")),
                    str(snapshot.get("health", "")),
                    str(snapshot.get("source", "")),
                ]
            )
        )
    return 0


def cmd_monitor(args: argparse.Namespace) -> int:
    snapshots = collect_snapshots(args)
    state_path = Path(args.state_file).expanduser()
    state = load_monitor_state(state_path)
    entries = state.setdefault("entries", {})
    alerts: list[dict[str, Any]] = []
    warn = float(args.warn_threshold)
    critical = float(args.critical_threshold)

    for snapshot in snapshots:
        key = "::".join(
            [
                str(snapshot.get("provider", "")),
                str(snapshot.get("account", "")),
                str(snapshot.get("window", "")),
            ]
        )
        bucket = bucket_for_snapshot(snapshot, warn, critical)
        reset_at = snapshot.get("reset_at")
        used_percent = snapshot.get("used_percent")
        previous = entries.get(key, {}) if isinstance(entries.get(key), dict) else {}
        previous_reset = previous.get("reset_at")
        previous_bucket = previous.get("last_alert_bucket")

        if bucket in {"warn", "crit"} and (previous_bucket != bucket or previous_reset != reset_at):
            alert = {
                **snapshot,
                "bucket": bucket,
                "message": alert_message(snapshot, bucket),
            }
            alerts.append(alert)
            entries[key] = {
                "last_alert_bucket": bucket,
                "reset_at": reset_at,
                "used_percent": used_percent,
                "alerted_at": now_iso(),
            }
        elif bucket == "ok":
            entries[key] = {
                "last_alert_bucket": None,
                "reset_at": reset_at,
                "used_percent": used_percent,
                "alerted_at": previous.get("alerted_at"),
            }
        else:
            entries[key] = {
                "last_alert_bucket": previous_bucket,
                "reset_at": reset_at,
                "used_percent": used_percent,
                "alerted_at": previous.get("alerted_at"),
            }

    state["updated_at"] = now_iso()
    save_monitor_state(state_path, state)
    result = {"generated_at": now_iso(), "snapshots": snapshots, "alerts": alerts, "state_file": str(state_path)}
    if args.json:
        print(json.dumps(result, ensure_ascii=True, indent=2))
        return 0
    for alert in alerts:
        print(alert["message"])
    return 0


def cmd_alerts(args: argparse.Namespace) -> int:
    audit_file = Path(args.audit_file).expanduser()
    if not audit_file.is_file():
        payload: list[dict[str, Any]] = []
    else:
        payload = []
        for line in audit_file.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict) or record.get("action") != "usage_alert":
                continue
            payload.append(record)
    limit = max(0, int(args.limit))
    if limit:
        payload = payload[-limit:]
    if args.json:
        print(json.dumps(payload, ensure_ascii=True, indent=2))
        return 0
    for record in payload:
        print(json.dumps(record, ensure_ascii=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    common_kwargs = {
        "help": argparse.SUPPRESS,
    }

    def add_source_args(cmd: argparse.ArgumentParser) -> None:
        cmd.add_argument("--claude-usage-cache", required=True, **common_kwargs)
        cmd.add_argument("--codex-sessions-dir", required=True, **common_kwargs)
        cmd.add_argument("--warn-threshold", type=float, default=90.0, **common_kwargs)
        cmd.add_argument("--critical-threshold", type=float, default=100.0, **common_kwargs)

    status_parser = sub.add_parser("status")
    add_source_args(status_parser)
    status_parser.add_argument("--json", action="store_true")
    status_parser.set_defaults(handler=cmd_status)

    monitor_parser = sub.add_parser("monitor")
    add_source_args(monitor_parser)
    monitor_parser.add_argument("--state-file", required=True)
    monitor_parser.add_argument("--json", action="store_true")
    monitor_parser.set_defaults(handler=cmd_monitor)

    alerts_parser = sub.add_parser("alerts")
    alerts_parser.add_argument("--audit-file", required=True)
    alerts_parser.add_argument("--limit", type=int, default=20)
    alerts_parser.add_argument("--json", action="store_true")
    alerts_parser.set_defaults(handler=cmd_alerts)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
