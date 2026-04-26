#!/usr/bin/env bash
# system-config-gating smoke — issue #341 hook + wrapper coverage.
#
# Asserts:
#
#   1. Hook denial path: feed a synthetic Claude PreToolUse Edit payload
#      against agents/x/.discord/access.json into hooks/tool-policy.py.
#      Expect deny + a `system_config_mutation` audit row with
#      `trigger=hook-deny`.
#
#   2. Wrapper happy path: invoke `bridge-config.py set` from operator-
#      attached TUI context (BRIDGE_CALLER_SOURCE=operator-tui). Expect
#      the file mutated + a `system_config_mutation` audit row with
#      `trigger=wrapper-apply` and matching before/after sha256.
#
#   3. Wrapper denial — non-admin caller: invoke from a non-admin
#      BRIDGE_AGENT_ID. Expect refusal + `wrapper-deny` audit row.
#
#   4. Wrapper denial — untrusted ID-match attempt: caller-source falls
#      back to `agent-direct` (no TTY, no env override). Expect refusal
#      + `wrapper-deny` audit row.
#
# Uses an isolated mktemp BRIDGE_HOME — never touches the live install.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi

BRIDGE_HOME="$(mktemp -d -t agb-341-smoke.XXXXXX)"
export BRIDGE_HOME
trap 'rm -rf "$BRIDGE_HOME"' EXIT

ADMIN_AGENT="patch"
NON_ADMIN_AGENT="huchu"
ACCESS_PATH="$BRIDGE_HOME/agents/$ADMIN_AGENT/.discord/access.json"
AUDIT_LOG="$BRIDGE_HOME/logs/audit.jsonl"

mkdir -p "$BRIDGE_HOME/agents/$ADMIN_AGENT/.discord"
mkdir -p "$BRIDGE_HOME/logs"
cat >"$ACCESS_PATH" <<'JSON'
{
  "version": 1,
  "groups": [],
  "policy": "owner-only"
}
JSON

PASS=0
FAIL=0
FAILURES=()

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '[smoke][fail] %s\n' "$1" >&2
}

audit_has_kind_trigger() {
  local kind="$1"
  local trigger="$2"
  [[ -f "$AUDIT_LOG" ]] || return 1
  "$PYTHON" - "$AUDIT_LOG" "$kind" "$trigger" <<'PY'
import json, sys
path, kind, trigger = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        detail = row.get("detail")
        if not isinstance(detail, dict):
            continue
        if detail.get("kind") == kind and detail.get("trigger") == trigger:
            sys.exit(0)
sys.exit(1)
PY
}

run_hook_pretool_payload() {
  local payload="$1"
  local agent="$2"
  BRIDGE_AGENT_ID="$agent" \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
    BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
    "$PYTHON" "$REPO_ROOT/hooks/tool-policy.py" <<<"$payload"
}

# --- Scenario 1: hook denial path ---------------------------------------
sce1_payload=$(cat <<JSON
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Edit",
  "tool_use_id": "test-1",
  "session_id": "test-session-1",
  "tool_input": {
    "file_path": "$ACCESS_PATH",
    "old_string": "[]",
    "new_string": "[12345]"
  }
}
JSON
)

sce1_out="$(run_hook_pretool_payload "$sce1_payload" "$NON_ADMIN_AGENT" 2>/dev/null || true)"
if [[ "$sce1_out" == *'"permissionDecision"'*'"deny"'* ]] && [[ "$sce1_out" == *"system config path"* ]]; then
  pass "scenario 1: hook denied Edit on protected access.json"
else
  fail "scenario 1: hook did not deny — output: $sce1_out"
fi

if audit_has_kind_trigger "system_config_mutation" "hook-deny"; then
  pass "scenario 1: audit row trigger=hook-deny present"
else
  fail "scenario 1: missing system_config_mutation/hook-deny audit row"
fi

