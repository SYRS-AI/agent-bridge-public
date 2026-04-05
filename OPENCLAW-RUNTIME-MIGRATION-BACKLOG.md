# Runtime Migration Backlog

이 문서는 현재 legacy source(`~/.openclaw`)에 남아 있는 런타임 자산을 Agent Bridge / Claude Code 기준으로 옮기기 위한 공개 backlog다.
이제 크론, 스킬, 스크립트, DB helper, secret 경로는 모두 "우리 런타임"으로 본다. legacy tree는 cutover 직전 import source일 뿐이고, canonical runtime은 `~/.agent-bridge`다.

## 목표
- `~/.openclaw`를 런타임 필수 의존성으로 남기지 않는다.
- canonical runtime을 Agent Bridge + Claude Code로 통일한다.
- 남아 있는 legacy skill/script/MCP/secret 경로를 inventory로 만들고 순차적으로 bridge-local 경로로 이전한다.

## 현재 라이브 진단 (2026-04-06)

### 1. 크론 source cutover를 끝내야 한다

- bridge-native cron store가 canonical source가 되어야 한다.
- import 전에만 legacy snapshot을 읽고, import 후에는 `~/.agent-bridge/cron/jobs.json`만 읽게 해야 한다.
- 따라서 다음 작업은 개별 잡 수동 이전이 아니라:
  - `cron import`
  - `rewrite-cron`
  - bridge-native `cron sync`
  - live recurring execution 확인
  순으로 끝내는 것이다.

### 2. 지금 cron sync를 바로 켜도 많은 잡이 실패할 가능성이 높다

현재 import source snapshot inventory 기준:

- total jobs: `123`
- enabled jobs: `98`
- recurring jobs: `103`
- recurring error jobs: `49`

payload / action text 기준으로 확인된 legacy runtime 의존:

- `~/.openclaw/scripts/...` 직접 호출: `17` jobs
- `~/.openclaw/skills/...` 직접 호출: `18` jobs
- `openclaw message send` 직접 호출: `9` jobs
- `agent-db`/postgres 계열 의존: `4` jobs

즉 "크론이 안 돈다"의 1차 원인은 canonical store cutover가 끝나지 않았기 때문이고, 2차 원인은 payload 자체가 아직 bridge-local runtime으로 완전히 옮겨지지 않았기 때문이다.

### 3. live agent docs / runtime notes에도 legacy 경로가 대량으로 남아 있다

`~/.agent-bridge/agents/*` 전수 검사 기준으로 다음 종류의 참조가 여전히 남아 있다.

- `~/.openclaw/skills/...`
- `~/.openclaw/scripts/...`
- `openclaw message send`
- `openclaw gateway ...`
- `~/.openclaw/credentials/...`
- `agent-db`

즉 단순히 cron만의 문제가 아니라, 에이전트가 참조하는 skill/tool/script/db/secret surface 전체가 아직 legacy source에 물려 있다.

## 범위

### 1. Skills
- legacy source의 agent-local / shared skill inventory 전수 조사
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

### 5. Local DB / Data Helpers

- `agent-db`, postgres, local sqlite, Supabase helper 등 데이터 접근 surface 전수 조사
- cron payload와 agent docs 안의 DB helper 호출을 bridge-local canonical wrapper로 치환
- "DB 쿼리 스킬 이름만 남아 있고 실제 실행 surface가 legacy tree를 보는 상태"를 제거

## 산출물
- 에이전트별 runtime dependency inventory
- Claude Code용 skills/scripts/MCP/secrets 설치 표준
- bridge-local canonical path 목록
- 남은 legacy dependency 제거 순서
- cron payload rewrite inventory와 family별 migration owner

## 즉시 실행 순서

1. recurring cron sync를 다시 켜기 전에, payload import inventory를 만든다.
   - 명령: `agent-bridge migrate runtime inventory`
2. `~/.openclaw/scripts`, `~/.openclaw/skills`, `~/.openclaw/shared/tools`, `~/.openclaw/credentials|secrets` 사용처를 bridge-local 기준으로 분류한다.
3. bridge-local canonical runtime root를 정한다. 예:
   - `~/.agent-bridge/runtime/scripts/`
   - `~/.agent-bridge/runtime/skills/`
   - `~/.agent-bridge/runtime/sql/`
   - `~/.agent-bridge/runtime/secrets/` 또는 `op` injector
4. cron payload를 family별로 bridge-local wrapper 호출로 rewrite한다.
5. 그 다음 daemon recurring sync를 live에서 다시 켠다.
6. 마지막으로 agent docs / SOUL / TOOLS / SKILLS 문서 안의 legacy 경로를 bridge-local 표준으로 치환한다.

## 선행 조건
- agent home 문서 정리 완료
- 각 에이전트 `CLAUDE.md`에서 legacy runtime reference 제거
- bridge-native queue / cron / notify 경로 안정화
