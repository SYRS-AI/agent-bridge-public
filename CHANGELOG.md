# Changelog

All notable changes to Agent Bridge are documented here. This project adheres
loosely to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and tracks
version bumps via the `VERSION` file.

## [0.6.8] — 2026-04-23

### Added
- linux-user isolation ACL contract expansion for memory-daily
  (issue #219):
  - `bridge_linux_prepare_agent_isolation` grants the isolated `os_user`
    `r-x` on `state/memory-daily/` (traverse only), `rwX` on
    `state/memory-daily/<agent>/` (per-agent manifest tree), and `rwX`
    on `state/memory-daily/shared/aggregate/` (shared aggregate files).
  - Legacy root-level `admin-aggregate-*.json` files migrate into
    `shared/aggregate/` during isolation prep (sudo-root `mv`) and
    during `bootstrap-memory-system.sh --apply` (controller `mv`).
  - `bridge_cron_run_dir_grant_isolation` (`lib/bridge-cron.sh`) grants
    the target `os_user` rwX on the per-run cron dir just before queue
    task creation. The grant is **best-effort**: memory-daily runs as
    the controller UID under v1.3 and does not need the isolated UID to
    own the run dir, so failure is ignored by the default caller. Other
    callers that rely on the grant can branch on the return code.
- `scripts/memory-daily-harvest.sh` under linux-user isolation stays in
  controller UID and passes `--transcripts-home=<target_home>` so
  `_scan_transcripts` reads the isolated user's `~/.claude/projects/`
  via the new controller r-X ACL. No `sudo` re-exec — that preserves
  the harvester's access to the controller-owned queue DB (read
  `task_events`, dedupe `_task_status`, write backfill tasks via
  `bridge-task.sh create`). When `<target_home>/.claude/projects/` is
  not readable (fresh agent before first session, or ACL not yet
  re-applied), the stub falls back to `--skipped-permission --os-user`
  for a structured skip + admin aggregate notify.
- `bridge_linux_prepare_agent_isolation` grants the controller `r-X`
  on the isolated user's `~/.claude/` + `~/.claude/projects/` (plus a
  default ACL so a future `projects/` inherits). This is the single
  cross-UID read lens; no write grant.
- `bridge_migration_sudoers_entry` is now `NOPASSWD: SETENV: tmux, bash`
  (adds the `SETENV:` tag used by `bridge-start.sh` launch path for
  env-preserving sudo exec). `bridge_linux_can_sudo_to` switches its
  probe from `sudo -n -u <os_user> true` to
  `sudo -n -u <os_user> -- <bash> -c 'exit 0'` so the probe matches
  the entry (otherwise already-isolated installs would fall back to
  shared-mode launch after upgrade).
- `agent-bridge isolate <agent> --reapply` — idempotent re-install of
  per-agent ACLs without re-running ownership migration. Required to
  pick up ACL-contract changes on already-isolated installs.
- Cron dispatch ordering reshuffle in `bridge-cron.sh::dispatch_cron_run`:
  run_dir artifacts (`request.json` / `status.json` / `manifest.json`)
  + per-run ACL grant are now written **before** the queue task is
  created. `dispatch_task_id` / `task_id` are seeded with sentinel
  `0` and atomically rewritten to the real queue id via new helpers
  `bridge_cron_update_request_task_id` / `bridge_cron_update_manifest_task_id`.
  The `already_enqueued` short-circuit now validates that the existing
  request carries a positive `dispatch_task_id` — a stranded run from
  a prior failed queue-create step is cleaned and re-enqueued instead
  of being skipped forever. `bridge_cron_run_dir_grant_isolation` is
  best-effort (non-fatal) under v1.3: memory-daily now runs as the
  controller UID so the grant is no longer load-bearing, and hosts
  without passwordless root sudo must not block dispatch because of
  an ACL the harvester does not need. Other families that spawn
  isolated subprocesses can still benefit from the grant when ACL
  infrastructure is available.
- Docs: `docs/agent-runtime/memory-daily-harvest.md` §10 rewritten;
  new `docs/handoff/219-linux-isolation-e2e.md` (Linux server admin
  patch E2E runbook).
- Smoke additions: scenario 9 (shared/aggregate path), scenario 14
  (stub isolation + readable `.claude/projects` → `--transcripts-home`
  dispatch, no sudo), scenario 15 (unreadable target → structured
  `--skipped-permission` fallback). Total 10/10 PASS on macOS mock.

