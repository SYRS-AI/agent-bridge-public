#!/usr/bin/env bash
# shellcheck disable=SC2012
# Verification for a single agent's PreCompact registration.
#
#   verify-precompact-registration.sh <agent>
#
# Exit 0 if all three smoke tests pass:
#   1. settings.json has a PreCompact hook pointing at
#      hooks/pre-compact.py with timeout=20.
#   2. Running the hook with stdin `{"trigger":"manual"}` and
#      BRIDGE_AGENT_ID=<a> exits 0 and writes a fresh envelope JSON
#      under agents/<a>/raw/captures/inbox/ with schema_version=="1".
#   3. `bridge-memory.py ingest --capture <file>` round-trips cleanly.
#
# All tests run against the live install. No destructive operations:
# the captures land in the agent's real inbox (marked source=
# "pre-compact-hook-verify") so they can be cleaned up with a simple
# glob after verification.

set -euo pipefail

AGENT="${1:-}"
if [ -z "$AGENT" ]; then
    echo "usage: verify-precompact-registration.sh <agent>" >&2
    exit 2
fi

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
AGENT_HOME="$BRIDGE_HOME/agents/$AGENT"
SETTINGS="$AGENT_HOME/.claude/settings.json"
INBOX="$AGENT_HOME/raw/captures/inbox"
HOOK="$BRIDGE_HOME/hooks/pre-compact.py"
MEM="$BRIDGE_HOME/bridge-memory.py"
TEMPLATE="$BRIDGE_HOME/agents/_template"

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s  %s\n' "$1" "$2" >&2; exit 1; }

# ---- Test 1: settings.json wiring ----
if [ ! -f "$SETTINGS" ]; then
    fail "settings.json" "$SETTINGS missing"
fi

python3 - "$SETTINGS" <<'PY' || fail "settings.json" "PreCompact hook absent/misconfigured"
import json, sys
p = sys.argv[1]
data = json.loads(open(p, encoding="utf-8").read())
events = (data.get("hooks") or {}).get("PreCompact") or []
for group in events:
    for hook in (group.get("hooks") or []):
        cmd = str(hook.get("command") or "")
        if "pre-compact.py" in cmd and int(hook.get("timeout") or 0) == 20 and hook.get("type") == "command":
            sys.exit(0)
sys.exit(1)
PY
pass "settings.json PreCompact hook present with timeout=20"

# ---- Test 2: run hook, expect new envelope in inbox ----
if [ ! -x "$(command -v python3)" ]; then
    fail "hook exec" "python3 not on PATH"
fi
if [ ! -f "$HOOK" ]; then
    fail "hook exec" "$HOOK missing"
fi

mkdir -p "$INBOX"
before="$(ls -1 "$INBOX" 2>/dev/null | wc -l | tr -d ' ')"

set +e
BRIDGE_AGENT_ID="$AGENT" BRIDGE_AGENT_HOME="$AGENT_HOME" BRIDGE_HOME="$BRIDGE_HOME" \
    python3 "$HOOK" <<<'{"trigger":"manual"}' >/tmp/precompact-verify.stdout 2>/tmp/precompact-verify.stderr
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    fail "hook exec" "pre-compact.py exited $rc (compaction-blocking contract violated)"
fi

after="$(ls -1 "$INBOX" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$after" -le "$before" ]; then
    fail "hook exec" "no new capture in $INBOX (before=$before after=$after)"
fi

newest="$(ls -1t "$INBOX"/*.json 2>/dev/null | head -n1)"
if [ -z "$newest" ]; then
    fail "hook exec" "no *.json files in $INBOX"
fi

schema="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); env=d.get("envelope") or {}; print(env.get("schema_version") or d.get("schema_version") or "")' "$newest")"
if [ "$schema" != "1" ]; then
    # Tolerate pre-envelope-diff rollout: consumer may not have the
    # patch yet, in which case schema_version lives inside the text blob.
    if ! grep -q 'schema_version.*1' "$newest" 2>/dev/null; then
        fail "hook exec" "capture $newest missing schema_version=1"
    fi
fi
pass "hook produced envelope capture: $newest"

# ---- Test 3: bridge-memory ingest round-trip ----
capture_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["capture_id"])' "$newest")"
if ! python3 "$MEM" ingest \
        --agent "$AGENT" \
        --home "$AGENT_HOME" \
        --template-root "$TEMPLATE" \
        --capture "$capture_id" \
        --dry-run --json >/tmp/precompact-verify.ingest 2>&1 ; then
    fail "ingest" "$(cat /tmp/precompact-verify.ingest)"
fi
pass "ingest round-trip (dry-run) OK for $capture_id"

printf 'OK    %s\n' "$AGENT"
