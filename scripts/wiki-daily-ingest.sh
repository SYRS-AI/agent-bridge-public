#!/bin/bash
# Wiki daily ingest orchestrator (Phase 1 hardening — 2026-04-19).
#
# Two lanes:
#
#   Lane A — daily-note replication (deterministic, no LLM):
#     Agent memory/YYYY-MM-DD.md files are copied as byte-equivalent
#     replicas to shared/wiki/agents/<agent>/daily/<agent>-YYYY-MM-DD.md
#     per wiki-graph-rules.md §2. Handled by wiki-daily-copy.py.
#
#   Lane B — non-daily capture ingest (LLM-assisted):
#     Research/project/decision/shared files modified in the last 24h
#     are queued as a [librarian-ingest] task. Daily notes are NEVER
#     included in this lane — previously that caused misrouting into
#     operating-rules.md because daily notes carry no schema_version=1
#     envelope and hit the librarian ambiguous-fallback path.
#
# This script runs both lanes in sequence. Either can no-op cleanly.

set -u
# Resolve bridge home + paths from env with sane defaults. Do not
# hardcode ~/.agent-bridge — other deployments may relocate.
: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
: "${BRIDGE_AGENTS_ROOT:=$BRIDGE_HOME/agents}"
: "${BRIDGE_SHARED_ROOT:=$BRIDGE_HOME/shared}"
: "${BRIDGE_WIKI_ROOT:=$BRIDGE_SHARED_ROOT/wiki}"
: "${BRIDGE_SCRIPTS_ROOT:=$BRIDGE_HOME/scripts}"
: "${BRIDGE_STATE_DIR:=$BRIDGE_HOME/state}"
: "${BRIDGE_AGB:=$BRIDGE_HOME/agent-bridge}"
: "${BRIDGE_ADMIN_AGENT:=${BRIDGE_ADMIN_AGENT_ID:-patch}}"

# Watermark of the last successful Lane A ingest. Persisted between runs so
# late-arriving daily notes (written after the previous run's window) are
# still picked up on the next run instead of being stranded by the static
# 2-day rolling window. See issue #321 Track A.
WIKI_INGEST_STATE_DIR="$BRIDGE_STATE_DIR/wiki"
WIKI_INGEST_WATERMARK_FILE="$WIKI_INGEST_STATE_DIR/last-ingest.txt"

AGENTS_ROOT="$BRIDGE_AGENTS_ROOT"
WIKI="$BRIDGE_WIKI_ROOT"
SCRIPTS_ROOT="$BRIDGE_SCRIPTS_ROOT"
DATE=$(date +%Y-%m-%d)

