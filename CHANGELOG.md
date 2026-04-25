# Changelog

All notable changes to Agent Bridge are documented here. This project adheres
loosely to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and tracks
version bumps via the `VERSION` file.

## [0.6.17] — 2026-04-25

### Documentation
- `CHANGELOG.md` and `OPERATIONS.md` get an explicit "v0.6.16 upgrade /
  migration notes" section that distinguishes operator-required steps from
  what `bridge-upgrade.sh` does automatically. The original v0.6.16 entry
  was complete on the per-PR change description but mixed automatic and
  manual concerns; operators upgrading from v0.6.15 → v0.6.16 needed to
  read each PR body to know what to run by hand. This release surfaces:
  - **Auto** (covered by `bridge-upgrade.sh`): apply-channel-policy.sh
    re-run (singleton + new BRIDGE_AGENT_PLUGINS overlay), daemon stop +
    restart with the new orphan sweep + heartbeat + sibling supervisor.
  - **Operator-required**:
    1. (Linux) v0.6.16 daemon verify after upgrade — single
       `bridge-daemon.sh run$` PID per user via
       `pgrep -af 'bridge-daemon\.sh run$'`.
    2. (Optional, recommended) per-agent plugin allowlist —
       `BRIDGE_AGENT_PLUGINS["<agent>"]="plugin1 plugin2"` in
       `agent-roster.local.sh` then `bash scripts/apply-channel-policy.sh
       && agb agent restart <agent>`. Closes the ~250 MCP / ~1 GB RSS
       scenario from #272.
    3. (Optional, per agent) daily-note migration —
       `bridge-memory.py migrate-canonical --home
       ~/.agent-bridge/agents/<agent> --user default --apply
       --i-know-this-is-live`. Default dry-run; `--apply` mandatory + the
       new `--i-know-this-is-live` guard required when `--home` resolves
       to the live `BRIDGE_HOME` (refused by default; the guard exists
       because `_resolve_bridge_bin` always routes admin task creation
       through the live binary regardless of `--home`).
    4. (Optional, per host) liveness watcher install — NOT auto-installed
       by upgrade; only fresh `bootstrap` adds it. Existing installs run
       `bash scripts/install-daemon-liveness-launchagent.sh --apply --load`
       (macOS) or `bash scripts/install-daemon-liveness-systemd.sh
       --apply --enable` (Linux). Pair with `--skip-liveness` on bootstrap
       if you do NOT want it installed automatically on a fresh host.
    5. (Optional, per cron) `--strict-mcp-config` opt-in — set
       `metadata.disableMcp=true` on individual cron jobs that don't call
       MCP, or set `BRIDGE_CRON_DISPOSABLE_DISABLE_MCP=1` install-wide
       in the daemon environment.
- **Backward-compat regression note**: installs that intentionally used
  `<home>/users/<user>/memory/` as a multi-tenant partition will see
  `bridge-memory.py summarize-weekly --user <id>` and
  `summarize-monthly --user <id>` no longer aggregate from that
  partition. Migrate via the command above, or document the multi-tenant
  intent in your local roster and continue indexing-only via
  `collect_index_documents` (still walks both roots). See
  `docs/agent-runtime/memory-schema.md`.
