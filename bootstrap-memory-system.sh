#!/usr/bin/env bash
# bootstrap-memory-system.sh — idempotent provisioner for the Plan-D memory
# stack (PreCompact hook + v2 hybrid index + 5 wiki-* crons).
#
# Modes:
#   --apply   (default) : converge the install toward the target state.
#   --dry-run           : report intended actions, mutate nothing, exit 0.
#   --check             : assert fully converged; exit 1 on any drift.
#
# Re-runnable: the 2nd run must be a no-op. Each step hashes or probes the live
# state before mutating.
#
# All outputs under $BRIDGE_STATE_ROOT/bootstrap-memory/.
#
# IMPORTANT: this script targets a *downstream* reference install. Never
# commit to applying on production without review.

set -euo pipefail

# -----------------------------------------------------------------------------
# locate bridge-home and load _common helpers
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
export BRIDGE_HOME

# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/_common.sh"

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
MODE="apply"
INDEX_STALE_DAYS=7
TARGET_AGENT=""
while (( $# > 0 )); do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    --apply)   MODE="apply" ;;
    --agent)   TARGET_AGENT="${2:-}"; shift ;;
    --stale-days) INDEX_STALE_DAYS="${2:-7}"; shift ;;
    -h|--help)
      cat <<EOF
usage: $(basename "$0") [--apply|--dry-run|--check] [--agent <name>] [--stale-days N]

Steps:
  1. PreCompact hook per active claude agent.
  2. v2 hybrid index rebuild per active claude agent (skip if fresh).
  3. Register 5 patch-owned wiki-* crons.

JSON report written to \$BRIDGE_STATE_ROOT/bootstrap-memory/report-<stamp>.json
EOF
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# output / report setup
# -----------------------------------------------------------------------------
REPORT_DIR="$BRIDGE_STATE_ROOT/bootstrap-memory"
mkdir -p "$REPORT_DIR"
STAMP="$(abs_stamp)"
REPORT="$REPORT_DIR/report-$STAMP.json"
TMP_REPORT="$REPORT.partial"

# Per-agent step records: "<agent>\t<step>\t<status>\t<note>"
RECORD_FILE="$(mktemp -t bootstrap-memory.XXXXXX)"
trap 'rm -f "$RECORD_FILE" "$TMP_REPORT" 2>/dev/null || true' EXIT

record() {
  # record <agent> <step> <status> <note>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$RECORD_FILE"
}

log() { printf '[%s] %s\n' "$MODE" "$*"; }

DRIFT=0
note_drift() { DRIFT=$((DRIFT + 1)); }

# -----------------------------------------------------------------------------
# load agents
# -----------------------------------------------------------------------------
AGENT_LIST_TMP="$(mktemp -t bootstrap-memory-agents.XXXXXX)"
list_active_claude_agents > "$AGENT_LIST_TMP"
if [[ -n "$TARGET_AGENT" ]]; then
  grep -E "^${TARGET_AGENT}"$'\t' "$AGENT_LIST_TMP" > "$AGENT_LIST_TMP.filt" || true
  mv "$AGENT_LIST_TMP.filt" "$AGENT_LIST_TMP"
fi
AGENT_COUNT=$(wc -l < "$AGENT_LIST_TMP" | tr -d ' ')
log "active claude agents: $AGENT_COUNT"

# -----------------------------------------------------------------------------
# step 1: PreCompact hook
# -----------------------------------------------------------------------------
hook_bootstrap_backup_tag="bootstrap-$STAMP"

step_hook_one() {
  local agent="$1" home="$2"
  local settings="$home/.claude/settings.json"

  if [[ ! -f "$home/CLAUDE.md" ]]; then
    record "$agent" "hook" "skip-no-claude-md" "no CLAUDE.md"
    return 0
  fi
  if [[ ! -f "$settings" ]]; then
    record "$agent" "hook" "skip-no-settings" "no settings.json"
    return 0
  fi

  # Status first: if PreCompact is already wired, skip silently.
  if "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-hooks.py" status-pre-compact-hook \
        --workdir "$home" \
        --bridge-home "$BRIDGE_HOME" \
        --python-bin "$BRIDGE_PYTHON" \
        --settings-file "$settings" \
        >/dev/null 2>&1; then
    record "$agent" "hook" "already-installed" ""
    return 0
  fi

  if [[ "$MODE" == "check" ]]; then
    record "$agent" "hook" "drift-missing" ""
    note_drift
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "$agent" "hook" "would-install" ""
    return 0
  fi

  # apply path: backup once per agent, then install.
  local bak="$settings.bak-$hook_bootstrap_backup_tag"
  if [[ ! -f "$bak" ]]; then
    cp "$settings" "$bak"
  fi
  if "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-hooks.py" ensure-pre-compact-hook \
        --workdir "$home" \
        --bridge-home "$BRIDGE_HOME" \
        --python-bin "$BRIDGE_PYTHON" \
        --settings-file "$settings" \
        >/dev/null 2>&1; then
    record "$agent" "hook" "installed" "bak=$bak"
  else
    record "$agent" "hook" "install-failed" ""
  fi
}

