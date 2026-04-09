#!/usr/bin/env python3
"""bridge-stall.py — normalize recent pane text and classify stall patterns."""

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
        "rate_limit",
        [
            r"selected model is at capacity",
            r"at capacity",
            r"hit your limit",
            r"rate limit exceeded",
            r"rate_limit_exceeded",
            r"too many requests",
            r"\b429\b",
            r"please wait before trying",
            r"try a different model",
            r"quota exceeded",
        ],
    ),
    (
        "auth",
        [
            r"session expired",
            r"unauthorized",
            r"login required",
            r"authentication failed",
            r"token expired",
            r"not authenticated",
        ],
    ),
    (
        "network",
        [
            r"econnreset",
            r"econnrefused",
            r"connection refused",
            r"timeout",
            r"timed out",
            r"503 service unavailable",
            r"502 bad gateway",
            r"upstream connect error",
        ],
    ),
]

IGNORED_PREFIXES = (
    "[Agent Bridge]",
)

IGNORED_LINES = {
    "A rate-limit or capacity error was detected. Retry the current task now and continue from the current state.",
    "A transient network or provider error was detected. Retry the current task and continue if the connection is healthy now.",
    "The current task appears stalled. Check the current state, summarize what is blocking progress, and continue if work can proceed.",
}


def looks_like_agent_output(stripped: str) -> bool:
    if not stripped:
        return False
    if stripped.startswith(("❯", ">", "›")):
        return True
    lowered = stripped.lower()
    for _classification, patterns in PATTERN_GROUPS:
        for pattern in patterns:
            if re.search(pattern, lowered, flags=re.IGNORECASE):
                return True
    return False


def read_capture(path: str | None) -> str:
    if path:
        return Path(path).read_text(encoding="utf-8", errors="ignore")
    return sys.stdin.read()


def normalize_excerpt(text: str, max_bytes: int) -> str:
    text = ANSI_RE.sub("", text.replace("\r", ""))
    lines = []
    skipping_bridge = False
    for raw in text.splitlines():
        stripped = raw.strip()
        if any(stripped.startswith(prefix) for prefix in IGNORED_PREFIXES):
            skipping_bridge = True
            continue
        if skipping_bridge:
            if looks_like_agent_output(stripped):
                skipping_bridge = False
            else:
                continue
        if stripped in IGNORED_LINES:
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
    for classification, patterns in PATTERN_GROUPS:
        for pattern in patterns:
            if re.search(pattern, lowered, flags=re.IGNORECASE):
                return classification, pattern
    return "", ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("analyze",))
    parser.add_argument("--capture-file")
    parser.add_argument("--max-bytes", type=int, default=8192)
    parser.add_argument("--format", choices=("json", "shell"), default="json")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    normalized = normalize_excerpt(read_capture(args.capture_file), max(args.max_bytes, 256))
    classification, matched = classify(normalized)
    payload = {
        "classification": classification,
        "matched_pattern": matched,
        "excerpt": normalized,
        "excerpt_hash": hashlib.sha256(normalized.encode("utf-8")).hexdigest() if normalized else "",
        "excerpt_lines": len(normalized.splitlines()) if normalized else 0,
    }
    if args.format == "shell":
        print(f"STALL_CLASSIFICATION={json.dumps(payload['classification'])}")
        print(f"STALL_MATCHED_PATTERN={json.dumps(payload['matched_pattern'])}")
        print(f"STALL_EXCERPT_HASH={json.dumps(payload['excerpt_hash'])}")
        print(f"STALL_EXCERPT_LINES={int(payload['excerpt_lines'])}")
        print(f"STALL_EXCERPT_B64={json.dumps(base64.b64encode(payload['excerpt'].encode('utf-8')).decode('ascii'))}")
    elif args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
