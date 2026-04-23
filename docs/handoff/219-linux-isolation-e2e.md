# Handoff — #219 Linux-user isolation E2E test

**수신**: Linux 서버의 admin patch 에이전트
**발신**: `agb-dev-claude` (macOS 호스트)
**이슈**: [#219](https://github.com/SYRS-AI/agent-bridge-public/issues/219) — linux-user isolation ACL + sudo re-exec 복원
**PR**: (생성 후 번호 기입)
**브랜치**: `fix/219-linux-isolation-acl-sudo-reexec`

## 목적

이 PR은 linux-user isolation 모드의 memory-daily harvester 동작을 복원한다. macOS 호스트에서는 mock smoke로 branch logic만 검증 가능하고, **실제 sudo/ACL/cron 동작은 Linux 서버에서만 검증 가능**. 이 문서대로 순서를 따라 실행하고 결과를 보고해달라.

## 전제

- Linux 서버에 agent-bridge가 live install 상태 (`~/.agent-bridge`).
- 최소 하나의 agent가 `isolation.mode=linux-user` + 유효한 `os_user`. 확인 방법:
  ```bash
  ~/.agent-bridge/agb agent list --json | \
    python3 -c 'import json,sys; rows=json.load(sys.stdin); [print(r["agent"], r["isolation"]) for r in rows if r["isolation"]["mode"]=="linux-user"]'
  ```
- 해당 agent에 대해 `sudo -n -u <os_user> true`가 현재 controller 사용자에서 동작. 안 되면 아래 step 2-3에서 sudoers 재설치 필요.
- 현재 Python 3.9+ + `setfacl` (acl 패키지).

아래에서 `<agent>` = 테스트 대상 isolated agent, `<os_user>` = 해당 agent의 os_user. 예시 치환해서 실행.

## 단계

### 1) 브랜치 배포

```bash
cd ~/.agent-bridge-source        # 또는 AGENT_BRIDGE_SOURCE_DIR로 지정된 경로
git fetch origin
git checkout fix/219-linux-isolation-acl-sudo-reexec
git pull --ff-only

# 라이브 install에 반영
bash ~/.agent-bridge/agent-bridge upgrade
# (source path가 non-standard면 --source 전달)
```

**체크**:
```bash
cat ~/.agent-bridge/VERSION         # 0.6.8이어야 함
ls -la ~/.agent-bridge/scripts/memory-daily-harvest.sh   # 존재 + 실행권한
# v1.3 stub은 sudo를 사용하지 않음 — transcripts-home 플래그로 controller-UID 실행
grep -c "transcripts-home" ~/.agent-bridge/scripts/memory-daily-harvest.sh   # ≥1
grep -c "shared/aggregate" ~/.agent-bridge/bridge-memory.py   # ≥1
```

실패 시: upgrade 로그 수집 (`~/.agent-bridge/logs/upgrade.log` 등), 이 단계에서 중단하고 보고.

### 2) ACL 재적용

```bash
~/.agent-bridge/agent-bridge isolate <agent> --reapply --dry-run
# plan을 검토 — bridge_linux_prepare_agent_isolation 호출이 보여야 함

~/.agent-bridge/agent-bridge isolate <agent> --reapply
# 실제 적용. "[done] ACL reapply complete for <agent>" 출력 확인
```

**체크 — 새 ACL 상태**:
```bash
getfacl $BRIDGE_STATE_DIR/memory-daily 2>/dev/null | head -20
getfacl $BRIDGE_STATE_DIR/memory-daily/<agent>/
getfacl $BRIDGE_STATE_DIR/memory-daily/shared/aggregate/
# v1.3 핵심: controller가 target user의 transcripts를 읽을 수 있어야 함
getfacl $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>/.claude/
getfacl $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>/.claude/projects/ 2>/dev/null || echo "projects/ 없음 (fresh agent; 첫 claude -p 실행 후 생성됨)"
```

기대:
- `memory-daily/` 자체는 `u:<os_user>:r-x` (traverse only).
- `memory-daily/<agent>/`는 `u:<os_user>:rwX` + default ACL 포함.
- `memory-daily/shared/aggregate/`도 `u:<os_user>:rwX` + default ACL.
- `<user_home>/.claude/`와 `.claude/projects/` 에 `u:<controller>:r-X` ACL (controller가 read 가능).

**Legacy aggregate 파일 migration 확인** (설치 이전에 `state/memory-daily/admin-aggregate-*.json`가 있었다면):
```bash
ls $BRIDGE_STATE_DIR/memory-daily/admin-aggregate-skip.json 2>&1     # no such file
ls $BRIDGE_STATE_DIR/memory-daily/shared/aggregate/admin-aggregate-skip.json 2>&1  # (있으면 OK, 없으면 first-run에 생성됨)
```

### 3) Controller read probe

v1.3에서 stub은 sudo를 쓰지 않는다. 대신 controller UID가 target의 transcripts를 직접 읽는다.

```bash
# controller UID로 실행하는 프로세스 입장에서 접근 가능해야 함
test -r $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>/.claude/projects && echo "read OK" || echo "read FAIL (ACL 미부여 또는 projects/ 없음)"
```

FAIL + `.claude/projects/`가 없는 경우: target agent가 한 번도 claude -p를 실행하지 않았을 가능성. 해당 agent를 평소처럼 작업시키면 첫 세션 후 생성됨. 그 후 `isolate --reapply`로 default ACL 재부여.

FAIL + `.claude/projects/`가 있는 경우: ACL 부여 실패. `getfacl`로 현재 상태 확인 + `isolate --reapply` 재실행.

(참고: tmux/bash launch용 `sudo -n -u <os_user> -- bash -c 'exit 0'` probe는 여전히 `bridge_linux_can_sudo_to`가 사용. 기존 sudoers `NOPASSWD: SETENV: tmux, bash`가 정상 설치됐다면 probe 성공. 확인:
```bash
sudo -n -u <os_user> -- bash -c 'exit 0' && echo "bash probe OK" || echo "bash probe FAIL"
```
)

### 4) Harvester 수동 invoke

먼저 stub이 어떤 branch로 들어가는지 확인:
```bash
export CRON_REQUEST_DIR="/tmp/s219-smoke-$$"
mkdir -p "$CRON_REQUEST_DIR"
bash -x ~/.agent-bridge/scripts/memory-daily-harvest.sh --agent <agent> 2>&1 | head -80
```

기대 (controller가 target의 .claude/projects 읽기 가능할 때):
```
+ exec /usr/bin/python3 .../bridge-memory.py harvest-daily \
  --agent <agent> --home <home> --workdir <workdir> \
  --os-user <os_user> --transcripts-home <target_home> \
  --sidecar-out <sidecar> --json
```

- `--transcripts-home=<target_home>`가 포함돼야 한다 (v1.3 핵심).
- `sudo`가 invoke되지 **않아야** 한다.
- `--skipped-permission`이 없어야 한다.

읽기 불가 시 기대:
```
+ exec /usr/bin/python3 .../bridge-memory.py harvest-daily \
  --agent <agent> --home <home> --workdir <workdir> \
  --os-user <os_user> --skipped-permission \
  --sidecar-out <sidecar> --json
```
이 경우 step 2~3의 ACL 재확인 필요.

**체크 — 실제 run artifacts**:
```bash
ls "$CRON_REQUEST_DIR"/authoritative-memory-daily.json    # 생성됨
cat "$CRON_REQUEST_DIR"/authoritative-memory-daily.json | python3 -m json.tool
# status, summary, actions_taken 확인 — 에러 없이 valid RESULT_SCHEMA
ls $BRIDGE_STATE_DIR/memory-daily/<agent>/<yesterday>.json   # manifest 생성됨
```

Manifest `decision.source_confidence`가 `none`이 아니라 실제 transcript 활동 반영하는지 확인 (agent가 해당 날짜에 실제 활동이 있었다면 `strong` 또는 `medium` 기대).

### 5) Cron dispatch E2E

```bash
# memory-daily 크론 job id 찾기
~/.agent-bridge/agb cron list --agent <agent> --json | \
  python3 -c 'import json,sys; [print(j["id"], j["title"]) for j in json.load(sys.stdin) if "memory-daily" in j["title"]]'
```

얻은 `<job-name-or-id>`로 수동 dispatch:
```bash
bash ~/.agent-bridge/bridge-cron.sh enqueue <job-name-or-id>
# 옵션: --slot, --target, --dry-run.
# dry-run으로 먼저 plan 출력 후 실제 실행 권장.
bash ~/.agent-bridge/bridge-cron.sh enqueue <job-name-or-id> --dry-run
```

Enqueue 성공 후 daemon이 task를 claim하고 worker가 `run-subagent`로 실행. 잠깐 대기 후 run_dir 확인.

Dispatch 후 잠깐 기다린 뒤:
```bash
# 가장 최근 run
ls -t $BRIDGE_CRON_STATE_DIR/runs/ | head -3
run_id="<위의 최신 run_id>"
cd $BRIDGE_CRON_STATE_DIR/runs/$run_id/
cat result.json | python3 -m json.tool
```

**체크**:
- `"status": "success"` (또는 harvest 결과에 따라 ok/noop/queued)
- `"child_result_source": "authoritative-sidecar"` (not "child-fallback", not "authoritative-sidecar-after-parse-error")
- `"actions_taken"`에 적절한 값
- **`sidecar_error_note` 필드 없음** (있으면 sidecar 문제)

**ACL 검증**:
```bash
getfacl $BRIDGE_CRON_STATE_DIR/runs/$run_id/
# u:<os_user>:rwX 포함 확인
```

### 6) Daemon refresh gating

`result.json`의 `actions_taken`에 `queue-backfill`이 있을 때와 없을 때의 daemon 동작:

```bash
# daemon audit log에서 해당 run_id 관련 이벤트 확인
grep "$run_id" $BRIDGE_LOG_DIR/audit.jsonl | python3 -m json.tool
```

- `queue-backfill` 있으면 `session_refresh_queued` 이벤트.
- 없으면 `session_refresh_skipped` + `reason=no_queue_backfill_action`.

### 7) 실패 triage

| 증상 | 원인 후보 | 확인 |
|---|---|---|
| `result.json`에 `child_result_source="child-fallback"` | sidecar write 실패 | `ls $CRON_REQUEST_DIR/authoritative-memory-daily.json` — 없으면 Python 예외. `stderr.log` 확인. |
| `state=skipped-permission`으로 끝남 | controller가 target의 `.claude/projects`에 read 불가 | step 2~3 재확인: `getfacl <target_home>/.claude/projects`, 없으면 `isolate --reapply`. `.claude/projects/`가 아예 없으면 agent로 first session 실행. |
| Python `PermissionError: [Errno 13]` | ACL grant 누락 | `getfacl` 확인. `isolate --reapply` 재실행. |
| `runner_error` 필드에 `cron runner failure` | Queue task race (이 PR이 막은 문제) | `request.json` 존재하고 `dispatch_task_id != 0`인지 확인. `status.json` 상태. |
| aggregate 파일 write EACCES | `shared/aggregate/`에 default ACL 없음 | `getfacl -d $BRIDGE_STATE_DIR/memory-daily/shared/aggregate/`. `isolate --reapply`로 재적용. |
| `bridge-start.sh` linux-user isolation fallback to shared | `bridge_linux_can_sudo_to` probe 실패 (sudoers 미설치 또는 오래된 entry) | `sudo -n -u <os_user> -- bash -c 'exit 0'` 직접 테스트. 실패면 `isolate --install-sudoers` 재실행 (sudoers entry가 `SETENV:` tag 포함인지 확인). |

## 보고 format

아래 체크리스트를 응답 body에 포함. 각 단계에 PASS/FAIL + 실패 시 log snippet.

```
[ ] 1. 브랜치 배포 (VERSION 0.6.8, stub/shared-aggregate 반영)
[ ] 2. agent-bridge isolate <agent> --reapply 성공, 새 ACL 확인 (memory-daily trees + <user_home>/.claude/projects에 controller r-X)
[ ] 3. controller read probe PASS (test -r <user_home>/.claude/projects). bash -c 'exit 0' sudo probe도 PASS.
[ ] 4. 수동 stub invoke — --transcripts-home branch, sudo 호출 없음, sidecar + manifest 생성, source_confidence 정상
[ ] 5. Cron dispatch E2E — result.json child_result_source=authoritative-sidecar, run_dir ACL OK
[ ] 6. Daemon refresh gating — session_refresh_{queued|skipped} 이벤트 확인
```

**전체 결과**: PASS / FAIL + (FAIL 시) 어느 단계에서 어떤 증상.

응답 경로: `/tmp/agb-codex-219-linux-e2e-report.md` 또는 public repo workdir 내부. `shared/` 금지.

응답 task 생성:
```bash
bash ~/.agent-bridge/bridge-task.sh create \
  --from patch \
  --to agb-dev-claude \
  --priority normal \
  --title "[#219 Linux E2E report]" \
  --body-file /tmp/agb-codex-219-linux-e2e-report.md
```

## 질문 / 미해결

테스트 중 spec과 실환경이 어긋나면 중단하고 `agb-dev-claude`에게 task 생성 (priority `high`).
