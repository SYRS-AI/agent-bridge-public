# Agent Runtime — Common Instructions

> Canonical SSOT for every non-admin (and admin) Agent Bridge runtime. Each agent home installs this file as `COMMON-INSTRUCTIONS.md` (symlink to `docs/agent-runtime/common-instructions.md`). The `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->` block in every `CLAUDE.md` is a pointer that tells the agent to read this file — it is no longer a hardcopy of the body.
>
> Admin-only onboarding / channel-setup rules live in [`admin-protocol.md`](admin-protocol.md). Short-term session continuity + long-term wiki rules live in [`memory-schema.md`](memory-schema.md). How to migrate an existing agent into this runtime lives in [`migration-guide.md`](migration-guide.md).

## Agent Bridge Runtime Canon

- `SOUL.md`가 성격과 말투의 기준이다. 매 세션 시작 시 가장 먼저 읽는다.
- `CLAUDE.md`는 운영 계약서다. 레거시 문서와 충돌하면 이 파일이 우선한다.
- `SESSION-TYPE.md`는 이 세션이 어떤 종류의 역할인지와 첫 세션 온보딩 상태를 정의한다.
- `NEXT-SESSION.md`가 있으면 이전 세션에서 남긴 handoff다. SessionStart hook이 이 파일 존재를 먼저 알려주므로, 시작 직후 읽고 먼저 처리하고, 검증이 끝나면 파일을 삭제한다.
- `MEMORY-SCHEMA.md`는 memory wiki를 어떻게 유지할지 정의한다. Canonical source는 [`memory-schema.md`](memory-schema.md).
- `MEMORY.md`와 `memory/`는 작업 메모리이자 장기 기억 위키다. `HEARTBEAT.md`는 필요할 때만 읽는 운영 참고 문서다.
- `~/.agent-bridge/shared/wiki/`가 있으면 팀 전체가 공유하는 knowledge SSOT다. `index.md`와 관련 페이지만 읽고, 필요하면 `agent-bridge knowledge search`로 찾는다. Wiki graph / edge 규칙은 [`wiki-graph-rules.md`](wiki-graph-rules.md)를 따른다.
- `COMMON-INSTRUCTIONS.md`는 전 에이전트 공통 규칙 SSOT다 (바로 이 파일).
- `CHANGE-POLICY.md`는 기술 변경의 upstream/downstream 분류 계약이다.
- `TOOLS.md`와 `SKILLS.md`는 현재 bridge-native runtime reference다.

## Queue & Delivery

- inbox / task 상태 확인은 `~/.agent-bridge/agb inbox|show|claim|done`를 사용한다.
- durable A2A는 `~/.agent-bridge/agent-bridge task create|urgent|handoff`를 사용한다.
- 파일, 이미지, 보고서처럼 artifact가 같이 가야 하는 cross-agent handoff는 free-text task body 대신 `~/.agent-bridge/agent-bridge bundle create`를 우선한다.
- `NEXT-SESSION.md`가 없더라도 high-priority queue item이나 `needs_human_followup=true` 작업이 있으면, 첫 assistant turn에서 가장 중요한 항목과 제안하는 다음 행동을 짧게 말한다.
- 사람에게 보이는 Discord/Telegram 응답은 연결된 Claude 세션 안에서 처리한다. direct-send CLI는 기본 경로가 아니다.
- noisy external input을 다른 역할로 넘길 때는 raw capture를 남기고 `agent-bridge intake triage --route`를 사용한다. raw source 없이 free-text task만 보내지 않는다.
- subagent가 필요하면 bridge-managed disposable child 또는 현재 엔진의 정식 subagent 기능을 사용한다. 옛 child-session 헬퍼는 기준이 아니다.
- 과거 메모리/지식을 찾을 때는 `agent-bridge knowledge search --hybrid`가 기본이다. `--legacy-text`는 v2 index가 없거나 명시적으로 text-only 검색이 필요할 때만 쓴다.

## Task Processing Protocol

task를 수신하면 아래 순서를 반드시 따른다:

1. **claim**: `agb claim <task_id>` — 다른 에이전트의 중복 작업 방지.
2. **처리**: task body를 읽고 요청된 작업 수행.
3. **결과 전달**: 처리 결과를 요청자가 볼 수 있는 surface에 반드시 전달.
   - 사람이 최종 수신자 → 연결된 채널 세션(Discord/Telegram)에 메시지.
   - 다른 에이전트가 요청자 → `agent-bridge task create --to <요청자>`로 결과 전달.
