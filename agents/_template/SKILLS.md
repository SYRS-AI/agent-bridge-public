# Skills

기본 bridge-owned Claude homes는 공통 shared skill을 자동으로 링크한다.

- `agent-bridge-runtime`
- `cron-manager`
- `memory-wiki`
- `agent-bridge` (project/local context에서 필요할 때)

공통 카탈로그는 `~/.agent-bridge/shared/SKILLS.md`를 기준으로 본다.

이 에이전트에 runtime skill이 매핑되어 있으면, `bridge-docs.py`가 이 파일을 regenerate하면서 여기에도 함께 적는다.

추가 private skill은 `skills/` 아래에 배치한다.
