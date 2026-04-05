# Migration Refactor Backlog

Agent Bridge로 런타임을 옮기면서 발견한 구조적 비효율과 임시 호환층을 기록한다.
목표는 "지금 당장 마이그레이션을 막지 않는 선에서 동작하게 만들고, 이후 한 번에 깨끗하게 리팩터링"하는 것이다.

원칙:
- 즉시 운영 복구가 필요한 수정은 먼저 반영한다.
- 하지만 레거시 호환 로직, 반복되는 rewrite 규칙, live-only 응급처치는 여기 backlog로 남긴다.
- 항목은 "왜 비효율인지"와 "리팩터링 방향"까지 같이 적는다.

## P0 Runtime Canon

### 1. cron/runtime cutover가 끝나면 legacy source 개념은 일회성 migration surface로만 남겨야 한다
- 현상: canonical cron store와 runtime root는 이미 `~/.agent-bridge`로 옮기는 중이지만, import/rewrite 도구와 일부 문서에는 아직 legacy source 개념이 남아 있다.
- 비효율:
  - cutover 이후에도 "어느 파일이 진짜 source of truth인가"를 다시 생각하게 만든다.
  - import가 끝난 설치에서도 migration wording이 남아 fresh install mental model을 흐린다.
- 지금 해야 하는 일:
  - 실제 runtime 자산 복사와 payload/doc rewrite는 즉시 진행한다.
  - backlog에 남기는 대상은 cutover 이후에도 잔존하는 호환 surface와 wording뿐이다.
- 리팩터링 방향:
  - import 완료 후에는 scheduler/inventory/help가 bridge-native store만 기본으로 보게 하기
  - legacy source path는 `cron import --source-jobs-file` 같은 일회성 cutover surface로만 격리
  - migration wording을 public docs의 optional appendix로 격리

### 1a. runtime sync와 rewrite가 두 단계로 분리돼 있어 전수 마이그레이션이 비효율적이다
- 현상: `runtime sync`, `rewrite-files`, `docs apply`를 순서대로 돌려야 해서 "복사됐지만 참조는 안 바뀐 상태"가 잠깐이라도 생긴다.
- 비효율:
  - 한 단계가 빠지면 inventory에 false positive가 많이 남는다.
  - 운영자가 지금 남은 게 "미복사"인지 "미재작성"인지 다시 판단해야 한다.
- 리팩터링 방향:
  - `agent-bridge migrate runtime apply` 같은 단일 cutover 명령으로 묶기
  - copy/rewrite/audit을 하나의 report에서 보여주기

### 2. runtime inventory가 "legacy debt"와 "정상 dependency"를 함께 센다
- 현상: db skill 사용이나 MCP 설정처럼 남아 있어도 되는 의존성이 migration debt처럼 집계된다.
- 비효율:
  - 실제 남은 migration debt 규모를 오판하게 된다.
  - 우선순위가 흐려진다.
- 리팩터링 방향:
  - inventory category를 `legacy_path_ref`, `bridge_runtime_dependency`, `historical_note`로 분리
  - summary는 debt와 정상 dependency를 따로 보여주기

### 3. runtime rewrite가 문자열 치환 중심이라 brittle하다
- 현상: `rewrite-cron`, `rewrite-files`, `bridge-docs`가 공통적으로 문자열/regex 치환에 크게 의존한다.
- 비효율:
  - source 문구가 조금만 바뀌면 rewrite coverage가 깨진다.
  - 같은 의미의 패턴을 여러 군데서 따로 관리한다.
- 리팩터링 방향:
  - 공통 rewrite registry/transformer 도입
  - path rewrite, delivery rewrite, doc rewrite를 같은 spec에서 구동

## P1 Docs / Skills

### 4. shared 문서가 canonical runtime docs와 historical notes를 함께 담고 있다
- 현상: `SYRS-RULES`, `ROSTER`, `SYRS-CONTEXT`에 현재 규칙과 과거 OpenClaw 설명이 섞여 있다.
- 비효율:
  - 에이전트가 오래된 예시를 source of truth로 오인한다.
  - migration override block이 계속 길어진다.
- 리팩터링 방향:
  - canonical runtime docs와 historical archive를 분리
  - live 에이전트가 읽는 문서는 bridge-native 설명만 남기기

### 5. 에이전트 memory / lessons / backups가 live home 안에 섞여 있다
- 현상: `memory`, `compound/lessons`, `backups` 안의 오래된 OpenClaw 경로가 inventory와 search 결과를 오염시킨다.
- 비효율:
  - 실제 운영 파일과 과거 기록을 구분하기 어렵다.
  - 자동 audit이 false positive를 많이 낸다.