# -----------------------------------------------------------------------------
# step 2: v2 hybrid rebuild-index
# -----------------------------------------------------------------------------
step_rebuild_one() {
  local agent="$1" home="$2"
  local db="$home/memory/index.sqlite"

  # Fresh check: if db exists AND index_kind==v2 AND chunks>0 AND
  # indexed_at within $INDEX_STALE_DAYS → skip.
  if [[ -f "$db" ]]; then
    local fresh_status
    fresh_status=$("$BRIDGE_PYTHON" - "$db" "$INDEX_STALE_DAYS" <<'PY'
import sqlite3, sys, datetime
db = sys.argv[1]
stale_days = int(sys.argv[2])
try:
    con = sqlite3.connect(db)
    cur = con.cursor()
    cur.execute("SELECT value FROM meta WHERE key='index_kind'")
    r = cur.fetchone()
    kind = r[0] if r else ""
    cur.execute("SELECT COUNT(*) FROM chunks")
    chunks = cur.fetchone()[0]
    cur.execute("SELECT value FROM meta WHERE key='indexed_at'")
    r = cur.fetchone()
    indexed_at = r[0] if r else ""
    con.close()
except Exception as e:
    print(f"missing:{e}")
    sys.exit(0)
if kind != "bridge-wiki-hybrid-v2":
    print(f"wrong-kind:{kind}")
    sys.exit(0)
if chunks <= 0:
    print("empty")
    sys.exit(0)
try:
    ts = datetime.datetime.fromisoformat(indexed_at.replace("Z","+00:00")) if indexed_at else None
except Exception:
    ts = None
if ts is None:
    print("no-ts")
    sys.exit(0)
age = datetime.datetime.now(datetime.timezone.utc) - (ts if ts.tzinfo else ts.replace(tzinfo=datetime.timezone.utc))
if age.days < stale_days:
    print(f"fresh:{age.days}d")
else:
    print(f"stale:{age.days}d")
PY
)
    case "$fresh_status" in
      fresh:*)
        record "$agent" "index" "already-fresh" "$fresh_status"
        return 0
        ;;
    esac
  fi

  if [[ "$MODE" == "check" ]]; then
    record "$agent" "index" "drift-stale-or-missing" ""
    note_drift
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "$agent" "index" "would-rebuild" ""
    return 0
  fi

  # apply: sequential rebuild via the same wiki-v2-rebuild logic but
  # in-process (no cron). We reuse bridge-memory.py directly but with the
  # tmp+swap pattern.
  local tmp_db="$db.rebuilding-$STAMP"
  rm -f "$tmp_db"
  if ! run_with_timeout 900 "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" rebuild-index \
        --agent "$agent" --home "$home" \
        --bridge-home "$BRIDGE_HOME" \
        --index-kind bridge-wiki-hybrid-v2 \
        --shared-root "$BRIDGE_SHARED_ROOT" \
        --db-path "$tmp_db" \
        --json \
        >/dev/null 2>&1; then
    record "$agent" "index" "rebuild-failed" ""
    return 0
  fi
  if ! "$BRIDGE_PYTHON" - "$tmp_db" <<'PY'
import sqlite3, sys
p = sys.argv[1]
con = sqlite3.connect(p); cur = con.cursor()
cur.execute("SELECT value FROM meta WHERE key='index_kind'")
r = cur.fetchone()
kind = r[0] if r else ""
cur.execute("SELECT COUNT(*) FROM chunks")
chunks = cur.fetchone()[0]
con.close()
sys.exit(0 if (kind == "bridge-wiki-hybrid-v2" and chunks > 0) else 1)
PY
  then
    rm -f "$tmp_db"
    record "$agent" "index" "validate-failed" ""
    return 0
  fi
  mkdir -p "$(dirname "$db")"
  mv -f "$tmp_db" "$db"
  record "$agent" "index" "rebuilt" ""
}

# -----------------------------------------------------------------------------
# step 3: 5 wiki-* crons
# -----------------------------------------------------------------------------

