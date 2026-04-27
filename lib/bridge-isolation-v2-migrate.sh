#!/usr/bin/env bash
# bridge-isolation-v2-migrate.sh — Operator tooling for migrating a legacy
# Agent Bridge install onto the v2 layout (BRIDGE_LAYOUT=v2, BRIDGE_DATA_ROOT=...).
#
# Public entrypoint: bridge_isolation_v2_migrate_cli (dispatched from
# bridge-migrate.sh). Subcommands:
#   dry-run --data-root <path>            print plan + manifest preview, no mutation
#   apply   --data-root <path> --yes      stop, mirror, normalize, marker flip, restart
#   rollback --yes                        marker remove + restart legacy
#   commit  --yes                         delete legacy paths recorded in manifest
#   status                                print current marker + manifest summary
#
# Contracts (agreed via 9 dev-codex review rounds):
#   * --apply / --rollback refuse to run when invoked from inside a managed
#     agent session whose own id appears in the active snapshot.
#   * Active-agent stop uses real CLI primitives (per-agent `bridge-agent.sh
#     stop <agent>`, then plain `bridge-daemon.sh stop` after active=0).
#   * Daemon presence/absence is verified via process-based polling
#     (`bridge_daemon_all_pids`), bounded with an integer attempt counter.
#   * Mirror is real copy (rsync -aHX --numeric-ids --no-links). No hardlinks
#     so subsequent chgrp/chmod can not mutate legacy inodes.
#   * Manifest schema (TSV, 9 columns):
#       ts  mapping_id  legacy_src_abs  v2_dst_abs  bytes  sha256_legacy
#       sha256_v2  verify_status  delete_eligible
#     commit candidate filter: $8 == "ok" && $9 == "1".
#   * Profile/memory/skills mirror to v2 workdir with delete_eligible=0 —
#     install-root retained as frozen snapshot, runtime reads from v2 workdir.
#   * Plugin catalog: only controller-managed (~/.claude/plugins/
#     installed_plugins.json + known_marketplaces.json + marketplaces/)
#     copied to $BRIDGE_DATA_ROOT/shared/plugins-cache/. Per-UID plugins/data
#     never merged into shared.
#   * Marker file written via tmpfile + atomic mv; loaded only after strict
#     validation in lib/bridge-marker-bootstrap.sh.
#   * Explicit BRIDGE_AGENT_PROFILE_HOME override that does not match the
#     v2 workdir is treated as roster intent — preflight prints a remediation
#     warning in dry-run and dies in apply, never silently rewrites roster.
#   * Group changes use sudo metadata ops; current shell's id -nG is
#     untrusted (warm-cache problem). Postflight probes each agent UID and
#     the controller via fresh `sudo -u <user> id -nG`.
#   * Self-cleanup in this module never installs a long-lived EXIT trap
#     (would clobber the existing COPY_JSON trap conventions in scripts/).
#
# shellcheck shell=bash disable=SC2034

# ---------------------------------------------------------------------------
# 0. helper: paths and constants
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_state_dir() {
  printf '%s/migration' "${BRIDGE_STATE_DIR}"
}

bridge_isolation_v2_migrate_active_snapshot_path() {
  printf '%s/active-agents.snapshot' "$(bridge_isolation_v2_migrate_state_dir)"
}

bridge_isolation_v2_migrate_lock_path() {
  printf '%s/migrate-isolation-v2.lock' "$(bridge_isolation_v2_migrate_state_dir)"
}

bridge_isolation_v2_migrate_manifest_path() {
  # Single rolling manifest. apply truncates + appends; commit reads.
  printf '%s/manifest.tsv' "$(bridge_isolation_v2_migrate_state_dir)"
}

bridge_isolation_v2_migrate_backup_tarball_path() {
  local stamp="$1"
  printf '%s/legacy-backup-%s.tar.zst' "$(bridge_isolation_v2_migrate_state_dir)" "$stamp"
}

