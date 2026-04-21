#!/usr/bin/env bash
# shellcheck shell=bash
# Centralized list of tmux session-name globs that represent smoke-test
# or ad hoc harness sessions. Consumed by:
#   - scripts/smoke-test.sh::kill_stale_smoke_tmux_sessions
#   - lib/bridge-state.sh::bridge_reconcile_dynamic_agents_from_tmux
# Keep the pattern list here so the two consumers cannot drift.

bridge_session_is_smoke_or_adhoc() {
  local session="$1"
  case "$session" in
    bridge-smoke-*|bridge-requester-*|auto-start-session-*|\
    always-on-session-*|static-session-*|claude-static-bridge-smoke-*|\
    worker-reuse-*|late-dynamic-agent-*|created-session-*|\
    bootstrap-session-*|bootstrap-wrapper-session-*|broken-channel-*|\
    context-pressure-bridge-smoke-*|codex-cli-session-*|\
    project-claude-session-bridge-smoke-*|stall-auth-*|stall-rate-*|\
    stall-unknown-*|roster-reload-session-*|smoke-admin-test*|\
    stall-rate-test-*|memtest*|bootstrap-fail*|memphase4-*)
      return 0
      ;;
  esac
  return 1
}
