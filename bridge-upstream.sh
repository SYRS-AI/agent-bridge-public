#!/usr/bin/env bash
# bridge-upstream.sh — draft and file upstream Agent Bridge issues with consent

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

UPSTREAM_REPO="${BRIDGE_UPSTREAM_REPO:-SYRS-AI/agent-bridge-public}"
UPSTREAM_CANDIDATE_DIR="${BRIDGE_UPSTREAM_CANDIDATE_DIR:-$BRIDGE_SHARED_DIR/upstream-candidates}"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") draft --title <title> --symptom <text> --why <text> [--reproduction-file <path>] [--output <path>]
  $(basename "$0") propose --title <title> --body-file <path> [--repo owner/name] [--yes]
  $(basename "$0") meta-status --target <owner/name#issue> [--days <n>] [--json] [--mock-json-file <path>]
  $(basename "$0") meta-record --target <owner/name#issue> (--summary <text> | --summary-file <path>) [--days <n>] [--reviewer <name>] [--dry-run]
  $(basename "$0") review
EOF
}

slugify() {
  local value="$1"

  bridge_require_python
  python3 - "$value" <<'PY'
import re
import sys

value = sys.argv[1].lower()
value = re.sub(r"[^a-z0-9._-]+", "-", value).strip("-")
print(value[:64] or "upstream-issue")
PY
}

redact_file() {
  local path="$1"

  [[ -f "$path" ]] || return 0
  bridge_require_python
  python3 - "$path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
patterns = [
    (r"(?i)(token|secret|password|api[_-]?key|authorization)(\s*[:=]\s*)(\S+)", r"\1\2[REDACTED]"),
    (r"(?i)bearer\s+[a-z0-9._~+/=-]+", "Bearer [REDACTED]"),
]
for pattern, repl in patterns:
    text = re.sub(pattern, repl, text)
if len(text) > 12000:
    text = text[:12000] + "\n\n[truncated]\n"
print(text.rstrip())
PY
}

save_candidate() {
  local title="$1"
  local body_file="$2"
  local slug=""
  local path=""

  mkdir -p "$UPSTREAM_CANDIDATE_DIR"
  slug="$(slugify "$title")"
  path="$UPSTREAM_CANDIDATE_DIR/$(date '+%Y%m%d-%H%M%S')-${slug}.md"
  {
    printf '# %s\n\n' "$title"
    printf 'repo: %s\n' "$UPSTREAM_REPO"
    printf 'saved_at: %s\n\n' "$(bridge_now_iso)"
    cat "$body_file"
    printf '\n'
  } >"$path"
  printf '%s\n' "$path"
}

parse_target() {
  local target="$1"
  local repo=""
  local issue=""

  [[ -n "$target" ]] || bridge_die "--target is required"
  [[ "$target" == *"#"* ]] || bridge_die "target must look like owner/name#123"
  repo="${target%#*}"
  issue="${target##*#}"
  [[ -n "$repo" ]] || bridge_die "target repo is empty: $target"
  [[ "$issue" =~ ^[0-9]+$ ]] || bridge_die "target issue number is invalid: $target"

  printf '%s\t%s\n' "$repo" "$issue"
}

load_issue_payload() {
  local repo="$1"
  local issue="$2"
  local mock_json_file="${3:-}"

  if [[ -n "$mock_json_file" ]]; then
    [[ -f "$mock_json_file" ]] || bridge_die "mock json file not found: $mock_json_file"
    cat "$mock_json_file"
    return 0
  fi

  command -v gh >/dev/null 2>&1 || bridge_die "gh CLI is required to inspect upstream issues"
  gh issue view "$issue" --repo "$repo" --json number,title,url,state,updatedAt,comments
}

