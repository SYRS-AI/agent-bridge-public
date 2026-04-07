AGENT_BRIDGE_HOME="${AGENT_BRIDGE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"

export BRIDGE_HOME="${BRIDGE_HOME:-$AGENT_BRIDGE_HOME}"
case ":$PATH:" in
  *":$AGENT_BRIDGE_HOME:"*) ;;
  *) export PATH="$AGENT_BRIDGE_HOME:$PATH" ;;
esac

alias bridge-start="bash \"$AGENT_BRIDGE_HOME/bridge-start.sh\""
alias bridge-send="bash \"$AGENT_BRIDGE_HOME/bridge-send.sh\""
alias bridge-action="bash \"$AGENT_BRIDGE_HOME/bridge-action.sh\""
alias bridge-task="bash \"$AGENT_BRIDGE_HOME/bridge-task.sh\""
alias bridge-daemon="bash \"$AGENT_BRIDGE_HOME/bridge-daemon.sh\""
alias bridge-status="bash \"$AGENT_BRIDGE_HOME/bridge-status.sh\""
alias bridge-sync="bash \"$AGENT_BRIDGE_HOME/bridge-sync.sh\""
