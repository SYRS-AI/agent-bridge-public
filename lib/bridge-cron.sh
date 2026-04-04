#!/usr/bin/env bash
# shellcheck shell=bash

bridge_require_openclaw_cron_jobs() {
  if [[ -f "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" ]]; then
    return 0
  fi

  bridge_die "OpenClaw cron jobs 파일이 없습니다: $BRIDGE_OPENCLAW_CRON_JOBS_FILE"
}

bridge_cron_python() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-cron.py" "$@"
}
