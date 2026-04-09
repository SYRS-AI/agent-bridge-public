#!/usr/bin/env python3
"""bridge-audit.py — append/query structured Agent Bridge audit logs."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def parse_json(text: str) -> dict[str, Any]:
    if not text:
        return {}
    payload = json.loads(text)
    if not isinstance(payload, dict):
        raise SystemExit("detail JSON must be an object")
    return payload


def parse_detail(items: list[str], detail_json: str | None) -> dict[str, Any]:
    detail = parse_json(detail_json or "")
    for item in items:
        if "=" not in item:
            raise SystemExit(f"detail must be key=value: {item}")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise SystemExit(f"detail key is empty: {item}")
        detail[key] = value
    return detail


def append_record(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, ensure_ascii=True) + "\n")


def cmd_write(args: argparse.Namespace) -> int:
    detail = parse_detail(args.detail, args.detail_json)
    record = {
        "ts": now_iso(),
        "actor": args.actor,
        "action": args.action,
        "target": args.target,
        "detail": detail,
        "pid": os.getpid(),
        "host": socket.gethostname(),
    }
    append_record(Path(args.file).expanduser(), record)
    if args.json:
        print(json.dumps(record, ensure_ascii=True))
    return 0


def parse_since(text: str | None) -> datetime | None:
    if not text:
        return None
    raw = text
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    return datetime.fromisoformat(raw)


def load_records(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                records.append(payload)
    return records


def matches_agent(record: dict[str, Any], agent: str) -> bool:
    if record.get("target") == agent:
        return True
    detail = record.get("detail")
    if not isinstance(detail, dict):
        return False
    for key in ("agent", "assigned_to", "source_agent", "target_agent"):
        if detail.get(key) == agent:
            return True
    return False


def cmd_list(args: argparse.Namespace) -> int:
    path = Path(args.file).expanduser()
    records = load_records(path)
    since_dt = parse_since(args.since)

    filtered: list[dict[str, Any]] = []
    for record in records:
        if args.action and record.get("action") != args.action:
            continue
        if args.agent and not matches_agent(record, args.agent):
            continue
        if since_dt is not None:
            ts = record.get("ts")
            if not isinstance(ts, str):
                continue
            try:
                ts_dt = parse_since(ts)
            except Exception:
                continue
            if ts_dt is None or ts_dt < since_dt:
                continue
        filtered.append(record)

    limit = max(0, int(args.limit))
    if limit:
        filtered = filtered[-limit:]

    if args.json:
        print(json.dumps(filtered, ensure_ascii=True, indent=2))
        return 0

    for record in filtered:
        detail = record.get("detail")
        if not isinstance(detail, dict):
            detail = {}
        print(
            "\t".join(
                [
                    str(record.get("ts", "")),
                    str(record.get("actor", "")),
                    str(record.get("action", "")),
                    str(record.get("target", "")),
                    json.dumps(detail, ensure_ascii=True, sort_keys=True),
                ]
            )
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    write_parser = sub.add_parser("write")
    write_parser.add_argument("--file", required=True)
    write_parser.add_argument("--actor", required=True)
    write_parser.add_argument("--action", required=True)
    write_parser.add_argument("--target", required=True)
    write_parser.add_argument("--detail", action="append", default=[])
    write_parser.add_argument("--detail-json")
    write_parser.add_argument("--json", action="store_true")
    write_parser.set_defaults(handler=cmd_write)

    list_parser = sub.add_parser("list")
    list_parser.add_argument("--file", required=True)
    list_parser.add_argument("--agent")
    list_parser.add_argument("--action")
    list_parser.add_argument("--since")
    list_parser.add_argument("--limit", type=int, default=20)
    list_parser.add_argument("--json", action="store_true")
    list_parser.set_defaults(handler=cmd_list)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
