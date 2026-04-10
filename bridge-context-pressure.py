#!/usr/bin/env python3
"""bridge-context-pressure.py — classify context pressure from recent pane text."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

PATTERN_GROUPS: list[tuple[str, list[str]]] = [
    (
        "critical",
        [
            r"context length exceeded",
            r"context window exceeded",
            r"maximum context",
            r"context limit exceeded",
            r"too long for the model",
            r"out of context",
            r"must compact before continuing",
        ],
    ),
    (
        "warning",
        [
            r"context remaining[^0-9]*(?:[0-9]|[1-2][0-9])%",
            r"(?:[0-9]|[1-2][0-9])%[^A-Za-z0-9]+context",
            r"low context",
            r"context is low",
            r"approaching.+context",
            r"consider compact",
            r"compact.+conversation",
            r"conversation.+compact",
        ],
    ),
]

IGNORED_PREFIXES = ("[Agent Bridge]",)


def read_capture(path: str | None) -> str:
    if path:
        return Path(path).read_text(encoding="utf-8", errors="ignore")
    return sys.stdin.read()


def normalize_excerpt(text: str, max_bytes: int) -> str:
    text = ANSI_RE.sub("", text.replace("\r", ""))
    lines: list[str] = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if any(stripped.startswith(prefix) for prefix in IGNORED_PREFIXES):
            continue
        lines.append(raw)
    while lines and not lines[-1].strip():
        lines.pop()
    normalized = "\n".join(lines).strip()
    if not normalized:
        return ""
    encoded = normalized.encode("utf-8")
    if len(encoded) <= max_bytes:
        return normalized
    return encoded[-max_bytes:].decode("utf-8", errors="ignore").lstrip()


def classify(normalized: str) -> tuple[str, str]:
    lowered = normalized.lower()
    for severity, patterns in PATTERN_GROUPS:
        for pattern in patterns:
            if re.search(pattern, lowered, flags=re.IGNORECASE | re.DOTALL):
                return severity, pattern
    return "", ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("analyze",))
    parser.add_argument("--capture-file")
    parser.add_argument("--max-bytes", type=int, default=4096)
    parser.add_argument("--format", choices=("json", "shell"), default="json")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    normalized = normalize_excerpt(read_capture(args.capture_file), max(args.max_bytes, 256))
    severity, matched = classify(normalized)
    payload = {
        "severity": severity,
        "matched_pattern": matched,
        "excerpt": normalized,
        "excerpt_hash": hashlib.sha256(normalized.encode("utf-8")).hexdigest() if normalized else "",
        "excerpt_lines": len(normalized.splitlines()) if normalized else 0,
    }
    if args.format == "shell":
        print(f"CONTEXT_PRESSURE_SEVERITY={json.dumps(payload['severity'])}")
        print(f"CONTEXT_PRESSURE_MATCHED_PATTERN={json.dumps(payload['matched_pattern'])}")
        print(f"CONTEXT_PRESSURE_EXCERPT_HASH={json.dumps(payload['excerpt_hash'])}")
        print(f"CONTEXT_PRESSURE_EXCERPT_LINES={int(payload['excerpt_lines'])}")
        encoded = base64.b64encode(payload["excerpt"].encode("utf-8")).decode("ascii")
        print(f"CONTEXT_PRESSURE_EXCERPT_B64={json.dumps(encoded)}")
    elif args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
