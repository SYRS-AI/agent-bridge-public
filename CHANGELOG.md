# Changelog

All notable changes to Agent Bridge are documented here. This project adheres
loosely to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and tracks
version bumps via the `VERSION` file.

## [0.6.9] — 2026-04-24

### Added
- `agent-bridge diagnose acl [--json]` scanner (issue #233 stage 3,
  PR #237): a read-only sweep over `/`, `/home`, the controller's
  home, `BRIDGE_HOME`, `BRIDGE_AGENT_HOME_ROOT`, and `BRIDGE_STATE_DIR`
  that flags named-user ACL entries left behind by earlier
  isolate/unisolate cycles. Distinguishes access vs. default ACL
  entries and prints the exact `setfacl -x` command to drain each
  one. Linux-only; non-Linux hosts and hosts without `getfacl` exit 0
  with a benign banner. `--json` mode emits
  `{"platform":..., "controller":..., "findings":[…]}` for machine
  consumption.
- Restored `next-session.md` auto-expiry helpers in
  `lib/bridge-state.sh` (issue #228, PR #229):
  `bridge_path_age_seconds`, `bridge_agent_next_session_digest`,
  `bridge_agent_next_session_is_delivered`,
  `bridge_agent_next_session_age_seconds`,
  `bridge_agent_clear_next_session_state`, and
  `bridge_agent_maybe_expire_next_session`. All six were lost during
  commit 7bf4e7d's lib trim; `bridge-run.sh:237` still referenced the
  last one and printed `command not found` on every Claude-engine
  launch. Restored verbatim (with the marker path routed through the
  current `bridge_agent_next_session_marker_file`
  `runtime_state_dir/next-session.sha` convention).
- SessionStart hook persists the NEXT-SESSION.md digest (PR #229):
  `hooks/bridge_hook_common.py::_stamp_next_session_delivered` now
  writes `sha1(content.rstrip(b"\n"))` to the per-agent marker path
  when `bootstrap_artifact_context` surfaces a handoff. The hook
  honours `BRIDGE_ACTIVE_AGENT_DIR` so deployments with a rerooted
  active-agent dir (e.g. linux-user isolation) land the marker where
  the bash reader actually looks. Closes the auto-expiry loop that
  was introduced in 1e75c0c but silently broken since 7bf4e7d.

### Fixed
- `scripts/*.sh` executable bit preserved across `agent-bridge upgrade`
  (issue #222, PR #225): `bridge-upgrade.py` now trusts the git
  index mode, not the checkout's filesystem mode, so a dev worktree
  with drifted permissions no longer propagates wrong modes
  downstream. A new `mode_drift` classification + `sync_mode` action
  repairs byte-identical live files whose exec bit went missing.
  `bootstrap-memory-system.sh::bootstrap_install_scripts` repairs the
  same drift defensively. `scripts/install-daemon-launchagent.sh` and
  `scripts/oss-preflight.sh` promoted to git mode 100755.
- Bun plugin orphan accumulation across agent restarts (issue #223,
  PR #226): `bridge-mcp-cleanup.py` DEFAULT_PATTERNS now matches the
  plugin root itself —
  `bun run --cwd .../.agent-bridge/plugins/` and
  `bun run --cwd .../claude-plugins-official/` — so
  `is_orphan_candidate`'s parent-chain check can classify the
  `bun server.ts` child as an orphan when it is reparented to PID 1.
  Non-greedy regex tolerates whitespace-bearing home directories.
- Admin-inbox alert fatigue (issue #230, PR #231):
  - `process_context_pressure_reports` only emits on severity-bucket
    transitions; a sustained warning/info bucket no longer re-broadcasts
    every 30 minutes. `critical` still uses the legacy cooldown
    rebroadcast because it's an ongoing emergency worth pinging on.
  - `dispatch_cron_work` gates `[cron-followup]` tasks behind a
    consecutive-failure counter keyed on `CRON_FAMILY`. Default
    threshold 3 (configurable via
    `BRIDGE_CRON_FOLLOWUP_FAIL_BURST_THRESHOLD`); counter resets on
    success or after a burst-triggered create. File update is
    `flock`-serialised on hosts that ship flock.
  - `process_crash_reports` skips manual-stop-armed agents entirely —
    no more `crash_loop_report mode=refresh` audits on an
    intentionally-offline agent.
- `bridge-run.sh` no longer prints
  `bridge_agent_maybe_expire_next_session: command not found` on every
  Claude-engine launch (issue #228, PR #229). See **Added** for the
  helpers and the SessionStart writer that completes the feature.
- Linux-user isolation no longer poisons `/` and `/home` with
  named-user ACL entries (issue #233, PRs #235/#236/#237):
  - Stage 1 (PR #235, `lib/bridge-migration.sh`): `unisolate` now
    strips `u:<os_user>` and `u:<controller>` named-user entries
    (access + default) from the shallow paths isolate is known to
    touch (`/`, `/home`, controller home, isolated home, BRIDGE_HOME,
    BRIDGE_AGENT_HOME_ROOT, memory-daily root + shared) and removes
    `u:<os_user>` recursively from agent-scoped trees including
    hooks/shared/runtime/lib/plugins/scripts/.claude, `memory-daily/
    <agent>`, `memory-daily/shared/aggregate`, and the root helper
    files (`agent-bridge`, `agb`, `VERSION`, `bridge-*.sh`,
    `bridge-*.py`). Default-ACL directories are swept with
    `find -type d -exec setfacl -d -x`.
  - Stage 2 (PR #236, `lib/bridge-agents.sh`, `lib/bridge-cron.sh`):
    `bridge_linux_grant_traverse_chain` now requires an explicit
    `stop_path`; `/` and empty strings warn + skip. A new
    `bridge_linux_traverse_stop_for` helper returns the controller's
    home when the target is under it, empty for system paths. Every
    call site passes a controller-scoped stop — no more walking to
    `/`. The `bridge_linux_grant_traverse_chain "$controller_user"
    "$isolated_claude_dir"` call that tagged `/` and `/home` with the
    operator UID is gone; replaced by scoped grants on
    `$user_home` + `$isolated_claude_dir` only.
  - Stage 3 (PR #237, `bridge-diagnose.sh`): `agent-bridge diagnose
    acl` scanner (see **Added**) lets operators audit shared roots
    for any lingering residue without running `unisolate`.
- Hook queue CLI no longer FileNotFoundErrors when a dynamic agent
  has no default home (PR #232, Sean Oh / SYRS-AI):
  `hooks/bridge_hook_common.py::queue_cli` routes through a new
  `queue_cli_cwd()` fallback chain
  (`BRIDGE_AGENT_WORKDIR` → `agent_default_home` → `cwd` →
  `bridge_script_dir` → `/`). Artifact lookup still uses
  `current_agent_workdir()` so handoff paths aren't affected. Smoke
  adds a `CODEX_DYNAMIC_NO_HOME_AGENT` regression asserting the hook
  exits 0 with valid Codex JSON and doesn't auto-create the missing
  home.

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