# Canonical cron definitions — one source of truth. Title MUST match exactly
# for re-entrancy detection.
#
# NOTE: cron create uses --payload (not --command). The payload we ship is the
# path to the shell script plus a conventional "exec" hint that downstream
# cron runners interpret via `bash <payload>` (see bridge-cron-runner.py).
CRON_SPECS=(
  # title|schedule|tz|script
  "wiki-weekly-summarize|0 22 * * 0|Asia/Seoul|wiki-weekly-summarize.sh"
  "wiki-monthly-summarize|0 2 1 * *|Asia/Seoul|wiki-monthly-summarize.sh"
  "wiki-repair-links|0 5 * * 6|Asia/Seoul|wiki-repair-links.sh"
  "wiki-v2-rebuild|0 6 * * 6|Asia/Seoul|wiki-v2-rebuild.sh"
  "wiki-dedup-weekly|0 4 * * 0|Asia/Seoul|wiki-dedup-weekly.sh"
  # Daily-note two-lane ingest. Lane A (wiki-daily-copy.py) runs inside
  # the shell script; Lane B queues [librarian-ingest] for non-daily.
  "wiki-daily-ingest|0 3 * * *|Asia/Seoul|wiki-daily-ingest.sh"
  # L1 observation scanner. Populates shared/wiki/_index/mentions.db and
  # the distribution-report snapshot. Offset :17 misses top-of-hour cluster.
  "wiki-mention-scan|17 * * * *|Asia/Seoul|wiki-mention-scan.sh"
  # Librarian is dynamic (session-type=dynamic). Watchdog polls every
  # 10 min for [librarian-ingest] tasks and starts the agent on demand.
  "librarian-watchdog|*/10 * * * *|Asia/Seoul|librarian-watchdog.sh"
)

# Fetch existing crons once, parse JSON, cache a title→{schedule,tz,id} map.
EXISTING_CRONS_JSON="$(mktemp -t bootstrap-crons.XXXXXX.json)"
"$BRIDGE_AGB" cron list --agent patch --json >"$EXISTING_CRONS_JSON" 2>/dev/null || echo '[]' > "$EXISTING_CRONS_JSON"

cron_lookup() {
  # cron_lookup <title> — prints "id<TAB>schedule<TAB>tz" or empty.
  local title="$1"
  "$BRIDGE_PYTHON" - "$EXISTING_CRONS_JSON" "$title" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
title = sys.argv[2]
# `agent-bridge cron list --json` can emit either a bare list (older versions)
# or an object with a `jobs` key (current). Handle both shapes.
if isinstance(data, dict):
    jobs = data.get("jobs") or []
elif isinstance(data, list):
    jobs = data
else:
    jobs = []
for j in jobs:
    if not isinstance(j, dict):
        continue
    # `agent-bridge cron list --json` exposes the display name under
    # either `title` (older tooling) or `name` (current bridge-cron.sh).
    # Same story for schedule: `schedule` vs `schedule_text`. Try both.
    name = j.get("title") or j.get("name") or ""
    # Some installs also suffix a short uuid to the name (e.g. when two
    # jobs share the canonical title). Tolerate that by matching on the
    # stem before the first "-<hex>" or by exact match.
    def _matches(candidate: str, wanted: str) -> bool:
        if candidate == wanted:
            return True
        # Trim trailing "-<8 hex>" that some installs add after create.
        import re
        stem = re.sub(r"-[0-9a-f]{8,}$", "", candidate)
        return stem == wanted
    if _matches(name, title):
        sched = j.get("schedule") or j.get("schedule_text") or ""
        tz = j.get("tz") or j.get("timezone") or j.get("schedule_tz") or ""
        jid = j.get("id") or j.get("job_id") or ""
        print(f"{jid}\t{sched}\t{tz}")
        break
PY
}

step_cron_one() {
  local title="$1" sched="$2" tz="$3" script="$4"

  # The script lives under the bootstrap-shipped scripts/ dir. We resolve
  # the *installed* script path by convention: scripts are copied to
  # $BRIDGE_HOME/scripts/ when this bootstrap runs with --apply.
  local installed_script="$BRIDGE_HOME/scripts/$script"

  local found
  found="$(cron_lookup "$title" || true)"
  if [[ -n "$found" ]]; then
    local existing_sched
    existing_sched="$(printf '%s' "$found" | awk -F'\t' '{print $2}')"
    # Cron list may return several shapes across bridge-cron versions:
    #   "cron <expr>"                  e.g. "cron 0 22 * * 0"
    #   "<expr>"                       e.g. "0 22 * * 0"
    #   "cron <expr> <tz>"             e.g. "cron 0 22 * * 0 Asia/Seoul"
    #   "<expr> <tz>"                  e.g. "0 22 * * 0 Asia/Seoul"
    # Our expected value is the bare expression (no "cron " prefix, no tz).
    # Normalize both sides to a 5-field cron expression before comparing.
    local norm_existing norm_expected
    norm_existing="${existing_sched#cron }"
    # If the expression carries a trailing timezone (contains '/' after
    # the five cron fields), drop everything from the 6th whitespace run.
    norm_existing="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(" ".join(parts[:5]))' "$norm_existing")"
    norm_expected="$sched"
    if [[ "$norm_existing" == "$norm_expected" ]]; then
      record "patch" "cron:$title" "already-registered" "$existing_sched"
      return 0
    else
      record "patch" "cron:$title" "conflict" "existing=$existing_sched want=$sched — refusing"
      note_drift
      return 0
    fi
  fi

  if [[ "$MODE" == "check" ]]; then
    record "patch" "cron:$title" "drift-missing" ""
    note_drift
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "patch" "cron:$title" "would-register" "schedule=$sched tz=$tz"
    return 0
  fi

  # apply: copy script into $BRIDGE_HOME/scripts/ (idempotent) then register.
  # The operator is expected to have copied _common.sh as well (this bootstrap
  # does it below, before the loop runs — see bootstrap_install_scripts).
  if [[ ! -x "$installed_script" ]]; then
    record "patch" "cron:$title" "skip-script-missing" "$installed_script"
    note_drift
    return 0
  fi

  local payload
  payload="bash $installed_script"

  if "$BRIDGE_AGB" cron create --agent patch \
        --schedule "$sched" \
        --tz "$tz" \
        --title "$title" \
        --payload "$payload" \
        >/dev/null 2>&1; then
    record "patch" "cron:$title" "registered" "$sched $tz"
  else
    record "patch" "cron:$title" "register-failed" ""
  fi
}

