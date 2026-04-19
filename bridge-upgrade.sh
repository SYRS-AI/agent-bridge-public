#!/usr/bin/env bash
# bridge-upgrade.sh — update a live Agent Bridge install from a repo checkout

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
ORIGINAL_ARGS=("$@")

SOURCE_ROOT="$SCRIPT_DIR"
TARGET_ROOT="$HOME/.agent-bridge"
SUBCOMMAND="apply"
PULL=0
PULL_EXPLICIT=0
SOURCE_EXPLICIT=0
CHANNEL="${AGENT_BRIDGE_UPGRADE_CHANNEL:-stable}"
CHANNEL_EXPLICIT=0
REQUESTED_VERSION=""
REQUESTED_REF=""
CHECK_ONLY=0
DRY_RUN=0
RESTART_DAEMON=1
RESTART_AGENTS=1
RESTART_AGENTS_EXPLICIT=0
JSON=0
ALLOW_DIRTY=0
STRICT_MERGE=0
BACKUP=1
MIGRATE_AGENTS=1
BACKUP_ROOT=""
ANALYSIS_JSON='{}'
TARGET_REF=""
TARGET_VERSION=""
TARGET_HEAD=""
SOURCE_VERSION=""
SOURCE_REF=""
SOURCE_HEAD=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--source <repo-dir>] [--target <bridge-home>] [--check] [--channel stable|dev|current] [--version <semver>] [--ref <git-ref>] [--pull|--no-pull] [--restart-daemon|--no-restart-daemon] [--restart-agents|--no-restart-agents] [--dry-run] [--json] [--allow-dirty] [--strict-merge] [--no-backup] [--no-migrate-agents]
  $(basename "$0") analyze [--source <repo-dir>] [--target <bridge-home>] [--json]
  $(basename "$0") rollback [--target <bridge-home>] [--backup-root <dir>] [--restart-daemon|--no-restart-daemon] [--restart-agents|--no-restart-agents] [--dry-run] [--json]

Updates a live Agent Bridge install from a repo checkout while preserving user-owned
customizations such as:
- agent-roster.local.sh
- state/, logs/, shared/
- backups/, worktrees/
- live agent homes under agents/<agent>/

The repo checkout remains source of truth for core code. Live-only operator changes are preserved.
When run from an installed live copy without --source, the last recorded source checkout is reused and pulled automatically.
Default channel is stable: the latest vX.Y.Z tag is used when one exists. Use --channel dev to track main, or --channel current/--source to deploy the current checkout.
EOF
}

bridge_upgrade_version_from_file() {
  local root="$1"
  if [[ -f "$root/VERSION" ]]; then
    head -n 1 "$root/VERSION" | tr -d '[:space:]'
    return 0
  fi
  printf '0.0.0-dev'
}

bridge_upgrade_current_ref() {
  local root="$1"
  git -C "$root" describe --tags --exact-match HEAD 2>/dev/null \
    || git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null \
    || printf '-'
}

bridge_upgrade_latest_stable_tag() {
  local root="$1"
  local tags
  tags="$(git -C "$root" tag --list 'v[0-9]*.[0-9]*.[0-9]*')"
  python3 -c '
import re
import sys

tags = [line.strip() for line in sys.stdin if re.fullmatch(r"v\d+\.\d+\.\d+", line.strip())]
tags.sort(key=lambda tag: tuple(int(part) for part in tag[1:].split(".")))
print(tags[-1] if tags else "")
' <<<"$tags"
}

bridge_upgrade_normalize_version_tag() {
  local version="$1"
  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    bridge_die "--version 값은 semver 형식이어야 합니다. 예: 0.1.0"
  fi
  printf 'v%s' "$version"
}

bridge_upgrade_head_for_ref() {
  local root="$1"
  local ref="$2"
  git -C "$root" rev-parse "${ref}^{commit}" 2>/dev/null || true
}

bridge_upgrade_version_at_ref() {
  local root="$1"
  local ref="$2"
  local version=""
  version="$(git -C "$root" show "${ref}:VERSION" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  if [[ -n "$version" ]]; then
    printf '%s' "$version"
  else
    bridge_upgrade_version_from_file "$root"
  fi
}

