#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/bridge-wave.sh — `agent-bridge wave` orchestration helpers.
#
# Phase 1.1 scope: dispatch (state + brief), list, show, templates,
# close-issue (placeholder). Worker startup, queue task creation, codex
# adapter, PR automation, main-agent feedback, policy loading, skill
# migration, and close-issue validation belong to Phases 1.2 - 1.6
# (see docs/design/wave-orchestration-plugin.md).
#
# Storage layout (per design §10):
#   $BRIDGE_STATE_DIR/waves/<wave-id>.json   — JSON SSOT
#   $BRIDGE_SHARED_DIR/waves/<wave-id>/      — briefs + README mirror
#     ├── README.md                          — auto-generated from JSON
#     └── <member-id>/brief.md               — per-member brief

bridge_wave_state_dir() {
  printf '%s/waves' "${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}"
}

bridge_wave_shared_dir() {
  printf '%s/waves' "${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}"
}

bridge_wave_python_helper() {
  printf '%s/bridge-wave.py' "$BRIDGE_SCRIPT_DIR"
}

bridge_wave_default_main_agent() {
  if [[ -n "${BRIDGE_AGENT_ID:-}" ]]; then
    printf '%s' "$BRIDGE_AGENT_ID"
    return 0
  fi
  if [[ -n "${BRIDGE_ADMIN_AGENT_ID:-}" ]]; then
    printf '%s' "$BRIDGE_ADMIN_AGENT_ID"
    return 0
  fi
  return 1
}

bridge_wave_close_keyword_lint() {
  # Block close-keyword (closes/fixes/resolves #N) in any of the given
  # files. Mechanical lint per design §5: the wave plugin never writes
  # close keywords; closing is gated through `wave close-issue`.
  local helper
  helper="$(bridge_wave_python_helper)"
  if [[ ! -x "$helper" && ! -r "$helper" ]]; then
    bridge_warn "wave_close_keyword_lint: bridge-wave.py not found at $helper"
    return 0
  fi
  python3 "$helper" close-keyword-scan "$@" >/dev/null
}

bridge_wave_dispatch() {
  local issue_or_brief=""
  local tracks=""
  local main_agent=""
  local worker_engine="claude"
  local reviewer="codex-rescue"
  local dry_run=0
  local json_out=0

  while (( $# > 0 )); do
    case "$1" in
      --tracks)         tracks="${2:-}"; shift 2 ;;
      --tracks=*)       tracks="${1#--tracks=}"; shift ;;
      --main-agent)     main_agent="${2:-}"; shift 2 ;;
      --main-agent=*)   main_agent="${1#--main-agent=}"; shift ;;
      --worker-engine)  worker_engine="${2:-}"; shift 2 ;;
      --worker-engine=*) worker_engine="${1#--worker-engine=}"; shift ;;
      --reviewer)       reviewer="${2:-}"; shift 2 ;;
      --reviewer=*)     reviewer="${1#--reviewer=}"; shift ;;
      --dry-run)        dry_run=1; shift ;;
      --json)           json_out=1; shift ;;
      -h|--help)
        cat <<EOF
agent-bridge wave dispatch <issue-or-brief> [--tracks A,B] [--main-agent <agent>] [--worker-engine claude|codex] [--reviewer <name>] [--dry-run] [--json]
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) bridge_die "wave dispatch: unknown option: $1" ;;
      *)
        if [[ -z "$issue_or_brief" ]]; then
          issue_or_brief="$1"
        else
          bridge_die "wave dispatch: extra positional arg: $1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$issue_or_brief" ]]; then
    bridge_die "wave dispatch: issue number or brief file required"
  fi

  if [[ -z "$main_agent" ]]; then
    if ! main_agent="$(bridge_wave_default_main_agent)"; then
      bridge_die "wave dispatch: --main-agent required (BRIDGE_AGENT_ID and BRIDGE_ADMIN_AGENT_ID both unset)"
    fi
  fi

  if [[ "$worker_engine" != "claude" && "$worker_engine" != "codex" ]]; then
    bridge_die "wave dispatch: --worker-engine must be claude or codex (got: $worker_engine)"
  fi

  local helper
  helper="$(bridge_wave_python_helper)"
  [[ -r "$helper" ]] || bridge_die "wave dispatch: bridge-wave.py missing at $helper"

  local wave_id
  wave_id="$(python3 "$helper" wave-id-generate "$issue_or_brief")" \
    || bridge_die "wave dispatch: wave-id-generate failed"

  local state_dir shared_dir state_file shared_wave_dir
  state_dir="$(bridge_wave_state_dir)"
  shared_dir="$(bridge_wave_shared_dir)"
  state_file="$state_dir/${wave_id}.json"
  shared_wave_dir="$shared_dir/$wave_id"

  if (( dry_run )); then
    cat <<EOF
