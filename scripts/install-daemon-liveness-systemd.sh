#!/usr/bin/env bash
# install-daemon-liveness-systemd.sh — issue #265 proposal D
#
# Installs a systemd --user .service + .timer pair that runs
# scripts/bridge-daemon-liveness.sh every BRIDGE_DAEMON_LIVENESS_INTERVAL
# seconds (default 60s). Same role as the macOS LaunchAgent variant — see
# scripts/install-daemon-liveness-launchagent.sh and
# scripts/bridge-daemon-liveness.sh for the design rationale.
#
# We pair the .service with a .timer rather than using a Path-unit on the
# heartbeat file, because the silent-hang case is `mtime stops advancing`,
# not `mtime changes`. A timer-driven poll is the natural fit.

set -euo pipefail

BRIDGE_HOME_TARGET="${HOME}/.agent-bridge"
SERVICE_NAME="agent-bridge-daemon-liveness.service"
TIMER_NAME="agent-bridge-daemon-liveness.timer"
SERVICE_PATH=""
TIMER_PATH=""
LOG_PATH=""
APPLY=0
ENABLE=0
BASH_PATH=""
INTERVAL="${BRIDGE_DAEMON_LIVENESS_INTERVAL:-60}"
THRESHOLD="${BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS:-600}"
COOLDOWN="${BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS:-600}"

usage() {
  cat <<EOF
Usage: $0 [--bridge-home <dir>] [--service <name>] [--timer <name>] [--service-path <path>] [--timer-path <path>] [--log-path <path>] [--interval <secs>] [--threshold <secs>] [--cooldown <secs>] [--apply] [--enable]

Without --apply, prints the systemd user .service and .timer unit files.
With --apply, writes both units to ~/.config/systemd/user (or --service-path / --timer-path targets).
With --enable, also runs systemctl --user daemon-reload and enable --now on the timer.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-home)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      BRIDGE_HOME_TARGET="$2"
      shift 2
      ;;
    --service)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      SERVICE_NAME="$2"
      shift 2
      ;;
    --timer)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      TIMER_NAME="$2"
      shift 2
      ;;
    --service-path)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      SERVICE_PATH="$2"
      shift 2
      ;;
    --timer-path)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      TIMER_PATH="$2"
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
    --enable)
      APPLY=1
      ENABLE=1
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

[[ -n "$SERVICE_PATH" ]] || SERVICE_PATH="$HOME/.config/systemd/user/$SERVICE_NAME"
[[ -n "$TIMER_PATH" ]] || TIMER_PATH="$HOME/.config/systemd/user/$TIMER_NAME"
[[ -n "$LOG_PATH" ]] || LOG_PATH="$BRIDGE_HOME_TARGET/state/systemd-daemon-liveness.log"

for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)" /bin/bash; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  BASH_PATH="$candidate"
  break
done

if [[ -z "$BASH_PATH" ]]; then
  echo "[error] bash not found" >&2
  exit 1
fi

SERVICE_CONTENT="$(cat <<EOF
[Unit]
Description=Agent Bridge Daemon Liveness Watcher
After=agent-bridge-daemon.service

[Service]
Type=oneshot
ExecStart=${BASH_PATH} ${BRIDGE_HOME_TARGET}/scripts/bridge-daemon-liveness.sh
WorkingDirectory=${BRIDGE_HOME_TARGET}
Environment=BRIDGE_HOME=${BRIDGE_HOME_TARGET}
Environment=BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS=${THRESHOLD}
Environment=BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS=${COOLDOWN}
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}
EOF
)"

TIMER_CONTENT="$(cat <<EOF
[Unit]
Description=Agent Bridge Daemon Liveness Watcher (timer)

[Timer]
OnBootSec=${INTERVAL}
OnUnitInactiveSec=${INTERVAL}
Unit=${SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF
)"

if [[ $APPLY -eq 0 ]]; then
  printf 'service_path: %s\n' "$SERVICE_PATH"
  printf 'timer_path: %s\n' "$TIMER_PATH"
  printf 'bridge_home: %s\n' "$BRIDGE_HOME_TARGET"
  printf 'log_path: %s\n' "$LOG_PATH"
  printf 'service: %s\n' "$SERVICE_NAME"
  printf 'timer: %s\n' "$TIMER_NAME"
  printf 'interval_seconds: %s\n' "$INTERVAL"
  printf 'threshold_seconds: %s\n' "$THRESHOLD"
  printf 'cooldown_seconds: %s\n\n' "$COOLDOWN"
  printf '# %s\n' "$SERVICE_NAME"
  printf '%s\n\n' "$SERVICE_CONTENT"
  printf '# %s\n' "$TIMER_NAME"
  printf '%s\n' "$TIMER_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$SERVICE_PATH")" "$(dirname "$TIMER_PATH")" "$(dirname "$LOG_PATH")"
printf '%s\n' "$SERVICE_CONTENT" >"$SERVICE_PATH"
printf '%s\n' "$TIMER_CONTENT" >"$TIMER_PATH"
echo "[info] wrote systemd user service: $SERVICE_PATH"
echo "[info] wrote systemd user timer:   $TIMER_PATH"

if [[ $ENABLE -eq 1 ]]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[error] systemctl not found; wrote units but cannot enable" >&2
    exit 1
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now "$TIMER_NAME"
  echo "[info] enabled systemd user timer: $TIMER_NAME"
  echo "[info] inspect with: systemctl --user status $TIMER_NAME"
fi

echo "[info] bridge_home: $BRIDGE_HOME_TARGET"
echo "[info] log_path: $LOG_PATH"
echo "[info] service_path: $SERVICE_PATH"
echo "[info] timer_path: $TIMER_PATH"
echo "[info] interval_seconds: $INTERVAL"
echo "[info] threshold_seconds: $THRESHOLD"
echo "[info] cooldown_seconds: $COOLDOWN"