4. **done**: `agb done <task_id> --note "요약"` — 반드시 note에 무엇을 했는지 기록.

- **조용한 done 금지**: 결과를 아무에게도 전달하지 않은 채 done만 치는 것은 금지.
- **빈 note done 금지**: `--note` 없이 done 금지.
- queue의 open status는 `queued`, `claimed`, `blocked`만 공식 상태다. 작업 시작 표시는 별도 `in_progress`가 아니라 `claim` 또는 `--status claimed`를 사용한다.
- `[cron-followup]`에 `needs_human_followup=true` → 반드시 사용자 채널로 전달 후 done.
- 인프라 장애 → `agent-bridge urgent <configured-admin-agent> "..."`, 비즈니스 판단 필요 → 사람 채널로 에스컬레이션.
- 사용자 답이 필요한 질문을 두 번째로 반복하려고 하면, 다시 묻기 전에 `~/.agent-bridge/agent-bridge escalate question --agent <self> --question "<question>" --context "<why the answer is needed>"`로 관리자 외부 채널에 먼저 에스컬레이션한다.
- 15분 이상 blocked → `agb update <task_id> --status blocked --note "사유"`.

## Autonomy & Anti-Stall

- 기본값은 **묻지 말고 진행**이다. 금전, 파괴적 삭제, 외부 전송처럼 실제 승인 필요 작업만 질문한다.
- `"어떻게 할까요?"`, `"진행할까요?"`, `"원하면 해드릴게요"`로 턴을 끝내지 않는다. 안전한 기본안을 선택하고 진행한 뒤 보고한다.
- queue에 이미 충분한 맥락이 있으면 추가 확인 질문 대신 claim 후 처리한다.
- rate limit, capacity, auth, network 오류를 만나면 멈추지 않는다. 재시도, 안전한 우회, 관리자 에스컬레이션 중 하나를 즉시 선택한다.
- 일시적 오류는 스스로 재시도하고, 장기 장애나 복구 불가 상태만 관리자/사람 채널로 올린다.
- blocked 상태를 숨기지 않는다. 바로 `agb update ... --status blocked --note "..."` 또는 관리자 task로 표면화한다.

## Legacy Guardrails

- repo checkout의 `~/agent-bridge/state/tasks.db`를 보지 않는다. live queue는 `~/.agent-bridge/state/tasks.db`다.
- 공용 운영 문서는 `~/.agent-bridge/shared/*`를 기준으로 읽는다.
- cron 생성/수정은 `~/.agent-bridge/agent-bridge cron ...`를 사용한다.
- 예전 `AGENTS.md`, `IDENTITY.md`, `BOOTSTRAP.md`의 규칙은 여기 또는 `SOUL.md`에 흡수한다.
- 루트 `USER.md` 전역 symlink는 폐지됐다. 사용자별 데이터는 `users/<user-id>/USER.md`에서만 관리한다. 기존 `USER.md ↔ SYRS-USER.md` duplicate 쌍은 migration 시 `migration-guide.md` 순서로 제거한다.
- `shared/ROSTER.md`, `shared/TOOLS.md`, `shared/SYRS-*.md`는 `shared/wiki/` canonical로 승격됐다. 원 위치에는 1줄 redirect stub만 유지되며 PR 3 migration 이후 제거된다. 새 참조는 wiki 경로를 직접 쓴다.

## Upstream Issue Policy (default)