[dry-run] would create wave: $wave_id
  state file: $state_file
  shared dir: $shared_wave_dir
  source:     $issue_or_brief
  main agent: $main_agent
  worker:     $worker_engine
  reviewer:   $reviewer
  tracks:     ${tracks:-(none — single member)}
EOF
    return 0
  fi

  mkdir -p "$state_dir" "$shared_wave_dir"

  local brief_relpath=""
  if [[ -f "$issue_or_brief" && ! "$issue_or_brief" =~ ^[0-9]+$ ]]; then
    brief_relpath="waves/$wave_id/source-brief.md"
    cp "$issue_or_brief" "$shared_dir/$wave_id/source-brief.md"
  fi

  python3 "$helper" state-init \
    "$wave_id" \
    "$issue_or_brief" \
    "$main_agent" \
    "$worker_engine" \
    "$reviewer" \
    "$tracks" \
    "$state_file" \
    "$brief_relpath" \
    >/dev/null \
    || bridge_die "wave dispatch: state-init failed"

  local member_dir member_id member_brief track
  if [[ -n "$tracks" ]]; then
    while IFS=',' read -ra _tracks; do
      for track in "${_tracks[@]}"; do
        track="${track//[[:space:]]/}"
        [[ -n "$track" ]] || continue
        member_id="$(_bridge_wave_member_id_for_track "$state_file" "$track")"
        member_dir="$shared_wave_dir/$member_id"
        member_brief="$member_dir/brief.md"
        mkdir -p "$member_dir"
        _bridge_wave_emit_member_brief \
          "$wave_id" "$member_id" "$track" "$issue_or_brief" \
          "$main_agent" "$worker_engine" "$reviewer" \
          > "$member_brief"
      done
    done <<< "$tracks"
  else
    member_id="$(_bridge_wave_member_id_for_track "$state_file" "main")"
    member_dir="$shared_wave_dir/$member_id"
    member_brief="$member_dir/brief.md"
    mkdir -p "$member_dir"
    _bridge_wave_emit_member_brief \
      "$wave_id" "$member_id" "main" "$issue_or_brief" \
      "$main_agent" "$worker_engine" "$reviewer" \
      > "$member_brief"
  fi

  python3 "$helper" state-render-readme "$state_file" "$shared_wave_dir/README.md" \
    || bridge_warn "wave dispatch: README render failed (non-fatal)"

  if (( json_out )); then
    python3 "$helper" state-show "$state_file"
  else
    printf 'wave dispatched: %s\n' "$wave_id"
    printf 'state: %s\n' "$state_file"
    printf 'briefs: %s/<member-id>/brief.md\n' "$shared_wave_dir"
    printf 'next: phase 1.2 will start workers + queue tasks. For now, members are pending.\n'
  fi
}

_bridge_wave_member_id_for_track() {
  # Read the member id for a given track from the state file. Used after
  # state-init has written the wave so we don't regenerate ids.
  local state_file="$1" track="$2"
  python3 -c '
import json, sys
state = json.loads(open(sys.argv[1]).read())
for m in state["members"]:
    if m["track"] == sys.argv[2]:
        print(m["member_id"]); break
' "$state_file" "$track"
}

