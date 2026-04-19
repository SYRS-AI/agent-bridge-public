#!/usr/bin/env python3
"""bridge-context-pressure.py — classify context pressure from recent pane text."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

# Claude HUD renders a live context meter like:
#   Context ████████░░ 40%
# We require the word "Context" followed within a short window by one of the
# bar glyphs (█ ░ ▓ ▒ ■), then a 1-3 digit percent. The glyph requirement is
# what distinguishes the authoritative HUD from prose text such as
# "Context remaining 8%" that happens to live in post-/compact scrollback
# after --continue/--resume (issue #126).
#
# Defense in depth against pane wrapping: the daemon's capture-pane call
# passes tmux -J (see lib/bridge-tmux.sh bridge_capture_recent "join"), but
# we also tolerate a single newline inside the short glyph-neighborhood so
# captures from non-joined callers (or older recordings used in tests) still
# match when the HUD wraps on a narrow terminal.
HUD_RE = re.compile(
    r"Context[\s\S]{0,60}?[\u2588\u2591\u2592\u2593\u25A0][\u2588\u2591\u2592\u2593\u25A0\s]{0,40}?(\d{1,3})\s*%",
    re.IGNORECASE,
)

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


def normalize_full(text: str) -> str:
    """Strip ANSI + ignored prefixes; DO NOT tail-truncate. Used for HUD scan."""
    text = ANSI_RE.sub("", text.replace("\r", ""))
    lines: list[str] = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if any(stripped.startswith(prefix) for prefix in IGNORED_PREFIXES):
            continue
        lines.append(raw)
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines).strip()


def normalize_excerpt(text: str, max_bytes: int) -> str:
    normalized = normalize_full(text)
    if not normalized:
        return ""
    encoded = normalized.encode("utf-8")
    if len(encoded) <= max_bytes:
        return normalized
    return encoded[-max_bytes:].decode("utf-8", errors="ignore").lstrip()


def _env_threshold(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return default
    if 0 <= value <= 100:
        return value
    return default


def hud_context_pct(normalized: str) -> int | None:
    """Return the latest HUD context percentage, or None if no HUD line seen."""
    matches = list(HUD_RE.finditer(normalized))
    if not matches:
        return None
    try:
        pct = int(matches[-1].group(1))
    except (TypeError, ValueError):
        return None
    if pct < 0 or pct > 100:
        return None
    return pct


def classify(normalized: str, full: str | None = None) -> tuple[str, str]:
    """Classify context pressure.

    The Claude HUD ("Context <bar> NN%") is the authoritative live signal: if
    present anywhere in the full (un-truncated) capture, it alone drives the
    classification and fallback patterns are skipped. This fixes the #126
    false-positive where post-/compact scrollback leftover from a previous
    session ("Conversation compacted" banner and prior /compact prompt) kept
    matching the 'conversation.+compact' fallback regex every daemon scan.

    If no HUD line is visible (pre-HUD Claude builds, Codex, or very fresh
    sessions), fall back to the existing pattern groups so genuine textual
    signals still fire.
    """
    scan_target = full if full is not None else normalized
    pct = hud_context_pct(scan_target)
    if pct is not None:
        critical_th = _env_threshold("BRIDGE_CONTEXT_PRESSURE_HUD_CRITICAL_PCT", 85)
        warning_th = _env_threshold("BRIDGE_CONTEXT_PRESSURE_HUD_WARNING_PCT", 60)
        if pct >= critical_th:
            return "critical", f"hud:context_pct={pct}"
        if pct >= warning_th:
            return "warning", f"hud:context_pct={pct}"
        # HUD says below threshold: authoritative, do not fall back.
        # Trade-off: if Claude ever renders a live low-HUD alongside a
        # simultaneously-live hard-block banner (e.g., "must compact before
        # continuing"), the banner is suppressed here. We bias to trusting
        # the HUD because the #126 false-positive volume came entirely from
        # post-/compact scrollback mimicking a banner while HUD was low.
        return "", f"hud:context_pct={pct}"

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

    raw_capture = read_capture(args.capture_file)
    full = normalize_full(raw_capture)
    normalized = normalize_excerpt(raw_capture, max(args.max_bytes, 256))
    severity, matched = classify(normalized, full=full)
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
