#!/usr/bin/env bash
# bootstrap-memory-system.sh — idempotent provisioner for the v0.4.0+
# wiki-graph automation stack: PreCompact hook + v2 hybrid index +
# dynamic librarian agent + nine admin-owned crons (wiki-*,
# librarian-watchdog).
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

# Admin agent used as cron owner + escalation target. Defaults to
# `patch` to preserve the reference-install convention, but any install
# that names its admin differently can export BRIDGE_ADMIN_AGENT.
# If no admin env is set at invocation time, source the agent roster to
# pick up BRIDGE_ADMIN_AGENT_ID persisted by `agb setup admin`. Operator-
# shell bootstrap runs then resolve the real admin name even when the
# calling shell has not inherited the env from a bridge-managed session.
# The roster files are plain shell that set `BRIDGE_ADMIN_AGENT_ID="..."`.
if [[ -z "${BRIDGE_ADMIN_AGENT:-}${BRIDGE_ADMIN_AGENT_ID:-}" ]]; then
  # Roster files assume bridge-lib.sh is already loaded (they call
  # `bridge_add_agent_id_if_missing` and write into declared -A arrays).
  # We don't need any of that — only the BRIDGE_ADMIN_AGENT_ID line.
  # Extract it without executing the rest of the file.
  for _roster in "$BRIDGE_HOME/agent-roster.local.sh" "$BRIDGE_HOME/agent-roster.sh"; do
    if [[ -r "$_roster" ]]; then
      _admin_line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=' "$_roster" | head -n 1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=//; s/^"([^"]*)".*/\1/; s/^'"'"'([^'"'"']*)'"'"'.*/\1/; s/[[:space:]]*#.*$//')"
      if [[ -n "$_admin_line" ]]; then
        BRIDGE_ADMIN_AGENT_ID="$_admin_line"
        export BRIDGE_ADMIN_AGENT_ID
        break
      fi
    fi
  done
fi

: "${BRIDGE_ADMIN_AGENT:=${BRIDGE_ADMIN_AGENT_ID:-patch}}"
export BRIDGE_ADMIN_AGENT
export BRIDGE_ADMIN_AGENT_ID="${BRIDGE_ADMIN_AGENT_ID:-$BRIDGE_ADMIN_AGENT}"

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
  3. Ensure the dynamic `librarian` agent is provisioned.
  4. Register the wiki-* + librarian-watchdog cron set on the admin
     agent (default: `patch`; override with BRIDGE_ADMIN_AGENT env).

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
  # L2 candidacy. Weekly scan of mentions.db → candidate report +
  # [wiki-hub-candidates] task for the admin agent. Admin judgement
  # required before canonical hub authoring — automation stops here.
  "wiki-hub-audit|0 23 * * 4|Asia/Seoul|wiki-hub-audit.sh"
)

