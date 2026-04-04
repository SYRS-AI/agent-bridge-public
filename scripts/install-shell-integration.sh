#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
TARGET_SHELL="zsh"
APPLY=0
RCFILE=""

usage() {
  cat <<EOF
Usage: $0 [--shell zsh] [--rcfile <path>] [--apply]

Without --apply, prints the snippet to add to your shell rc file.
With --apply, appends a managed block to the rc file if it is not already present.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      TARGET_SHELL="$2"
      shift 2
      ;;
    --rcfile)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      RCFILE="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

case "$TARGET_SHELL" in
  zsh)
    [[ -n "$RCFILE" ]] || RCFILE="$HOME/.zshrc"
    SNIPPET="source \"$REPO_ROOT/shell/agent-bridge.zsh\""
    START_MARKER="# >>> agent-bridge zsh >>>"
    END_MARKER="# <<< agent-bridge zsh <<<"
    ;;
  *)
    echo "[error] unsupported shell: $TARGET_SHELL" >&2
    exit 1
    ;;
esac

if [[ $APPLY -eq 0 ]]; then
  cat <<EOF
$START_MARKER
$SNIPPET
$END_MARKER
EOF
  exit 0
fi

mkdir -p "$(dirname "$RCFILE")"
touch "$RCFILE"

if grep -Fq "$START_MARKER" "$RCFILE"; then
  echo "[info] shell integration already present in $RCFILE"
  exit 0
fi

cat >>"$RCFILE" <<EOF

$START_MARKER
$SNIPPET
$END_MARKER
EOF

echo "[info] wrote agent-bridge shell integration to $RCFILE"
echo "[info] restart your shell or run: exec ${TARGET_SHELL}"
