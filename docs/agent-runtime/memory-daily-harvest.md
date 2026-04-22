# Agent Runtime — memory-daily harvester

> Per-agent detection-only reconciler for the canonical daily note
> (`<agent-home>/memory/YYYY-MM-DD.md`). **Not** the primary writer — the daily
> note itself is written by session `/wrap-up` (see
> [`auto-memory-isolation.md`](auto-memory-isolation.md)). The harvester only
> observes: if the previous operating day had activity but the note is missing
> or semantic-empty, it queues a `[memory-daily-backfill]` task for the agent
> to reconstruct from transcript + captures + git.

## 1. Purpose

The harvester is a **reconcile-kicker** that runs once per agent per day and
decides one of:

- Canonical note exists and is non-empty → no action.
- Canonical note missing but legacy `<home>/users/default/memory/<date>.md`
  exists and is non-empty → no action, note the legacy path.
- Canonical note missing with strong/medium activity evidence → queue a
  backfill task for the agent.
- Weak-only evidence (git commits, PreCompact captures) → no action.
- Gate disabled → skip and write a minimal manifest.
- Sudo wrap failed on linux-isolated installs → skip and aggregate.

No LLM is invoked. The harvester is pure detection.

## 2. Cron registration

`bootstrap-memory-system.sh` registers one cron per active Claude agent:

- Title: `memory-daily-<agent>`
- Schedule: `0 3 * * *` (Asia/Seoul)
- Payload:

  ```
  bash "$BRIDGE_HOME/scripts/memory-daily-harvest.sh" --agent <agent>

  # The harvester writes the authoritative RESULT_SCHEMA JSON to
  # $CRON_REQUEST_DIR/authoritative-memory-daily.json. The runner reads that
  # file directly. Your structured_output is a secondary relay.
  # Do NOT re-interpret status / summary / actions_taken — the harvester is authoritative.
  ```

The inline `Do NOT re-interpret` comment is load-bearing. The cron runner
forwards payload text to a Claude subagent as the prompt body; without the
override the subagent could paraphrase `actions_taken`, which would defeat the
daemon refresh-gating contract in §7.

Gate-off agents (`BRIDGE_AGENT_MEMORY_DAILY_REFRESH[<agent>]=0`) skip
registration. A re-run of `bootstrap-memory-system.sh --apply` after disabling
the gate deletes the stale cron.

## 3. Harvest runtime chain

```
native cron scheduler
  └─> bridge-cron-runner.py
        ├─ exports CRON_REQUEST_DIR=<per-run workdir>
        └─ spawns claude -p … (prompt = cron payload text)
              └─ Claude subagent uses Bash tool to run the stub:
                   scripts/memory-daily-harvest.sh --agent <agent>
                     └─ parses `agent show --json` for workdir + profile.home
                        + isolation.mode + isolation.os_user (each via its own
                        python3 parse — whitespace-safe)
                     └─ linux-user isolation + user mismatch:
                          · exec python --skipped-permission --os-user …
                            (isolation ACLs deny the isolated UID write
                             access to the controller-owned cron/state trees,
                             so the right behaviour per v0.5 §10.1 is to
                             record a structured skip. Expanding the ACL
                             contract is tracked separately.)
                     └─ exec bridge-memory.py harvest-daily \
                          --agent … --home … --workdir … \
                          --sidecar-out "$CRON_REQUEST_DIR/authoritative-memory-daily.json"
                            └─ writes manifest atomically
                            └─ writes sidecar atomically (RESULT_SCHEMA-compliant)
                            └─ emits same JSON on stdout for LLM relay
        ├─ sidecar is preferred source (parse_claude_output is fallback)
        ├─ exception path: re-attempt sidecar before returning error
        └─ writes result.json with `child_result_source` audit field
bridge-daemon.sh
  └─ reads CRON_RESULT_FILE on cron worker completion
  └─ if actions_taken contains "queue-backfill" → queue session refresh
     else → audit `session_refresh_skipped`
```

## 4. Manifest schema v1

Path: `state/memory-daily/<agent>/<date>.json`.