bridge_upgrade_collect_agent_restart_report() {
  local target_root="$1"
  local dry_run="${2:-0}"

  "$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    target_root="$1"
    dry_run="$2"
    export BRIDGE_HOME="$target_root"
    source "$target_root/bridge-lib.sh"
    bridge_load_roster

    agent=""
    session=""
    attached=0
    status=""
    reason=""

    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue

      session="$(bridge_agent_session "$agent")"
      attached=0
      status="skipped"
      reason="inactive"

      if [[ "$(bridge_agent_loop "$agent")" != "1" ]]; then
        reason="not-loop"
      elif bridge_agent_manual_stop_active "$agent"; then
        reason="manual-stop"
      elif [[ -z "$session" ]]; then
        reason="no-session"
      elif ! bridge_tmux_session_exists "$session"; then
        reason="inactive"
      else
        attached="$(bridge_tmux_session_attached_count "$session" 2>/dev/null || printf "0")"
        [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
        if (( attached > 0 )); then
          reason="attached"
        elif [[ "$dry_run" == "1" ]]; then
          status="would-restart"
          reason="eligible"
        elif "$BRIDGE_BASH_BIN" "$target_root/bridge-agent.sh" restart "$agent" >/dev/null 2>&1; then
          status="restarted"
          reason="eligible"
        else
          status="failed"
          reason="restart-failed"
        fi
      fi

      printf "%s\t%s\t%s\t%s\t%s\n" "$agent" "$status" "$reason" "$attached" "$session"
    done
  ' -- "$target_root" "$dry_run"
}

bridge_upgrade_agent_restart_json() {
  local report="$1"
  local enabled="$2"
  local dry_run="${3:-0}"

  python3 - "$enabled" "$dry_run" "$report" <<'PY'
import json
import sys

enabled = sys.argv[1] == "1"
dry_run = sys.argv[2] == "1"
report = sys.argv[3]
payload = {
    "enabled": enabled,
    "dry_run": dry_run,
    "considered": 0,
    "eligible": 0,
    "would_restart": 0,
    "restarted": 0,
    "failed": 0,
    "skipped": 0,
    "restarted_agents": [],
    "would_restart_agents": [],
    "failed_agents": [],
    "skipped_reasons": {},
}

for raw in report.splitlines():
    raw = raw.rstrip("\n")
    if not raw:
        continue
    agent, status, reason, _attached, _session = (raw.split("\t", 4) + ["", "", "", "", ""])[:5]
    payload["considered"] += 1
    if reason == "eligible":
        payload["eligible"] += 1
    if status == "would-restart":
        payload["would_restart"] += 1
        payload["would_restart_agents"].append(agent)
    elif status == "restarted":
        payload["restarted"] += 1
        payload["restarted_agents"].append(agent)
    elif status == "failed":
        payload["failed"] += 1
        payload["failed_agents"].append(agent)
    else:
        payload["skipped"] += 1
        payload["skipped_reasons"][reason] = payload["skipped_reasons"].get(reason, 0) + 1

print(json.dumps(payload, ensure_ascii=False))
PY
}

bridge_upgrade_print_agent_restart_summary() {
  local payload="$1"

  python3 - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(f"agent_restart_enabled: {'yes' if payload.get('enabled') else 'no'}")
print(f"agent_restart_considered: {payload.get('considered', 0)}")
print(f"agent_restart_eligible: {payload.get('eligible', 0)}")
print(f"agent_restart_restarted: {payload.get('restarted', 0)}")
print(f"agent_restart_failed: {payload.get('failed', 0)}")
print(f"agent_restart_skipped: {payload.get('skipped', 0)}")
if payload.get("would_restart"):
    print(f"agent_restart_would_restart: {payload.get('would_restart', 0)}")
if payload.get("restarted_agents"):
    print(f"agent_restart_agents: {','.join(payload['restarted_agents'])}")
if payload.get("would_restart_agents"):
    print(f"agent_restart_would_agents: {','.join(payload['would_restart_agents'])}")
if payload.get("failed_agents"):
    print(f"agent_restart_failed_agents: {','.join(payload['failed_agents'])}")
for reason in sorted(payload.get("skipped_reasons", {})):
    print(f"agent_restart_skipped_{reason}: {payload['skipped_reasons'][reason]}")
PY
}

bridge_upgrade_channel_guard_report() {
  local source_root="$1"
  local target_root="$2"

  "$BRIDGE_BASH_BIN" -s -- "$source_root" "$target_root" <<'EOF'
set -euo pipefail
source_root="$1"
target_root="$2"
export BRIDGE_HOME="$target_root"
source "$source_root/bridge-lib.sh"
bridge_load_roster

agent=""
session=""
active="no"
reason=""
required=""

for agent in "${BRIDGE_AGENT_IDS[@]}"; do
  if [[ "$(bridge_agent_channel_status "$agent")" != "miss" ]]; then
    continue
  fi
  session="$(bridge_agent_session "$agent")"
  active="no"
  if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
    active="yes"
  fi
  reason="$(bridge_agent_channel_runtime_drift_reason "$agent")"
  if [[ -z "$reason" ]]; then
    reason="$(bridge_agent_channel_status_reason "$agent")"
  fi
  reason="${reason//$'\t'/ }"
  reason="${reason//$'\n'/ }"
  required="$(bridge_agent_channels_csv "$agent")"
  printf "%s\t%s\t%s\t%s\n" "$agent" "$active" "$required" "$reason"
done
EOF
}

bridge_upgrade_channel_guard_json() {
  local report="$1"

  python3 - "$report" <<'PY'
import json
import sys

items = []
active_count = 0
for raw in sys.argv[1].splitlines():
    raw = raw.rstrip("\n")
    if not raw:
        continue
    agent, active, required, reason = (raw.split("\t", 3) + ["", "", "", ""])[:4]
    is_active = active == "yes"
    if is_active:
        active_count += 1
    items.append(
        {
            "agent": agent,
            "active": is_active,
            "required_channels": required,
            "reason": reason,
        }
    )

print(json.dumps({"count": len(items), "active_count": active_count, "agents": items}, ensure_ascii=False))
PY
}

bridge_upgrade_print_channel_guard_summary() {
  local payload="$1"

  python3 - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
items = payload.get("agents", [])
if not items:
    raise SystemExit(0)

print(f"channel_guard_miss: {payload.get('count', 0)}")
print(f"channel_guard_active_miss: {payload.get('active_count', 0)}")
print("[warn] live roster has channel/runtime mismatches that can block restart:")
for item in items[:10]:
    suffix = " (active)" if item.get("active") else ""
    print(f"  - {item.get('agent')}{suffix}: {item.get('reason')}")
if len(items) > 10:
    print(f"  ... +{len(items) - 10} more")
PY
}

bridge_upgrade_installed_field() {
  local target_root="$1"
  local field="$2"
  python3 - "$target_root/state/upgrade/last-upgrade.json" "$field" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
field = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    print("")
    raise SystemExit(0)
value = payload.get(field, "")
print("" if value is None else str(value))
PY
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    analyze|rollback)
      SUBCOMMAND="$1"
      shift
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -lt 2 ]] && bridge_die "--source 뒤에 값을 지정하세요."
      SOURCE_ROOT="$2"
      SOURCE_EXPLICIT=1
      shift 2
      ;;
    --target)
      [[ $# -lt 2 ]] && bridge_die "--target 뒤에 값을 지정하세요."
      TARGET_ROOT="$2"
      shift 2
      ;;
    --backup-root)
      [[ $# -lt 2 ]] && bridge_die "--backup-root 뒤에 값을 지정하세요."
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --pull)
      PULL=1
      PULL_EXPLICIT=1
      shift
      ;;
    --no-pull)
      PULL=0
      PULL_EXPLICIT=1
      shift
      ;;
    --check)
      CHECK_ONLY=1
      DRY_RUN=1
      RESTART_DAEMON=0
      shift
      ;;
    --channel)
      [[ $# -lt 2 ]] && bridge_die "--channel 뒤에 stable|dev|current 중 하나를 지정하세요."
      CHANNEL="$2"
      CHANNEL_EXPLICIT=1
      shift 2
      ;;
    --version)
      [[ $# -lt 2 ]] && bridge_die "--version 뒤에 버전을 지정하세요."
      REQUESTED_VERSION="$2"
      CHANNEL="stable"
      CHANNEL_EXPLICIT=1
      shift 2
      ;;
    --ref)
      [[ $# -lt 2 ]] && bridge_die "--ref 뒤에 git ref를 지정하세요."
      REQUESTED_REF="$2"
      CHANNEL="ref"
      CHANNEL_EXPLICIT=1
      shift 2
      ;;
    --restart-daemon)
      RESTART_DAEMON=1
      shift
      ;;
    --no-restart-daemon)
      RESTART_DAEMON=0
      shift
      ;;
    --restart-agents)
      RESTART_AGENTS=1
      RESTART_AGENTS_EXPLICIT=1
      shift
      ;;
    --no-restart-agents)
      RESTART_AGENTS=0
      RESTART_AGENTS_EXPLICIT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --strict-merge)
      STRICT_MERGE=1
      shift
      ;;
    --no-backup)
      BACKUP=0
      shift
      ;;
    --backup)
      BACKUP=1
      shift
      ;;
    --no-migrate-agents)
      MIGRATE_AGENTS=0
      shift
      ;;
    --migrate-agents)
      MIGRATE_AGENTS=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      bridge_die "지원하지 않는 upgrade 옵션입니다: $1"
      ;;
  esac
