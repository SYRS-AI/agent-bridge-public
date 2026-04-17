#!/usr/bin/env python3
"""Agent Bridge prompt guard CLI."""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from typing import Any

from bridge_guard_common import (
    analyze_text,
    canary_tokens_for_agent,
    prompt_guard_enabled,
    sanitize_text,
)


def shell_line(key: str, value: str) -> str:
    return f"{key}={shlex.quote(str(value))}"


def read_input(args: argparse.Namespace) -> str:
    if args.file:
        return open(args.file, "r", encoding="utf-8").read()
    if getattr(args, "text_flag", None) is not None:
        return str(args.text_flag)
    if args.text is not None:
        return args.text
    return sys.stdin.read()


def print_payload(payload: dict[str, Any], fmt: str) -> None:
    if fmt == "json":
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return
    if fmt == "shell":
        for key, value in payload.items():
            if isinstance(value, list):
                text = json.dumps(value, ensure_ascii=False)
            elif isinstance(value, bool):
                text = "1" if value else "0"
            else:
                text = str(value)
            print(shell_line(key, text))
        return
    for key, value in payload.items():
        if isinstance(value, list):
            text = ", ".join(str(item) for item in value)
        else:
            text = str(value)
        print(f"{key}: {text}")


def cmd_status(args: argparse.Namespace) -> int:
    payload = {
        "guard_enabled": prompt_guard_enabled(),
        "agent": args.agent or "",
        "surface": args.surface or "",
    }
    print_payload(payload, args.format)
    return 0


def cmd_scan(args: argparse.Namespace) -> int:
    text = read_input(args)
    result = analyze_text(
        text,
        threshold=args.threshold,
        surface=args.surface,
        agent=args.agent or "",
    )
    payload = {
        "guard_enabled": prompt_guard_enabled(),
        "surface": result.surface,
        "agent": result.agent,
        "backend": result.backend,
        "severity": result.severity,
        "threshold": result.threshold,
        "blocked": result.blocked,
        "action": result.action,
        "reasons": result.reasons,
        "categories": result.categories,
        "text_preview": result.text[:200],
    }
    print_payload(payload, args.format)
    return 0 if not result.blocked else 10


def cmd_sanitize(args: argparse.Namespace) -> int:
    text = read_input(args)
    result = sanitize_text(
        text,
        surface=args.surface,
        agent=args.agent or "",
        canary_tokens=canary_tokens_for_agent(args.agent or ""),
    )
    payload = {
        "guard_enabled": prompt_guard_enabled(),
        "surface": result.surface,
        "agent": result.agent,
        "backend": result.backend,
        "blocked": result.blocked,
        "was_modified": result.was_modified,
        "redaction_count": result.redaction_count,
        "redacted_types": result.redacted_types,
        "canary_triggered": result.canary_triggered,
        "canary_tokens": result.canary_tokens,
        "sanitized_text": result.sanitized_text,
    }
    print_payload(payload, args.format)
    return 0 if not result.blocked else 10


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-guard.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_format_flags(subparser: argparse.ArgumentParser) -> None:
        fmt = subparser.add_mutually_exclusive_group()
        fmt.add_argument("--format", choices=("text", "json", "shell"), default="text")
        fmt.add_argument("--json", action="store_const", const="json", dest="format")
        fmt.add_argument("--shell", action="store_const", const="shell", dest="format")

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--agent", default="")
    status_parser.add_argument("--surface", default="")
    add_format_flags(status_parser)
    status_parser.set_defaults(handler=cmd_status)

    scan_parser = subparsers.add_parser("scan")
    scan_parser.add_argument("text", nargs="?")
    scan_parser.add_argument("--text", dest="text_flag")
    scan_parser.add_argument("--file")
    scan_parser.add_argument("--agent", default="")
    scan_parser.add_argument("--surface", default="generic")
    scan_parser.add_argument("--threshold", default="high")
    add_format_flags(scan_parser)
    scan_parser.set_defaults(handler=cmd_scan)

    sanitize_parser = subparsers.add_parser("sanitize")
    sanitize_parser.add_argument("text", nargs="?")
    sanitize_parser.add_argument("--text", dest="text_flag")
    sanitize_parser.add_argument("--file")
    sanitize_parser.add_argument("--agent", default="")
    sanitize_parser.add_argument("--surface", default="output")
    add_format_flags(sanitize_parser)
    sanitize_parser.set_defaults(handler=cmd_sanitize)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
