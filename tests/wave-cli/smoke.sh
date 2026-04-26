#!/usr/bin/env bash
# tests/wave-cli/smoke.sh — `agent-bridge wave` Phase 1.1 acceptance.
#
# Phase 1.1 covers: dispatch (state JSON + briefs + README), list, show,
# templates, close-issue placeholder. Worker startup, queue tasks, codex
# adapter, PR automation, and validation flows belong to Phases 1.2-1.6
# and are out of scope for this smoke.
#
# Runs with an isolated BRIDGE_HOME under TMPDIR. No live state touched.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log()  { printf '[wave-cli] %s\n' "$*"; }
ok()   { printf '[wave-cli] ok: %s\n' "$*"; }
die()  { printf '[wave-cli][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[wave-cli][skip] %s\n' "$*"; exit 0; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required (have ${BASH_VERSION})"
fi

if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 missing"
fi

TMP_ROOT="$(mktemp -d -t agb-wave-cli.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

export BRIDGE_HOME="$TMP_ROOT/bridge-home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_SHARED_DIR"

# Pin a deterministic main agent so dispatch doesn't try to read
# BRIDGE_AGENT_ID from the live process env.
export BRIDGE_AGENT_ID="wave-smoke-runner"

AB="$REPO_ROOT/agent-bridge"
WAVE_SH="$REPO_ROOT/bridge-wave.sh"
WAVE_PY="$REPO_ROOT/bridge-wave.py"

[[ -x "$AB" ]] || die "agent-bridge missing or not executable at $AB"
[[ -r "$WAVE_SH" ]] || die "bridge-wave.sh missing at $WAVE_SH"
[[ -r "$WAVE_PY" ]] || die "bridge-wave.py missing at $WAVE_PY"

# ---------------------------------------------------------------------------
# 1. python helper smokes
# ---------------------------------------------------------------------------

wave_id="$(python3 "$WAVE_PY" wave-id-generate 276)"
[[ "$wave_id" =~ ^wave-276-[0-9]{8}-[0-9]{4}-[0-9a-f]{8}$ ]] \
  || die "wave-id-generate shape unexpected: $wave_id"
ok "wave-id-generate composes wave-<issue>-<stamp>-<sha8>"

member_id="$(python3 "$WAVE_PY" member-id-generate "$wave_id" A)"
[[ "$member_id" == "$wave_id"-A-* && "${#member_id}" -gt "${#wave_id}" ]] \
  || die "member-id-generate shape unexpected: $member_id"
ok "member-id-generate appends -<track>-<sha8>"

# Close-keyword scanner positive: a brief with `closes #276`
positive="$TMP_ROOT/positive.md"
cat >"$positive" <<'BAD'
This PR closes #276 and fixes #999.
BAD
if python3 "$WAVE_PY" close-keyword-scan "$positive" >/dev/null; then
  die "close-keyword-scan should have flagged $positive"
fi
ok "close-keyword-scan flags closes/fixes/resolves"

negative="$TMP_ROOT/negative.md"
cat >"$negative" <<'OK'
Reference: (#276 Track A). See also: #999 for the related work.
OK
python3 "$WAVE_PY" close-keyword-scan "$negative" >/dev/null \
  || die "close-keyword-scan flagged a clean reference"
ok "close-keyword-scan accepts (#N) reference style"

# ---------------------------------------------------------------------------
# 2. wave dispatch --dry-run
# ---------------------------------------------------------------------------

dry_out="$("$AB" wave dispatch 276 --tracks A,B --main-agent ws-smoke --dry-run 2>&1)"
[[ "$dry_out" == *"would create wave: wave-276-"* ]] \
  || die "dispatch --dry-run output unexpected: $dry_out"
[[ "$dry_out" == *"tracks:     A,B"* ]] \
  || die "dispatch --dry-run did not echo tracks: $dry_out"

# Confirm dry-run wrote nothing.
[[ "$(find "$BRIDGE_STATE_DIR" -name '*.json' 2>/dev/null | wc -l)" -eq 0 ]] \
  || die "dispatch --dry-run wrote state: $(find "$BRIDGE_STATE_DIR" -name '*.json')"
ok "wave dispatch --dry-run echoes plan + writes nothing"

# ---------------------------------------------------------------------------
# 3. wave dispatch (real)
# ---------------------------------------------------------------------------

dispatch_out="$("$AB" wave dispatch 276 --tracks A,B --main-agent ws-smoke 2>&1)"
real_wave_id="$(printf '%s\n' "$dispatch_out" | awk '/^wave dispatched: /{print $3}')"
[[ -n "$real_wave_id" ]] || die "could not parse wave id from dispatch output: $dispatch_out"
ok "wave dispatch returns wave id ($real_wave_id)"

state_file="$BRIDGE_STATE_DIR/waves/${real_wave_id}.json"
[[ -r "$state_file" ]] || die "state file missing: $state_file"
ok "wave dispatch writes state JSON"

shared_dir="$BRIDGE_SHARED_DIR/waves/$real_wave_id"
[[ -d "$shared_dir" ]] || die "shared wave dir missing: $shared_dir"
[[ -r "$shared_dir/README.md" ]] || die "README mirror missing: $shared_dir/README.md"
brief_count="$(find "$shared_dir" -name brief.md | wc -l | tr -d ' ')"
[[ "$brief_count" == 2 ]] || die "expected 2 briefs (A,B), got $brief_count"
ok "wave dispatch writes README + 2 member briefs"

# Each brief must NOT contain a close-keyword (Phase 1.1 emits the
# 11-section template — verify the close-keyword footgun warning is in
# place but no actual `closes #N` line).
for b in "$shared_dir"/*/brief.md; do
  # close-keyword-scan returns rc=0 when clean, rc=1 when a hit is found.
  # The brief MUST be clean.
  if ! python3 "$WAVE_PY" close-keyword-scan "$b" >/dev/null; then
    grep -nE "closes\s+#[0-9]+|fixes\s+#[0-9]+|resolves\s+#[0-9]+" "$b" || true
    die "generated brief contains a close-keyword: $b"
  fi
done
ok "generated briefs are close-keyword-clean"

# State JSON shape sanity.
python3 - "$state_file" <<'PY' || die "state JSON sanity check failed"
import json, sys
s = json.loads(open(sys.argv[1]).read())
assert s["wave_id"], "wave_id missing"
assert s["issue"] == "276", f"issue mismatch: {s['issue']!r}"
assert s["main_agent"] == "ws-smoke", f"main_agent mismatch: {s['main_agent']!r}"
assert s["worker_engine"] == "claude", f"default worker engine mismatch: {s['worker_engine']!r}"
assert sorted(s["tracks"]) == ["A", "B"], f"tracks mismatch: {s['tracks']!r}"
assert len(s["members"]) == 2, f"members count mismatch: {len(s['members'])}"
for m in s["members"]:
    assert m["state"] == "pending", f"member state should be pending: {m}"
    assert m["task_id"] is None, "phase 1.1 must not set task_id"
    assert m["pr_url"] is None, "phase 1.1 must not set pr_url"
    assert m["worktree_root"] is None, "phase 1.1 must not set worktree_root"
PY
ok "state JSON shape and pending-state invariants hold"

# ---------------------------------------------------------------------------
# 4. wave list / show
# ---------------------------------------------------------------------------

list_json="$("$AB" wave list --json)"
echo "$list_json" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
n = len(data["waves"])
assert n == 1, f"expected 1 wave, got {n}"
w = data["waves"][0]
assert w["issue"] == "276"
assert w["member_states"]["pending"] == 2
' || die "wave list --json shape mismatch"
ok "wave list --json reports 1 wave with 2 pending members"

show_json="$("$AB" wave show "$real_wave_id" --json)"
echo "$show_json" | python3 -c '
import json, sys
s = json.loads(sys.stdin.read())
assert s["wave_id"], "wave show: wave_id missing"
assert sorted(s["tracks"]) == ["A", "B"]
' || die "wave show --json shape mismatch"
ok "wave show --json round-trips state"

show_human="$("$AB" wave show "$real_wave_id")"
[[ "$show_human" == *"wave: $real_wave_id"* ]] || die "wave show (human) header mismatch"
[[ "$show_human" == *"main agent:   ws-smoke"* ]] || die "wave show (human) main_agent missing"
ok "wave show prints human-readable summary"

# ---------------------------------------------------------------------------
# 5. wave templates + close-issue placeholder
# ---------------------------------------------------------------------------

templates_out="$("$AB" wave templates 2>&1)"
[[ "$templates_out" == *"default"* ]] || die "wave templates should mention default"
ok "wave templates lists at least the default template"

# close-issue is a placeholder that exits 64 (operator must do it manually
# for now). Catch the rc explicitly.
set +e
"$AB" wave close-issue 276 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || die "wave close-issue placeholder should exit 64, got $rc"
ok "wave close-issue is placeholder until Phase 1.6 (rc=64)"

# ---------------------------------------------------------------------------
# 6. dispatch with brief-file (no issue number) writes source-brief.md
# ---------------------------------------------------------------------------

brief="$TMP_ROOT/some-brief.md"
cat >"$brief" <<'EOF'
# Some brief
This is a non-issue-numbered brief used to dispatch a wave.
EOF
brief_dispatch="$("$AB" wave dispatch "$brief" --tracks main --main-agent ws-smoke 2>&1)"
brief_wave_id="$(printf '%s\n' "$brief_dispatch" | awk '/^wave dispatched: /{print $3}')"
[[ -n "$brief_wave_id" ]] || die "brief-file dispatch did not return wave id"
[[ -r "$BRIDGE_SHARED_DIR/waves/$brief_wave_id/source-brief.md" ]] \
  || die "brief-file dispatch did not copy source-brief.md"
ok "wave dispatch <brief-file> mirrors the brief into shared/waves/<id>/source-brief.md"

log "all Phase 1.1 acceptance checks passed"
