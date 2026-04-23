#!/usr/bin/env bash
# memory-daily harvester stub — thin CLI adapter between cron runner and
# bridge-memory.py. Keep this script policy-free; Python owns all decisions.
# Under linux-user isolation the stub probes passwordless sudo and either
# re-execs Python as the target OS user or signals --skipped-permission.
set -euo pipefail

AGENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$AGENT" ]] || { echo "error: --agent required" >&2; exit 2; }

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
BRIDGE_AGB="${BRIDGE_AGB:-$BRIDGE_HOME/agb}"
BRIDGE_PYTHON="${BRIDGE_PYTHON:-python3}"

json="$("$BRIDGE_AGB" agent show "$AGENT" --json 2>/dev/null)" \
  || { echo "error: agent show failed for $AGENT" >&2; exit 2; }
[[ -n "$json" ]] || { echo "error: empty agent show output for $AGENT" >&2; exit 2; }

# Parse JSON twice to stay whitespace-safe (paths may contain spaces).
workdir="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("workdir", ""))')"
home="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("profile", {}).get("home", ""))')"
isolation_mode="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("isolation", {}).get("mode", ""))')"
os_user="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("isolation", {}).get("os_user", ""))')"

[[ -n "$workdir" && -n "$home" ]] \
  || { echo "error: missing workdir/home for $AGENT" >&2; exit 2; }

# Sidecar path: runner-exported CRON_REQUEST_DIR (cron path). Fallback is an
# agent-scoped state dir for manual/ad-hoc invocation outside the runner.
if [[ -n "${CRON_REQUEST_DIR:-}" ]]; then
  sidecar_out="$CRON_REQUEST_DIR/authoritative-memory-daily.json"
else
  sidecar_out="$BRIDGE_HOME/state/memory-daily/$AGENT/adhoc.authoritative.json"
  mkdir -p "$(dirname "$sidecar_out")"
fi

current_user="$(id -un 2>/dev/null || echo '')"
current_uid="$(id -u 2>/dev/null || echo '')"

# linux-user isolation: if the target os_user differs from the invoker, emit
# skipped-permission. We deliberately do NOT sudo re-exec python as the target
# user: `bridge_linux_prepare_agent_isolation` strips ACLs on the global
# BRIDGE_STATE_DIR / BRIDGE_CRON_STATE_DIR trees and only grants per-agent
# runtime/log/request/response dirs, so the isolated UID cannot persist the
# manifest (`state/memory-daily/...`) or the sidecar (under
# `state/cron/runs/.../authoritative-memory-daily.json`). Until the isolation
# ACL contract is extended to cover those paths (tracked as a separate issue),
# the right behaviour per v0.5 §10.1 is to record a structured skip so the
# admin aggregate surfaces the gap.
if [[ "$isolation_mode" == "linux-user" \
      && -n "$os_user" \
      && -n "$current_user" \
      && "$os_user" != "$current_user" \
      && "$current_uid" != "0" ]]; then
  exec "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
    --agent "$AGENT" \
    --home "$home" \
    --workdir "$workdir" \
    --os-user "$os_user" \
    --skipped-permission \
    --sidecar-out "$sidecar_out" \
    --json
fi

exec "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
  --agent "$AGENT" \
  --home "$home" \
  --workdir "$workdir" \
  --sidecar-out "$sidecar_out" \
  --json