done

TARGET_ROOT="$(cd -P "$(dirname "$TARGET_ROOT")" && pwd -P)/$(basename "$TARGET_ROOT")"
SOURCE_ROOT="$(cd -P "$SOURCE_ROOT" && pwd -P)"

if [[ $SOURCE_EXPLICIT -eq 0 && "$SOURCE_ROOT" == "$TARGET_ROOT" ]]; then
  RECORDED_SOURCE_ROOT="$(
    python3 - "$TARGET_ROOT/state/upgrade/last-upgrade.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    print("")
    raise SystemExit(0)

source = str(payload.get("source_root") or "").strip()
print(source)
PY
  )"
  if [[ -n "$RECORDED_SOURCE_ROOT" && -d "$RECORDED_SOURCE_ROOT/.git" ]]; then
    SOURCE_ROOT="$(cd -P "$RECORDED_SOURCE_ROOT" && pwd -P)"
    if [[ "$SUBCOMMAND" == "apply" && $PULL_EXPLICIT -eq 0 ]]; then
      PULL=1
    fi
  else
    for CANDIDATE_SOURCE_ROOT in \
      "${AGENT_BRIDGE_SOURCE_DIR:-}" \
      "$HOME/.agent-bridge-source" \
      "$HOME/Projects/agent-bridge-public" \
      "$HOME/agent-bridge-public" \
      "$HOME/agent-bridge"
    do
      [[ -n "$CANDIDATE_SOURCE_ROOT" ]] || continue
      if [[ -d "$CANDIDATE_SOURCE_ROOT/.git" ]]; then
        SOURCE_ROOT="$(cd -P "$CANDIDATE_SOURCE_ROOT" && pwd -P)"
        if [[ "$SUBCOMMAND" == "apply" && $PULL_EXPLICIT -eq 0 ]]; then
          PULL=1
        fi
        break
      fi
    done
  fi
fi

if [[ "${BRIDGE_UPGRADE_SOURCE_REEXEC:-0}" != "1" \
  && "$SCRIPT_DIR" == "$TARGET_ROOT" \
  && "$SOURCE_ROOT" != "$SCRIPT_DIR" \
  && -f "$SOURCE_ROOT/bridge-upgrade.sh" ]]; then
  export BRIDGE_UPGRADE_SOURCE_REEXEC=1
  exec "$BRIDGE_BASH_BIN" "$SOURCE_ROOT/bridge-upgrade.sh" "${ORIGINAL_ARGS[@]}" --target "$TARGET_ROOT"
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
if [[ -z "$BACKUP_ROOT" && "$SUBCOMMAND" != "rollback" ]]; then
  BACKUP_ROOT="$TARGET_ROOT/backups/upgrade-$TIMESTAMP"
