#!/usr/bin/env bash
# tests/surface-reply-enforce/smoke.sh
#
# Regression test for issue #415 — Stop hook input-source ↔ output-reply
# enforcement.
#
# The hook reads a Claude Code Stop event from stdin (JSON with
# `transcript_path` and optional `stop_hook_active`), inspects the JSONL
# transcript at `transcript_path`, and emits
# `{"decision":"block","reason":"..."}` on stdout iff:
#
#   1. BRIDGE_AGENT_ID is non-empty (i.e. real agent session, not TUI-only)
#   2. The latest user turn carries a <channel source="<surface>"
#      chat_id="<id>" message_id="<id>"> tag for a supported surface
#      (discord/telegram/teams)
#   3. No subsequent assistant turn invoked
#      mcp__plugin_<surface>__reply with matching chat_id
#   4. No subsequent assistant text emitted
#      <no-reply-needed source="<surface>" chat_id="<id>" ...>
#
# Otherwise it is silent and exits 0 (Stop proceeds).
#
# We exercise five cases:
#   (a) channel input + matching mcp reply  -> exit 0, no output
#   (b) channel input + missing reply       -> exit 0, JSON block on stdout
#   (c) channel input + <no-reply-needed/>  -> exit 0, no output
#   (d) TUI-source input (no channel tag)   -> exit 0, no output
#   (e) BRIDGE_AGENT_ID empty               -> exit 0, no output
#   (f) stop_hook_active=true re-entry      -> exit 0, no output

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/surface-reply-enforce.py"

log() { printf '[surface-reply-enforce] %s\n' "$*"; }
die() { printf '[surface-reply-enforce][error] %s\n' "$*" >&2; exit 1; }
pass() { printf '[surface-reply-enforce][pass] %s\n' "$*"; }

[[ -f "$HOOK" ]] || die "hook missing: $HOOK"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

write_transcript_with_reply() {
  # User turn (Discord-source) followed by assistant tool_use of
  # mcp__plugin_discord__reply with matching chat_id.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sending"},{"type":"tool_use","name":"mcp__plugin_discord__reply","input":{"chat_id":"C123","content":"hi back"}}]}}
JSONL
}

write_transcript_missing_reply() {
  # User turn (Discord-source) followed by an assistant turn that ONLY
  # writes prose — no reply tool, no marker. This is the bug.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Here are three options: A/B/C."}]}}
JSONL
}

write_transcript_no_reply_marker() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"bot noise; no reply needed.\n<no-reply-needed source=\"discord\" chat_id=\"C123\" reason=\"bot ack\" />"}]}}
JSONL
}

write_transcript_tui_only() {
  # No <channel ...> tag on the latest user turn.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"please show me the queue"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sure"}]}}
JSONL
}

write_transcript_old_reply_new_unanswered() {
  # codex r1 fix: an OLD reply to chat_id=C123 must NOT satisfy a NEW
  # unanswered user turn from the SAME chat_id. The reply scanner used
  # to walk forward from the start of the transcript and matched the
  # first reply for that chat_id, leaking past a newer unanswered
  # message in the same chat.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"discord\" chat_id=\"C123\" message_id=\"M111\" />\nfirst question"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"answering"},{"type":"tool_use","name":"mcp__plugin_discord__reply","input":{"chat_id":"C123","content":"old reply"}}]}}
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"discord\" chat_id=\"C123\" message_id=\"M222\" />\nsecond question — needs a fresh reply"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"thinking out loud, no reply tool"}]}}
JSONL
}

run_hook() {
  # $1: transcript path
  # $2: BRIDGE_AGENT_ID value (use empty string to unset)
  # $3: extra event JSON keys (e.g. ',"stop_hook_active":true'); may be empty
  local transcript="$1" agent_id="$2" extra="${3:-}"
  local event="{\"transcript_path\":\"$transcript\"$extra}"
  if [[ -z "$agent_id" ]]; then
    BRIDGE_AGENT_ID="" python3 "$HOOK" <<<"$event"
  else
    BRIDGE_AGENT_ID="$agent_id" python3 "$HOOK" <<<"$event"
  fi
}

# ---- Case (a) channel input + matching mcp reply -> silent --------------
T="$TMP/a.jsonl"
write_transcript_with_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (a) expected no output, got: $out"
pass "(a) channel input + matching reply -> silent"

# ---- Case (b) channel input + missing reply -> block --------------------
T="$TMP/b.jsonl"
write_transcript_missing_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -n "$out" ]] || die "case (b) expected block JSON, got empty"
echo "$out" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
decision = data.get("decision")
assert decision == "block", "decision=" + repr(decision)
reason = data.get("reason", "")
assert "discord" in reason.lower(), "reason missing surface: " + reason
assert "C123" in reason, "reason missing chat_id: " + reason
assert "mcp__plugin_discord__reply" in reason, "reason missing tool: " + reason
' || die "case (b) JSON shape mismatch"
pass "(b) channel input + missing reply -> block"

# ---- Case (c) channel input + <no-reply-needed/> -> silent --------------
T="$TMP/c.jsonl"
write_transcript_no_reply_marker "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (c) expected no output, got: $out"
pass "(c) channel input + no-reply marker -> silent"

# ---- Case (d) TUI-source input (no channel tag) -> silent ---------------
T="$TMP/d.jsonl"
write_transcript_tui_only "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (d) expected no output, got: $out"
pass "(d) TUI-source input -> silent"

# ---- Case (e) BRIDGE_AGENT_ID empty -> silent (even on a missing-reply transcript) ----
T="$TMP/e.jsonl"
write_transcript_missing_reply "$T"
out="$(run_hook "$T" "")"
[[ -z "$out" ]] || die "case (e) expected no output (BRIDGE_AGENT_ID empty), got: $out"
pass "(e) BRIDGE_AGENT_ID empty -> silent"

# ---- Case (f) stop_hook_active=true re-entry -> silent ------------------
T="$TMP/f.jsonl"
write_transcript_missing_reply "$T"
out="$(run_hook "$T" "agent-foo" ',"stop_hook_active":true')"
[[ -z "$out" ]] || die "case (f) expected no output (stop_hook_active=true), got: $out"
pass "(f) stop_hook_active re-entry -> silent"

# ---- Case (g) old reply for same chat_id must NOT satisfy newer unanswered ----
# codex r1 regression: reply scanner anchored at index of the LATEST
# channel-source user turn, not the first same-chat user turn from the
# start of the transcript.
T="$TMP/g.jsonl"
write_transcript_old_reply_new_unanswered "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -n "$out" ]] || die "case (g) expected block JSON for new unanswered turn, got empty (old reply leaked through)"
echo "$out" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
assert data.get("decision") == "block"
reason = data.get("reason", "")
assert "M222" in reason, "reason should reference NEW message_id, got: " + reason
' || die "case (g) JSON shape mismatch (old reply may be satisfying new unanswered)"
pass "(g) old reply for same chat_id does not satisfy newer unanswered turn"

log "all cases passed"