_bridge_wave_emit_member_brief() {
  # Emit a generic brief skeleton per member. Phase 1.1 ships a minimal
  # template; Phase 1.2+ will expand to the 11-section shape from
  # references/brief-template.md once we land that asset.
  local wave_id="$1" member_id="$2" track="$3" issue_or_brief="$4"
  local main_agent="$5" worker_engine="$6" reviewer="$7"

  cat <<EOF
# Wave member brief — ${wave_id} / track ${track}

> Auto-generated by \`agent-bridge wave dispatch\` (Phase 1.1 skeleton).
> Operator should expand sections 3-7 below before Phase 1.2 dispatches a
> worker against this brief.

- **Wave id**: \`${wave_id}\`
- **Member id**: \`${member_id}\`
- **Track**: \`${track}\`
- **Source**: \`${issue_or_brief}\`
- **Main agent**: \`${main_agent}\`
- **Worker engine**: \`${worker_engine}\`
- **Reviewer policy**: \`${reviewer}\`

## 1. Repo / branch / scope

- Branch: \`fix/${track,,}-...\` or \`feat/${track,,}-...\` (operator to fill)

## 2. Read first (do not skip)

- Operator: enumerate files + commands the worker must inspect before editing.

## 3. What to change

- Per-file recipe.

## 4. Out of scope

- Items the worker MUST NOT touch.

## 5. Verification

\`\`\`bash
PATH="/opt/homebrew/bin:\$PATH"
bash -n <files>
shellcheck <files>
\`\`\`

## 6. CI status

- Pre-existing failures the worker should not chase.

## 7. PR opening

- Title format: \`<type>: <subject> (#${issue_or_brief//[!0-9]/} Track ${track})\`
- Body: Summary, Changes, Verification, Related, Out of scope.

## 8. CRITICAL — close-keyword footgun

**Do NOT use \`closes #N\`, \`fixes #N\`, \`resolves #N\` in the PR title, body, or commit subject.**
Use \`(#N Track ${track})\` for citation. Issue close is gated through \`agent-bridge wave close-issue\`.

## 9. Stop point

Stop after PR open. Return JSON.

## 10. Reminders

- Worktree-relative paths only.
- Single commit per member.
- No VERSION/CHANGELOG bumps.

## 11. Output JSON

\`\`\`json
{
  "branch": "<head-branch>",
  "pr_number": <int>,
  "pr_url": "<url>",
  "files_touched": [],
  "loc_added": 0,
  "loc_deleted": 0,
  "verification": {
    "bash_n": "pass|fail",
    "shellcheck": "pass|fail"
  }
}
\`\`\`
EOF
}

bridge_wave_list() {
  local json_out=0
  local include_all=0
  while (( $# > 0 )); do
    case "$1" in
      --json) json_out=1; shift ;;
      --all)  include_all=1; shift ;;
      -h|--help) printf 'agent-bridge wave list [--all] [--json]\n'; return 0 ;;
      *) bridge_die "wave list: unknown arg: $1" ;;
    esac
  done

  local state_dir
  state_dir="$(bridge_wave_state_dir)"

  local helper
  helper="$(bridge_wave_python_helper)"
  [[ -r "$helper" ]] || bridge_die "wave list: bridge-wave.py missing at $helper"

  if (( json_out )); then
    python3 "$helper" state-list "$state_dir"
    return 0
  fi

  if [[ ! -d "$state_dir" ]]; then
    printf 'no waves dispatched yet. state dir: %s\n' "$state_dir"
    return 0
  fi

  python3 "$helper" state-list-pretty "$state_dir"
}

bridge_wave_show() {
  local wave_id="" json_out=0
  while (( $# > 0 )); do
    case "$1" in
      --json) json_out=1; shift ;;
      -h|--help) printf 'agent-bridge wave show <wave-id> [--json]\n'; return 0 ;;
      -*) bridge_die "wave show: unknown option: $1" ;;
      *)
        if [[ -z "$wave_id" ]]; then
          wave_id="$1"
        else
          bridge_die "wave show: extra positional arg: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$wave_id" ]] || bridge_die "wave show: <wave-id> required"

  local state_dir state_file
  state_dir="$(bridge_wave_state_dir)"
  state_file="$state_dir/${wave_id}.json"
  [[ -r "$state_file" ]] || bridge_die "wave show: state file not found: $state_file"

  local helper
  helper="$(bridge_wave_python_helper)"

  if (( json_out )); then
    python3 "$helper" state-show "$state_file"
    return 0
  fi

  python3 "$helper" state-show-pretty "$state_file"
}

bridge_wave_templates() {
  cat <<EOF
Available brief templates (Phase 1.1 ships a single skeleton):

  default     — auto-generated 11-section skeleton (operator fills sections 3-7)

Phase 1.2+ will expand the catalog with templates derived from
references/brief-template.md (issue-fixer, doc-only, release-bump, etc).
EOF
}

bridge_wave_close_issue() {
  local issue="" wave_id="" force=0
  while (( $# > 0 )); do
    case "$1" in
      --wave)  wave_id="${2:-}"; shift 2 ;;
      --wave=*) wave_id="${1#--wave=}"; shift ;;
      --force) force=1; shift ;;
      -h|--help) printf 'agent-bridge wave close-issue <issue> [--wave <wave-id>] [--force]\n'; return 0 ;;
      -*) bridge_die "wave close-issue: unknown option: $1" ;;
      *)
        if [[ -z "$issue" ]]; then
          issue="$1"
        else
          bridge_die "wave close-issue: extra positional arg: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$issue" ]] || bridge_die "wave close-issue: <issue> required"

  if (( force )); then
    bridge_warn "wave close-issue: --force is operator-only and reserved for Phase 1.6 implementation."
  fi

  cat >&2 <<EOF
wave close-issue is implemented in Phase 1.6 (per design §11).
For Phase 1.1 this command is a placeholder. Validation logic (every
wave member tagged \`issue=#${issue}\` is MERGED, every dispatched track
has a merged member, no recent codex needs-more) is not yet wired.

Operator flow until Phase 1.6:
  1. Verify all wave member PRs are merged.
  2. Run \`gh issue comment ${issue} --body ...\` to summarize.
  3. Run \`gh issue close ${issue}\` after live verification (if applicable).

(Wave context: $wave_id)
EOF
  return 64  # EX_USAGE-style — operator must do it manually for now.
}
