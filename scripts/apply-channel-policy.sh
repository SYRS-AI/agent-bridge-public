#!/usr/bin/env bash
# apply-channel-policy.sh — enforce the agent-bridge singleton channel policy.
#
# Closes upstream #244. Claude Code auto-spawns every user-level enabledPlugins
# entry for every agent session. For "singleton channel" plugins (Telegram,
# Discord) only one process per bot token can poll `getUpdates` or hold the
# gateway websocket — so when multiple agents run concurrently, every restart
# of any agent kicks the previous holder off its lease with a 409 Conflict
# and the last one to restart becomes the sole holder. Under normal multi-
# agent operation this silently leaves the admin / router agent without a
# Telegram channel, and operator DMs go nowhere.
#
# Fix has two parts:
#
# 1. Write the shared overlay (`agents/.claude/settings.local.json`) so every
#    agent whose `.claude/settings.json` resolves to the shared effective
#    settings gets `enabledPlugins[telegram@…]=false` and
#    `enabledPlugins[discord@…]=false`.
# 2. When an admin agent is configured, write a per-agent local overlay at
#    `agents/<admin>/.claude/settings.local.json` that re-enables the same
#    singleton plugins. Claude Code's settings merge order prefers a project
#    `.claude/settings.local.json` over the project `.claude/settings.json`,
#    so the admin keeps the singleton plugins even when its
#    `.claude/settings.json` is the shared-effective symlink. Without this
#    bypass, #242's shared-symlink bootstrap means the admin loses exactly
#    the channels it is supposed to hold — see the PR #246 review.
#
# This script is idempotent. It is safe to re-run on every upgrade.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/_common.sh
source "$SCRIPT_DIR/_common.sh"

: "${BRIDGE_AGENT_HOME_ROOT:=$BRIDGE_HOME/agents}"
: "${BRIDGE_AGENTS_CLAUDE_DIR:=$BRIDGE_AGENT_HOME_ROOT/.claude}"

BASE_SETTINGS="$BRIDGE_AGENTS_CLAUDE_DIR/settings.json"
OVERLAY_SETTINGS="$BRIDGE_AGENTS_CLAUDE_DIR/settings.local.json"
EFFECTIVE_SETTINGS="$BRIDGE_AGENTS_CLAUDE_DIR/settings.effective.json"

# Plugins that enforce one-connection-per-bot-token upstream. Adding a plugin
# here is a declaration that "multiple concurrent instances are broken by the
# service the plugin talks to, not by the plugin itself." Plugins that talk to
# stateless HTTP APIs (teams, ms365) do NOT belong here.
SINGLETON_PLUGINS=(
  "telegram@claude-plugins-official"
  "discord@claude-plugins-official"
)

DRY_RUN=0
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --quiet)   QUIET=1 ;;
    --help|-h)
      cat <<'USAGE'
Usage: apply-channel-policy.sh [--dry-run] [--quiet]

Idempotently enforce the singleton channel plugin policy by writing the
shared overlay at $BRIDGE_HOME/agents/.claude/settings.local.json and
re-rendering the effective settings.

With --dry-run, prints the planned action but does not modify any file.
USAGE
      exit 0 ;;
    *) echo "apply-channel-policy.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$BRIDGE_AGENTS_CLAUDE_DIR"

python_plan="$(BRIDGE_PYTHON_HOME="$BRIDGE_HOME" "$BRIDGE_PYTHON" - "$OVERLAY_SETTINGS" "${SINGLETON_PLUGINS[@]}" <<'PY'
import json
import sys
from pathlib import Path

overlay_path = Path(sys.argv[1])
singleton_plugins = sys.argv[2:]

if overlay_path.exists():
    try:
        payload = json.loads(overlay_path.read_text() or "{}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"overlay is not valid JSON: {overlay_path}: {exc}")
else:
    payload = {}

if not isinstance(payload, dict):
    raise SystemExit(f"overlay root must be a JSON object: {overlay_path}")

enabled = payload.get("enabledPlugins")
if not isinstance(enabled, dict):
    enabled = {}

changed = False
for plugin_id in singleton_plugins:
    if enabled.get(plugin_id) is not False:
        enabled[plugin_id] = False
        changed = True

if changed:
    payload["enabledPlugins"] = enabled
    plan = {"changed": True, "payload": payload}
else:
    plan = {"changed": False, "payload": payload}

print(json.dumps(plan))
PY
)"

changed="$(printf '%s' "$python_plan" | "$BRIDGE_PYTHON" -c 'import json,sys;print(json.loads(sys.stdin.read())["changed"])')"

if [[ "$changed" == "True" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] would write $OVERLAY_SETTINGS (disable: ${SINGLETON_PLUGINS[*]})"
  else
    printf '%s' "$python_plan" | "$BRIDGE_PYTHON" -c '
import json,sys,pathlib
plan=json.loads(sys.stdin.read())
p=pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(plan["payload"], indent=2, sort_keys=True) + "\n")
' "$OVERLAY_SETTINGS"
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] wrote $OVERLAY_SETTINGS"
  fi
else
  [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] overlay already enforces singleton policy (no change)"
fi