- 설치/환경 문제와 코어 제품 문제를 구분한다. 사용자 로컬 설정, 비밀키, 채널 권한, 일회성 운영 실수는 먼저 로컬 문제로 본다.
- Agent Bridge 코어 버그나 제품 개선점으로 보이면, 바로 GitHub issue를 만들지 않는다.
- upstream 가능성이 높다고 판단한 같은 턴에 표준 제안을 반드시 한다: 증상 한 줄, 로컬 설정 문제가 아니라 코어 이슈로 보는 이유 한 줄, `Agent Bridge 코어 이슈로 보입니다. upstream GitHub issue를 바로 등록할까요?`라는 yes/no 질문.
- 재현 로그가 있으면 `~/.agent-bridge/agent-bridge upstream draft --title "<title>" --symptom "<symptom>" --why "<reason>" --reproduction-file <path> --output <draft.md>`로 초안을 만든다.
- 사용자가 승인하면 `~/.agent-bridge/agent-bridge upstream propose --title "<title>" --body-file <draft.md> --yes`로 등록한다.
- 사용자가 거절하거나 답하지 않으면 `~/.agent-bridge/agent-bridge upstream propose --title "<title>" --body-file <draft.md>`를 사용해 local candidate로 저장하거나, 직접 `~/.agent-bridge/shared/upstream-candidates/`에 저장한다.
- 사용자가 명시적으로 승인한 뒤에만 GitHub issue를 등록한다.
- 사용자와 함께 작업하다가 범용 제품에 들어갈 만한 변경이 보이면, upstream 후보라고 먼저 알린다.
- upstream 성격의 변경은 관리자 에이전트가 로컬 live install이나 repo에 바로 적용하지 않는다. 먼저 사용자 승인 또는 upstream 제안 여부를 확인한다.

> **Local override precedence**: 개별 에이전트(예: patch)는 위의 기본 정책 위에 local override를 둘 수 있다. override는 해당 에이전트의 `CLAUDE.md` 내 관리 블록 **바깥**의 별도 섹션에서 선언하고, 충돌 시 override가 우선한다. override의 존재는 `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->` 블록 아래쪽에 한 줄 주석 (`> Upstream Issue Policy — Local Override: see below`)으로 표기한다.

## User Preference Promotion (active-preferences)

사용자가 "앞으로 계속 이렇게 해" 식의 **지속 preference**를 말하면, 일회성 이후에도 유지되도록 `active-preferences.md` 계층으로 승격한다. 규칙은 [`user-preference-injection.md`](user-preference-injection.md)를 따른다. 요약:

- 본문에 `앞으로 / 항상 / 계속 / 매번 / from now on / whenever` 등의 signal이 있거나 사용자가 명시적으로 "앞으로 적용해라"라고 하면 후보로 등록한다.
- Agent-local feedback → `agents/<agent>/ACTIVE-PREFERENCES.md`. Team-wide feedback → `docs/agent-runtime/active-preferences.md` (admin 승인 필요).
- 승격 전에 엔트리 포맷(`Rule/Why/How to apply/Source`)으로 정돈하고, 원본 feedback 파일에 `promoted_to: <path>` 헤더를 단다.

## First Session Onboarding (non-admin)

- `SESSION-TYPE.md`에 `Onboarding State: pending`이 남아 있거나 placeholder가 그대로면 일반 작업 전에 온보딩을 수행한다.
- admin 세션은 [`admin-protocol.md`](admin-protocol.md)의 절차를 우선한다. 비admin 세션은 SOUL / role / primary user만 확인한 뒤 바로 작업을 진행한다.
- 온보딩이 끝나면 `SOUL.md`, `SESSION-TYPE.md`, 필요 시 `users/<user-id>/USER.md`를 업데이트하고 상태를 `complete`로 바꾼다.
- 재시작이 필요하면 `NEXT-SESSION.md`를 남긴 뒤 상태를 `complete`로 바꾸고, 다음 세션이 handoff를 따라 검증 후 파일을 삭제하게 한다.

## Managed block contract

- `CLAUDE.md`의 `<!-- BEGIN AGENT BRIDGE DOC MIGRATION --> ... <!-- END AGENT BRIDGE DOC MIGRATION -->` 구간은 `bridge-docs.py`가 관리한다. 사람이 직접 편집하지 않는다.
- 블록 안은 **pointer only**: 읽을 파일 목록 + `docs/agent-runtime/` canonical들의 symlink 설명. 본문 하드카피 금지.
- 블록 바깥은 에이전트별 custom 영역이다. persona, role-specific 규칙, local override는 전부 바깥에 둔다.
- `normalize_claude()`의 regex (`MANAGED_START..MANAGED_END`)는 변경 대상 아니다. 새 렌더러가 같은 마커 안에 새 pointer 본문을 쓰는 형태로 호환된다.

## Changelog

- 2026-04-19: initial ratified version. 공통 블록 7,037B × 18 agents ≈ 126 KB 하드카피 제거, pointer-only SSOT로 전환. Admin-only 섹션을 분리(→ `admin-protocol.md`), legacy shared 파일 redirect, user preference promotion layer 명문화.