bridge_isolation_v2_migrate_mkstate() {
  install -d -m 0750 "$(bridge_isolation_v2_migrate_state_dir)" 2>/dev/null \
    || mkdir -p "$(bridge_isolation_v2_migrate_state_dir)"
}

# ---------------------------------------------------------------------------
# 1. self-stop guard
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_self_stop_guard() {
  local self="${BRIDGE_AGENT_ID:-}"
  [[ -n "$self" ]] || return 0

  local snapshot_path="$1"
  [[ -f "$snapshot_path" ]] || return 0

  local line
  while IFS= read -r line; do
    if [[ "$line" == "$self" ]]; then
      bridge_die "self-stop guard: '$self' is in the active snapshot. \
Run this command from an out-of-band controller shell (unset BRIDGE_AGENT_ID), \
not from inside an Agent Bridge agent session. No state has been mutated."
    fi
  done < "$snapshot_path"
  return 0
}

# ---------------------------------------------------------------------------
# 2. lock + active-agent snapshot
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_acquire_lock() {
  bridge_isolation_v2_migrate_mkstate
  local lock_path
  lock_path="$(bridge_isolation_v2_migrate_lock_path)"
  exec 9>"$lock_path"
  if ! flock -n 9; then
    bridge_die "another isolation-v2 migrate operation is in progress (lock=$lock_path)"
  fi
}

bridge_isolation_v2_migrate_capture_active_snapshot() {
  bridge_isolation_v2_migrate_mkstate
  local snapshot
  snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"
  bridge_active_agent_ids > "$snapshot"
}

# ---------------------------------------------------------------------------
# 3. profile_home override preflight
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_check_profile_home_overrides() {
  # Returns 0 when no agent in the snapshot has a misaligned explicit
  # BRIDGE_AGENT_PROFILE_HOME. Returns 1 otherwise; warns to stderr.
  # Caller is responsible for the dry-run-vs-apply policy decision.
  local snapshot_path="$1"
  local data_root="$2"
  [[ -f "$snapshot_path" && -n "$data_root" ]] || return 0

  local agent override expected mismatch=0
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    override="${BRIDGE_AGENT_PROFILE_HOME[$agent]-}"
    [[ -n "$override" ]] || continue
    override="$(bridge_expand_user_path "$override")"
    expected="$data_root/agents/$agent/workdir"
    if [[ "$override" != "$expected" ]]; then
      bridge_warn "agent '$agent' has explicit BRIDGE_AGENT_PROFILE_HOME=$override which is not the v2 workdir ($expected). agent-bridge profile deploy will land in the wrong location after marker flip. Edit roster (agent-roster.local.sh or agent-roster.sh) to unset or align this entry, then re-run --apply."
      mismatch=1
    fi
  done < "$snapshot_path"
  return $(( mismatch ))
}

# ---------------------------------------------------------------------------
# 4. mirror map enumeration
# ---------------------------------------------------------------------------