# Re-render the shared effective settings so every non-admin agent's
# `.claude/settings.json` symlink immediately picks up the new overlay. The
# admin agent owns its own non-shared settings.json and is not affected.
if [[ $DRY_RUN -eq 0 ]]; then
  # Prefer the live-runtime copy; fall back to the source-root copy so this
  # script works in smoke tests where BRIDGE_HOME is a scratch dir.
  bridge_hooks_py=""
  if [[ -f "$BRIDGE_HOME/bridge-hooks.py" ]]; then
    bridge_hooks_py="$BRIDGE_HOME/bridge-hooks.py"
  elif [[ -f "$SCRIPT_DIR/../bridge-hooks.py" ]]; then
    bridge_hooks_py="$(cd -P "$SCRIPT_DIR/.." && pwd -P)/bridge-hooks.py"
  fi
  if [[ -n "$bridge_hooks_py" ]]; then
    "$BRIDGE_PYTHON" "$bridge_hooks_py" render-shared-settings \
      --base-settings-file "$BASE_SETTINGS" \
      --overlay-settings-file "$OVERLAY_SETTINGS" \
      --effective-settings-file "$EFFECTIVE_SETTINGS" >/dev/null
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] re-rendered $EFFECTIVE_SETTINGS"
  else
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] warning: bridge-hooks.py not found under BRIDGE_HOME or repo; overlay written but effective not re-rendered" >&2
  fi
fi

# Admin bypass: re-enable singleton plugins in the admin's per-agent local
# overlay. We resolve admin id only from an explicit signal (env or roster
# grep) — we never fall back to a default, because this bypass must be a
# no-op on installs that have not configured an admin yet (e.g. smoke
# fixtures, pre-bootstrap hosts).
admin_agent_id=""
if [[ -n "${BRIDGE_ADMIN_AGENT_ID:-}" ]]; then
  admin_agent_id="$BRIDGE_ADMIN_AGENT_ID"
else
  for _admin_roster in "$BRIDGE_HOME/agent-roster.local.sh" "$BRIDGE_HOME/agent-roster.sh"; do
    if [[ -r "$_admin_roster" ]]; then
      _admin_line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=' "$_admin_roster" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=//; s/^"([^"]*)".*/\1/; s/^'"'"'([^'"'"']*)'"'"'.*/\1/; s/[[:space:]]*#.*$//')"
      if [[ -n "$_admin_line" ]]; then
        admin_agent_id="$_admin_line"
        break
      fi
    fi
  done
fi

if [[ -n "$admin_agent_id" ]]; then
  ADMIN_HOME="$BRIDGE_AGENT_HOME_ROOT/$admin_agent_id"
  ADMIN_LOCAL_SETTINGS="$ADMIN_HOME/.claude/settings.local.json"

  # Only write the bypass if the admin home already exists. During upgrade the
  # admin is already bootstrapped; in smoke fixtures or pre-bootstrap hosts the
  # directory is absent and we must stay a no-op rather than materialise an
  # empty agent dir from an env var that might be a stale default.
  if [[ ! -d "$ADMIN_HOME" ]]; then
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] skip admin re-enable: '$admin_agent_id' home not present under $BRIDGE_AGENT_HOME_ROOT"
  else
    admin_plan="$("$BRIDGE_PYTHON" - "$ADMIN_LOCAL_SETTINGS" "${SINGLETON_PLUGINS[@]}" <<'PY'
import json
import sys
from pathlib import Path

overlay_path = Path(sys.argv[1])
singleton_plugins = sys.argv[2:]

if overlay_path.exists():
    try:
        payload = json.loads(overlay_path.read_text() or "{}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"admin overlay is not valid JSON: {overlay_path}: {exc}")
else:
    payload = {}

if not isinstance(payload, dict):
    raise SystemExit(f"admin overlay root must be a JSON object: {overlay_path}")

enabled = payload.get("enabledPlugins")
if not isinstance(enabled, dict):
    enabled = {}

changed = False
for plugin_id in singleton_plugins:
    if enabled.get(plugin_id) is not True:
        enabled[plugin_id] = True
        changed = True

payload["enabledPlugins"] = enabled
print(json.dumps({"changed": changed, "payload": payload}))
PY
)"

    admin_changed="$(printf '%s' "$admin_plan" | "$BRIDGE_PYTHON" -c 'import json,sys;print(json.loads(sys.stdin.read())["changed"])')"

    if [[ "$admin_changed" == "True" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] would write $ADMIN_LOCAL_SETTINGS (re-enable for admin '$admin_agent_id': ${SINGLETON_PLUGINS[*]})"
      else
        printf '%s' "$admin_plan" | "$BRIDGE_PYTHON" -c '
import json,sys,pathlib
plan=json.loads(sys.stdin.read())
p=pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(plan["payload"], indent=2, sort_keys=True) + "\n")
' "$ADMIN_LOCAL_SETTINGS"
        [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] wrote $ADMIN_LOCAL_SETTINGS (admin re-enable)"
      fi
    else
      [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] admin overlay for '$admin_agent_id' already re-enables singleton policy (no change)"
    fi
  fi
fi
