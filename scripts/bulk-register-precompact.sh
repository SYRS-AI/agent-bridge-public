#!/usr/bin/env bash
# Bulk PreCompact hook registration — canary-first rollout.
#
# Usage:
#   bulk-register.sh --canary     # phase 1, register on `patch` only
#   bulk-register.sh --phase2     # phase 2, three non-customer-facing agents
#   bulk-register.sh --all        # phase 3, every claude-engine agent (post-gate)
#   bulk-register.sh --dry-run ... # show the plan, take no action
#
# All phases append one ndjson record per agent to
#   $BRIDGE_HOME/state/precompact-registration/<stamp>.jsonl
# and snapshot the old .claude/settings.json to backups/ before touching it.
#
# Idempotent: re-running a phase on already-registered agents yields
# status="unchanged" entries and no settings.json write.

set -euo pipefail

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
AGENT_BRIDGE_BIN="${AGENT_BRIDGE_BIN:-$BRIDGE_HOME/agent-bridge}"
STATE_DIR="$BRIDGE_HOME/state/precompact-registration"
BACKUP_DIR="$STATE_DIR/backups"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$STATE_DIR/$STAMP.jsonl"

PHASE=""
DRY_RUN=0

usage() {
    sed -n '2,12p' "$0"
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --canary)  PHASE="canary"; shift ;;
        --phase2)  PHASE="phase2"; shift ;;
        --all)     PHASE="all";    shift ;;
        --dry-run) DRY_RUN=1;      shift ;;
        -h|--help) usage ;;
        *) echo "bulk-register: unknown flag: $1" >&2; usage ;;
    esac
done

if [ -z "$PHASE" ]; then
    echo "bulk-register: one of --canary|--phase2|--all is required" >&2
    usage
fi

CANARY_AGENTS=(patch)
PHASE2_AGENTS=(newsbot syrs-calendar syrs-creative)

list_all_claude_agents() {
    # Roster rows look like: `name [...] | claude | ... | engine=... | ...`.
    # The `agent list` CLI has a stable first column = agent name and a
    # second column = engine (claude|codex).
    "$AGENT_BRIDGE_BIN" agent list 2>/dev/null \
        | awk -F '|' 'NR>1 && $2 ~ /claude/ {
              split($1, name_parts, " ")
              gsub(/^[ \t]+|[ \t]+$/, "", name_parts[1])
              if (name_parts[1] != "") print name_parts[1]
          }' \
        | grep -Ev '^(shared|_template)$' \
        || true
}

pick_targets() {
    case "$PHASE" in
        canary) printf '%s\n' "${CANARY_AGENTS[@]}" ;;
        phase2) printf '%s\n' "${PHASE2_AGENTS[@]}" ;;
        all)    list_all_claude_agents ;;
    esac
}

json_escape() {
    # Minimal JSON string escaper for embedding in ndjson.
    python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

record() {
    # record <agent> <action> <status> <command> <backup> [<error>]
    local agent="$1" action="$2" status="$3" command="$4" backup="$5" err="${6:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local a c b e
    a="$(json_escape "$agent")"
    c="$(json_escape "$command")"
    b="$(json_escape "$backup")"
    e="$(json_escape "$err")"
    printf '{"ts":"%s","phase":"%s","dry_run":%s,"agent":%s,"action":"%s","status":"%s","command":%s,"backup":%s,"error":%s}\n' \
        "$ts" "$PHASE" "$([ $DRY_RUN -eq 1 ] && echo true || echo false)" \
        "$a" "$action" "$status" "$c" "$b" "$e" \
        >> "$LOG_FILE"
}

backup_settings() {
    local agent="$1"
    local settings="$BRIDGE_HOME/agents/$agent/.claude/settings.json"
    if [ ! -f "$settings" ]; then
        echo ""
        return 0
    fi
    local dest="$BACKUP_DIR/${agent}-${STAMP}.json"
    if [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$BACKUP_DIR"
        cp -p "$settings" "$dest"
    fi
    echo "$dest"
}

register_one() {
    local agent="$1"
    local settings="$BRIDGE_HOME/agents/$agent/.claude/settings.json"

    if [ ! -d "$BRIDGE_HOME/agents/$agent" ]; then
        record "$agent" "skip" "missing_home" "" "" "no home dir"
        echo "skip   $agent (no home)"
        return 0
    fi

    # Pre-check
    local pre_status="missing"
    if [ -f "$settings" ] && grep -q 'pre-compact.py' "$settings" 2>/dev/null; then
        pre_status="present"
    fi

    local backup
    backup="$(backup_settings "$agent")"

    if [ $DRY_RUN -eq 1 ]; then
        record "$agent" "register" "dry_run" \
            "agent-bridge hooks ensure-pre-compact-hook --agent $agent" \
            "$backup" ""
        printf 'dry    %-20s pre=%s backup=%s\n' "$agent" "$pre_status" "$backup"
        return 0
    fi

    local out status
    if out="$("$AGENT_BRIDGE_BIN" hooks ensure-pre-compact-hook --agent "$agent" 2>&1)"; then
        status="ok"
    else
        status="error"
    fi

    if [ "$status" = "ok" ]; then
        printf 'ok     %-20s pre=%s backup=%s\n' "$agent" "$pre_status" "$backup"
        record "$agent" "register" "ok" \
            "agent-bridge hooks ensure-pre-compact-hook --agent $agent" \
            "$backup" ""
    else
        printf 'ERR    %-20s: %s\n' "$agent" "$out" >&2
        record "$agent" "register" "error" \
            "agent-bridge hooks ensure-pre-compact-hook --agent $agent" \
            "$backup" "$out"
    fi
}

main() {
    if [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$STATE_DIR" "$BACKUP_DIR"
        : > "$LOG_FILE"
    else
        # Dry-run: route log to a tmp path so the real state dir stays clean.
        LOG_FILE="$(mktemp -t precompact-dryrun.XXXXXX).jsonl"
    fi

    local targets
    targets="$(pick_targets)"
    if [ -z "$targets" ]; then
        echo "bulk-register: no targets for phase=$PHASE" >&2
        exit 1
    fi

    echo "# phase=$PHASE dry_run=$DRY_RUN log=$LOG_FILE"
    local agent
    while IFS= read -r agent; do
        [ -z "$agent" ] && continue
        register_one "$agent"
        # Gentle pause to avoid racing settings.json writes.
        if [ $DRY_RUN -eq 0 ] && [ "$PHASE" = "all" ]; then
            sleep 5
        fi
    done <<< "$targets"

    echo "# done. log: $LOG_FILE"
}

main "$@"
