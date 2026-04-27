#!/usr/bin/env bash
# Hermetic mock of `agent-bridge` for the wiki-daily-ingest smoke.
# Returns valid empty JSON for `agent list --json` (so PR-D's strict Lane B
# parser sees zero active agents but parses cleanly), exits non-zero for
# `agent show librarian` (so the librarian-watchdog branch short-circuits),
# and no-ops for `task create` if ever reached. Any other subcommand exits
# non-zero so unexpected calls surface in test failures.

set -euo pipefail

case "${1:-}" in
  agent)
    case "${2:-}" in
      list)
        if [[ "${3:-}" == "--json" ]]; then
          printf '[]'
          exit 0
        fi
        exit 1
        ;;
      show)
        # No librarian fixture in this smoke — let the watchdog probe fail.
        exit 1
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  task)
    if [[ "${2:-}" == "create" ]]; then
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
