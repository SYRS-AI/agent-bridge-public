# OpenClaw Runtime Migration Backlog

이 문서는 OpenClaw에서 실제로 설치·사용 중이던 런타임 자산을 Agent Bridge / Claude Code 기준으로 옮기기 위한 공개 backlog다.

## 목표
- `~/.openclaw`를 런타임 필수 의존성으로 남기지 않는다.
- canonical runtime을 Agent Bridge + Claude Code로 통일한다.
- 남아 있는 레거시 skill/script/MCP/secret 경로를 inventory로 만들고 순차적으로 bridge-local 경로로 이전한다.

## 범위

### 1. Skills
- OpenClaw 시절 agent-local / shared skill inventory 전수 조사
- 문서형 skill과 실행 helper를 분리
- bridge-local `skills/` 또는 `~/.agent-bridge/shared/SKILLS.md` 체계로 재배치

### 2. Scripts
- 실제 호출 중인 Bash/Python helper 전수 조사
- Agent Bridge queue / notify / cron 모델에 맞는 wrapper로 재정리
- legacy poller, gateway send CLI, wrapper bridge는 제거 또는 compatibility-only로 격하

### 3. MCP
- OpenClaw에서 쓰던 MCP 서버 목록과 에이전트별 사용처 조사
- Claude Code용 `.mcp.json` 또는 공통 설정으로 재구성
- live agent home에서 바로 동작하도록 경로/바이너리 검증

### 4. Secrets / 1Password
- `op` 기반 1Password secret 사용처 전수 조사
- Claude Code에서 재현 가능한 secret injection 방식 정의
- `~/.openclaw/credentials` 의존 제거 또는 compatibility-only로 축소

## 산출물
- 에이전트별 runtime dependency inventory
- Claude Code용 skills/scripts/MCP/secrets 설치 표준
- bridge-local canonical path 목록
- 남은 legacy dependency 제거 순서

## 선행 조건
- agent home 문서 정리 완료
- 각 에이전트 `CLAUDE.md`에서 legacy runtime reference 제거
- bridge-native queue / cron / notify 경로 안정화