fi
ADMIN_AGENT_ID=""
BACKUP_JSON='{}'
MIGRATION_JSON='{}'
MIGRATION_PREVIEW_JSON='{}'
APPLY_JSON='{}'

if ! git -C "$SOURCE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  if [[ $SOURCE_EXPLICIT -eq 0 && "$SOURCE_ROOT" == "$TARGET_ROOT" ]]; then
    bridge_die "live install은 git repo가 아니고 source checkout 기록도 없습니다: $TARGET_ROOT
복구: git clone https://github.com/SYRS-AI/agent-bridge-public \"\$HOME/.agent-bridge-source\" 후 다시 실행하거나,
AGENT_BRIDGE_SOURCE_DIR를 설정하거나,
명시적으로 실행하세요: $TARGET_ROOT/agent-bridge upgrade --source /path/to/agent-bridge-public"
  fi
  bridge_die "git repo가 아닙니다: $SOURCE_ROOT"
fi

if [[ $SOURCE_EXPLICIT -eq 1 && $CHANNEL_EXPLICIT -eq 0 ]]; then
  CHANNEL="current"
fi
if [[ "$SUBCOMMAND" != "apply" && $CHANNEL_EXPLICIT -eq 0 ]]; then
  CHANNEL="current"
fi

case "$CHANNEL" in
  stable|dev|current|ref)
    ;;
  *)
    bridge_die "--channel 값은 stable|dev|current 중 하나여야 합니다: $CHANNEL"
    ;;
esac

if [[ "$SUBCOMMAND" == "apply" ]]; then
  if [[ $PULL -eq 1 || $CHECK_ONLY -eq 1 || "$CHANNEL" != "current" ]]; then
    if git -C "$SOURCE_ROOT" remote get-url origin >/dev/null 2>&1; then
      git -C "$SOURCE_ROOT" fetch --tags --prune origin >/dev/null
      if [[ "$CHANNEL" == "dev" ]]; then
        git -C "$SOURCE_ROOT" fetch origin main >/dev/null 2>&1 || true
      fi
    fi
  fi

  case "$CHANNEL" in
    current)
      TARGET_REF=""
      ;;
    stable)
      if [[ -n "$REQUESTED_VERSION" ]]; then
        TARGET_REF="$(bridge_upgrade_normalize_version_tag "$REQUESTED_VERSION")"
      else
        TARGET_REF="$(bridge_upgrade_latest_stable_tag "$SOURCE_ROOT")"
      fi
      if [[ -n "$TARGET_REF" ]] && ! git -C "$SOURCE_ROOT" rev-parse --verify "${TARGET_REF}^{commit}" >/dev/null 2>&1; then
        bridge_die "요청한 stable 릴리즈 태그를 찾을 수 없습니다: $TARGET_REF"
      fi
      ;;
    dev)
      if git -C "$SOURCE_ROOT" rev-parse --verify main >/dev/null 2>&1; then
        TARGET_REF="main"
      elif git -C "$SOURCE_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
        TARGET_REF="origin/main"
      else
        TARGET_REF=""
      fi
      ;;
    ref)
      TARGET_REF="$REQUESTED_REF"
      if ! git -C "$SOURCE_ROOT" rev-parse --verify "${TARGET_REF}^{commit}" >/dev/null 2>&1; then
        bridge_die "git ref를 찾을 수 없습니다: $TARGET_REF"
      fi
      ;;
  esac

  if [[ -n "$TARGET_REF" ]]; then
    TARGET_VERSION="$(bridge_upgrade_version_at_ref "$SOURCE_ROOT" "$TARGET_REF")"
    TARGET_HEAD="$(bridge_upgrade_head_for_ref "$SOURCE_ROOT" "$TARGET_REF")"
  else
    TARGET_VERSION="$(bridge_upgrade_version_from_file "$SOURCE_ROOT")"
    TARGET_HEAD="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
  fi

  if [[ $CHECK_ONLY -eq 1 ]]; then
    INSTALLED_VERSION="$(bridge_upgrade_installed_field "$TARGET_ROOT" version)"
    INSTALLED_HEAD="$(bridge_upgrade_installed_field "$TARGET_ROOT" source_head)"
    UPDATE_AVAILABLE=0
    if [[ -z "$INSTALLED_VERSION" || "$INSTALLED_VERSION" != "$TARGET_VERSION" || -z "$INSTALLED_HEAD" || "$INSTALLED_HEAD" != "$TARGET_HEAD" ]]; then
      UPDATE_AVAILABLE=1
    fi

    if [[ $JSON -eq 1 ]]; then
      python3 - "$SOURCE_ROOT" "$TARGET_ROOT" "$CHANNEL" "$TARGET_REF" "$TARGET_VERSION" "$TARGET_HEAD" "$INSTALLED_VERSION" "$INSTALLED_HEAD" "$UPDATE_AVAILABLE" <<'PY'
import json
import sys