# Fetch existing crons once, parse JSON, cache a title→{schedule,tz,id} map.
EXISTING_CRONS_JSON="$(mktemp -t bootstrap-crons.XXXXXX.json)"
"$BRIDGE_AGB" cron list --agent "$BRIDGE_ADMIN_AGENT" --json >"$EXISTING_CRONS_JSON" 2>/dev/null || echo '[]' > "$EXISTING_CRONS_JSON"

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
    local existing_sched existing_tz
    existing_sched="$(printf '%s' "$found" | awk -F'\t' '{print $2}')"
    existing_tz="$(printf '%s' "$found" | awk -F'\t' '{print $3}')"
    # Cron list may return several shapes across bridge-cron versions:
    #   "cron <expr>"                  e.g. "cron 0 22 * * 0"
    #   "<expr>"                       e.g. "0 22 * * 0"
    #   "cron <expr> <tz>"             e.g. "cron 0 22 * * 0 Asia/Seoul"
    #   "<expr> <tz>"                  e.g. "0 22 * * 0 Asia/Seoul"
    # Our expected value is the bare expression (no "cron " prefix, no tz).
    # Normalize both sides to a 5-field cron expression before comparing
    # AND separately compare the timezone — two identical 5-field
    # expressions in different TZs fire at completely different wall
    # times, so skipping tz can register `already` for the wrong slot.
    local norm_existing norm_expected trailing_tz
    norm_existing="${existing_sched#cron }"
    # Split the normalized string into (cron-expr, tz). Anything from
    # the 6th whitespace run onward is treated as the tz expression.
    trailing_tz="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(" ".join(parts[5:]))' "$norm_existing")"
    norm_existing="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(" ".join(parts[:5]))' "$norm_existing")"
    # Prefer the explicit `tz` column from cron_lookup; fall back to the
    # trailing-tz chunk of the schedule string.
    local effective_existing_tz="${existing_tz:-$trailing_tz}"
    norm_expected="$sched"
    if [[ "$norm_existing" == "$norm_expected" && "$effective_existing_tz" == "$tz" ]]; then
      record "$BRIDGE_ADMIN_AGENT" "cron:$title" "already-registered" "$existing_sched tz=$effective_existing_tz"
      return 0
    else
      record "$BRIDGE_ADMIN_AGENT" "cron:$title" "conflict" "existing=$existing_sched tz=$effective_existing_tz want=$sched tz=$tz — refusing"
      note_drift
      return 0
    fi
  fi

  if [[ "$MODE" == "check" ]]; then
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "drift-missing" ""
    note_drift
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "would-register" "schedule=$sched tz=$tz"
    return 0
  fi

  # apply: copy script into $BRIDGE_HOME/scripts/ (idempotent) then register.
  # The operator is expected to have copied _common.sh as well (this bootstrap
  # does it below, before the loop runs — see bootstrap_install_scripts).
  if [[ ! -x "$installed_script" ]]; then
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "skip-script-missing" "$installed_script"
    note_drift
    return 0
  fi

  local payload
  payload="bash $installed_script"

  if "$BRIDGE_AGB" cron create --agent "$BRIDGE_ADMIN_AGENT" \
        --schedule "$sched" \
        --tz "$tz" \
        --title "$title" \
        --payload "$payload" \
        >/dev/null 2>&1; then
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "registered" "$sched $tz"
  else
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "register-failed" ""
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
           wiki-hub-audit.py wiki-hub-audit.sh \
           sync-memory-schema.py \
           librarian-provision.sh librarian-watchdog.sh librarian-idle-exit.sh \
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

  # librarian-provision.sh resolves its CLAUDE.md template at
  # $SCRIPT_DIR/agents/librarian/CLAUDE.md. On a downstream install
  # where $BRIDGE_HOME != the repo checkout, this file is missing
  # unless we explicitly stage it. Ensure the template sits next to
  # the provisioner before step_librarian_provision runs.
  local agents_src="$SCRIPT_DIR/scripts/agents"
  local agents_dst="$BRIDGE_HOME/scripts/agents"
  if [[ -d "$agents_src" ]]; then
    local templ_changed=0
    while IFS= read -r -d '' src; do
      local rel="${src#$agents_src/}"
      local dst="$agents_dst/$rel"
      if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        continue
      fi
      if [[ "$MODE" == "check" ]]; then
        note_drift
        record "install" "template:agents/$rel" "drift-mismatch" ""
        continue
      fi
      if [[ "$MODE" == "dry-run" ]]; then
        record "install" "template:agents/$rel" "would-install" ""
        continue
      fi
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      templ_changed=$((templ_changed + 1))
      record "install" "template:agents/$rel" "installed" ""
    done < <(find "$agents_src" -type f -name '*.md' -print0 2>/dev/null)
    [[ "$templ_changed" -gt 0 ]] && log "agent templates changed: $templ_changed"
  fi
}

# -----------------------------------------------------------------------------
# librarian provisioning (dynamic agent — required for Lane B ingest)
# -----------------------------------------------------------------------------
step_librarian_provision() {
  local provision_script="$BRIDGE_HOME/scripts/librarian-provision.sh"
  if [[ ! -x "$provision_script" ]]; then
    record "librarian" "provision" "skip-script-missing" "$provision_script"
    note_drift
    return 0
  fi
  # Fast-path: librarian already registered → no-op. The provision script
  # is idempotent but this avoids an extra subprocess on common case.
  if "$BRIDGE_AGB" agent list 2>/dev/null | awk '{print $1}' | grep -qx "librarian"; then
    record "librarian" "provision" "already-provisioned" ""
    return 0
  fi
  if [[ "$MODE" == "check" ]]; then
    note_drift
    record "librarian" "provision" "drift-missing" ""
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "librarian" "provision" "would-provision" ""
    return 0
  fi
  if bash "$provision_script" >>"$RECORD_FILE.provision.log" 2>&1; then
    record "librarian" "provision" "provisioned" ""
  else
    record "librarian" "provision" "provision-failed" \
      "see $RECORD_FILE.provision.log"
    note_drift
  fi
}

