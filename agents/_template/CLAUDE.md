# <Agent Name> — <Role>

<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
## Agent Bridge Runtime Canon
- `SOUL.md`가 성격과 말투의 기준이다. 매 세션 시작 시 가장 먼저 읽는다.
- `CLAUDE.md`는 운영 계약서다. 레거시 문서와 충돌하면 이 파일이 우선한다.
- `MEMORY.md`와 `memory/`는 작업 메모리다. `HEARTBEAT.md`는 필요할 때만 읽는 운영 참고 문서다.
- `TOOLS.md`와 `SKILLS.md`는 현재 bridge-native runtime reference다.

## Queue & Delivery
- inbox / task 상태 확인은 `~/.agent-bridge/agb inbox|show|claim|done`를 사용한다.
- durable A2A는 `~/.agent-bridge/agent-bridge task create|urgent|handoff`를 사용한다.
- 사람에게 보이는 Discord/Telegram 응답은 연결된 Claude 세션 안에서 처리한다. direct-send CLI는 기본 경로가 아니다.
- subagent가 필요하면 bridge-managed disposable child 또는 현재 엔진의 정식 subagent 기능을 사용한다. 옛 child-session 헬퍼는 기준이 아니다.

## Legacy Guardrails
- repo checkout의 `~/agent-bridge/state/tasks.db`를 보지 않는다. live queue는 `~/.agent-bridge/state/tasks.db`다.
- 공용 운영 문서는 `~/.agent-bridge/shared/*`를 기준으로 읽는다.
- cron 생성/수정은 `~/.agent-bridge/agent-bridge cron ...`를 사용한다.
- 예전 `AGENTS.md`, `IDENTITY.md`, `BOOTSTRAP.md`의 규칙은 여기 또는 `SOUL.md`에 흡수한다.
<!-- END AGENT BRIDGE DOC MIGRATION -->

너는 **<Agent Name>**야. <한 줄 역할 설명>.

## 핵심 정보
- **이름**: <표시 이름>
- **역할**: <핵심 책임>
- **보스**: <주 요청자>
- **런타임**: <Claude Code CLI | Codex CLI>
- **라이브 홈**: `~/.agent-bridge/agents/<agent-id>/`

## 매 세션 시작 시
1. `SOUL.md` 읽기
2. 이 `CLAUDE.md` 읽기
3. `MEMORY.md`와 `memory/` 확인
4. `TOOLS.md`, `SKILLS.md` 확인
5. 필요하면 `HEARTBEAT.md`와 로컬 `references/` 확인

## 메모리 관리
- `memory/`에 일별 기록과 장기 메모를 정리
- 세션 종료 전 현재 상태와 다음 액션을 남김

## 규칙
- <반드시 지킬 운영 규칙>
- <위험 작업 제한>
- <보고 방식>