### Changed
- Python harvester writes aggregate state under
  `state/memory-daily/shared/aggregate/` rather than the memory-daily
  root. Controller-context migration ensures backward compatibility
  with existing installs.

### Notes
- macOS hosts have no linux-user isolation path; behaviour unchanged.
- Full linux E2E validation runs on the user's Linux server (see the
  handoff doc). macOS CI covers mock-level branch logic only.

Fixes #219

## [0.6.7] — 2026-04-23

### Added
- `memory-daily-<agent>` per-agent cron, autoregistered by
  `bootstrap-memory-system.sh` for every active Claude agent whose refresh
  gate is on. Schedule `0 3 * * *` (Asia/Seoul). Disabling the gate on a
  subsequent `--apply` deletes the stale cron.
- `bridge-memory.py harvest-daily` subcommand — detection-only reconcile
  kicker with manifest schema v1, state machine
  (`checked / queued / resolved / skipped-permission / disabled / escalated`),
  semantic-empty parser, source-confidence tiering (strong / medium / weak),
  legacy-path probe, `(agent, date)` dedupe, 24h cooldown, and
  attempts>3 escalation. Aggregate state
  (`state/memory-daily/admin-aggregate-skip.json`,
  `admin-aggregate-escalated.json`) merged with `fcntl.flock`. New
  `--skipped-permission` / `--os-user` flags wire the
  skipped-permission branch (minimal manifest + permission aggregate
  merge), and `--transcripts-home` overrides the base for
  `~/.claude/projects` scanning (used by the stub's sudo wrap and by
  smoke fixtures).
- `scripts/memory-daily-harvest.sh` — cron payload stub. Parses
  `agent show --json` so workdir / profile-home / isolation.mode /
  isolation.os_user each survive whitespace-bearing paths (per-field
  python3 parse). Derives the sidecar path from `CRON_REQUEST_DIR`
  (runner-exported) with a fallback under
  `state/memory-daily/<agent>/adhoc.authoritative.json` for manual
  invocation. Under `linux-user` isolation with a user mismatch, the
  stub forwards `--skipped-permission --os-user <user>` so the Python
  harvester writes `state=skipped-permission` and merges `(agent, date)`
  into `admin-aggregate-skip.json`. (A sudo re-exec is deliberately not
  used: the isolated UID cannot write the controller-owned cron/state
  trees until `bridge_linux_prepare_agent_isolation` grants those paths
  — tracked separately.)
- Runner-level authoritative sidecar enforcement for the `memory-daily`
  family in `bridge-cron-runner.py`. Sidecar is the preferred source in the
  normal path and in the parse-exception recovery path, with
  `child_result_source` and `sidecar_error_note` audit fields in
  `result.json`.
- Daemon refresh gating in `bridge-daemon.sh` — `session_refresh_queued` is
  emitted only when `actions_taken` contains `queue-backfill`; otherwise
  `session_refresh_skipped` is emitted with
  `reason=no_queue_backfill_action`. `process_memory_daily_refresh_requests`
  clears stuck pending refresh state ahead of the disabled-gate skip
  (`session_refresh_pending_cleared`, `reason=gate_off`).
- `lib/bridge-cron.sh::bridge_cron_actions_taken_contains` helper.
- Docs: `docs/agent-runtime/memory-daily-harvest.md`.
- Smoke: `tests/memory-daily-harvest/smoke.sh` covering scenarios 2, 4, 8,
  9 (skipped-permission writes manifest + aggregate), 10, residual-risk
  sidecar recovery (11), stub isolation-mismatch dispatch (12), and
  stub default-path dispatch (13).

### Changed
- `bridge-cron-runner.py`: `run_codex` and `run_claude` signatures accept an
  optional `request_file` so the runner can export `CRON_REQUEST_DIR` to the
  child process environment.
- `bridge-daemon.sh` cron worker completion path now gates the memory-daily
  session-refresh on `actions_taken`.

### Notes
- Canonical `users/default/memory` path alignment is tracked separately. This
  release probes the legacy path read-only to suppress false-positive
  backfills.
- Session `/wrap-up` remains the primary daily-note writer and is out of
  scope here.

Fixes #216