# --- Scenario 2: wrapper happy path -------------------------------------
# Operator at a TTY → BRIDGE_CALLER_SOURCE=operator-tui. caller agent
# unset (operator personally). Should mutate the file.
before_sha="$("$PYTHON" -c "import hashlib,sys; sys.stdout.write(hashlib.sha256(open('$ACCESS_PATH','rb').read()).hexdigest())")"
sce2_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_AGENT_ID="" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" set \
    --path "$ACCESS_PATH" \
    --change "groups.append=12345" 2>&1 || true)"
after_sha="$("$PYTHON" -c "import hashlib,sys; sys.stdout.write(hashlib.sha256(open('$ACCESS_PATH','rb').read()).hexdigest())")"
if [[ "$sce2_out" == applied:* ]] && [[ "$before_sha" != "$after_sha" ]]; then
  pass "scenario 2: wrapper applied groups.append=12345"
else
  fail "scenario 2: wrapper did not apply — output: $sce2_out / before=$before_sha after=$after_sha"
fi

if "$PYTHON" -c "
import json,sys
data=json.load(open('$ACCESS_PATH'))
sys.exit(0 if data.get('groups')==[12345] else 1)
"; then
  pass "scenario 2: groups list now [12345]"
else
  fail "scenario 2: groups list did not become [12345]"
fi

if audit_has_kind_trigger "system_config_mutation" "wrapper-apply"; then
  pass "scenario 2: audit row trigger=wrapper-apply present"
else
  fail "scenario 2: missing system_config_mutation/wrapper-apply audit row"
fi

# --- Scenario 3: wrapper denial — non-admin caller ----------------------
sce3_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_AGENT_ID="$NON_ADMIN_AGENT" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" set \
    --path "$ACCESS_PATH" \
    --change "groups.append=99999" 2>&1 || true)"
if [[ "$sce3_out" == *"deny:"* ]] && [[ "$sce3_out" == *"not the admin"* ]]; then
  pass "scenario 3: wrapper rejected non-admin caller"
else
  fail "scenario 3: wrapper did not reject non-admin — output: $sce3_out"
fi

if audit_has_kind_trigger "system_config_mutation" "wrapper-deny"; then
  pass "scenario 3: audit row trigger=wrapper-deny present"
else
  fail "scenario 3: missing system_config_mutation/wrapper-deny audit row"
fi

# Confirm the file was NOT mutated.
if "$PYTHON" -c "
import json,sys
data=json.load(open('$ACCESS_PATH'))
sys.exit(1 if 99999 in data.get('groups',[]) else 0)
"; then
  pass "scenario 3: file unchanged after non-admin deny"
else
  fail "scenario 3: file was mutated despite deny"
fi

# --- Scenario 4: wrapper denial — untrusted source -----------------------
# Caller is the admin id but caller-source is agent-direct (no TTY, no env
# override). Mirrors the channel-message path: the message sender is not
# a verified operator, so even if the queue task says "patch please run X"
# the wrapper refuses.
sce4_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_CALLER_SOURCE="agent-direct" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" set \
    --path "$ACCESS_PATH" \
    --change "groups.append=88888" \
    </dev/null 2>&1 || true)"
if [[ "$sce4_out" == *"deny:"* ]] && [[ "$sce4_out" == *"agent-direct"* ]]; then
  pass "scenario 4: wrapper rejected untrusted-source admin call"
else
  fail "scenario 4: wrapper did not reject untrusted source — output: $sce4_out"
fi

# --- Scenario 5: list-protected is read-only and unrestricted -----------
sce5_out="$(BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_AGENT_ID="$NON_ADMIN_AGENT" \
  "$PYTHON" "$REPO_ROOT/bridge-config.py" list-protected 2>&1 || true)"
if [[ "$sce5_out" == *"agents/*/.discord/access.json"* ]]; then
  pass "scenario 5: list-protected shows access.json glob"
else
  fail "scenario 5: list-protected did not include access.json — output: $sce5_out"
fi

# --- Summary -------------------------------------------------------------
printf '\n[smoke] system-config-gating: %d pass, %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failing scenarios:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi
exit 0