source_root, target_root, channel, target_ref, target_version, target_head, installed_version, installed_head, update_available = sys.argv[1:]
payload = {
    "mode": "upgrade-check",
    "source_root": source_root,
    "target_root": target_root,
    "channel": channel,
    "target_ref": target_ref,
    "target_version": target_version,
    "target_head": target_head,
    "installed_version": installed_version,
    "installed_head": installed_head,
    "update_available": update_available == "1",
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
    else
      echo "== Agent Bridge upgrade check =="
      echo "channel: $CHANNEL"
      echo "target_ref: ${TARGET_REF:-current}"
      echo "target_version: $TARGET_VERSION"
      echo "installed_version: ${INSTALLED_VERSION:-unknown}"
      echo "update_available: $([[ $UPDATE_AVAILABLE -eq 1 ]] && printf yes || printf no)"
    fi
    exit 0
  fi

  if [[ $ALLOW_DIRTY -eq 0 && $DRY_RUN -eq 0 ]]; then
    if [[ -n "$(git -C "$SOURCE_ROOT" status --short)" ]]; then
      bridge_die "working tree가 dirty 합니다. 먼저 커밋/정리하거나 --allow-dirty 를 사용하세요."
    fi
  fi

  if [[ -n "$TARGET_REF" && $DRY_RUN -eq 0 ]]; then
    git -C "$SOURCE_ROOT" checkout -q "$TARGET_REF"
  fi

  if [[ $PULL -eq 1 && $DRY_RUN -eq 0 ]]; then
    if [[ "$CHANNEL" == "dev" ]]; then
      if git -C "$SOURCE_ROOT" rev-parse --verify main >/dev/null 2>&1; then
        git -C "$SOURCE_ROOT" checkout -q main
      else
        git -C "$SOURCE_ROOT" checkout -q -B main origin/main
      fi
      git -C "$SOURCE_ROOT" pull --ff-only origin main
    elif [[ "$CHANNEL" == "current" ]]; then
      git -C "$SOURCE_ROOT" pull --ff-only
    fi
  fi
fi

SOURCE_VERSION="$(bridge_upgrade_version_from_file "$SOURCE_ROOT")"
SOURCE_REF="$(bridge_upgrade_current_ref "$SOURCE_ROOT")"
SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ $DRY_RUN -eq 0 || -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION="$SOURCE_VERSION"
  TARGET_HEAD="$SOURCE_HEAD"
fi

if [[ $RESTART_DAEMON -eq 0 && $RESTART_AGENTS_EXPLICIT -eq 0 ]]; then
  RESTART_AGENTS=0
fi
if [[ $CHECK_ONLY -eq 1 ]]; then
  RESTART_AGENTS=0
fi

ANALYSIS_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" analyze-live --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT")"
CHANNEL_GUARD_REPORT="$(bridge_upgrade_channel_guard_report "$SOURCE_ROOT" "$TARGET_ROOT")"
CHANNEL_GUARD_JSON="$(bridge_upgrade_channel_guard_json "$CHANNEL_GUARD_REPORT")"

if [[ "$SUBCOMMAND" == "analyze" ]]; then
  if [[ $JSON -eq 1 ]]; then
    python3 - "$ANALYSIS_JSON" "$CHANNEL_GUARD_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["channel_guard"] = json.loads(sys.argv[2])
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  else
    python3 - "$ANALYSIS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
counts = payload.get("counts", {})
print("== Agent Bridge upgrade analyze ==")
print(f"source_root: {payload.get('source_root')}")
print(f"target_root: {payload.get('target_root')}")
print(f"base_ref: {payload.get('base_ref') or '-'}")
for key in ("missing_live", "upstream_only", "live_only", "merge_required", "unknown_base_live_diff"):
    print(f"{key}: {counts.get(key, 0)}")
PY
    bridge_upgrade_print_channel_guard_summary "$CHANNEL_GUARD_JSON"
  fi
  exit 0
fi

if [[ "$SUBCOMMAND" == "rollback" ]]; then
  ROLLBACK_AGENT_RESTART_JSON="$(bridge_upgrade_agent_restart_json "" 0 "$DRY_RUN")"
  rollback_args=(rollback-live --target-root "$TARGET_ROOT")
  if [[ -n "$BACKUP_ROOT" ]]; then
    rollback_args+=(--backup-root "$BACKUP_ROOT")
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    rollback_args+=(--dry-run)
  fi
  ROLLBACK_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${rollback_args[@]}")"
  if [[ $RESTART_DAEMON -eq 1 && $DRY_RUN -eq 0 ]]; then
    bash "$TARGET_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
    bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
  fi
  if [[ $RESTART_AGENTS -eq 1 ]]; then
    ROLLBACK_AGENT_RESTART_REPORT="$(bridge_upgrade_collect_agent_restart_report "$TARGET_ROOT" "$DRY_RUN")"
    ROLLBACK_AGENT_RESTART_JSON="$(bridge_upgrade_agent_restart_json "$ROLLBACK_AGENT_RESTART_REPORT" 1 "$DRY_RUN")"
  fi
  if [[ $JSON -eq 1 ]]; then
    python3 - "$ROLLBACK_JSON" "$ROLLBACK_AGENT_RESTART_JSON" "$RESTART_DAEMON" "$RESTART_AGENTS" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["restart_daemon"] = sys.argv[3] == "1"
payload["restart_agents"] = sys.argv[4] == "1"
payload["agent_restart"] = json.loads(sys.argv[2])
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  else
    python3 - "$ROLLBACK_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print("== Agent Bridge rollback ==")
print(f"target_root: {payload.get('target_root')}")
print(f"backup_root: {payload.get('backup_root')}")
print(f"restored: {'yes' if payload.get('restored') else 'no'}")
print(f"removed_entries: {payload.get('removed_entries', 0)}")
PY
    bridge_upgrade_print_agent_restart_summary "$ROLLBACK_AGENT_RESTART_JSON"
  fi
  exit 0
fi

