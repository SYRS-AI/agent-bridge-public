#!/usr/bin/env bash
# install-daemon-liveness-launchagent.sh — issue #265 proposal D
#
# Installs a separate macOS LaunchAgent that runs
# scripts/bridge-daemon-liveness.sh every BRIDGE_DAEMON_LIVENESS_INTERVAL
# seconds (default 60s). The watcher itself decides whether to restart the
# daemon based on the heartbeat-file mtime — see scripts/bridge-daemon-liveness.sh.
#
# This is intentionally a sibling LaunchAgent of ai.agent-bridge.daemon, not
# a property added to the daemon plist itself, because the daemon plist's
# KeepAlive only restarts on process exit. The hang vector documented in
# issue #265 leaves the process alive but the loop frozen, which KeepAlive
# does not detect.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
BRIDGE_HOME_DEFAULT="${HOME}/.agent-bridge"
BRIDGE_HOME_TARGET="$BRIDGE_HOME_DEFAULT"
LABEL_DEFAULT="ai.agent-bridge.daemon-liveness"
LABEL="$LABEL_DEFAULT"
PLIST_PATH=""
LOG_PATH=""
APPLY=0
LOAD=0
BASH_PATH=""
INTERVAL="${BRIDGE_DAEMON_LIVENESS_INTERVAL:-60}"
THRESHOLD="${BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS:-600}"
COOLDOWN="${BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS:-600}"

usage() {
  cat <<EOF
Usage: $0 [--bridge-home <dir>] [--label <launchd-label>] [--plist <path>] [--log-path <path>] [--interval <secs>] [--threshold <secs>] [--cooldown <secs>] [--apply] [--load]

Without --apply, prints the LaunchAgent plist for the daemon liveness watcher.
With --apply, writes the plist to ~/Library/LaunchAgents (or --plist target).
With --load, also bootstraps and kickstarts the LaunchAgent after writing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-home)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      BRIDGE_HOME_TARGET="$2"
      shift 2
      ;;
    --label)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      LABEL="$2"
      shift 2
      ;;
    --plist)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      PLIST_PATH="$2"
      shift 2
      ;;
    --log-path)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      LOG_PATH="$2"
      shift 2
      ;;
    --interval)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      INTERVAL="$2"
      shift 2
      ;;
    --threshold)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      THRESHOLD="$2"
      shift 2
      ;;
    --cooldown)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      COOLDOWN="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --load)
      APPLY=1
      LOAD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ "$INTERVAL" =~ ^[0-9]+$ ]]  || { echo "[error] --interval must be an integer (got: $INTERVAL)" >&2; exit 1; }
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || { echo "[error] --threshold must be an integer (got: $THRESHOLD)" >&2; exit 1; }
[[ "$COOLDOWN" =~ ^[0-9]+$ ]]  || { echo "[error] --cooldown must be an integer (got: $COOLDOWN)" >&2; exit 1; }

[[ -n "$PLIST_PATH" ]] || PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
[[ -n "$LOG_PATH" ]] || LOG_PATH="$BRIDGE_HOME_TARGET/state/launchagent-liveness.log"

for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  BASH_PATH="$candidate"
  break
done

if [[ -z "$BASH_PATH" ]]; then
  echo "[error] bash not found" >&2
  exit 1
fi

# We deliberately point at $BRIDGE_HOME_TARGET/scripts/bridge-daemon-liveness.sh
# (the deployed live-install copy), not at the source checkout. That way the
# watcher tracks whatever the upgrader laid down, same convention the daemon
# plist uses.
PLIST_CONTENT="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${BASH_PATH}</string>
    <string>${BRIDGE_HOME_TARGET}/scripts/bridge-daemon-liveness.sh</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${BRIDGE_HOME_TARGET}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>BRIDGE_HOME</key>
    <string>${BRIDGE_HOME_TARGET}</string>
    <key>BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS</key>
    <string>${THRESHOLD}</string>
    <key>BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS</key>
    <string>${COOLDOWN}</string>
  </dict>

  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>

  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
EOF
)"

if [[ $APPLY -eq 0 ]]; then
  printf 'plist_path: %s\n' "$PLIST_PATH"
  printf 'bridge_home: %s\n' "$BRIDGE_HOME_TARGET"
  printf 'log_path: %s\n' "$LOG_PATH"
  printf 'interval_seconds: %s\n' "$INTERVAL"
  printf 'threshold_seconds: %s\n' "$THRESHOLD"
  printf 'cooldown_seconds: %s\n\n' "$COOLDOWN"
  printf '%s\n' "$PLIST_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$PLIST_PATH")" "$(dirname "$LOG_PATH")"
printf '%s\n' "$PLIST_CONTENT" >"$PLIST_PATH"
echo "[info] wrote LaunchAgent plist: $PLIST_PATH"

if [[ $LOAD -eq 1 ]]; then
  launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$PLIST_PATH"
  launchctl enable "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  launchctl kickstart "gui/$UID/$LABEL"
  echo "[info] loaded LaunchAgent: $LABEL"
  echo "[info] inspect with: launchctl print gui/$UID/$LABEL"
fi

echo "[info] bridge_home: $BRIDGE_HOME_TARGET"
echo "[info] log_path: $LOG_PATH"
echo "[info] plist_path: $PLIST_PATH"
echo "[info] interval_seconds: $INTERVAL"
echo "[info] threshold_seconds: $THRESHOLD"
echo "[info] cooldown_seconds: $COOLDOWN"
