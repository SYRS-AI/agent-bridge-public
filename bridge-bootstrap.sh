#!/usr/bin/env bash
# bridge-bootstrap.sh — AI-native bootstrap wrapper for fresh installs

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [bootstrap options...] [init options...]

Bootstrap options:
  --shell <name>          Shell to integrate (default: current shell basename, fallback zsh)
  --rcfile <path>         Override shell rc file target
  --skip-shell-integration
  --skip-daemon
  --skip-launchagent      Do not install/load the macOS LaunchAgent
  --dry-run
  --json

Everything else is forwarded to \`agent-bridge init\`.

Examples:
  $(basename "$0") --admin manager --engine claude --channels plugin:telegram --allow-from 123456789 --default-chat 123456789
  $(basename "$0") --admin manager --engine claude --dry-run --json
EOF
}

bootstrap_shell="${SHELL##*/}"
bootstrap_shell="${bootstrap_shell:-zsh}"
bootstrap_rcfile=""
skip_shell_integration=0
skip_daemon=0
skip_launchagent=0
dry_run=0
json_mode=0
init_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      bootstrap_shell="$2"
      shift 2
      ;;
    --rcfile)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      bootstrap_rcfile="$2"
      shift 2
      ;;
    --skip-shell-integration)
      skip_shell_integration=1
      shift
      ;;
    --skip-daemon)
      skip_daemon=1
      shift
      ;;
    --skip-launchagent)
      skip_launchagent=1
      shift
      ;;
    --dry-run)
      dry_run=1
      init_args+=("$1")
      shift
      ;;
    --json)
      json_mode=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      init_args+=("$1")
      shift
      ;;
  esac
done

case "$bootstrap_shell" in
  zsh|bash) ;;
  *)
    bridge_die "지원하지 않는 shell 입니다: $bootstrap_shell"
    ;;
esac

bridge_require_python

shell_status="skipped"
daemon_status="skipped"
launchagent_status="skipped"
next_command="agb admin"

if [[ $skip_shell_integration -eq 0 ]]; then
  shell_status="planned"
  if [[ $dry_run -eq 0 ]]; then
    shell_args=(--shell "$bootstrap_shell" --apply)
    [[ -n "$bootstrap_rcfile" ]] && shell_args+=(--rcfile "$bootstrap_rcfile")
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-shell-integration.sh" "${shell_args[@]}" >/dev/null
    shell_status="applied"
  fi
fi

init_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-init.sh" "${init_args[@]}" --json)"

if [[ $skip_daemon -eq 0 ]]; then
  daemon_status="planned"
  if [[ $dry_run -eq 0 ]]; then
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" ensure >/dev/null
    daemon_status="ensured"
  fi
fi

if [[ $skip_launchagent -eq 0 ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    launchagent_status="planned"
    if [[ $dry_run -eq 0 ]]; then
      "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-daemon-launchagent.sh" --apply --load >/dev/null
      launchagent_status="loaded"
    fi
  else
    launchagent_status="unsupported"
  fi
fi

if [[ $json_mode -eq 1 ]]; then
  python3 - "$init_json" "$shell_status" "$bootstrap_shell" "$bootstrap_rcfile" "$daemon_status" "$launchagent_status" "$next_command" <<'PY'
import json
import sys

init_payload = json.loads(sys.argv[1])
payload = {
    "mode": "bootstrap",
    "shell_integration": {
        "status": sys.argv[2],
        "shell": sys.argv[3],
        "rcfile": sys.argv[4],
    },
    "init": init_payload,
    "daemon": {"status": sys.argv[5]},
    "launchagent": {"status": sys.argv[6]},
    "next_command": sys.argv[7],
    "handoff_steps": [
        "Close the temporary installer session.",
        "Open a fresh shell if needed so the shell integration is loaded.",
        f"Run `{sys.argv[7]}`.",
        "Let the admin agent guide the rest of the onboarding.",
    ],
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  exit 0
fi

admin_agent="$(python3 - "$init_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1]).get("admin", ""))
PY
)"

echo "== Agent Bridge bootstrap =="
printf 'admin_agent: %s\n' "$admin_agent"
printf 'shell_integration: %s\n' "$shell_status"
printf 'daemon: %s\n' "$daemon_status"
printf 'launchagent: %s\n' "$launchagent_status"
echo
echo "handoff:"
echo "1. Close the temporary installer session."
echo "2. Open a fresh shell if this terminal has not reloaded your shell rc yet."
echo "3. Run: $next_command"
echo "4. Let the admin agent guide the rest of the onboarding."