if [[ -f "$TARGET_ROOT/agent-roster.local.sh" ]]; then
  if ADMIN_AGENT_ID="$("$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    export BRIDGE_HOME="$1"
    source "$2/bridge-lib.sh"
    bridge_load_roster
    printf "%s" "${BRIDGE_ADMIN_AGENT_ID:-}"
  ' -- "$TARGET_ROOT" "$SOURCE_ROOT" 2>/dev/null)"; then
    :
  else
    ADMIN_AGENT_ID=""
  fi
fi

if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  MIGRATION_PREVIEW_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" migrate-agents --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --admin-agent "$ADMIN_AGENT_ID" --dry-run)"
fi

if [[ $BACKUP -eq 1 ]]; then
  backup_args=(backup-live --target-root "$TARGET_ROOT" --backup-root "$BACKUP_ROOT" --source-root "$SOURCE_ROOT")
  if [[ "$ANALYSIS_JSON" != "{}" ]]; then
    backup_args+=(--analysis-json "$ANALYSIS_JSON")
  fi
  if [[ "$MIGRATION_PREVIEW_JSON" != "{}" ]]; then
    backup_args+=(--migration-json "$MIGRATION_PREVIEW_JSON")
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    backup_args+=(--dry-run)
  fi
  BACKUP_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${backup_args[@]}")"
fi

BASE_REF="$(python3 - "$ANALYSIS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(payload.get("base_ref", ""))
PY
)"

apply_args=(apply-live --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT")
if [[ -n "$BASE_REF" ]]; then
  apply_args+=(--base-ref "$BASE_REF")
fi
if [[ $DRY_RUN -eq 1 ]]; then
  apply_args+=(--dry-run)
fi
if [[ $STRICT_MERGE -eq 1 ]]; then
  apply_args+=(--strict-merge)
fi
APPLY_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${apply_args[@]}")"
AGENT_RESTART_JSON="$(bridge_upgrade_agent_restart_json "" 0 "$DRY_RUN")"

if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    MIGRATION_JSON="$MIGRATION_PREVIEW_JSON"
  else
    MIGRATION_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" migrate-agents --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --admin-agent "$ADMIN_AGENT_ID")"
  fi
  "$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    export BRIDGE_HOME="$1"
    source "$2/bridge-lib.sh"
    bridge_load_roster
    dry_run="$3"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
      bridge_sync_claude_runtime_skills "$agent" "$(bridge_agent_workdir "$agent")" "$dry_run" >/dev/null 2>&1 || true
    done
  ' -- "$TARGET_ROOT" "$SOURCE_ROOT" "$DRY_RUN"

  # Also propagate per-agent doc sync (bridge-docs.py apply) so
  # MEMORY-SCHEMA.md / SKILLS.md / CLAUDE.md managed blocks track the
  # canonical runtime on every upgrade. Before 2026-04-19 this hook was
  # only reachable via bridge_sync_skill_docs which had no upstream
  # caller — agents silently drifted from the template. See
  # bridge-docs.sync_memory_schema_from_template.
  if [[ $DRY_RUN -eq 0 ]]; then
    python3 "$SOURCE_ROOT/bridge-docs.py" apply --all \
      --bridge-home "$TARGET_ROOT" \
      --target-root "$TARGET_ROOT/agents" >/dev/null 2>&1 || true
  fi
fi

if [[ $RESTART_DAEMON -eq 1 && $DRY_RUN -eq 0 ]]; then
  bash "$TARGET_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
  bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
fi

if [[ $DRY_RUN -eq 0 ]]; then
  python3 "$SOURCE_ROOT/bridge-upgrade.py" write-state \
    --source-root "$SOURCE_ROOT" \
    --target-root "$TARGET_ROOT" \
    --backup-root "$BACKUP_ROOT" \
    --analysis-json "$ANALYSIS_JSON" \
    --version "$SOURCE_VERSION" \
    --source-ref "$SOURCE_REF" \
    --channel "$CHANNEL" >/dev/null
fi

# Post-upgrade admin signal: file a [upgrade-complete] task with a
# ready-to-execute checklist. Without this the admin has to know to
# go read docs/agent-runtime/wiki-onboarding.md; the task makes the
# first run self-announcing. Skipped on dry-runs and when no admin
# agent is configured.
if [[ $DRY_RUN -eq 0 ]]; then
  # Resolve admin id: env override → grep the roster → skip.
  # We grep instead of sourcing because the roster files reference
  # bridge-lib arrays/functions that are not loaded in this scope;
  # `source` would error out and leave _post_admin empty.
  _post_admin="${BRIDGE_ADMIN_AGENT:-${BRIDGE_ADMIN_AGENT_ID:-}}"
  if [[ -z "$_post_admin" ]]; then
    for _roster in "$TARGET_ROOT/agent-roster.local.sh" "$TARGET_ROOT/agent-roster.sh"; do
      if [[ -r "$_roster" ]]; then
        _admin_line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=' "$_roster" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=//; s/^"([^"]*)".*/\1/; s/^'"'"'([^'"'"']*)'"'"'.*/\1/; s/[[:space:]]*#.*$//')"
        if [[ -n "$_admin_line" ]]; then
          _post_admin="$_admin_line"
          break
        fi
      fi
    done
  fi
  if [[ -n "$_post_admin" && -x "$TARGET_ROOT/agent-bridge" ]]; then
    _post_body="$(mktemp -t bridge-upgrade-post.XXXXXX)"
    cat >"$_post_body" <<POST_EOF
# Agent Bridge upgrade completed