# -----------------------------------------------------------------------------
# run all steps
# -----------------------------------------------------------------------------
bootstrap_install_scripts
step_librarian_provision

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
# first-run post-bootstrap signal — queue the "do the first scan + hub
# candidate review" task for the admin agent. Only fires once per install;
# subsequent --apply runs skip so the admin isn't spammed.
# -----------------------------------------------------------------------------
FIRST_RUN_MARKER="$REPORT_DIR/.first-run-complete"
# Only emit the first-run task when:
#   - mode is apply (dry-run / check never notify)
#   - marker does not yet exist (prevents spam on re-applies)
#   - bootstrap converged (DRIFT=0 — no install/register failures)
#   - bridge CLI is executable
# AND only write the marker AFTER `agb task create` succeeds, so if
# task creation fails we retry the signal on the next --apply.
if [[ "$MODE" == "apply" && ! -f "$FIRST_RUN_MARKER" \
      && "$DRIFT" -eq 0 && -x "$BRIDGE_AGB" ]]; then
  FIRST_RUN_BODY="$(mktemp -t bootstrap-first-run.XXXXXX)"
  cat >"$FIRST_RUN_BODY" <<FR_EOF
# Wiki pipeline bootstrap completed — first run on this host

- bootstrap_report: $REPORT
- admin_agent: $BRIDGE_ADMIN_AGENT
- bridge_home: $BRIDGE_HOME
- completed_at: $(date -Iseconds 2>/dev/null || date)

## Next steps (one-time)

1. Full mention scan — builds shared/wiki/_index/mentions.db and
   today's distribution report. Idempotent, safe to re-run.
   \`$BRIDGE_HOME/scripts/wiki-mention-scan.py --full-rebuild\`

2. Review the distribution report. Use every section:
   - §1 cross-agent reach — sanity check.
   - §2 L2 hub candidates — the weekly cron resurfaces these as
     \`[wiki-hub-candidates]\` tasks; trigger now in step 3.
   - §3 unresolved wikilinks — typos or missing stubs. Fix
     unambiguous targets with \`agb wiki repair-links --apply\`.
   - §4 orphan entity slugs — delete per
     \`docs/agent-runtime/wiki-entity-lifecycle.md\` §3.6 or
     leave until Phase 3 LLM can classify.
   Path: \`$BRIDGE_WIKI_ROOT/_index/distribution-report-<date>.md\`

3. Trigger the first L2 candidacy sweep now (cron will run this
   weekly on Thursday 23:00 KST from now on):
   \`\`\`
   $BRIDGE_HOME/scripts/wiki-hub-audit.py \\
     --emit-task --admin-agent $BRIDGE_ADMIN_AGENT \\
     --bridge-bin $BRIDGE_AGB \\
     --out $BRIDGE_WIKI_ROOT/_audit/hub-candidates-\$(date +%Y-%m-%d).md
   \`\`\`
   Note: \`--emit-task\` requires \`--out\`; without \`--out\`
   the script writes to stdout and skips the task creation.

4. When the \`[wiki-hub-candidates]\` task lands, process per
   \`docs/agent-runtime/admin-protocol.md\` "Wiki Canonical Hub
   Curation" section.

## Pipeline reference

- \`docs/agent-runtime/wiki-onboarding.md\` — full admin walkthrough
- \`docs/agent-runtime/admin-protocol.md\` — weekly hub curation ritual
- \`docs/agent-runtime/wiki-mention-index.md\` — L1 schema + cadence
- \`docs/agent-runtime/wiki-entity-lifecycle.md\` — entity frontmatter rules
- \`docs/agent-runtime/wiki-graph-rules.md\` — graph edge policy

## Done

Close with: \`agb done <task_id> --note "first scan <N> files / <E> entities; <C> hub candidates for review"\`
FR_EOF
  if "$BRIDGE_AGB" task create \
      --to "$BRIDGE_ADMIN_AGENT" --priority normal --from "$BRIDGE_ADMIN_AGENT" \
      --title "[wiki-system-first-run] bootstrap complete — do initial scan" \
      --body-file "$FIRST_RUN_BODY" >/dev/null 2>&1; then
    : > "$FIRST_RUN_MARKER"
  fi
  rm -f "$FIRST_RUN_BODY"
elif [[ "$MODE" == "apply" && ! -f "$FIRST_RUN_MARKER" && "$DRIFT" -gt 0 ]]; then
  # Bootstrap did not converge cleanly. Do NOT emit a "complete" task
  # and do NOT write the marker — the next --apply will retry once
  # the underlying failures are fixed.
  log "first-run signal deferred: drift=$DRIFT (bootstrap did not converge)"
fi

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