# Print one TSV row per planned mirror op:
#   <mapping_id> TAB <legacy_src> TAB <v2_dst> TAB <delete_eligible>
# Only paths whose legacy src exists are emitted. v2 dst dirs are created
# at mirror time, not here.
bridge_isolation_v2_migrate_emit_plan() {
  local data_root="$1"
  local snapshot_path="$2"
  local controller_user="${SUDO_USER:-${USER:-}}"
  local controller_home
  controller_home="$(bridge_linux_resolve_user_home "$controller_user" 2>/dev/null \
    || printf '%s' "$HOME")"

  # ---- per-agent rows ----
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    local legacy_root="$BRIDGE_AGENT_HOME_ROOT/$agent"
    local v2_agent_root="$data_root/agents/$agent"

    # runtime, delete_eligible=1
    bridge_isolation_v2_migrate_emit_row \
      "agent_claude:$agent" "$legacy_root/.claude" "$v2_agent_root/home/.claude" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_discord:$agent" "$legacy_root/.discord" "$v2_agent_root/workdir/.discord" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_telegram:$agent" "$legacy_root/.telegram" "$v2_agent_root/workdir/.telegram" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_teams:$agent" "$legacy_root/.teams" "$v2_agent_root/workdir/.teams" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_ms365:$agent" "$legacy_root/.ms365" "$v2_agent_root/workdir/.ms365" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_credentials:$agent" "$legacy_root/credentials" "$v2_agent_root/credentials" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_workdir:$agent" "$legacy_root/workdir" "$v2_agent_root/workdir" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_logs:$agent" "$legacy_root/logs" "$v2_agent_root/logs" 1

    # dual-read (delete_eligible=0)
    bridge_isolation_v2_migrate_emit_row \
      "agent_session_type:$agent" "$legacy_root/SESSION-TYPE.md" "$v2_agent_root/workdir/SESSION-TYPE.md" 0
    bridge_isolation_v2_migrate_emit_row \
      "agent_next_session:$agent" "$legacy_root/NEXT-SESSION.md" "$v2_agent_root/workdir/NEXT-SESSION.md" 0

    # profile / instruction (delete_eligible=0)
    local pf
    for pf in CLAUDE.md MEMORY.md SKILLS.md SOUL.md HEARTBEAT.md \
              MEMORY-SCHEMA.md COMMON-INSTRUCTIONS.md CHANGE-POLICY.md TOOLS.md; do
      bridge_isolation_v2_migrate_emit_row \
        "agent_profile_${pf}:$agent" "$legacy_root/$pf" "$v2_agent_root/workdir/$pf" 0
    done

    # profile / skills / memory subtrees (delete_eligible=0)
    local sd
    for sd in .agents memory users references skills; do
      bridge_isolation_v2_migrate_emit_row \
        "agent_subtree_${sd}:$agent" "$legacy_root/$sd" "$v2_agent_root/workdir/$sd" 0
    done
  done < "$snapshot_path"

  # ---- global rows ----
  bridge_isolation_v2_migrate_emit_row \
    "runtime_root" "$BRIDGE_RUNTIME_ROOT" "$data_root/state/runtime" 1
  bridge_isolation_v2_migrate_emit_row \
    "runtime_shared" "$BRIDGE_RUNTIME_SHARED_DIR" "$data_root/shared" 1
  if [[ "$BRIDGE_WORKTREE_ROOT" == "$BRIDGE_HOME"/* ]]; then
    bridge_isolation_v2_migrate_emit_row \
      "worktree_root" "$BRIDGE_WORKTREE_ROOT" "$data_root/worktrees" 1
  fi

  # ---- plugin catalog (controller-managed only) ----
  if [[ -n "$controller_home" ]]; then
    local plugins_root="$controller_home/.claude/plugins"
    if [[ -f "$plugins_root/installed_plugins.json" ]]; then
      bridge_isolation_v2_migrate_emit_row \
        "plugin_installed_json" \
        "$plugins_root/installed_plugins.json" \
        "$data_root/shared/plugins-cache/installed_plugins.json" 1
    fi
    if [[ -f "$plugins_root/known_marketplaces.json" ]]; then
      bridge_isolation_v2_migrate_emit_row \
        "plugin_known_markets_json" \
        "$plugins_root/known_marketplaces.json" \
        "$data_root/shared/plugins-cache/known_marketplaces.json" 1
    fi
    if [[ -d "$plugins_root/marketplaces" ]]; then
      bridge_isolation_v2_migrate_emit_row \
        "plugin_marketplaces_tree" \
        "$plugins_root/marketplaces" \
        "$data_root/shared/plugins-cache/marketplaces" 1
    fi
  fi
}

bridge_isolation_v2_migrate_emit_row() {
  local mapping_id="$1" legacy_src="$2" v2_dst="$3" delete_eligible="$4"
  [[ -e "$legacy_src" ]] || return 0
  printf '%s\t%s\t%s\t%s\n' "$mapping_id" "$legacy_src" "$v2_dst" "$delete_eligible"
}

# ---------------------------------------------------------------------------
# 5. mirror execution + manifest
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_sha256_of() {
  # Print sha256 of a path. For files, hash the bytes. For dirs, hash
  # the sorted concatenation of (relpath, sha256) lines so two trees
  # with identical content compare equal regardless of inode/atime.
  local target="$1"
  if [[ -f "$target" && ! -L "$target" ]]; then
    sha256sum "$target" 2>/dev/null | awk '{print $1}'
    return
  fi
  if [[ -d "$target" ]]; then
    (
      cd "$target" 2>/dev/null || exit 0
      find . -type f -print0 2>/dev/null \
        | sort -z \
        | xargs -0 sha256sum 2>/dev/null
    ) | sha256sum | awk '{print $1}'
    return
  fi
  printf 'absent'
}

bridge_isolation_v2_migrate_bytes_of() {
  local target="$1"
  if [[ -f "$target" && ! -L "$target" ]]; then
    stat -c '%s' "$target" 2>/dev/null || printf '0'
    return
  fi
  if [[ -d "$target" ]]; then
    du -sb "$target" 2>/dev/null | awk '{print $1}'
    return
  fi
  printf '0'
}

bridge_isolation_v2_migrate_mirror_one() {
  local mapping_id="$1" legacy_src="$2" v2_dst="$3" delete_eligible="$4"
  local manifest_path="$5"
  local ts bytes sha_legacy sha_v2 verify

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  bytes="$(bridge_isolation_v2_migrate_bytes_of "$legacy_src")"
  sha_legacy="$(bridge_isolation_v2_migrate_sha256_of "$legacy_src")"

  # Make destination parent.
  local dst_parent
  if [[ -d "$legacy_src" ]]; then
    mkdir -p "$v2_dst" 2>/dev/null
  else
    dst_parent="$(dirname "$v2_dst")"
    mkdir -p "$dst_parent" 2>/dev/null
  fi

  # Real copy. -a preserves perm/owner/time. -X xattrs. --numeric-ids
  # avoids name lookups on the destination side. --no-links so symlinks
  # are followed (rare in the layouts we mirror; if a symlink is later
  # discovered we treat it as runtime).
  local rc=0
  if [[ -d "$legacy_src" ]]; then
    rsync -aHX --numeric-ids --no-links --delete-excluded \
      "$legacy_src/" "$v2_dst/" >/dev/null 2>&1 || rc=$?
  else
    rsync -aHX --numeric-ids --no-links \
      "$legacy_src" "$v2_dst" >/dev/null 2>&1 || rc=$?
  fi
  if (( rc != 0 )); then
    verify="rsync_fail_$rc"
    sha_v2="absent"
  else
    sha_v2="$(bridge_isolation_v2_migrate_sha256_of "$v2_dst")"
    if [[ "$sha_legacy" == "$sha_v2" ]]; then
      verify="ok"
    else
      verify="checksum_mismatch"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$mapping_id" "$legacy_src" "$v2_dst" "$bytes" \
    "$sha_legacy" "$sha_v2" "$verify" "$delete_eligible" \
    >> "$manifest_path"

  [[ "$verify" == "ok" ]] || return 1
  return 0
}

bridge_isolation_v2_migrate_mirror_all() {
  local data_root="$1" snapshot_path="$2" manifest_path="$3"
  : > "$manifest_path"

  local row mapping_id legacy_src v2_dst delete_eligible
  local fail=0
  while IFS=$'\t' read -r mapping_id legacy_src v2_dst delete_eligible; do
    [[ -n "$mapping_id" ]] || continue
    if ! bridge_isolation_v2_migrate_mirror_one \
        "$mapping_id" "$legacy_src" "$v2_dst" "$delete_eligible" "$manifest_path"; then
      fail=$(( fail + 1 ))
    fi
  done < <(bridge_isolation_v2_migrate_emit_plan "$data_root" "$snapshot_path")

  if (( fail > 0 )); then
    bridge_warn "mirror: $fail row(s) failed (see $manifest_path verify_status column)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 6. group ensure + post-flight probe
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_ensure_groups() {
  local snapshot_path="$1"
  local _g
  for _g in "ab-shared" "ab-controller"; do
    bridge_isolation_v2_ensure_group "$_g" || return 1
  done
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    bridge_isolation_v2_ensure_group "$(bridge_isolation_v2_agent_group_name "$agent")" \
      || return 1
  done < "$snapshot_path"
  return 0
}

bridge_isolation_v2_migrate_postflight_groups() {
  local snapshot_path="$1"
  local controller_user="${SUDO_USER:-${USER:-}}"
  local agent groups os_user
  local mismatch=0

  # Controller fresh probe.
  if [[ -n "$controller_user" ]]; then
    groups="$(sudo -n -u "$controller_user" id -nG 2>/dev/null || true)"
    if [[ -z "$groups" ]]; then
      bridge_warn "postflight: cannot fresh-probe controller groups for $controller_user"
      mismatch=1
    fi
  fi

  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    [[ -n "$os_user" ]] || continue
    groups="$(sudo -n -u "$os_user" id -nG 2>/dev/null || true)"
    if [[ -z "$groups" ]]; then
      bridge_warn "postflight: cannot fresh-probe groups for $os_user (agent $agent)"
      mismatch=1
      continue
    fi
    local agent_group
    agent_group="$(bridge_isolation_v2_agent_group_name "$agent")"
    if ! grep -qw "$agent_group" <<<"$groups"; then
      bridge_warn "postflight: $os_user (agent $agent) missing group $agent_group; got: $groups"
      mismatch=1
    fi
    if ! grep -qw "ab-shared" <<<"$groups"; then
      bridge_warn "postflight: $os_user (agent $agent) missing group ab-shared; got: $groups"
      mismatch=1
    fi
  done < "$snapshot_path"

  return $(( mismatch ))
}

# ---------------------------------------------------------------------------
# 7. daemon poll (process-based, bounded, integer attempts)
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_wait_daemon_gone() {
  local timeout_s="${1:-10}"
  local interval_s=0.2
  local max_attempts=$(( timeout_s * 5 ))
  local attempt
  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    if [[ -z "$(bridge_daemon_all_pids 2>/dev/null || true)" ]]; then
      return 0
    fi
    sleep "$interval_s"
  done
  bridge_die "daemon stop verification failed: still running PIDs after ${timeout_s}s"
}

bridge_isolation_v2_migrate_wait_daemon_present() {
  local timeout_s="${1:-10}"
  local interval_s=0.2
  local max_attempts=$(( timeout_s * 5 ))
  local attempt
  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    if [[ -n "$(bridge_daemon_all_pids 2>/dev/null || true)" ]]; then
      return 0
    fi
    sleep "$interval_s"
  done
  bridge_die "daemon failed to come up within ${timeout_s}s after restart"
}

# ---------------------------------------------------------------------------
# 8. orchestrate stop / restart
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_orchestrate_stop() {
  local snapshot_path="$1"

  # Per-agent stop.
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-agent.sh" stop "$agent" >/dev/null 2>&1 \
      || bridge_warn "stop failed for agent '$agent' — continuing; will be skipped at restart"
  done < "$snapshot_path"

  # Verify zero active.
  local remaining
  remaining="$(bridge_active_agent_ids | wc -l | tr -d ' ')"
  if [[ "$remaining" =~ ^[0-9]+$ ]] && (( remaining > 0 )); then
    bridge_die "agents still active after per-agent stop loop: $remaining"
  fi

  # Plain daemon stop (active=0 now → no --force needed).
  "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-daemon.sh" stop >/dev/null 2>&1 \
    || bridge_die "daemon stop returned non-zero"
  bridge_isolation_v2_migrate_wait_daemon_gone 10
}

bridge_isolation_v2_migrate_orchestrate_restart() {
  local snapshot_path="$1"

  "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-daemon.sh" start >/dev/null 2>&1 \
    || bridge_die "daemon restart failed"
  bridge_isolation_v2_migrate_wait_daemon_present 10

  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-agent.sh" start "$agent" >/dev/null 2>&1 \
      || bridge_warn "restart failed for agent '$agent' — operator will need to start manually"
  done < "$snapshot_path"
}

# ---------------------------------------------------------------------------
# 9. marker write (atomic, validated content)
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_marker_write() {
  local data_root="$1"
  local marker_path
  marker_path="$(bridge_isolation_v2_marker_path)"

  bridge_isolation_v2_migrate_mkstate
  install -d -m 0750 "$(dirname "$marker_path")" 2>/dev/null \
    || mkdir -p "$(dirname "$marker_path")"

  local tmp="${marker_path}.tmp.$$"
  {
    printf 'BRIDGE_LAYOUT=%s\n' "$(printf %q "v2")"
    printf 'BRIDGE_DATA_ROOT=%s\n' "$(printf %q "$data_root")"
  } > "$tmp"

  chmod 0640 "$tmp" || { rm -f "$tmp"; bridge_die "marker chmod failed"; }
  # Owner: leave as caller (controller). Group bit 0 prevents group write
  # already; ownership is inherited from caller process which is the
  # controller running the migration.
  mv -f "$tmp" "$marker_path" || bridge_die "marker mv failed"

  if ! bridge_isolation_v2_marker_validate "$marker_path"; then
    rm -f "$marker_path"
    bridge_die "marker validation failed after write — refusing to leave half-formed marker on disk"
  fi
}

bridge_isolation_v2_migrate_marker_remove() {
  local marker_path
  marker_path="$(bridge_isolation_v2_marker_path)"
  rm -f "$marker_path"
}

# ---------------------------------------------------------------------------
# 10. legacy data path enumeration (commit candidate filter)
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_legacy_data_paths() {
  local manifest_path
  manifest_path="$(bridge_isolation_v2_migrate_manifest_path)"
  [[ -f "$manifest_path" ]] || return 0
  awk -F'\t' '$8 == "ok" && $9 == "1" { print $3 }' "$manifest_path"
}

# ---------------------------------------------------------------------------
# 11. entrypoints
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_dry_run() {
  local data_root="$1"
  bridge_isolation_v2_migrate_acquire_lock
  bridge_isolation_v2_migrate_capture_active_snapshot
  local snapshot
  snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"

  printf '== isolation-v2 migrate dry-run ==\n'
  printf 'data_root: %s\n' "$data_root"
  printf 'active agents: %s\n' "$(wc -l < "$snapshot" | tr -d ' ')"
  printf '\n-- mirror plan (mapping_id  src  dst  delete_eligible) --\n'
  bridge_isolation_v2_migrate_emit_plan "$data_root" "$snapshot"

  printf '\n-- profile_home overrides --\n'
  if bridge_isolation_v2_migrate_check_profile_home_overrides "$snapshot" "$data_root"; then
    printf '(none misaligned)\n'
  else
    printf '(see warnings above; --apply will refuse until roster is aligned)\n'
  fi
}

bridge_isolation_v2_migrate_apply() {
  local data_root="$1"
  [[ -n "$data_root" && "${data_root:0:1}" == "/" ]] \
    || bridge_die "--apply requires --data-root <absolute-path>"
  if bridge_isolation_v2_active; then
    bridge_warn "v2 already active — apply is idempotent only when --data-root matches; proceeding will re-mirror."
  fi

  bridge_isolation_v2_migrate_acquire_lock
  bridge_isolation_v2_migrate_capture_active_snapshot
  local snapshot
  snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"

  bridge_isolation_v2_migrate_self_stop_guard "$snapshot"

  if ! bridge_isolation_v2_migrate_check_profile_home_overrides "$snapshot" "$data_root"; then
    bridge_die "explicit BRIDGE_AGENT_PROFILE_HOME override(s) misaligned; see warnings above; align roster and retry"
  fi

  install -d -m 0755 "$data_root" 2>/dev/null || mkdir -p "$data_root"

  bridge_isolation_v2_migrate_orchestrate_stop "$snapshot"

  bridge_isolation_v2_migrate_ensure_groups "$snapshot" \
    || bridge_die "group ensure failed"

  local manifest
  manifest="$(bridge_isolation_v2_migrate_manifest_path)"
  if ! bridge_isolation_v2_migrate_mirror_all "$data_root" "$snapshot" "$manifest"; then
    bridge_warn "mirror reported failures — marker NOT written; legacy tree intact; restarting agents on legacy"
    bridge_isolation_v2_migrate_orchestrate_restart "$snapshot"
    bridge_die "apply aborted at mirror step (manifest=$manifest)"
  fi

  bridge_isolation_v2_migrate_marker_write "$data_root"

  bridge_isolation_v2_migrate_orchestrate_restart "$snapshot"

  if ! bridge_isolation_v2_migrate_postflight_groups "$snapshot"; then
    bridge_warn "post-flight group probe reported issues — investigate before --commit"
  fi

  printf 'apply ok: marker=%s manifest=%s\n' \
    "$(bridge_isolation_v2_marker_path)" "$manifest"
}

bridge_isolation_v2_migrate_rollback() {
  bridge_isolation_v2_migrate_acquire_lock
  bridge_isolation_v2_migrate_capture_active_snapshot
  local snapshot
  snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"

  bridge_isolation_v2_migrate_self_stop_guard "$snapshot"

  bridge_isolation_v2_migrate_orchestrate_stop "$snapshot"
  bridge_isolation_v2_migrate_marker_remove
  bridge_isolation_v2_migrate_orchestrate_restart "$snapshot"

  printf 'rollback ok: marker removed; legacy tree intact\n'
}

bridge_isolation_v2_migrate_commit() {
  bridge_isolation_v2_migrate_acquire_lock

  if ! bridge_isolation_v2_active; then
    bridge_die "commit requires v2 active (marker present + valid)"
  fi

  local manifest
  manifest="$(bridge_isolation_v2_migrate_manifest_path)"
  [[ -f "$manifest" ]] || bridge_die "no manifest at $manifest — apply must have run first"

  local stamp tarball candidate
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  tarball="$(bridge_isolation_v2_migrate_backup_tarball_path "$stamp")"

  local -a candidates=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -e "$candidate" ]] || continue
    candidates+=("$candidate")
  done < <(bridge_isolation_v2_migrate_legacy_data_paths)

  if (( ${#candidates[@]} == 0 )); then
    printf 'commit: nothing to delete (no manifest rows with verify_status=ok && delete_eligible=1)\n'
    return 0
  fi

  printf 'commit candidates (%d):\n' "${#candidates[@]}"
  printf '  %s\n' "${candidates[@]}"

  if [[ "${BRIDGE_ISOLATION_V2_MIGRATE_YES:-0}" != "1" ]]; then
    bridge_die "refusing to delete without --yes"
  fi

  # Backup tarball first.
  if command -v zstd >/dev/null 2>&1; then
    tar --zstd -cf "$tarball" "${candidates[@]}" 2>/dev/null \
      || bridge_die "backup tarball creation failed"
  else
    tarball="${tarball%.zst}"
    tar -cf "$tarball" "${candidates[@]}" 2>/dev/null \
      || bridge_die "backup tarball creation failed"
  fi
  chmod 0640 "$tarball" || true

  # Delete.
  local cand
  for cand in "${candidates[@]}"; do
    rm -rf -- "$cand" || bridge_warn "delete failed: $cand"
  done

  printf 'commit ok: deleted %d path(s); backup at %s\n' "${#candidates[@]}" "$tarball"
}

bridge_isolation_v2_migrate_status() {
  local marker_path
  marker_path="$(bridge_isolation_v2_marker_path)"
  printf 'marker: %s\n' "$marker_path"
  if [[ -f "$marker_path" ]]; then
    if bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
      printf 'marker_valid: yes\n'
    else
      printf 'marker_valid: no\n'
    fi
    printf '---\n'
    cat "$marker_path"
    printf '---\n'
  else
    printf 'marker_valid: absent\n'
  fi
  printf 'isolation_v2_active: %s\n' \
    "$(bridge_isolation_v2_active && echo yes || echo no)"

  local manifest
  manifest="$(bridge_isolation_v2_migrate_manifest_path)"
  if [[ -f "$manifest" ]]; then
    local total ok delete_elig
    total="$(wc -l < "$manifest" | tr -d ' ')"
    ok="$(awk -F'\t' '$8 == "ok"' "$manifest" | wc -l | tr -d ' ')"
    delete_elig="$(awk -F'\t' '$8 == "ok" && $9 == "1"' "$manifest" | wc -l | tr -d ' ')"
    printf 'manifest: %s  total=%s  ok=%s  delete_eligible=%s\n' \
      "$manifest" "$total" "$ok" "$delete_elig"
  else
    printf 'manifest: (none)\n'
  fi
}

# ---------------------------------------------------------------------------
# 12. CLI dispatch
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_cli() {
  local sub="${1:-}"
  shift || true

  case "$sub" in
    dry-run)
      local data_root=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --data-root) data_root="$2"; shift 2 ;;
          *) bridge_die "unknown dry-run option: $1" ;;
        esac
      done
      [[ -n "$data_root" ]] || bridge_die "Usage: agent-bridge migrate isolation-v2 dry-run --data-root <path>"
      bridge_isolation_v2_migrate_dry_run "$data_root"
      ;;
    apply)
      local data_root=""
      local yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --data-root) data_root="$2"; shift 2 ;;
          --yes) yes=1; shift ;;
          *) bridge_die "unknown apply option: $1" ;;
        esac
      done
      (( yes == 1 )) || bridge_die "Usage: agent-bridge migrate isolation-v2 apply --data-root <path> --yes"
      bridge_isolation_v2_migrate_apply "$data_root"
      ;;
    rollback)
      local yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) yes=1; shift ;;
          *) bridge_die "unknown rollback option: $1" ;;
        esac
      done
      (( yes == 1 )) || bridge_die "Usage: agent-bridge migrate isolation-v2 rollback --yes"
      bridge_isolation_v2_migrate_rollback
      ;;
    commit)
      local yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) yes=1; shift ;;
          *) bridge_die "unknown commit option: $1" ;;
        esac
      done
      (( yes == 1 )) || bridge_die "Usage: agent-bridge migrate isolation-v2 commit --yes"
      BRIDGE_ISOLATION_V2_MIGRATE_YES=1 bridge_isolation_v2_migrate_commit
      ;;
    status)
      bridge_isolation_v2_migrate_status
      ;;
    ""|-h|--help|help)
      cat <<'USAGE'
Usage: agent-bridge migrate isolation-v2 <subcommand> [options]
Subcommands:
  dry-run --data-root <path>       Print the legacy→v2 mirror plan + profile_home preflight (no mutation).
  apply   --data-root <path> --yes Stop active agents+daemon, mirror, ensure groups, write marker, restart.
  rollback --yes                   Stop, remove marker, restart on legacy. Idempotent on absent marker.
  commit  --yes                    Tar-zst backup + delete legacy paths recorded in manifest as
                                   verify_status=ok && delete_eligible=1.
  status                           Print marker + manifest summary.

Notes:
  - apply/rollback refuse when invoked from inside an Agent Bridge agent
    session whose own id is in the active snapshot (self-stop guard).
  - Run from an out-of-band controller shell with sudo available.
USAGE
      ;;
    *)
      bridge_die "unknown isolation-v2 subcommand: $sub"
      ;;
  esac
}
