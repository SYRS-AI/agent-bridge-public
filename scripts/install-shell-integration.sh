#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
TARGET_SHELL="zsh"
APPLY=0
RCFILE=""

usage() {
  cat <<EOF
Usage: $0 [--shell zsh|bash] [--rcfile <path>] [--apply]

Without --apply, prints the snippet to add to your shell rc file.
With --apply, writes or updates a managed block in the rc file.
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
  bash)
    [[ -n "$RCFILE" ]] || RCFILE="$HOME/.bashrc"
    SNIPPET="source \"$REPO_ROOT/shell/agent-bridge.bash\""
    START_MARKER="# >>> agent-bridge bash >>>"
    END_MARKER="# <<< agent-bridge bash <<<"
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
  UPDATE_RESULT="$(
    python3 - "$RCFILE" "$START_MARKER" "$END_MARKER" "$SNIPPET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
start_marker, end_marker, snippet = sys.argv[2:]
text = path.read_text(encoding="utf-8")
managed_block = f"{start_marker}\n{snippet}\n{end_marker}"
pattern = re.compile(
    re.escape(start_marker) + r"\n.*?\n" + re.escape(end_marker),
    re.DOTALL,
)

if not pattern.search(text):
    print("malformed")
    raise SystemExit(0)

updated = pattern.sub(managed_block, text, count=1)
if updated == text:
    print("unchanged")
    raise SystemExit(0)

path.write_text(updated, encoding="utf-8")
print("updated")
PY
  )"
  case "$UPDATE_RESULT" in
    updated)
      echo "[info] updated agent-bridge shell integration in $RCFILE"
      echo "[info] restart your shell or run: exec ${TARGET_SHELL}"
      ;;
    unchanged)
      echo "[info] shell integration already up to date in $RCFILE"
      ;;
    malformed)
      echo "[error] existing managed block in $RCFILE is malformed; fix it manually or remove it and rerun." >&2
      exit 1
      ;;
    *)
      echo "[error] unexpected shell integration update result: $UPDATE_RESULT" >&2
      exit 1
      ;;
  esac
  exit 0
fi

cat >>"$RCFILE" <<EOF

$START_MARKER
$SNIPPET
$END_MARKER
EOF

echo "[info] wrote agent-bridge shell integration to $RCFILE"
echo "[info] restart your shell or run: exec ${TARGET_SHELL}"
echo "[info] commands on PATH: agent-bridge, agb, bridge-start, bridge-send, bridge-action, bridge-task"