- **Do not run `bridge-daemon.sh stop` separately before `upgrade --apply`** —
  the upgrader handles daemon orchestration internally. Stopping the daemon
  manually on a v0.6.13 host can cascade into all-agent tmux respawn with
  stale `AGENT_SESSION_ID` resume (see issue #314). On hosts upgraded past
  v0.6.13 the cascade is mitigated by hardening waves shipped in v0.6.14-0.6.16,
  but `upgrade --apply` remains the only sanctioned entrypoint.
- **Recommended upgrade order on a host with running agents**:
  ```bash
  # Recommended upgrade on a host with running agents — single entrypoint
  agent-bridge upgrade --apply

  # (Linux) verify single daemon PID
  pgrep -af 'bridge-daemon\.sh run$'

  # (Optional) per-agent plugin allowlist + restart specific agents
  $EDITOR ~/.agent-bridge/agent-roster.local.sh   # add BRIDGE_AGENT_PLUGINS
  bash ~/.agent-bridge/scripts/apply-channel-policy.sh
  agb agent restart <agent>

  # (Optional, per agent) daily-note migration
  bridge-memory.py migrate-canonical --home ~/.agent-bridge/agents/<agent> \
    --user default --apply --i-know-this-is-live

  # (Optional, per host) liveness watcher install
  bash ~/.agent-bridge/scripts/install-daemon-liveness-launchagent.sh \
    --apply --load
  ```

This release does NOT change any code path — only `VERSION` and
`CHANGELOG.md`. Operators on v0.6.16 do not strictly need to upgrade to
v0.6.17; pulling latest `main` is sufficient.

## [0.6.16] — 2026-04-25

### Added
- New `agb agent forget-session` complement: parallel-wave operator pattern
  validated and shipped a large hotfix wave on top of v0.6.15. See PR list
  below for full scope.
- `BRIDGE_AGENT_PLUGINS["<agent>"]` per-agent plugin allowlist (issue #272,
  PR #298). `scripts/apply-channel-policy.sh` writes
  `agents/<agent>/.claude/settings.local.json` with `enabledPlugins=false`
  for every globally-installed plugin not in the allowlist. Channels
  declared via `BRIDGE_AGENT_CHANNELS` are auto-included so an oversight
  cannot break a required transport. Legacy agents without the key keep
  full-set behaviour. Closes the ~250 MCP process / ~1 GB RSS scenario the
  issue documented.
- New `bridge-watchdog-silence.py` sibling supervisor (issue #265 proposal
  C, PR #293). Reads daemon_tick audit log; if no tick in
  `BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS` (default 600s), emits
  `daemon_silence_detected` + restarts daemon. Cooldown protected. Spawned
  by `bridge-daemon.sh start`, killed by `stop` before the daemon itself.
- New launchd LaunchAgent (macOS) + systemd `.service` + `.timer`
  (Linux) liveness watcher (issue #265 proposal D, PR #292). Checks the
  heartbeat file mtime every 60s; restarts daemon on staleness. Sibling to
  the daemon plist/unit, lives outside the bridge process tree. Opt-out
  via `--skip-liveness` to bootstrap.
- Daemon writes a `daemon.heartbeat` file alongside the `daemon_tick`
  audit row (PR #292 prep). Throttled by the same
  `BRIDGE_DAEMON_HEARTBEAT_SECONDS`.
- Per-job `metadata.disableMcp` (4 aliases) + install-wide
  `BRIDGE_CRON_DISPOSABLE_DISABLE_MCP` env opt-in `--strict-mcp-config`
  for cron disposable Claude children (issue #263 partial, PR #297). Local
  bench: ~5–10s real → ~3.2–3.7s real per fire (~78% CPU saved). Channel-
  relay safety override built-in.
- New `interactive_picker` stall classification + admin escalation
  (PR #295). Daemon detects `/rate-limit-options`, `claude --resume` long-
  resume, and verbatim picker tail patterns; routes through the same
  admin-escalation branch as `auth` (no nudge — picker takes a keystroke,
  not text). Picker-specific recommended message distinguishes safe-default
  Enter from billing-impact options.
- `bridge-memory.py migrate-canonical --home <home> [--user <id>] [--apply]`
  folds legacy `<home>/users/<user>/memory/*.md` into the unified
  `<home>/memory/` root (issue #220, PR #296). Default mode is dry-run; pass
  `--apply` to perform an atomic move and write
  `<home>/memory/_migration_log.json` (schema
  `memory-canonical-migration-v1`). Idempotent — a second `--apply`
  on a converged install reports `moved: 0`. Collisions (the same
  `<date>.md` exists in both roots) are renamed to
  `<date>.legacy.md` in the canonical root and an admin task is
  filed best-effort via `agent-bridge task create --to patch`. The
  manifest accumulates a `runs[]` history so multi-pass migrations
  retain provenance. `--i-know-this-is-live` flag required to run
  `--apply` against the live `BRIDGE_HOME` (refused by default to
  prevent the demonstrated accident class — codex review of PR #296).
- `BRIDGE_MEMORY_LEGACY_PROBE` env var now gates the harvester's
  legacy `<home>/users/default/memory/<date>.md` read-only probe.
  Defaults to `1` for one release so partially-migrated installs
  don't see false-positive backfills; set to `0` after running
  `migrate-canonical --apply` everywhere. Probe removal target:
  v0.7.

### Fixed
- Daily-note canonical path is now unified at `<agent-home>/memory/<date>.md`
  for every user, including `default` (issue #220). Closes the
  `_daily_notes_base` split that PR #218 only papered over with a
  read-only legacy probe in the harvester. The actual writer
  (`bridge-memory.py daily-append`) has always taken no `user`
  argument and landed in `<home>/memory/`; the summarizer's `--user`
  flag previously redirected reads into a separate
  `<home>/users/<user>/memory/` tree that no writer ever populated,
  so split-brain symptoms (missed daily notes after PR #218 in
  rebuild-index, monthly cascades reading the wrong tree) are
  resolved by aligning the resolver. Multi-tenant
  `users/<user>/memory/` partitions remain an indexed escape hatch
  (`collect_index_documents` still walks them) but are no longer the
  bridge writer's target — see `docs/agent-runtime/memory-schema.md`.
- `bridge_linux_prepare_agent_isolation` now grants the queue-gateway
  agent directory + root the necessary ACLs (`--x` for the isolated UID,
  `r-x` + default ACL for the controller) so `bridge-queue-gateway.py
  serve-once`'s glob doesn't silently return empty when the root is
  `root:root 700` (PR #287, issue from operator). New
  `tests/isolation-queue-gateway-acl.sh` (Linux-only) covers isolate,
  cross-agent isolation, isolated-uid write access, serve-once
  consumption, and unisolate ACL strip. `bridge-state.sh diagnose acl`
  scanner reaches the new ACL paths without changes.
- Documentation-only update: `KNOWN_ISSUES.md` adds entry #11 closing
  historical issue #194 daemon-exit observability — the
  v0.6.15 hardening (#261/#262/#270/#273/#274/#279/#281/#289/#293/#292)
  subsumes every observability gap the original tracking issue named
  (PR #299).

## [0.6.15] — 2026-04-25

### Added
- `agb agent forget-session <agent>` clears persisted `AGENT_SESSION_ID`
  from all authoritative state files (active env, history env, optional
  linux-user overlay) under a per-agent lock (issue #268, PR #280).
  Idempotent: a second call exits with `already_forgotten` and no
  rewrite. Concurrent callers serialize via `flock` (with `mkdir`
  fallback for hosts without flock) so only one writer ever logs the
  cleared audit row. `bridge-start.sh` and `bridge-run.sh` now warn on
  `--no-continue` when a persisted id remains, and `agent show --json`
  surfaces a `session_source` field naming which file the active id
  came from. `--fresh --persist` one-shot recovery, tombstone for
  forgotten ids, and tmux duplicate-session race hardening are
  intentionally deferred to follow-up PRs per the spec round.
- "External Tool Latency and User Visibility" section in
  `docs/agent-runtime/common-instructions.md` (issue #271, PR #278).
  Six directive bullets: pre-call announcement on slow external calls,
  30s/2m/5m visibility tiers (status → escalation → assumed-failure),
  no `sleep` loops or silent polling, explicit "this will take a
  while" up-front for deliberate long jobs, user-reply-first as the
  first action of any post-failure turn. Triggering incident: a
  21-minute silent MCP wait that broke the user contract.

### Fixed
- Daemon main loop now wraps high-risk subprocess invocations in
  `bridge_with_timeout` (issue #265 proposal A, PR #279) and the
  same helper now wraps every `tmux send-keys` call site in
  `lib/bridge-tmux.sh` (PR #281). The original 34h hang documented
  in #265 was a `tmux send-keys` blocked on a closed Discord SSL
  pipe; PR #279 capped the daemon python sites first, PR #281
  closed the actual hang vector. Default 30s for daemon python
  sites (`BRIDGE_DAEMON_SUBPROCESS_TIMEOUT_SECONDS`) and 10s for
  tmux IPC (`BRIDGE_TMUX_SEND_TIMEOUT_SECONDS`). On 124/137 exit
  the helper writes a `daemon_subprocess_timeout` audit row tagged
  with the call-site label. Hosts without `timeout`/`gtimeout`
  fall back to running unwrapped after a one-time
  `daemon_subprocess_timeout_unavailable` warn.
- Closed PR #239's 14-bullet bundle has been re-landed as eight
  scope-isolated PRs after the original umbrella PR cycled through
  CLAUDE.md's three-round limit. The split shipped in five waves
  using the new wave-style operator pattern (parallel
  `upstream-issue-fixer` dispatch + `codex:codex-rescue` review).
  Bullet 6 (broken-launch state file from circuit breaker) was
  already in #262; bullet 9 was a duplicate of bullet 1. The
  remaining bullets landed as:
  - PR #282 — smoke fixture hardening: fake `claude` binary in
    isolated smoke PATH so init preflight does not depend on a real
    Claude install, bootstrap smoke pinned to `--shell zsh
    --skip-systemd`, daemon side-work reduced by default with
    per-block re-enables, plugin liveness cooldown / watchdog
    dedupe / admin manual-stop fixture stabilizations (PR #239
    bullets 3 + 4 + 11 partial + 13 partial).
  - PR #284 — `agent-bridge audit` reads `BRIDGE_AUDIT_LOG`
    instead of hard-coding `$BRIDGE_HOME/logs/audit.jsonl`, and
    auto-memory seeding is allowed when both `BRIDGE_HOME` and
    the target settings path are ephemeral (bullets 1 + 2).
  - PR #285 — Claude resume smoke fixtures explicit for realpath
    and stale-session cases (no longer silently passing on a
    missing-channel launch path), and `bridge_watchdog_problem_key`
    strips volatile `heartbeat_age_seconds` from the dedupe hash
    while keeping `heartbeat_present` and drift fields (bullets
    10 + 14).
  - PR #286 — upgrade dry-run restart analysis sources `bridge-lib.sh`
    from `SOURCE_ROOT` instead of assuming the target `BRIDGE_HOME`
    contains it; large upgrade JSON payloads route through a temp
    file instead of process argv (avoiding Linux `Argument list
    too long`); restart-analysis subshell scrubs caller-side
    `BRIDGE_*` exports so `--target <fresh-temp-home> --dry-run`
    reports the target's roster (`considered=0`), not the live
    caller's (bullets 7 + 8 + r2 env isolation).
  - PR #288 — `runtime/credentials` and `runtime/secrets` are
    secured to `0700`/`0600` after canonical template overlay so
    repo-managed credential templates do not inherit `0644` and
    leak (bullet 12).
  - PR #289 — `process_channel_health` and `process_usage_monitor`
    in `bridge-daemon.sh` now honour
    `BRIDGE_CHANNEL_HEALTH_ENABLED` / `BRIDGE_USAGE_MONITOR_ENABLED`
    env gates so PR #282's smoke env exports are no longer silently
    dead (bullet 11 daemon side).
  - PR #290 — restored safe-mode launch helpers
    (`bridge_build_safe_claude_launch_cmd`,
    `bridge_safe_mode_resume_mode`, `bridge_build_safe_launch_cmd`)
    so `bridge-run.sh --safe-mode` (already wired up) can build
    minimal Claude launches without channel flags; smoke fixture
    clears the admin manual-stop overlay before the admin crash
    daemon-sync block so the upgrade-restart fixture's bulk
    manual-stop does not silently disable admin alerting
    (bullets 5 + 13).

## [0.6.14] — 2026-04-25

### Fixed
- `bridge-stall.py` no longer self-loops on the agent's own narration
  of a past provider error (issue #264, PR #270, three rounds). The
  classifier had matched `PATTERN_GROUPS` regexes inside
  `looks_like_agent_output`, treating any agent reply containing
  `429` / `rate limit` / `timeout` as agent UI and re-firing a fresh
  stall against the agent's own text every daemon tick. r1 collapsed
  the loop but regressed glyph-less raw provider errors arriving
  immediately after an `[Agent Bridge]` nudge; r2 restored that
  capture path; r3 added the `join` mode to the stall-side
  `bridge_capture_recent` call so `tmux capture-pane` runs with `-J`
  and a long agent reply does not wrap into a glyph-less continuation
  line that classify mistakes for raw provider output.
  `AGENT_GLYPH_PREFIXES` documents the Claude UI markers that the
  layered classify-pass excludes (`❯`, `>`, `›`, `⏺`, `⎿`, `✢`, `✻`,
  `✱`, `ℹ`, `✓`, `✗`).
- `bridge-queue.py` cron-dispatch dedup now preserves fresh and
  pre-fire sibling slots so high-frequency crons survive worker-pool
  backlog (issue #266, PR #275). The previous dedup cancelled every
  non-newest open slot regardless of whether the newest had been
  fired; under recovery from a daemon hang, every fresh slot was
  superseded by the next before any worker could claim it
  (`cs-line-poll-5m` ran zero successful fires across 144 slots in
  36h). Two layered guards: a grace window
  (`BRIDGE_CRON_SUPERSEDE_GRACE_SECONDS`, default 60s) preserves
  unclaimed siblings while they may still get picked up, and a
  newest-not-fired guard preserves all unclaimed siblings while the
  newest itself is still queued. Claimed-but-not-newest siblings are
  still cancelled (genuine duplicate work). Normal operation is
  unchanged because newest fires quickly and the guards stay
  inactive.
- `bridge-daemon.sh stop` now sweeps every own-user
  `bridge-daemon.sh run` process, not just the PID recorded in
  `BRIDGE_DAEMON_PID_FILE` (issue #269, PR #273, two rounds). An
  earlier daemon that lost its pid-file (install moved paths,
  `bridge-daemon.sh run` invoked manually for diagnostics, orphan
  re-parented to PPID=1) survived stop + systemd's
  `Restart=always` and ran concurrently with the systemd-managed
  daemon, silently ignoring later env drop-ins like
  `BRIDGE_SKIP_PLUGIN_LIVENESS=1`. The new helper
  `bridge_daemon_all_pids` matches own-user processes by cmdline
  (path-agnostic, scoped to `pgrep -U "$(id -u)"` so other users on
  the same host are never touched), excludes the caller's own PID,
  and is overridable via `BRIDGE_DAEMON_STOP_PATTERN` for isolated
  tests. `cmd_stop` audits `killed_count`, `failed_count`,
  `orphan_count`, and `recorded_pid` so after-the-fact inspection can
  tell sweeping cycles from clean stops.

### Added
- Periodic `daemon_tick` audit event so a hung daemon main loop is
  externally observable (issue #265 partial, PR #274, proposal B
  only). The previous daemon kept emitting "alive" to launchctl and
  `agent-bridge status` while the bash main loop was wedged at
  `__wait4` for 34 hours after a `tmux send-keys` blocked on a
  closed Discord SSL pipe — every observable health check stayed
  green and audit went silent. The daemon now writes a
  `daemon_tick` audit row at the end of each completed sync cycle,
  throttled by `BRIDGE_DAEMON_HEARTBEAT_SECONDS` (default 60s,
  ~1.4k lines/day; set to 0 to disable). Detail fields surface
  `loop_step` (the value of `BRIDGE_DAEMON_LAST_STEP` when the tick
  fired), `interval_seconds`, and `heartbeat_interval_seconds` so
  operators and a future audit-silence supervisor can pinpoint
  which loop step the daemon was in immediately before going
  silent. Followups for proposals A (per-call `timeout`s on every
  external invocation), C (sibling supervisor that restarts the
  daemon on audit silence), and D (launchd liveness watcher on a
  heartbeat file) are tracked separately on issue #265.

## [0.6.13] — 2026-04-25

### Changed
- Upgrade restart summary labels renamed from `would_restart` /
  `restarted` / `would_restart_agents` / `restarted_agents` to
  `restart_eligible` / `restart_attempted_ok` and the matching
  `_agents` pairs (issue #257, PR #259). The prior names
  over-promised at both layers — dry-run predicted eligibility
  (not success), apply recorded a `bridge-agent.sh restart` exit-0
  count (not agent health). `agent-bridge upgrade --dry-run` now
  additionally prints an `agent_restart_note` disclaimer reminding
  operators that runtime failures (plugin resolution, settings
  corruption, dependency outages) only surface at apply. This is a
  small JSON-key breaking change for any external consumer of the
  `agent_restart` payload; in-tree consumers (smoke) are updated in
  the same release.

### Fixed
- `hooks/tool-policy.py::protected_alias_reason` no longer
  substring-matches the queue DB and roster filenames across the
  entire Bash command text (issue #252, PR #260). The prior check
  blocked any invocation whose body merely mentioned the suffix —
  `gh issue comment --body "…state/tasks.db…"`,
  `git commit -m "…roster file…"`, `rg '…state/tasks.db' docs/`,
  even the description of the bug report itself. The rewrite
  `shlex.split`s the command, skips message-body option flags
  (`--body` / `-m` / `--message` / `--title` / `--description` /
  `--notes` / `--subject`), routes file-valued flags
  (`--body-file` / `-F` / `--file` / `--input`) through the same
  path comparison positional tokens use, splits each token on
  shell control operators (`;` / `&&` / `||` / `|` / `&` /
  newline) and peels a single redirection prefix (`<` / `>` /
  `>>` / `2>` / `&>`), then expands `~` / `$VAR` before the
  `Path ==` check. `sqlite3 <abs>/state/tasks.db`,
  `sqlite3 "$BRIDGE_HOME"/state/tasks.db`, `cat <abs roster>`,
  and `git commit -F <abs roster>` still block with the intended
  reasons; incidental suffix mentions pass through.
- `bridge-upgrade.sh` now surfaces per-agent restart-failure
  diagnostics on the apply summary (issue #256 Gap 1, PR #261).
  The restart report tuple grew from 5 to 7 columns to carry the
  failing `bridge-agent.sh restart` exit code and the agent's
  most recent `.err.log` tail (or `.log` tail when `.err.log`
  is empty — the silent-exit common case). The JSON payload's
  `agent_restart` object now includes a `failed_details` list
  with `{agent, exit_code, last_log_tail}` entries, and the
  text summary prints one
  `agent_restart_failed_detail_<agent>: exit=<N> tail=<flat>`
  line per failure. The aggregator tolerates older 5-column
  tuples so a half-upgraded host does not crash the parser, and
  a PEP 604 `str | None` annotation slipped into r1 was fixed
  in r2 (Python 3.9.6 compatibility).
- `bridge_daemon_autostart_allowed` now honours the broken-launch
  quarantine marker and stops relaunching an agent whose
  `bridge-run.sh` rapid-fail circuit breaker has tripped (issue
  #256 Gap 2, PR #262). The missing
  `bridge_agent_write_broken_launch_state` writer (called from
  `bridge-run.sh:512` since the circuit breaker landed but never
  defined anywhere in the tree) is now present in
  `lib/bridge-state.sh`, so the marker is actually written on
  trip. Matching `bridge_agent_clear_broken_launch` helper is
  wired onto the `agent-bridge agent start` / `safe-mode` /
  `restart` entry points, guarded behind the dry-run
  short-circuit and restart preflight so an inspection or a
  pre-launch failure does not silently unquarantine the agent.
  Root cause of the 137-relaunch-in-2h13m #254 repro on the
  reference host.

## [0.6.12] — 2026-04-25

### Fixed
- `scripts/apply-channel-policy.sh` no longer silently disables the
  singleton channel plugins for non-admin agents that explicitly own
  them via `BRIDGE_AGENT_CHANNELS["<agent>"]="plugin:…"` in the roster
  (issue #254, PR #255). The v0.6.11 admin-bypass overlay assumed the
  admin agent was the sole router for every singleton channel, but
  multi-persona deployments (e.g. `dev` owns discord while `dev_mun`
  owns telegram) had their owning agent's plugin blanket-disabled —
  claude silently exited during plugin resolution and the agent
  entered a restart loop. The script now walks every reachable roster
  file, parses `BRIDGE_AGENT_CHANNELS` entries (including dotted agent
  ids like `foo.bar`), and writes a per-agent
  `.claude/settings.local.json` that selectively re-enables only the
  singleton plugins each agent actually owns. Admin retains the
  existing full re-enable. When two or more agents declare the same
  singleton plugin, a `WARNING: '<plugin>' declared by multiple
  agents (…)` line is emitted on stderr — the upstream bot API still
  enforces one-connection-per-token, so "most recently restarted
  wins" is surfaced instead of both agents silently failing. A bash
  4+ self-exec guard identical to `bridge-lib.sh` now protects the
  script from macOS's default `/bin/bash` 3.2, and an admin grep that
  previously aborted under `set -euo pipefail` when the roster had no
  `BRIDGE_ADMIN_AGENT_ID` line is now tolerant of that shape.

## [0.6.11] — 2026-04-25

### Fixed
- `bootstrap-memory-system.sh` no longer aborts on macOS installs with
  hyphenated or dot-named agent ids (queue task #886, PR #250). Two
  regressions introduced in 0.6.10 are addressed together: (a) the
  script now re-execs under Bash 4+ when picked up by macOS's default
  `/bin/bash` 3.2 (mirrors the guard in `bridge-lib.sh`), and (b)
  `memory_daily_gate_on` normalises every character outside the bash
  identifier alphabet to `_` before building the
  `BRIDGE_AGENT_MEMORY_DAILY_REFRESH_<agent>` env lookup, so agents
  like `agb-dev-claude` and `foo.bar` no longer trip `invalid variable
  name` during indirect expansion. Operators overriding the env must
  use the underscore-normalised key; the roster-level associative
  array form (`BRIDGE_AGENT_MEMORY_DAILY_REFRESH[<agent>]=0`) is
  unchanged.
- `scripts/apply-channel-policy.sh` now writes a per-agent local
  overlay at `agents/<admin>/.claude/settings.local.json` that
  re-enables `telegram@claude-plugins-official` /
  `discord@claude-plugins-official` for the configured admin agent
  (issue #244, PR #246). Claude Code's settings merge order prefers
  `.claude/settings.local.json` over the shared-effective
  `.claude/settings.json` symlink, so the admin keeps the router role
  while every other agent stops contending on the bot tokens. Admin
  id is resolved only from an explicit signal (env
  `BRIDGE_ADMIN_AGENT_ID` or a roster-file grep) and is a no-op when
  the admin home does not yet exist, keeping the bypass safe on
  smoke fixtures and pre-bootstrap hosts.

## [0.6.10] — 2026-04-24

### Fixed
- `hooks/tool-policy.py::other_agent_homes` no longer classifies the
  `agents/shared` symlink (or `.claude` / `_template` siblings) as
  peer agent homes (issue #240, PR #242). Every Claude-authored Write
  to `$BRIDGE_SHARED_DIR` on 0.6.9 was being rejected with
  `cross-agent access is blocked: shared` because `path.resolve()`
  collapsed the alias onto the real shared tree. The filter is now an
  exact-name allowlist (`shared`, `_template`, `.claude`) — no
  prefix/symlink heuristic — so agents whose names legitimately start
  with `_` or `.` (e.g. `_real_agent_name`, `.real_dot_agent`) keep
  their cross-agent isolation.

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
