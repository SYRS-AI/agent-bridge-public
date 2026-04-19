#!/bin/bash
# Wiki daily LLM-ingest — patch가 librarian 겸임 (librarian 전담 에이전트 생성은 agent create bug 수리 후).
#
# 역할: Karpathy LLM-wiki의 Ingest 루프.
# 매일 밤, 각 에이전트의 오늘자 daily + 신규 research 파일을 수집해서
# patch inbox에 "ingest 대상 N건" task 생성. patch claim 후 서브에이전트 spawn으로 LLM 분석 수행.
#
# 장기: bridge-wiki.py ingest --llm 구현되면 여기서 직접 호출로 대체.

set -u
AGENTS_ROOT=~/.agent-bridge/agents
WIKI=~/.agent-bridge/shared/wiki
DATE=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
LOG="$WIKI/_audit/ingest-$DATE.md"
mkdir -p "$(dirname "$LOG")"

# 1. 어제~오늘 daily 변경 파일 수집
touched_daily=()
for home in "$AGENTS_ROOT"/*/; do
  agent=$(basename "$home")
  case "$agent" in --help|_template|shared) continue ;; esac
  for d in "$home/memory/$DATE.md" "$home/memory/$YESTERDAY.md"; do
    [ -f "$d" ] && touched_daily+=("$d")
  done
done

# 2. 신규/갱신 research 파일 수집 (최근 24시간)
touched_research=$(find "$AGENTS_ROOT"/*/memory/research -type f -name '*.md' -mtime -1 2>/dev/null | sort)
research_count=$(printf '%s\n' "$touched_research" | grep -c '[^[:space:]]' || true)
research_count=${research_count:-0}

# 3. 신규/갱신 projects/shared/decisions 파일 (최근 24시간)
touched_other=$(find "$AGENTS_ROOT"/*/memory/projects "$AGENTS_ROOT"/*/memory/shared "$AGENTS_ROOT"/*/memory/decisions -type f -name '*.md' -mtime -1 2>/dev/null | sort)
other_count=$(printf '%s\n' "$touched_other" | grep -c '[^[:space:]]' || true)
other_count=${other_count:-0}

daily_count=${#touched_daily[@]}
total=$(( daily_count + research_count + other_count ))

# 4. 리포트
{
  echo "# Wiki Daily Ingest Queue — $DATE"
  echo ""
  echo "## 총 ingest 대상: $total"
  echo ""
  echo "### Daily notes ($daily_count)"
  for d in "${touched_daily[@]:-}"; do
    [ -n "$d" ] && echo "- $d"
  done
  echo ""
  echo "### Research files ($research_count)"
  echo "$touched_research" | while read f; do [ -n "$f" ] && echo "- $f"; done
  echo ""
  echo "### Other (projects/shared/decisions) ($other_count)"
  echo "$touched_other" | while read f; do [ -n "$f" ] && echo "- $f"; done
} > "$LOG"

# 5. task 생성 (대상 있을 때만). 가능하면 librarian에게, 없으면 patch로 폴백.
if [ "$total" -gt 0 ]; then
  target="patch"
  if ~/.agent-bridge/agent-bridge agent show librarian >/dev/null 2>&1; then
    target="librarian"
  fi
  ~/.agent-bridge/agent-bridge task create --to "$target" --priority normal --from patch \
    --title "[librarian-ingest] $total 파일 ingest 필요 — $DATE" \
    --body-file "$LOG" >/dev/null 2>&1 || true
fi

echo "wiki-daily-ingest: date=$DATE daily=$daily_count research=$research_count other=$other_count total=$total log=$LOG"