- 리팩터링 방향:
  - live runtime files / historical notes / backups를 디렉터리 레벨에서 분리
  - inventory는 기본적으로 runtime-canonical 파일만 스캔

### 6. skill/tool migration이 "파일 복사" 수준에 머무르고 있다
- 현상: legacy skills/scripts를 runtime으로 복사해 왔지만 invocation contract는 아직 균일하지 않다.
- 비효율:
  - 어떤 skill은 문서형, 어떤 skill은 shell wrapper, 어떤 skill은 python entrypoint라 호출면이 제각각이다.
- 리팩터링 방향:
  - bridge runtime skill contract 정의
  - skill metadata, entrypoint, required secrets, expected outputs를 표준화

## P1 Delivery / Queue

### 7. completion notice / nudge / review nudge가 아직 noisy하다
- 현상: duplicate completion notice, stale queued notification, follow-up nudge가 반복적으로 발생했다.
- 비효율:
  - 실제 작업과 시스템 소음이 섞인다.
  - 인박스 판단 비용이 올라간다.
- 리팩터링 방향:
  - task type별 notification policy 명시
  - duplicate suppression과 completion fan-out rule 정리

### 8. Claude/Codex delivery path가 엔진별로 여전히 다르게 느껴진다
- 현상: 현재는 많이 정리됐지만 wake, nudge, prompt gate, queue-first semantics가 엔진별로 다르게 보인다.
- 비효율:
  - 운영자가 mental model을 하나로 들고가기 어렵다.
- 리팩터링 방향:
  - "queue-first, engine-specific wake only" 원칙으로 API surface 단일화
  - 엔진별 차이는 notifier/wake adapter 내부로만 숨기기

## P2 Secrets / DB / MCP

### 9. secrets source of truth가 아직 혼재돼 있다
- 현상: `runtime/secrets`, `runtime/credentials`, `runtime/openclaw.json`, 1Password/op usage가 섞여 있다.
- 비효율:
  - 어떤 비밀이 어디서 주입되는지 한눈에 안 보인다.
- 리팩터링 방향:
  - secret class별 표준 source 지정
  - 1Password/op integration과 local secret mount contract 정리

### 10. DB skill이 runtime local wrapper 없이 개별 스크립트 경로에 묶여 있다
- 현상: `agent-db`, `syrs-commerce-db`, `meta-api`, `tracx-logis-api` 등이 각자 다른 방식으로 호출된다.
- 비효율:
  - cron/prompt/docs에서 호출 문법이 난립한다.
  - connection policy나 retries를 공통화하기 어렵다.
- 리팩터링 방향:
  - `agent-bridge runtime db <provider> ...` 같은 공통 wrapper 고려
  - DB skill entrypoint별 connection config 표준화

### 11. MCP 구성이 agent-local 파일과 historical config에 흩어져 있다
- 현상: `.mcp.json`, old plugin configs, runtime notes가 따로 있다.
- 비효율:
  - fresh install과 migrated install의 설정 경로가 다르게 보인다.
- 리팩터링 방향:
  - bridge-owned MCP merge policy 명확화
  - agent-local override와 shared default를 분리

## P3 Install / Product

### 12. repo checkout vs live install의 경계가 아직 선명하지 않다
- 현상: repo-first 원칙은 세웠지만 live drift warning, runtime state skip, manual deploy helper에 의존하는 부분이 남아 있다.
- 비효율:
  - fresh install 제품 관점에서 복잡하다.
- 리팩터링 방향:
  - install/update/sync lifecycle을 공식 명령 하나로 통합
  - repo code, live state, generated runtime artifact를 명확히 분리

### 13. 관리자 에이전트 중심 UX가 아직 CLI 표면에 완전히 녹지 않았다
- 현상: `agb admin`은 생겼지만 생성, 초기설정, 역할 연결, audit, cutover 흐름이 여러 명령에 흩어져 있다.
- 비효율:
  - 관리자 에이전트가 전체 운영을 장악하는 story가 덜 매끈하다.
- 리팩터링 방향:
  - `agent create|configure|migrate|audit|cutover` 흐름 재정리
  - manager-first onboarding 문서/CLI 정비

## Notes

- 이 backlog는 migration 진행 중 계속 추가한다.
- "당장 막히는 운영 이슈"는 별도 이슈/커밋으로 먼저 해결하고, 구조적 debt만 여기 남긴다.