render_meta_status() {
  local payload_json="$1"
  local repo="$2"
  local issue="$3"
  local days="$4"
  local json_mode="$5"

  python3 - "$payload_json" "$repo" "$issue" "$days" "$json_mode" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

payload = json.loads(sys.argv[1])
repo = sys.argv[2]
issue = int(sys.argv[3])
days = float(sys.argv[4])
json_mode = sys.argv[5] == "1"
marker = "<!-- bridge:meta-review -->"


def parse_iso(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None


comments = payload.get("comments") or []
review_comments = []
for comment in comments:
    body = str(comment.get("body") or "")
    if marker not in body:
        continue
    created_at = parse_iso(comment.get("createdAt"))
    review_comments.append(
        {
            "created_at": created_at,
            "created_at_raw": comment.get("createdAt"),
            "url": str(comment.get("url") or ""),
            "author": str((comment.get("author") or {}).get("login") or ""),
            "body": body,
        }
    )

review_comments = [row for row in review_comments if row["created_at"] is not None]
review_comments.sort(key=lambda row: row["created_at"])
last_review = review_comments[-1] if review_comments else None

now = datetime.now(timezone.utc)
due_after = timedelta(days=days)
last_review_at = last_review["created_at"] if last_review else None
review_due = last_review_at is None or (now - last_review_at) >= due_after

issue_updated_at = parse_iso(payload.get("updatedAt"))
changed_since_review = bool(
    issue_updated_at is not None
    and last_review_at is not None
    and issue_updated_at > last_review_at
)

result = {
    "repo": repo,
    "issue": issue,
    "target": f"{repo}#{issue}",
    "state": str(payload.get("state") or ""),
    "title": str(payload.get("title") or ""),
    "url": str(payload.get("url") or ""),
    "issue_updated_at": payload.get("updatedAt"),
    "due_after_days": days,
    "last_review_at": last_review["created_at_raw"] if last_review else None,
    "last_review_url": last_review["url"] if last_review else None,
    "last_review_author": last_review["author"] if last_review else None,
    "changed_since_review": changed_since_review,
    "review_due": review_due,
}
if last_review_at is not None:
    delta = now - last_review_at
    result["days_since_review"] = round(delta.total_seconds() / 86400.0, 3)
else:
    result["days_since_review"] = None

if json_mode:
    print(json.dumps(result, ensure_ascii=False))
else:
    for key in (
        "target",
        "state",
        "title",
        "url",
        "issue_updated_at",
        "due_after_days",
        "last_review_at",
        "last_review_url",
        "last_review_author",
        "days_since_review",
        "changed_since_review",
        "review_due",
    ):
        print(f"{key}: {result.get(key)}")
PY
}

cmd_meta_status() {
  local target=""
  local repo=""
  local issue=""
  local days="7"
  local json_mode=0
  local mock_json_file=""
  local payload_json=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        target="${2:-}"
        shift 2
        ;;
      --repo)
        repo="${2:-}"
        shift 2
        ;;
      --issue)
        issue="${2:-}"
        shift 2
        ;;
      --days)
        days="${2:-}"
        shift 2
        ;;
      --json)
        json_mode=1
        shift
        ;;
      --mock-json-file)
        mock_json_file="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "알 수 없는 meta-status 옵션: $1"
        ;;
    esac
  done

  if [[ -n "$target" ]]; then
    IFS=$'\t' read -r repo issue < <(parse_target "$target")
  else
    [[ -n "$repo" ]] || bridge_die "--repo is required when --target is omitted"
    [[ "$issue" =~ ^[0-9]+$ ]] || bridge_die "--issue must be a number"
  fi
  [[ "$days" =~ ^[0-9]+([.][0-9]+)?$ ]] || bridge_die "--days must be numeric"

  payload_json="$(load_issue_payload "$repo" "$issue" "$mock_json_file")"
  render_meta_status "$payload_json" "$repo" "$issue" "$days" "$json_mode"
}

cmd_meta_record() {
  local target=""
  local repo=""
  local issue=""
  local days="7"
  local summary=""
  local summary_file=""
  local reviewer="${USER:-unknown}"
  local dry_run=0
  local temp_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        target="${2:-}"
        shift 2
        ;;
      --repo)
        repo="${2:-}"
        shift 2
        ;;
      --issue)
        issue="${2:-}"
        shift 2
        ;;
      --days)
        days="${2:-}"
        shift 2
        ;;
      --summary)
        summary="${2:-}"
        shift 2
        ;;
      --summary-file)
        summary_file="${2:-}"
        shift 2
        ;;
      --reviewer)
        reviewer="${2:-}"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "알 수 없는 meta-record 옵션: $1"
        ;;
    esac
  done

  if [[ -n "$target" ]]; then
    IFS=$'\t' read -r repo issue < <(parse_target "$target")
  else
    [[ -n "$repo" ]] || bridge_die "--repo is required when --target is omitted"
    [[ "$issue" =~ ^[0-9]+$ ]] || bridge_die "--issue must be a number"
  fi
  [[ "$days" =~ ^[0-9]+([.][0-9]+)?$ ]] || bridge_die "--days must be numeric"

  if [[ -n "$summary_file" ]]; then
    [[ -f "$summary_file" ]] || bridge_die "summary file not found: $summary_file"
    summary="$(cat "$summary_file")"
  fi
  [[ -n "$summary" ]] || bridge_die "--summary or --summary-file is required"

  temp_file="$(mktemp)"
  python3 - "$repo" "$issue" "$days" "$reviewer" "$summary" <<'PY' >"$temp_file"
import sys
from datetime import datetime, timezone

