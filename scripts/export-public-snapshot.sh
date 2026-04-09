#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/export-public-snapshot.sh --dest <dir> [options]

Options:
  --dest <dir>         Destination directory for the exported public snapshot.
  --ref <git-ref>      Git ref to export. Default: HEAD
  --branch <name>      Branch name to use when --init-git is enabled. Default: main
  --message <text>     Commit message when --init-git is enabled.
  --remote <url>       Remote URL to configure when --init-git is enabled.
  --init-git           Initialize a clean git repo in the destination.
  --push               Push the initialized repo to the configured remote.
  --force              Force-push when used with --push.
  --skip-preflight     Skip scripts/oss-preflight.sh before export.
  --dry-run            Print the plan without writing files.
  --json               Emit a JSON summary.
EOF
}

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

dest=""
ref="HEAD"
branch="main"
message=""
remote_url=""
init_git=0
push_remote=0
force_push=0
skip_preflight=0
dry_run=0
json_mode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -lt 2 ]] && { usage >&2; exit 1; }
      dest="$2"
      shift 2
      ;;
    --ref)
      [[ $# -lt 2 ]] && { usage >&2; exit 1; }
      ref="$2"
      shift 2
      ;;
    --branch)
      [[ $# -lt 2 ]] && { usage >&2; exit 1; }
      branch="$2"
      shift 2
      ;;
    --message)
      [[ $# -lt 2 ]] && { usage >&2; exit 1; }
      message="$2"
      shift 2
      ;;
    --remote)
      [[ $# -lt 2 ]] && { usage >&2; exit 1; }
      remote_url="$2"
      shift 2
      ;;
    --init-git)
      init_git=1
      shift
      ;;
    --push)
      push_remote=1
      shift
      ;;
    --force)
      force_push=1
      shift
      ;;
    --skip-preflight)
      skip_preflight=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --json)
      json_mode=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      echo "[error] unknown option: $1" >&2
      exit 1
      ;;
  esac
done

[[ -n "$dest" ]] || { usage >&2; echo "[error] --dest is required" >&2; exit 1; }
if [[ $push_remote -eq 1 && $init_git -ne 1 ]]; then
  echo "[error] --push requires --init-git" >&2
  exit 1
fi
if [[ $push_remote -eq 1 && -z "$remote_url" ]]; then
  echo "[error] --push requires --remote" >&2
  exit 1
fi

if [[ -z "$message" ]]; then
  message="public snapshot from ${ref}"
fi

cd "$REPO_ROOT"
git rev-parse --verify "$ref" >/dev/null

dest_abs="$(python3 - "$dest" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve())
PY
)"

if [[ $skip_preflight -eq 0 ]]; then
  if [[ $dry_run -eq 0 ]]; then
    bash "$SCRIPT_DIR/oss-preflight.sh" >/dev/null
  fi
fi

if [[ $json_mode -eq 1 ]]; then
  python3 - "$dest_abs" "$ref" "$branch" "$message" "$remote_url" "$init_git" "$push_remote" "$force_push" "$skip_preflight" "$dry_run" <<'PY'
import json
import sys

payload = {
    "mode": "export-public-snapshot",
    "dest": sys.argv[1],
    "ref": sys.argv[2],
    "branch": sys.argv[3],
    "message": sys.argv[4],
    "remote": sys.argv[5],
    "init_git": sys.argv[6] == "1",
    "push": sys.argv[7] == "1",
    "force": sys.argv[8] == "1",
    "skip_preflight": sys.argv[9] == "1",
    "dry_run": sys.argv[10] == "1",
}
print(json.dumps(payload, ensure_ascii=True, indent=2))
PY
  if [[ $dry_run -eq 1 ]]; then
    exit 0
  fi
fi

if [[ $dry_run -eq 1 && $json_mode -ne 1 ]]; then
  cat <<EOF
dest: $dest_abs
ref: $ref
branch: $branch
message: $message
remote: ${remote_url:-<none>}
init_git: $init_git
push: $push_remote
force: $force_push
skip_preflight: $skip_preflight
EOF
  exit 0
fi

stage_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

mkdir -p "$dest_abs"
rm -rf "$dest_abs"
mkdir -p "$dest_abs"

git archive "$ref" | tar -x -C "$stage_dir"
cp -R "$stage_dir"/. "$dest_abs"

if [[ $init_git -eq 1 ]]; then
  export_public_git_name="${EXPORT_PUBLIC_GIT_NAME:-Agent Bridge}"
  export_public_git_email="${EXPORT_PUBLIC_GIT_EMAIL:-}"
  if [[ -z "$export_public_git_email" ]]; then
    printf -v export_public_git_email '%s@%s' bridge local.invalid
  fi
  git -C "$dest_abs" init -b "$branch" >/dev/null 2>&1 || {
    git -C "$dest_abs" init >/dev/null
    git -C "$dest_abs" checkout -B "$branch" >/dev/null 2>&1 || true
  }
  git -C "$dest_abs" add .
  git -C "$dest_abs" -c user.name="$export_public_git_name" -c user.email="$export_public_git_email" commit -m "$message" >/dev/null
  if [[ -n "$remote_url" ]]; then
    if git -C "$dest_abs" remote get-url origin >/dev/null 2>&1; then
      git -C "$dest_abs" remote set-url origin "$remote_url"
    else
      git -C "$dest_abs" remote add origin "$remote_url"
    fi
  fi
  if [[ $push_remote -eq 1 ]]; then
    push_args=(push origin "$branch")
    if [[ $force_push -eq 1 ]]; then
      push_args=(push --force origin "$branch")
    fi
    git -C "$dest_abs" "${push_args[@]}"
  fi
fi

if [[ $json_mode -ne 1 ]]; then
  echo "export: ok"
  echo "dest: $dest_abs"
  echo "ref: $ref"
  echo "branch: $branch"
  echo "init_git: $init_git"
  echo "push: $push_remote"
fi