# compute_since_date — resolve effective --since for Lane A.
#
# Reads the persisted watermark if it exists and parses as YYYY-MM-DD.
# Falls back to "yesterday" on missing/empty/malformed input. Clamps the
# result to max(watermark, today-14d) so a long-stale watermark cannot
# trigger an unbounded backfill. The 14-day floor matches the practical
# lookback window operators care about; revisit if data shows otherwise.
compute_since_date() {
  local watermark=""
  if [ -f "$WIKI_INGEST_WATERMARK_FILE" ]; then
    watermark="$(head -n1 "$WIKI_INGEST_WATERMARK_FILE" 2>/dev/null | tr -d '[:space:]')"
    if ! [[ "$watermark" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      watermark=""
    fi
  fi
  local default_since
  default_since=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  if [ -z "$watermark" ]; then
    printf '%s' "$default_since"
    return 0
  fi
  local floor
  floor=$(date -v-14d +%Y-%m-%d 2>/dev/null || date -d '14 days ago' +%Y-%m-%d)
  # Lexicographic compare is correct for ISO-8601 YYYY-MM-DD.
  if [[ "$watermark" < "$floor" ]]; then
    printf '%s' "$floor"
  else
    printf '%s' "$watermark"
  fi
}

YESTERDAY="$(compute_since_date)"
LOG="$WIKI/_audit/ingest-$DATE.md"
mkdir -p "$(dirname "$LOG")"

# write_watermark_atomic — durable, crash-safe watermark write.
#
# Writes to a tempfile in the same directory and renames into place so a
# crash mid-write cannot leave a partial / corrupt watermark behind.
write_watermark_atomic() {
  local date_str="$1"
  mkdir -p "$WIKI_INGEST_STATE_DIR" || return 1
  local tmp
  tmp="$(mktemp "$WIKI_INGEST_STATE_DIR/.last-ingest.XXXXXX")" || return 1
  printf '%s\n' "$date_str" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$WIKI_INGEST_WATERMARK_FILE"
}

# -------------------------------------------------------------------------
# Lane A — daily-note byte-replica copy (no librarian involvement)
# -------------------------------------------------------------------------

COPY_JSON="$(mktemp -t wiki-daily-copy.XXXXXX.json)"
# shellcheck disable=SC2064
trap "rm -f '$COPY_JSON'" EXIT

copy_rc=0
python3 "$SCRIPTS_ROOT/wiki-daily-copy.py" \
  --since "$YESTERDAY" --until "$DATE" --json \
  >"$COPY_JSON" 2>>"$LOG" || copy_rc=$?

copy_summary=$(python3 - "$COPY_JSON" <<'PYEOF'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    print("copy-summary-unavailable")
    sys.exit(0)
print(
    f"agents={data.get('agents_seen',0)} "
    f"files={data.get('files_seen',0)} "
    f"created={data.get('created',0)} "
    f"replaced={data.get('replaced',0)} "
    f"unchanged={data.get('unchanged',0)} "
    f"errors={data.get('errors',0)}"
)
PYEOF
)

# Extract Lane A error count for watermark gating. Treat parse failure /
# missing field as non-zero so we never advance the watermark on a run we
# could not verify succeeded.
copy_errors=$(python3 - "$COPY_JSON" <<'PYEOF'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
    print(int(data.get("errors", 1)))
except Exception:
    print(1)
PYEOF
)

# -------------------------------------------------------------------------
# Lane B — non-daily captures for librarian ingest
# -------------------------------------------------------------------------

# Research files touched in last 24h.
touched_research=$(find "$AGENTS_ROOT"/*/memory/research -type f -name '*.md' -mtime -1 2>/dev/null | sort)
research_count=$(printf '%s\n' "$touched_research" | grep -c '[^[:space:]]' || true)
research_count=${research_count:-0}

# projects/shared/decisions files touched in last 24h.
touched_other=$(find "$AGENTS_ROOT"/*/memory/projects "$AGENTS_ROOT"/*/memory/shared "$AGENTS_ROOT"/*/memory/decisions -type f -name '*.md' -mtime -1 2>/dev/null | sort)
other_count=$(printf '%s\n' "$touched_other" | grep -c '[^[:space:]]' || true)
other_count=${other_count:-0}

non_daily_total=$(( research_count + other_count ))

# Audit log — always written.
{
  echo "# Wiki Daily Ingest Queue — $DATE"
  echo ""
  echo "## Lane A (daily byte-replica copy, no librarian)"
  echo ""
  echo "$copy_summary"
  if [ "$copy_rc" -ne 0 ]; then
    echo ""
    echo "**Lane A exit code:** $copy_rc — see stderr above."
  fi
  echo ""
  echo "## Lane B (non-daily captures for librarian)"
  echo ""
  echo "### Research files ($research_count)"
  echo "$touched_research" | while read -r f; do [ -n "$f" ] && echo "- $f"; done
  echo ""
  echo "### Other projects/shared/decisions ($other_count)"
  echo "$touched_other" | while read -r f; do [ -n "$f" ] && echo "- $f"; done
} > "$LOG"

# Queue librarian task only for non-daily work. Lane A already handled
# daily notes and did not produce a task. Falls back to the admin agent
# (default: patch) only if the librarian is not provisioned on this
# install — treated as an install incompleteness signal, not a routine
# routing choice.
if [ "$non_daily_total" -gt 0 ]; then
  target="$BRIDGE_ADMIN_AGENT"
  if "$BRIDGE_AGB" agent show librarian >/dev/null 2>&1; then
    target="librarian"
  fi
  "$BRIDGE_AGB" task create --to "$target" --priority normal --from "$BRIDGE_ADMIN_AGENT" \
    --title "[librarian-ingest] $non_daily_total 파일 ingest 필요 — $DATE" \
    --body-file "$LOG" >/dev/null 2>&1 || true
fi

# Advance the watermark only when Lane A reported errors=0 AND the copy
# subprocess exited cleanly. Any failure leaves the previous watermark in
# place so the next run retries the same window.
if [ "$copy_rc" -eq 0 ] && [ "$copy_errors" = "0" ]; then
  write_watermark_atomic "$DATE" || true
fi

echo "wiki-daily-ingest: date=$DATE since=$YESTERDAY lane-a ${copy_summary} lane-b research=$research_count other=$other_count total=$non_daily_total log=$LOG"
