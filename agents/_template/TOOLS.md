# Tools

이 홈에서 일반적으로 사용하는 bridge-native 도구:

- `~/.agent-bridge/agent-bridge status`
- `~/.agent-bridge/agb inbox <agent>`
- `~/.agent-bridge/agb show <task-id>`
- `~/.agent-bridge/agb claim <task-id> --agent <agent>`
- `~/.agent-bridge/agb done <task-id> --agent <agent> --note "..."`
- `~/.agent-bridge/agent-bridge task create --to <agent> ...`
- `~/.agent-bridge/agent-bridge bundle create --to <agent> ...`
- `~/.agent-bridge/agent-bridge intake triage --capture <id> --owner <agent> --route`
- `~/.agent-bridge/agent-bridge urgent <agent> "..."`
- `~/.agent-bridge/agent-bridge escalate question --agent <agent> --question "..." --context "..."`
- `~/.agent-bridge/agent-bridge cron ...`
- `~/.agent-bridge/agent-bridge memory capture --agent <agent> ...`
- `~/.agent-bridge/agent-bridge memory ingest --agent <agent> --latest`
- `~/.agent-bridge/agent-bridge memory promote --agent <agent> ...`
- `~/.agent-bridge/agent-bridge memory remember --agent <agent> --source <source> --text "..." --kind user|shared|project|decision`
- `~/.agent-bridge/agent-bridge memory search --agent <agent> --query "..."`
- `~/.agent-bridge/agent-bridge memory rebuild-index --agent <agent>`
- `~/.agent-bridge/agent-bridge memory query --agent <agent> --query "..."`

채널 응답은 연결된 Claude/Codex 세션 안에서 처리한다. queue와 roster 상태는 `~/.agent-bridge` live runtime 기준으로 본다.
메모리 판정 기준은 shared `memory-wiki` skill을 우선 따른다.