repo = sys.argv[1]
issue = sys.argv[2]
days = sys.argv[3]
reviewer = sys.argv[4]
summary = sys.argv[5].rstrip()
checked_at = datetime.now(timezone.utc).astimezone()
print("<!-- bridge:meta-review -->")
print()
print("## Meta Review Checkpoint")
print()
print(f"- checked_at: {checked_at.isoformat(timespec='seconds')}")
print(f"- reviewer: {reviewer}")
print(f"- target: {repo}#{issue}")
print(f"- cadence_days: {days}")
print()
print("### Summary")
print()
print(summary or "_No summary provided._")
print()
print("### Next Review")
print()
print(f"- due_after_days: {days}")
PY

  if [[ "$dry_run" == "1" ]]; then
    cat "$temp_file"
    rm -f "$temp_file"
    return 0
  fi

  command -v gh >/dev/null 2>&1 || bridge_die "gh CLI is required to comment on upstream issues"
  gh issue comment "$issue" --repo "$repo" --body-file "$temp_file" >/dev/null
  rm -f "$temp_file"
  printf 'commented: %s#%s\n' "$repo" "$issue"
}

cmd_draft() {
  local title=""
  local symptom=""
  local why=""
  local reproduction_file=""
  local output=""
  local body=""
  local repro=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)
        title="${2:-}"
        shift 2
        ;;
      --symptom)
        symptom="${2:-}"
        shift 2
        ;;
      --why)
        why="${2:-}"
        shift 2
        ;;
      --reproduction-file)
        reproduction_file="${2:-}"
        shift 2
        ;;
      --output)
        output="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "알 수 없는 upstream draft 옵션: $1"
        ;;
    esac
  done

  [[ -n "$title" ]] || bridge_die "--title is required"
  [[ -n "$symptom" ]] || bridge_die "--symptom is required"
  [[ -n "$why" ]] || bridge_die "--why is required"

  if [[ -n "$reproduction_file" ]]; then
    [[ -f "$reproduction_file" ]] || bridge_die "reproduction file not found: $reproduction_file"
    repro="$(redact_file "$reproduction_file")"
  else
    repro="(Add exact command, redacted output, and minimal reproduction steps.)"
  fi

  body="$(cat <<EOF
## Symptom

$symptom

## Why this looks upstream

$why

## Reproduction

\`\`\`text
$repro
\`\`\`

## Environment

- Agent Bridge version: $(bridge_version)
- Agent Bridge source: $BRIDGE_SCRIPT_DIR
- OS: $(uname -a)
- Shell: ${SHELL:-unknown}

## Consent

This draft must not be filed until the user explicitly approves.
EOF
)"

  if [[ -n "$output" ]]; then
    mkdir -p "$(dirname "$output")"
    printf '%s\n' "$body" >"$output"
    printf '%s\n' "$output"
  else
    printf '%s\n' "$body"
  fi
}

cmd_propose() {
  local title=""
  local body_file=""
  local repo="$UPSTREAM_REPO"
  local yes=0
  local answer=""
  local saved=""
  local url=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)
        title="${2:-}"
        shift 2
        ;;
      --body-file)
        body_file="${2:-}"
        shift 2
        ;;
      --repo)
        repo="${2:-}"
        shift 2
        ;;
      --yes)
        yes=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "알 수 없는 upstream propose 옵션: $1"
        ;;
    esac
  done

  [[ -n "$title" ]] || bridge_die "--title is required"
  [[ -n "$body_file" ]] || bridge_die "--body-file is required"
  [[ -f "$body_file" ]] || bridge_die "body file not found: $body_file"

  UPSTREAM_REPO="$repo"

  if [[ "$yes" != "1" ]]; then
    printf 'Agent Bridge 코어 이슈 후보입니다.\n'
    printf 'title: %s\n' "$title"
    printf 'repo: %s\n\n' "$repo"
    sed -n '1,80p' "$body_file"
    printf '\nAgent Bridge 코어 이슈로 보입니다. upstream GitHub issue를 바로 등록할까요? [y/N] '
    if [[ -t 0 ]]; then
      read -r answer
    else
      answer="n"
    fi
    case "$answer" in
      y|Y|yes|YES)
        yes=1
        ;;
      *)
        saved="$(save_candidate "$title" "$body_file")"
        printf 'saved_candidate: %s\n' "$saved"
        exit 0
        ;;
    esac
  fi

  command -v gh >/dev/null 2>&1 || bridge_die "gh CLI is required to file upstream issues"
  url="$(gh issue create --repo "$repo" --title "$title" --body-file "$body_file")"
  printf '%s\n' "$url"
}

cmd_review() {
  local file=""

  mkdir -p "$UPSTREAM_CANDIDATE_DIR"
  shopt -s nullglob
  for file in "$UPSTREAM_CANDIDATE_DIR"/*.md; do
    printf '%s\n' "$file"
  done | sort
  shopt -u nullglob
}

case "${1:-}" in
  draft)
    shift
    cmd_draft "$@"
    ;;
  propose)
    shift
    cmd_propose "$@"
    ;;
  meta-status)
    shift
    cmd_meta_status "$@"
    ;;
  meta-record)
    shift
    cmd_meta_record "$@"
    ;;
  review)
    shift
    [[ $# -eq 0 ]] || bridge_die "Usage: $(basename "$0") review"
    cmd_review
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    bridge_die "지원하지 않는 upstream 명령입니다: $1"
    ;;
esac
