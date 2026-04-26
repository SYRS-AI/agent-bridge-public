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
# We anchor on "Context" at the start of a line (leading whitespace is
# tolerated for the indent prefix Claude renders before the meter), then
# require an immediate run of bar-block glyphs (█ ░ ▒ ▓ ■), then the
# trailing percent. Only whitespace is allowed between "Context" and the
# first bar glyph; this preserves the #126 distinction from prose like
# "Context remaining 8%" while also rejecting the wrong-window false-
# positives flagged in #338 Track A — sentences such as
# "In this Context we should ████████ 100% of …" no longer match because
# arbitrary words between "Context" and the bar block are excluded.
#
# Defense in depth against pane wrapping: the daemon's capture-pane call
# passes tmux -J (see lib/bridge-tmux.sh bridge_capture_recent "join"), but
# the whitespace tolerance (\s+ includes \n) still lets the HUD match when
# it wraps across "Context" and the bar block on a narrow terminal.
HUD_RE = re.compile(
    r"(?m)^\s*Context\s+[\u2588\u2591\u2592\u2593\u25A0][\u2588\u2591\u2592\u2593\u25A0\s]*?\s*(\d{1,3})\s*%",
)

# Fresh-session markers — when one of these appears in the captured pane
# *after* the latest HUD-line match, the HUD line is stale scrollback from
# the pre-reset session and must not drive classification (issue #338
# Track B). The post-/clear and post-/new banners both render the literal
# "Welcome to Claude Code" / "Welcome to Codex" string verbatim. The B1
# strategy keeps the analyzer purely text-based — no daemon-side state
# coordination is needed because the captured pane buffer carries both the
# stale HUD and the fresh-session banner side-by-side.
RESET_MARKER_RE = re.compile(
    r"Welcome to (?:Claude Code|Codex)",
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

# Engines with no trustworthy authoritative HUD of their own. When the HUD
# regex fails for these, we skip the WARNING-severity fallback group to
# avoid false-positives on scrollback containing literal UI phrases
# ("Context compacted", "compact the conversation") and doc excerpts that
# hit the warning prose patterns (issue #183). CRITICAL-severity patterns
# ("context window exceeded", "must compact before continuing", etc.) still
# fire — those are genuine hard-stop banners and are rare enough in
# scrollback that the false-positive budget is effectively zero.
# Claude keeps the existing HUD-or-fallback behavior because the fallback
# is the only signal on pre-HUD builds.
ENGINES_WITHOUT_HUD = frozenset({"codex"})

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
    """Return the latest HUD context percentage, or None if no HUD line seen.

    Issue #338 Track B: if a fresh-session marker (post-/clear or post-/new
    "Welcome to …" banner) appears *after* the latest HUD-line match in the
    captured pane, the HUD line is stale scrollback from the pre-reset
    session. Treat it the same as "no HUD seen" so the analyzer does not
    cache a critical reading from a session the operator has already
    cleared. The captured pane buffer carries both lines simultaneously,
    so the reset detection happens here in the extractor without any
    daemon-side state coordination.
    """
    matches = list(HUD_RE.finditer(normalized))
    if not matches:
        return None
    last_match = matches[-1]
    if RESET_MARKER_RE.search(normalized, last_match.end()):
        return None
    try:
        pct = int(last_match.group(1))
    except (TypeError, ValueError):
        return None
    if pct < 0 or pct > 100:
        return None
    return pct


def classify(normalized: str, full: str | None = None, engine: str = "") -> tuple[str, str]:
    """Classify context pressure.

    The Claude HUD ("Context <bar> NN%") is the authoritative live signal: if
    present anywhere in the full (un-truncated) capture, it alone drives the
    classification and fallback patterns are skipped. This fixes the #126
    false-positive where post-/compact scrollback leftover from a previous
    session ("Conversation compacted" banner and prior /compact prompt) kept
    matching the 'conversation.+compact' fallback regex every daemon scan.

    If no HUD line is visible (pre-HUD Claude builds, Codex, or very fresh
    sessions), fall back to the existing pattern groups so genuine textual
    signals still fire. For engines in ``ENGINES_WITHOUT_HUD`` the WARNING-
    severity group is skipped because it false-positives reliably on UI
    prose and doc excerpts (issue #183); the CRITICAL-severity group still
    runs so genuine hard-stop banners like "context window exceeded" or
    "must compact before continuing" still raise a task (PR #188 review
    feedback — silencing critical outright would hide real failures).
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

    skip_warning_fallback = bool(engine) and engine.lower() in ENGINES_WITHOUT_HUD

    lowered = normalized.lower()
    for severity, patterns in PATTERN_GROUPS:
        if skip_warning_fallback and severity == "warning":
            continue
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
    parser.add_argument(
        "--engine",
        default="",
        help=(
            "Owning agent's engine name (e.g. 'claude', 'codex'). Engines in "
            "ENGINES_WITHOUT_HUD skip the fallback regex when no HUD is visible."
        ),
    )
    args = parser.parse_args()

    raw_capture = read_capture(args.capture_file)
    full = normalize_full(raw_capture)
    normalized = normalize_excerpt(raw_capture, max(args.max_bytes, 256))
    severity, matched = classify(normalized, full=full, engine=args.engine)
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