# -----------------------------------------------------------------------------
# scripts installation (apply only)
# -----------------------------------------------------------------------------
bootstrap_install_scripts() {
  local target="$BRIDGE_HOME/scripts"
  mkdir -p "$target"
  local changed=0
  for f in _common.sh wiki-weekly-summarize.sh wiki-monthly-summarize.sh \
           wiki-repair-links.sh wiki-v2-rebuild.sh wiki-dedup-weekly.sh \
           wiki-daily-ingest.sh wiki-daily-copy.py \
           wiki-mention-scan.py wiki-mention-scan.sh \
           sync-memory-schema.py \
           librarian-watchdog.sh librarian-idle-exit.sh \
           librarian-process-ingest.py; do
    local src="$SCRIPT_DIR/scripts/$f"
    local dst="$target/$f"
    if [[ ! -f "$src" ]]; then
      log "warn: source script missing: $src"
      continue
    fi
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      continue
    fi
    if [[ "$MODE" == "check" ]]; then
      note_drift
      record "install" "script:$f" "drift-mismatch" ""
      continue
    fi
    if [[ "$MODE" == "dry-run" ]]; then
      record "install" "script:$f" "would-install" ""
      continue
    fi
    cp "$src" "$dst"
    chmod 0755 "$dst"
    changed=$((changed + 1))
    record "install" "script:$f" "installed" ""
  done
  log "scripts changed: $changed"
}

# -----------------------------------------------------------------------------
# run all steps
# -----------------------------------------------------------------------------
bootstrap_install_scripts

while IFS=$'\t' read -r agent home; do
  [[ -z "$agent" || -z "$home" ]] && continue
  step_hook_one "$agent" "$home"
  step_rebuild_one "$agent" "$home"
done < "$AGENT_LIST_TMP"

for spec in "${CRON_SPECS[@]}"; do
  IFS='|' read -r title sched tz script <<<"$spec"
  step_cron_one "$title" "$sched" "$tz" "$script"
done

rm -f "$EXISTING_CRONS_JSON" "$AGENT_LIST_TMP"

# -----------------------------------------------------------------------------
# emit JSON report
# -----------------------------------------------------------------------------
"$BRIDGE_PYTHON" - "$RECORD_FILE" "$MODE" "$DRIFT" "$REPORT" <<'PY'
import json, sys, datetime, pathlib
record_file, mode, drift_str, out_path = sys.argv[1:5]
drift = int(drift_str)
records = []
with open(record_file, encoding="utf-8") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        while len(parts) < 4:
            parts.append("")
        agent, step, status, note = parts
        records.append({"agent": agent, "step": step, "status": status, "note": note})
payload = {
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "mode": mode,
    "drift": drift,
    "record_count": len(records),
    "records": records,
}
pathlib.Path(out_path).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
print(f"report: {out_path}")
PY

log "done mode=$MODE drift=$DRIFT"

# Exit policy:
# - apply: 0 unless install-failed or register-failed records exist.
# - dry-run: 0 always (report is the output).
# - check: 0 only when drift==0, else 1.
case "$MODE" in
  check)
    if (( DRIFT > 0 )); then exit 1; fi
    ;;
  apply)
    # Escalate to 2 if any hard-fail step happened.
    if grep -qE $'\t'"(install-failed|register-failed|rebuild-failed|validate-failed)"$'\t' "$RECORD_FILE"; then
      exit 2
    fi
    ;;
esac
exit 0