- from_version: ${INSTALLED_VERSION:-unknown}
- to_version: $SOURCE_VERSION
- ref: $SOURCE_REF
- channel: $CHANNEL
- upgraded_at: $(date -Iseconds 2>/dev/null || date)

## Immediate action

The v0.4.0 wiki-graph pipeline requires a one-time bootstrap on this
host. The following sequence is idempotent — re-running produces no
drift if the state is already converged.

1. \`$TARGET_ROOT/bootstrap-memory-system.sh --apply\`
   Registers all wiki + librarian crons, provisions the dynamic
   librarian agent, and installs the Phase 1/2 scripts into
   \`$TARGET_ROOT/scripts/\`.

2. \`$TARGET_ROOT/scripts/wiki-mention-scan.py --full-rebuild\`
   Builds the initial L1 observation index
   (\`$TARGET_ROOT/shared/wiki/_index/mentions.db\`) and generates
   today's distribution report.

3. Review the distribution report at
   \`$TARGET_ROOT/shared/wiki/_index/distribution-report-<date>.md\`.
   - §1 cross-agent reach (how entities are connected).
   - §2 L2 hub candidates (the weekly cron resurfaces these as
     \`[wiki-hub-candidates]\` tasks; trigger now with the full
     command below).
   - §3 unresolved wikilinks (stubs to create or link typos to
     fix via \`agb wiki repair-links --apply\`).
   - §4 orphan entity slugs (delete candidates per
     \`wiki-entity-lifecycle.md\` §3.6).

4. Trigger the first L2 sweep manually (cron will run weekly from now on):
   \`\`\`
   $TARGET_ROOT/scripts/wiki-hub-audit.py \\
     --emit-task --admin-agent "$_post_admin" \\
     --bridge-bin "$TARGET_ROOT/agent-bridge" \\
     --out "$TARGET_ROOT/shared/wiki/_audit/hub-candidates-\$(date +%Y-%m-%d).md"
   \`\`\`

## Full onboarding

- \`docs/agent-runtime/wiki-onboarding.md\` — complete v0.4.0 admin walkthrough
- \`docs/agent-runtime/admin-protocol.md\` — Wiki Canonical Hub Curation section (weekly ritual)
- \`docs/agent-runtime/wiki-mention-index.md\` — L1 observation layer spec
- \`docs/agent-runtime/wiki-entity-lifecycle.md\` — entity schema + dedup rules
- \`docs/agent-runtime/wiki-graph-rules.md\` — graph edge policy

## What's already automatic

- MEMORY-SCHEMA.md sync to every agent home (just ran via \`bridge-docs.py apply --all\`)
- Librarian CLAUDE.md template propagation
- PreCompact hook registration on active claude agents (from bootstrap)

## Done note format

When you finish the three steps above, close this task with:
\`agb done <task_id> --note "bootstrap OK; first-scan <N> files / <M> entities; distribution report at <path>"\`
POST_EOF
    # Persist the task body in state/ so the recovery command the
    # WARN block prints is actually rerunnable. Tempfiles vanish on
    # exit and leave the operator with guidance instead of a command
    # that would copy-paste into "no such file". The persistent copy
    # is deleted only on successful task create.
    _post_body_persist_dir="$TARGET_ROOT/state/bridge-upgrade/post-task"
    mkdir -p "$_post_body_persist_dir"
    _post_body_persist="$_post_body_persist_dir/upgrade-complete-$(date -u +%Y%m%dT%H%M%SZ).md"
    cp "$_post_body" "$_post_body_persist"
    _post_task_log="$(mktemp -t bridge-upgrade-post-task.XXXXXX.log)"
    if "$TARGET_ROOT/agent-bridge" task create \
        --to "$_post_admin" --priority normal --from "$_post_admin" \
        --title "[upgrade-complete] Agent Bridge $SOURCE_VERSION — run bootstrap" \
        --body-file "$_post_body_persist" >"$_post_task_log" 2>&1; then
      # Task created successfully — queue kept a durable copy of the
      # body; the persist file in state/ is redundant.
      rm -f "$_post_body_persist"
    else
      # Surface failure on stderr so the operator sees it on upgrade.
      # A silent `|| true` here was the R9 reliability gap — the
      # entire post-upgrade signal chain is anchored on this task
      # actually being delivered. The rest of the upgrade succeeded;
      # the notification specifically did not. Re-running agb upgrade
      # retries the task emission. The persistent body stays on disk
      # so the printed recovery command is literally rerunnable.
      {
        echo "[bridge-upgrade] WARN: could not file [upgrade-complete] task for admin=$_post_admin"
        echo "[bridge-upgrade] WARN: admin inbox will not be auto-notified. Re-run 'agb upgrade' to retry, or"
        echo "[bridge-upgrade] WARN: queue manually:"
        echo "[bridge-upgrade] WARN:   $TARGET_ROOT/agent-bridge task create --to $_post_admin \\"
        echo "[bridge-upgrade] WARN:     --priority normal --from $_post_admin \\"
        echo "[bridge-upgrade] WARN:     --title '[upgrade-complete] Agent Bridge $SOURCE_VERSION — run bootstrap' \\"
        echo "[bridge-upgrade] WARN:     --body-file $_post_body_persist"
        echo "[bridge-upgrade] WARN: task create stderr follows:"
        sed 's/^/[bridge-upgrade] WARN:   /' "$_post_task_log"
      } >&2
    fi
    rm -f "$_post_body" "$_post_task_log"
  fi
fi

if [[ $RESTART_AGENTS -eq 1 ]]; then
  AGENT_RESTART_REPORT="$(bridge_upgrade_collect_agent_restart_report "$TARGET_ROOT" "$DRY_RUN")"
  AGENT_RESTART_JSON="$(bridge_upgrade_agent_restart_json "$AGENT_RESTART_REPORT" 1 "$DRY_RUN")"
fi

if [[ $JSON -eq 1 ]]; then
  python3 - "$SOURCE_ROOT" "$TARGET_ROOT" "$PULL" "$DRY_RUN" "$RESTART_DAEMON" "$RESTART_AGENTS" "$BACKUP" "$MIGRATE_AGENTS" "$BACKUP_ROOT" "$BACKUP_JSON" "$MIGRATION_JSON" "$APPLY_JSON" "$ANALYSIS_JSON" "$AGENT_RESTART_JSON" "$STRICT_MERGE" "$CHANNEL" "$SOURCE_VERSION" "$SOURCE_REF" "$SOURCE_HEAD" "$TARGET_REF" "$TARGET_VERSION" "$TARGET_HEAD" "$CHANNEL_GUARD_JSON" <<'PY'
import json, sys
source_root, target_root, pull, dry_run, restart_daemon, restart_agents, backup_enabled, migrate_agents, backup_root, backup_json, migration_json, apply_json, analysis_json, agent_restart_json, strict_merge, channel, source_version, source_ref, source_head, target_ref, target_version, target_head, channel_guard_json = sys.argv[1:]
backup_payload = json.loads(backup_json)
migration_payload = json.loads(migration_json)
apply_payload = json.loads(apply_json)
analysis_payload = json.loads(analysis_json)
agent_restart_payload = json.loads(agent_restart_json)
channel_guard_payload = json.loads(channel_guard_json)
payload = {
    "mode": "upgrade",
    "version": source_version,
    "source_root": source_root,
    "source_ref": source_ref,
    "source_head": source_head,
    "target_root": target_root,
    "channel": channel,
    "target_ref": target_ref,
    "target_version": target_version,
    "target_head": target_head,
    "pull": pull == "1",
    "dry_run": dry_run == "1",
    "restart_daemon": restart_daemon == "1",
    "restart_agents": restart_agents == "1",
    "backup_enabled": backup_enabled == "1",
    "migrate_agents": migrate_agents == "1",
    "strict_merge": strict_merge == "1",
    "backup_root": backup_root,
    "preserved_paths": [
        "agent-roster.local.sh",
        "state/",
        "logs/",
        "shared/",
        "backups/",
        "worktrees/",
        "agents/<agent>/",
    ],
    "backup": backup_payload,
    "apply": apply_payload,
    "analysis": analysis_payload,
    "channel_guard": channel_guard_payload,
    "agent_restart": agent_restart_payload,
    "agent_migration": migration_payload,
  }
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  exit 0
fi

echo "== Agent Bridge upgrade =="
echo "version: $SOURCE_VERSION"
echo "channel: $CHANNEL"
echo "source_ref: $SOURCE_REF"
echo "source_head: ${SOURCE_HEAD:0:12}"
echo "target_ref: ${TARGET_REF:-current}"
echo "source_root: $SOURCE_ROOT"
echo "target_root: $TARGET_ROOT"
echo "preserved_customizations: agent-roster.local.sh, state/, logs/, shared/, backups/, worktrees/, agents/<agent>/"
echo "strict_merge: $([[ $STRICT_MERGE -eq 1 ]] && printf yes || printf no)"
echo "restart_agents: $([[ $RESTART_AGENTS -eq 1 ]] && printf yes || printf no)"
if [[ $BACKUP -eq 1 ]]; then
  echo "backup_root: $BACKUP_ROOT"
  python3 - "$BACKUP_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(f"backup_created: {'yes' if payload.get('created') else 'no'}")
PY
fi
python3 - "$ANALYSIS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
counts = payload.get("counts", {})
print(f"analysis_base_ref: {payload.get('base_ref') or '-'}")
print(f"analysis_missing_live: {counts.get('missing_live', 0)}")
print(f"analysis_upstream_only: {counts.get('upstream_only', 0)}")
print(f"analysis_live_only: {counts.get('live_only', 0)}")
print(f"analysis_merge_required: {counts.get('merge_required', 0)}")
print(f"analysis_unknown_base_live_diff: {counts.get('unknown_base_live_diff', 0)}")
PY
bridge_upgrade_print_channel_guard_summary "$CHANNEL_GUARD_JSON"
python3 - "$APPLY_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
counts = payload.get("counts", {})
print(f"files_copied: {counts.get('files_copied', 0)}")
print(f"files_merged_clean: {counts.get('files_merged_clean', 0)}")
print(f"files_merged_conflict: {counts.get('files_merged_conflict', 0)}")
print(f"files_preserved_live: {counts.get('files_preserved_live', 0)}")
conflicts = payload.get("conflict_backups") or []
print(f"conflict_backups: {len(conflicts)}")
if conflicts:
    print("[warn] unresolved merge conflicts were backed up; review these files:")
    for path in conflicts[:10]:
        print(f"  - {path}")
    if len(conflicts) > 10:
        print(f"  ... +{len(conflicts) - 10} more")
PY
if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  python3 - "$MIGRATION_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(f"agents_migrated: {payload.get('agents_with_additions', 0)}")
print(f"migrated_files: {payload.get('added_files', 0)}")
PY
fi
bridge_upgrade_print_agent_restart_summary "$AGENT_RESTART_JSON"
