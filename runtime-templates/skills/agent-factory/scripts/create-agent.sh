#!/usr/bin/env bash

set -euo pipefail

NAME="${1:?Usage: create-agent.sh <name> <type> [model]}"
TYPE="${2:?Types: persistent-internal, ephemeral-internal, persistent-external, ephemeral-external}"
MODEL="${3:-sonnet}"
BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
RUNTIME_ROOT="$BRIDGE_HOME/runtime"
TIMESTAMP="$(TZ=Asia/Seoul date +"%Y-%m-%d")"

echo "Creating agent: $NAME (type: $TYPE, model: $MODEL)"

case "$TYPE" in
  persistent-internal|persistent-external)
    AGENT_HOME="$BRIDGE_HOME/agents/$NAME"
    mkdir -p "$AGENT_HOME/memory" "$AGENT_HOME/skills" "$AGENT_HOME/scripts"

    cat >"$AGENT_HOME/SOUL.md" <<EOF
# $NAME

## Identity
- Name: $NAME
- Role: TODO
- Language: Korean

## Personality
- TODO

## Rules
1. Read MEMORY.md before significant work.
2. Update memory after important work.
3. Use Agent Bridge queue for handoffs and reports.
EOF

    cat >"$AGENT_HOME/MEMORY.md" <<EOF
# $NAME Memory

## Overview
- Role: TODO
- Created: $TIMESTAMP

## Key Knowledge

## Maintenance Log
### $TIMESTAMP
- Initial scaffold
EOF

    cat >"$AGENT_HOME/CLAUDE.md" <<EOF
# $NAME

Read SOUL.md first, then MEMORY.md. Use Agent Bridge queue as the source of truth for cross-agent work.
EOF

    echo "Created: $AGENT_HOME"
    echo ""
    echo "Next steps:"
    echo "  1. Fill SOUL.md, MEMORY.md, CLAUDE.md"
    echo "  2. Add roster entry or use agent-bridge --claude --name $NAME for a first session"
    echo "  3. Run: $BRIDGE_HOME/agent-bridge setup agent $NAME"
    ;;
  ephemeral-internal)
    echo "Ephemeral internal workers are created on demand."
    echo "Use:"
    echo "  $BRIDGE_HOME/agent-bridge --claude --name $NAME --prefer new"
    ;;
  ephemeral-external)
    SCRIPT_DIR="$RUNTIME_ROOT/scripts"
    mkdir -p "$SCRIPT_DIR"
    cat >"$SCRIPT_DIR/run-$NAME.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
BRIDGE_HOME="\${BRIDGE_HOME:-\$HOME/.agent-bridge}"
TASK="\${1:?Usage: run-$NAME.sh \"task\"}"
claude -p --dangerously-skip-permissions --model "$MODEL" --output-format text "\$TASK"
EOF
    chmod +x "$SCRIPT_DIR/run-$NAME.sh"
    echo "Created: $SCRIPT_DIR/run-$NAME.sh"
    ;;
  *)
    echo "Unsupported type: $TYPE" >&2
    exit 1
    ;;
esac
