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
            r"etimedout",
            r"connection refused",
            r"\bconnection\s+reset\s+by\s+peer\b",
            r"\bconnection\s+aborted\b",
            r"\bname\s+or\s+service\s+not\s+known\b",
            r"\bcontext\s+deadline\s+exceeded\b",
            # Issue #161: bare `timeout` / `timed out` matched benign scrollback
            # like Claude Code's `⎿  (timeout 5m)` tool-budget hint, shell
            # `timeout 120000ms`, and documentation strings — producing
            # repeated "retry the transient network error" nudges to idle
            # agents. Require a network-ish subject word next to the timeout
            # so only real transport errors classify as network.
            r"\b(?:connection|request|socket|read|write|fetch|network|upstream|gateway|dns|tcp|tls|ssl|i/o)\s+timed?\s*out\b",
            r"network\s+timeout",
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

# Claude Code UI glyphs used to mark agent-authored output lines (prompt
# carets, tool-call markers, status pips, etc.). Any line beginning with
# one of these is the agent narrating — never raw provider error output.
AGENT_GLYPH_PREFIXES = ("❯", ">", "›", "⏺", "⎿", "✢", "✻", "✱", "ℹ", "✓", "✗")


def looks_like_agent_output(stripped: str) -> bool:
    # Issue #264: previously also matched PATTERN_GROUPS regexes, which made
    # any agent reply containing "429" / "rate limit" / etc. read as agent UI
    # and re-enter capture. classify() then re-matched the same pattern and
    # fired a fresh stall against the agent's own narration. Glyph prefixes
    # alone are the agent-output signal; pattern matching belongs in classify.
    return bool(stripped) and stripped.startswith(AGENT_GLYPH_PREFIXES)


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
    # Issue #264: skip agent-authored lines so the classifier never matches
    # the agent narrating a previous error (e.g. "⏺ inbox empty, no 429
    # reoccurrence"). Without this, agent replies referencing past errors
    # become a self-sustaining stall loop.
    candidate_lines: list[str] = []
    for raw in normalized.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith(AGENT_GLYPH_PREFIXES):
            continue
        candidate_lines.append(stripped.lower())
    if not candidate_lines:
        return "", ""
    haystack = "\n".join(candidate_lines)
    for classification, patterns in PATTERN_GROUPS:
        for pattern in patterns:
            if re.search(pattern, haystack, flags=re.IGNORECASE):
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