```json
{
  "schema": "memory-daily-manifest-v1",
  "agent": "<agent>",
  "date": "YYYY-MM-DD",
  "timezone": "Asia/Seoul",
  "state": "checked|queued|resolved|skipped-permission|disabled|escalated",
  "first_detected_at": "2026-04-23T03:00:12+09:00",
  "last_checked_at":   "2026-04-24T03:00:04+09:00",
  "resolved_at":       null,
  "attempts": 1,
  "aggregate_notified_at": null,
  "run_id": "<cron run id>",
  "daily_note": {
    "path": "<agent-home>/memory/YYYY-MM-DD.md",
    "status": "present|semantic-empty|missing",
    "size_bytes": 1234,
    "has_meta_marker": true,
    "meta_schema_version": 1,
    "session_count": 3,
    "writer_mix": {"session": 2, "cron": 1},
    "has_tag_line": false,
    "semantic_nonempty": true
  },
  "legacy_paths_checked": [
    {"path": "<agent-home>/users/default/memory/YYYY-MM-DD.md",
     "present": true, "non_empty": true}
  ],
  "legacy_note_present": true,
  "activity": {
    "strong": {"transcript_sessions": [...]},
    "medium": {
      "queue_task_ids": [329, 331],
      "ingested_captures_non_precompact": ["<home>/raw/captures/ingested/….json"]
    },
    "weak": {
      "precompact_captures": ["<home>/raw/captures/ingested/….json"],
      "git_commits": ["abc1234", "def5678"]
    }
  },
  "decision": {
    "source_confidence": "strong|medium|weak|none",
    "action": "ok|queue-backfill|no-op|skip",
    "reason_code": null
  },
  "task": {
    "current_task_id": 333,
    "current_task_status": "queued",
    "last_task_id": null,
    "last_task_closed_at": null,
    "requeue_after": null
  }
}
```

Notes:

- `daily_note` field set reflects v0.7 §2 alignment with the actual
  `bridge-memory.py` daily-note format (meta marker + session count +
  writer_mix dict).
- `writer_mix` is a `{session: int, cron: int}` count map.
- `legacy_note_present` exists for the transitional period; canonical path
  alignment (`users/default/memory` vs `<home>/memory`) is tracked separately.
- Atomic write: `<file>.tmp.<pid>` → `os.replace` (see `_atomic_write_json`).

## 5. State machine

```
entry
├─ gate off                                              → state=disabled, action=skip
├─ sudo wrap failed (linux-user isolation)               → state=skipped-permission, action=skip
│                                                          (merges (agent,date) into admin-aggregate-skip)
├─ canonical note present + non-empty                    → state=checked, action=ok
├─ canonical missing/empty + legacy present + non-empty  → state=checked, action=no-op
├─ canonical missing/empty + strong OR medium activity   → state=queued, action=queue-backfill
├─ canonical missing/empty + weak-only activity          → state=checked, action=no-op
└─ canonical missing/empty + no activity                 → state=checked, action=no-op

resolution (next run carries over previous manifest)
├─ prev.state=queued + current canonical non-empty       → state=resolved
├─ prev.state=queued + prev task open                    → DEDUPE
├─ prev.state=queued + task closed < 24h + note missing  → cooldown, DEDUPE
├─ prev.state=queued + task closed ≥ 24h + note missing  → re-queue, attempts+=1
└─ attempts > 3                                          → state=escalated
```

## 6. Aggregate state

- `state/memory-daily/admin-aggregate-skip.json` — permission-skip aggregate.
- `state/memory-daily/admin-aggregate-escalated.json` — attempts>3 aggregate.

Both use `_merge_aggregate_state(path, merger)` with `fcntl.flock` for exclusive
access (see `bridge-memory.py:2371`). Schema:

```json
{
  "schema": "memory-daily-admin-aggregate-v1",
  "last_notified_at": "2026-04-23T03:00:12+09:00",
  "open_task_id": 456,
  "window_start": "2026-04-22T03:00:00+09:00",
  "by_day": {
    "2026-04-22": {
      "agents": ["patch", "librarian"],
      "first_seen_at": "…",
      "last_seen_at": "…"
    }
  }
}
```

A newly appearing `(agent, date)` pair triggers create-or-update of the admin
aggregate task (`[memory-daily-skip-admin]` or `[memory-daily-escalated]`).
Inside a 24h window with no new pair, `last_notified_at` is carried forward
without re-touching the task.

## 7. Daemon gating contract

`bridge-daemon.sh` cron_worker_complete handler only queues a session refresh
when the harvester backfilled the queue. The check is:

```bash
if [[ "${CRON_FAMILY:-}" == "memory-daily" && "${CRON_RUN_STATE:-}" == "success" ]]; then
  if bridge_agent_memory_daily_refresh_enabled "$TASK_ASSIGNED_TO"; then
    if bridge_cron_actions_taken_contains "${CRON_RESULT_FILE:-}" "queue-backfill"; then
      bridge_agent_note_memory_daily_refresh "$TASK_ASSIGNED_TO" "$run_id" "${CRON_SLOT:-}"
      bridge_audit_log daemon session_refresh_queued …
    else
      bridge_audit_log daemon session_refresh_skipped … --detail reason=no_queue_backfill_action
    fi
  fi
fi
```

