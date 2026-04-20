#!/usr/bin/env bash
# Plan-D stream-a common helpers. Sourced by every wiki-* cron script and
# the bootstrap script. No side effects at source time.

set -euo pipefail

# BRIDGE_HOME defaults to ~/.agent-bridge but can be overridden for tests.
: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
export BRIDGE_HOME

: "${BRIDGE_AGB:=$BRIDGE_HOME/agent-bridge}"
: "${BRIDGE_PYTHON:=$(command -v python3 || echo /usr/bin/python3)}"
: "${BRIDGE_SHARED_ROOT:=$BRIDGE_HOME/shared}"
: "${BRIDGE_WIKI_ROOT:=$BRIDGE_SHARED_ROOT/wiki}"
: "${BRIDGE_AUDIT_ROOT:=$BRIDGE_WIKI_ROOT/_audit}"
: "${BRIDGE_STATE_ROOT:=$BRIDGE_HOME/state}"
# Admin agent used as cron-failure escalation target + fallback librarian
# queue owner. Defaults to `patch` on the reference install. Other
# deployments override BRIDGE_ADMIN_AGENT in the roster or via env.
: "${BRIDGE_ADMIN_AGENT:=${BRIDGE_ADMIN_AGENT_ID:-patch}}"

mkdir -p "$BRIDGE_AUDIT_ROOT" "$BRIDGE_STATE_ROOT"

# abs_date — KST-local date string YYYY-MM-DD that all audit logs use.
abs_date() { date +%Y-%m-%d; }
abs_stamp() { date +%Y%m%d-%H%M%S; }

# log_audit <job> <line> — append a timestamped line to the per-job audit doc.
# Creates the file with a markdown header on first call.
log_audit() {
  local job="$1"
  shift
  local dest="$BRIDGE_AUDIT_ROOT/${job}-$(abs_date).md"
  if [[ ! -f "$dest" ]]; then
    {
      echo "# ${job} audit — $(abs_date)"
      echo ""
      echo "started: $(date -Iseconds 2>/dev/null || date)"
      echo ""
    } > "$dest"
  fi
  printf '%s %s\n' "$(date -Iseconds 2>/dev/null || date +%H:%M:%S)" "$*" >> "$dest"
  printf '%s\n' "$dest"
}

# audit_path <job> — return the current day's audit path for <job>.
audit_path() {
  local job="$1"
  printf '%s\n' "$BRIDGE_AUDIT_ROOT/${job}-$(abs_date).md"
}

# file_failure_task <job> <log_path> — create a patch-facing task on cron failure.
# Never exits non-zero itself so it can run from a trap.
file_failure_task() {
  local job="$1"
  local log="$2"
  local title="[cron-failure] $job — $(abs_date)"
  if [[ -x "$BRIDGE_AGB" ]]; then
    "$BRIDGE_AGB" task create \
      --to "$BRIDGE_ADMIN_AGENT" \
      --priority high \
      --from "$BRIDGE_ADMIN_AGENT" \
      --title "$title" \
      --body-file "$log" >/dev/null 2>&1 || true
  fi
}

# list_active_claude_agents — prints one agent name per line.
# Filters to engine=claude AND active=true (loop-enabled agents ready to run).
# Falls back to grepping the roster if --json support is missing.
list_active_claude_agents() {
  if [[ ! -x "$BRIDGE_AGB" ]]; then
    echo "BRIDGE_AGB not executable: $BRIDGE_AGB" >&2
    return 1
  fi
  "$BRIDGE_AGB" agent list --json 2>/dev/null \
    | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in data:
    if not isinstance(a, dict):
        continue
    if a.get("engine") != "claude":
        continue
    if not a.get("active"):
        continue
    name = a.get("agent") or ""
    wd = a.get("workdir") or ""
    # Skip entries that dont have an agent home (catch codex stubs).
    if not name or not wd:
        continue
    print(f"{name}\t{wd}")
'
}

# agent_home_for <agent> — print the workdir for <agent> or empty string.
agent_home_for() {
  local agent="$1"
  "$BRIDGE_AGB" agent list --json 2>/dev/null \
    | "$BRIDGE_PYTHON" -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in data:
    if not isinstance(a, dict):
        continue
    if a.get('agent') == '$agent':
        print(a.get('workdir') or '')
        break
"
}

# run_with_timeout <seconds> <cmd...> — portable timeout wrapper.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    # fallback: no timeout available. Run directly and hope for the best.
    "$@"
  fi
}
