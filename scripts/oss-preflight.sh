#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0
tracked_file_list="$(mktemp)"
trap 'rm -f "$tracked_file_list"' EXIT
git ls-files > "$tracked_file_list"
tracked_files=()
while IFS= read -r path; do
  [[ -f "$path" ]] || continue
  tracked_files+=("$path")
done < "$tracked_file_list"

check_pattern() {
  local description="$1"
  local pattern="$2"
  local matches

  matches="$(rg -n --color never -e "$pattern" "${tracked_files[@]}" || true)"
  if [[ -n "$matches" ]]; then
    echo "[oss] fail: ${description}"
    echo "$matches"
    fail=1
  fi
}

echo "[oss] checking tracked agent profiles"
extra_profiles=""
for path in "${tracked_files[@]}"; do
  if [[ "$path" =~ ^agents/[^_/][^/]*/CLAUDE\.md$ ]]; then
    extra_profiles+="${path}"$'\n'
  fi
done
if [[ -n "$extra_profiles" ]]; then
  echo "[oss] fail: public repo should not ship private agent profiles"
  printf '%s' "$extra_profiles"
  fail=1
fi

check_pattern "email addresses in tracked content" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
check_pattern "discord webhook URLs in tracked content" 'discord\.com/api/webhooks/'
check_pattern "discord mention IDs in tracked content" '<@[0-9]{6,}>'
check_pattern "internal personal or team markers in tracked content" 'sean@syrs\.kr|7670324081|8089687974|workspace-syrs-|syrs-shopify|syrs-satomi|syrs-meta|syrs-cs|syrs-calendar|syrs-sns|syrs-video|syrs-warehouse|syrs-fi|syrs-production|syrs-trend|syrs-derm|syrs-buzz|션님|묘님|리드님|Myo|@seanssoh'

if (( fail != 0 )); then
  exit 1
fi

echo "[oss] preflight passed"