The helper `bridge_cron_actions_taken_contains` (in `lib/bridge-cron.sh`) reads
`result.json`, parses `actions_taken`, and returns exit 0 iff the action is
present.

`process_memory_daily_refresh_requests` clears any stuck pending refresh for a
disabled agent **before** the gate skip, emitting a
`session_refresh_pending_cleared` audit with `reason=gate_off`.

Source-of-truth ordering inside the cron runner (v0.9 §2):

1. `run_claude` completes.
2. For `memory-daily` family, if
   `<request_file>/authoritative-memory-daily.json` exists, load + validate it
   and use that as `child_result` (`child_result_source=authoritative-sidecar`).
3. Otherwise fall back to `parse_claude_output(stdout)`
   (`child_result_source=child-fallback` for the memory-daily family, `child`
   for others).
4. Exception path: `parse_claude_output` failure retries the sidecar once more
   (`child_result_source=authoritative-sidecar-after-parse-error`).
5. `final_state` is recalculated after sidecar recovery so a valid sidecar
   rescues a parse error.

`result.json` carries `child_result_source` and, when applicable, a
`sidecar_error_note` for audit.

## 8. Opt-out

Per-agent:

```bash
# agent-roster.local.sh
BRIDGE_AGENT_MEMORY_DAILY_REFRESH[<agent>]=0
```

The bash gate helper at `lib/bridge-agents.sh::bridge_agent_memory_daily_refresh_enabled`
enforces this at daemon dispatch time. Re-running
`bootstrap-memory-system.sh --apply` after disabling the gate deletes the
stale cron for that agent.

For the Python harvester's fallback probe (invoked outside a sourced roster),
set `BRIDGE_AGENT_MEMORY_DAILY_REFRESH_<agent>=0` in the environment.

## 9. Audit fields

`result.json` written by `bridge-cron-runner.py`:

- `child_result_source` ∈ `{authoritative-sidecar,
  authoritative-sidecar-after-parse-error, child-fallback, child}`.
- `sidecar_error_note` — present only when sidecar load/validate failed and
  fallback to child stdout was taken.

Daemon audit events:

- `session_refresh_queued` — harvester produced `queue-backfill`.
- `session_refresh_skipped` — family=memory-daily with no backfill action.
  Detail `reason=no_queue_backfill_action`.
- `session_refresh_pending_cleared` — gate-off cleanup of a stale pending
  refresh. Detail `reason=gate_off`.

## 10. Linux-user isolation

When `agent show --json` reports `isolation.mode=linux-user` and
`isolation.os_user != $(id -un)`, the stub forwards `--skipped-permission
--os-user <os_user>` to the Python harvester, which writes a minimal manifest
with `state=skipped-permission`, merges `(agent, date)` into
`admin-aggregate-skip.json`, and exits 0 so the cron run records a structured
skip rather than an engine error.

The harvester does **not** `sudo -u <os_user>` re-exec itself under
isolation. `bridge_linux_prepare_agent_isolation()`
(`lib/bridge-agents.sh:952~1003`) strips ACLs on the controller-owned global
state / cron trees (`BRIDGE_STATE_DIR`, `BRIDGE_LOG_DIR`) and only re-grants
per-agent runtime / log / request / response dirs. Re-executing the harvester
as the isolated UID would therefore fail to persist either
`state/memory-daily/<agent>/<date>.json` or the sidecar under
`state/cron/runs/.../authoritative-memory-daily.json`. Until that ACL
contract is expanded to cover memory-daily state + the cron per-run dir
(tracked as a separate issue), isolation-mismatch runs are
structurally-skipped.

The `--transcripts-home <path>` override on `bridge-memory.py harvest-daily`
is kept for smoke tests and manual invocation; production cron invocations do
not use it.

When sudoers configuration changes unblock isolated operation, follow-up work
is expected to (a) expand `bridge_linux_prepare_agent_isolation` ACLs to the
memory-daily manifest dir and per-run cron dirs, and (b) re-introduce a sudo
re-exec in the stub. See [`docs/linux-host-acceptance.md`](../linux-host-acceptance.md).

## 11. Known limits

- Canonical path alignment (`users/default/memory` vs `<home>/memory`) is a
  separate issue. The harvester probes the legacy path read-only to suppress
  false-positive backfills; it does not migrate.
- The primary daily-note writer is session `/wrap-up`, tracked in
  [`auto-memory-isolation.md`](auto-memory-isolation.md). This harvester does
  not write notes — only queues backfill tasks.
- Cron rebalancing via `agb cron rebalance-memory-daily` is a separate
  operational surface and not invoked by bootstrap.
