#!/usr/bin/env bash
# tests/codex-composer/smoke.sh
#
# Regression test for issue #331 Track B — codex composer state-machine
# hardening + type_and_submit fallback.
#
# The live failure mode (from the issue body):
#   1. daemon nudges a codex agent via paste-buffer + C-m
#   2. paste lands visually but the codex composer focus race restores
#      the dim placeholder ghost text on the composer line
#   3. C-m hits an empty input; submit is dropped silently
#   4. session_nudge_sent is logged as success even though the agent
#      never received the message
#
# This test exercises the pure-text helpers added in lib/bridge-tmux.sh:
#   - bridge_tmux_codex_post_paste_is_clean
#   - bridge_tmux_codex_submit_landed
# These are the predicates that gate the new fallback path. We do not
# spin up a real tmux session — the helpers operate on ANSI-preserving
# capture text and are testable in isolation.
#
# We also exercise bridge_tmux_paste_and_submit indirectly by stubbing
# tmux + the capture helpers, then asserting the stubbed
# bridge_tmux_type_and_submit fallback fires when the post-paste state
# is the dim placeholder, and does NOT fire when the post-paste state
# carries the real signature on the composer line followed by a
# Working banner.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log() { printf '[codex-composer] %s\n' "$*"; }
die() { printf '[codex-composer][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[codex-composer][skip] %s\n' "$*"; exit 0; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required (have ${BASH_VERSION})"
fi

TMP_ROOT="$(mktemp -d -t codex-composer-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

# ---------------------------------------------------------------------------
# Source bridge-tmux.sh in isolation. We stub the few external
# dependencies the helpers reach for (bridge_warn, bridge_audit_log,
# bridge_nonce, bridge_with_timeout) so the file sources cleanly without
# pulling the rest of bridge-lib.sh.
# ---------------------------------------------------------------------------

bridge_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
# shellcheck disable=SC2329  # shadowed below for case-by-case capture
bridge_audit_log() { :; }
bridge_nonce() { printf '%s' "$RANDOM"; }
bridge_with_timeout() { shift 2; "$@"; }
# These globals are referenced by some helpers but not by the code paths
# we exercise here — define defensively so `set -u` in callers stays
# happy if behavior shifts.
BRIDGE_TMUX_PROMPT_WAIT_SECONDS="${BRIDGE_TMUX_PROMPT_WAIT_SECONDS:-15}"

# shellcheck disable=SC1090
source "$REPO_ROOT/lib/bridge-tmux.sh"

# ---------------------------------------------------------------------------
# Step 1 — bridge_tmux_codex_post_paste_is_clean
#
# Real-paste capture: the last `›` line carries the [Agent Bridge] header
# without dim attribute. Helper must return 0.
# ---------------------------------------------------------------------------

ESC=$'\x1b'

log "step 1 — clean paste with signature on composer line is accepted"
SIGNATURE="[Agent Bridge] task #1533"
CLEAN_CAPTURE=$(cat <<CAP
some scrollback line
${ESC}[1mwarm pane content${ESC}[0m
> typed something earlier
› ${SIGNATURE} please claim and respond
  gpt-5.5 xhigh · ~/Projects/cosmax-crm-cli
CAP
)
if ! bridge_tmux_codex_post_paste_is_clean "$CLEAN_CAPTURE" "$SIGNATURE"; then
  die "expected clean post-paste to be accepted (signature on composer line, no dim)"
fi

log "step 1 — placeholder-restored capture (dim last \`›\` line) is rejected"
PLACEHOLDER_CAPTURE=$(cat <<CAP
${SIGNATURE} body line one
${SIGNATURE} body line two
some other scrollback
${ESC}[2m› Find and fix a bug in @filename${ESC}[0m
  gpt-5.5 xhigh · ~/Projects/cosmax-crm-cli
CAP
)
if bridge_tmux_codex_post_paste_is_clean "$PLACEHOLDER_CAPTURE" "$SIGNATURE"; then
  die "expected placeholder-restored capture to be rejected (last \`›\` line is dim)"
fi

log "step 1 — empty capture is rejected"
if bridge_tmux_codex_post_paste_is_clean "" "$SIGNATURE"; then
  die "expected empty capture to be rejected"
fi

log "step 1 — capture with no \`›\` line is rejected"
NO_PROMPT_CAPTURE=$(cat <<CAP
just some output
no codex composer here
CAP
)
if bridge_tmux_codex_post_paste_is_clean "$NO_PROMPT_CAPTURE" "$SIGNATURE"; then
  die "expected capture without \`›\` line to be rejected"
fi

log "step 1 — capture where last \`›\` line lacks signature is rejected"
WRONG_SIGNATURE_CAPTURE=$(cat <<CAP
› unrelated content
› still unrelated content
CAP
)
if bridge_tmux_codex_post_paste_is_clean "$WRONG_SIGNATURE_CAPTURE" "$SIGNATURE"; then
  die "expected capture without signature on last \`›\` line to be rejected"
fi

# ---------------------------------------------------------------------------
# Step 2 — bridge_tmux_codex_submit_landed
#
# Real submit lands when:
#   (a) Working banner visible
#   (b) signature no longer on composer line BUT only via the Working banner
#
# Real submit lost when:
#   - signature still on composer line (input never cleared)
#   - composer back to placeholder/empty AND no Working banner
# ---------------------------------------------------------------------------

log "step 2 — Working banner present → submit landed"
WORKING_CAPTURE=$(cat <<CAP
• Working (3s • esc to interrupt)
${ESC}[2m› Find and fix a bug in @filename${ESC}[0m
  gpt-5.5 xhigh · ~/Projects/cosmax-crm-cli
CAP
)
if ! bridge_tmux_codex_submit_landed "$WORKING_CAPTURE" "$SIGNATURE"; then
  die "expected submit-landed when 'Working' banner is visible"
fi

log "step 2 — esc-to-interrupt only → submit landed"
ESC_BANNER_CAPTURE=$(cat <<CAP
some thinking output
press esc to interrupt the task
› ready
CAP
)
if ! bridge_tmux_codex_submit_landed "$ESC_BANNER_CAPTURE" "$SIGNATURE"; then
  die "expected submit-landed when 'esc to interrupt' is visible"
fi

log "step 2 — signature still on composer line → submit lost"
STUCK_CAPTURE=$(cat <<CAP
› ${SIGNATURE} please claim and respond
  gpt-5.5 xhigh · ~/Projects/cosmax-crm-cli
CAP
)
if bridge_tmux_codex_submit_landed "$STUCK_CAPTURE" "$SIGNATURE"; then
  die "expected submit-lost when signature is still on the composer line"
fi

log "step 2 — placeholder restored without Working banner → submit lost (#331)"
LOST_SUBMIT_CAPTURE=$(cat <<CAP
some scrollback above
${ESC}[2m› Find and fix a bug in @filename${ESC}[0m
  gpt-5.5 xhigh · ~/Projects/cosmax-crm-cli
CAP
)
if bridge_tmux_codex_submit_landed "$LOST_SUBMIT_CAPTURE" "$SIGNATURE"; then
  die "expected submit-lost when placeholder restored without Working banner (#331 root cause)"
fi

log "step 2 — empty capture → submit lost"
if bridge_tmux_codex_submit_landed "" "$SIGNATURE"; then
  die "expected submit-lost on empty capture"
fi

# ---------------------------------------------------------------------------
# Step 3 — bridge_tmux_paste_and_submit fallback path integration
#
# Stub tmux, capture helpers, and bridge_tmux_type_and_submit. Drive
# paste_and_submit twice:
#
#   case A: post-paste capture is the dim placeholder restoration (#331).
#           The helper must call bridge_tmux_type_and_submit AND emit the
#           tmux_codex_composer_placeholder_restored audit signal.
#
#   case B: post-paste capture has the signature on the live composer
#           line, AND the post-submit capture has a Working banner.
#           The helper must NOT call bridge_tmux_type_and_submit.
# ---------------------------------------------------------------------------


# Test harness state. The capture stubs are called from inside `$(...)`
# command substitutions in bridge_tmux_paste_and_submit, which means any
# variable increments happen in a subshell and do not propagate back to
# the parent. We use a file-backed scratch dir to script the response
# sequence so each invocation reads the next entry deterministically.
case_label=""
SCRATCH_DIR="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH_DIR"
fallback_called=0
audit_records=()

# Helper: write each scripted capture to plain-NN/ansi-NN files. The
# stubs read the file matching their current index and bump a counter
# file using a flock-free renames-only protocol that also survives
# subshell calls.
bridge_capture_recent() {
  local kind="plain"
  local idx_file="$SCRATCH_DIR/${kind}.idx"
  local idx
  idx="$(cat "$idx_file" 2>/dev/null || echo 0)"
  local entry_file="$SCRATCH_DIR/${kind}-${idx}"
  printf '%d' "$((idx + 1))" >"$idx_file"
  if [[ -f "$entry_file" ]]; then
    cat "$entry_file"
  fi
}

bridge_capture_recent_ansi() {
  local kind="ansi"
  local idx_file="$SCRATCH_DIR/${kind}.idx"
  local idx
  idx="$(cat "$idx_file" 2>/dev/null || echo 0)"
  local entry_file="$SCRATCH_DIR/${kind}-${idx}"
  printf '%d' "$((idx + 1))" >"$idx_file"
  if [[ -f "$entry_file" ]]; then
    cat "$entry_file"
  fi
}

scripted_capture() {
  # scripted_capture <kind> <idx> <text>
  printf '%s' "$3" >"$SCRATCH_DIR/${1}-${2}"
}

# Stub tmux invocations entirely — the helper only uses set-buffer,
# paste-buffer, delete-buffer, send-keys (via wrapper) for codex.
tmux() { :; }

# Stub the per-key fallback so we can detect when paste_and_submit chose
# to escalate. type_and_submit also runs sleep + tmux stuff, but those
# are no-ops in this stubbed env.
bridge_tmux_type_and_submit() {
  fallback_called=1
}

# Capture audit signals so we can assert which branch fired.
# Signature: bridge_audit_log <component> <action> <agent> [--detail k=v ...]
bridge_audit_log() {
  audit_records+=("$2")
}

# Stubs for things paste_and_submit calls but which are fine as no-ops
# here.
bridge_tmux_send_keys_with_timeout() { :; }
bridge_tmux_session_has_pending_input() { return 1; }

# Helper to reset state between cases.
reset_case() {
  case_label="$1"
  rm -f "$SCRATCH_DIR"/plain-* "$SCRATCH_DIR"/ansi-* \
        "$SCRATCH_DIR/plain.idx" "$SCRATCH_DIR/ansi.idx" 2>/dev/null
  fallback_called=0
  audit_records=()
}

# ----- Case A: placeholder restored after paste -----
log "step 3 — case A: placeholder restored after paste triggers fallback"
reset_case A
case_a_text="[Agent Bridge] task #1533 please claim"
case_a_sig="$(bridge_tmux_paste_signature "$case_a_text")"
# bridge_tmux_paste_and_submit calls bridge_capture_recent twice:
#   plain[0] = pre_capture (before paste)
#   plain[1] = post_capture after first paste-buffer -p
# Then bridge_capture_recent_ansi once for pre_submit_ansi.
#
# We need plain post-capture to satisfy paste_landed (signature appears
# more often than in pre), then the ANSI capture must fail
# codex_post_paste_is_clean (last `›` line is the dim placeholder).
scripted_capture plain 0 "some scrollback
> typed text earlier
› idle"
scripted_capture plain 1 "some scrollback
> typed text earlier
› idle
${case_a_sig} body landed in scrollback
› ${case_a_sig} body line"
scripted_capture ansi 0 "some scrollback
${case_a_sig} body landed in scrollback
${ESC}[2m› Find and fix a bug in @filename${ESC}[0m
  gpt-5.5 xhigh"

bridge_tmux_paste_and_submit "fake-session" "$case_a_text" "codex" || true

[[ "$fallback_called" == "1" ]] \
  || die "case A: expected type_and_submit fallback when placeholder restored"
matched_audit=0
for action in "${audit_records[@]}"; do
  if [[ "$action" == "tmux_codex_composer_placeholder_restored" ]]; then
    matched_audit=1
    break
  fi
done
[[ "$matched_audit" == "1" ]] \
  || die "case A: expected tmux_codex_composer_placeholder_restored audit signal; got: ${audit_records[*]:-<none>}"

# ----- Case B: paste landed cleanly + Working banner -> no fallback -----
log "step 3 — case B: clean paste + Working banner does NOT trigger fallback"
reset_case B
case_b_text="[Agent Bridge] task #1533 please claim"
case_b_sig="$(bridge_tmux_paste_signature "$case_b_text")"
[[ -n "$case_b_sig" ]] || die "case B: paste_signature should be non-empty"

scripted_capture plain 0 "some scrollback
> typed text earlier
› idle"
scripted_capture plain 1 "some scrollback
> typed text earlier
› idle
[Agent Bridge] task #1533 please claim and respond
› ${case_b_sig} body"
# pre-submit ANSI: clean composer line carrying signature, no dim escape
scripted_capture ansi 0 "some scrollback
[Agent Bridge] task #1533 please claim and respond
› ${case_b_sig} body line
  gpt-5.5 xhigh"
# post-submit ANSI: Working banner present
scripted_capture ansi 1 "• Working (2s • esc to interrupt)
${ESC}[2m› Find and fix a bug in @filename${ESC}[0m
  gpt-5.5 xhigh"

bridge_tmux_paste_and_submit "fake-session" "$case_b_text" "codex" || true

[[ "$fallback_called" == "0" ]] \
  || die "case B: type_and_submit must NOT fire when paste landed cleanly and Working banner is visible"
for action in "${audit_records[@]}"; do
  if [[ "$action" == "tmux_codex_composer_placeholder_restored" \
      || "$action" == "tmux_codex_submit_lost" \
      || "$action" == "tmux_paste_landing_failed" ]]; then
    die "case B: unexpected audit action fired: $action"
  fi
done

# ----- Case C: clean paste, but submit lost (no Working, signature gone) -----
log "step 3 — case C: clean paste then submit lost triggers fallback"
reset_case C
case_c_text="[Agent Bridge] task #1601 please claim"
case_c_sig="$(bridge_tmux_paste_signature "$case_c_text")"

scripted_capture plain 0 "some scrollback
> typed text earlier
› idle"
scripted_capture plain 1 "some scrollback
> typed text earlier
› idle
[Agent Bridge] task #1601 please claim and respond
› ${case_c_sig} body"
# pre-submit ANSI: clean composer line, no dim
scripted_capture ansi 0 "some scrollback
[Agent Bridge] task #1601 please claim and respond
› ${case_c_sig} body line
  gpt-5.5 xhigh"
# post-submit ANSI: placeholder restored, no Working banner — the #331
# lost-submit signature.
scripted_capture ansi 1 "some scrollback
${ESC}[2m› Find and fix a bug in @filename${ESC}[0m
  gpt-5.5 xhigh"

bridge_tmux_paste_and_submit "fake-session" "$case_c_text" "codex" || true

[[ "$fallback_called" == "1" ]] \
  || die "case C: expected type_and_submit fallback when submit was lost (placeholder + no Working)"
matched_audit=0
for action in "${audit_records[@]}"; do
  if [[ "$action" == "tmux_codex_submit_lost" ]]; then
    matched_audit=1
    break
  fi
done
[[ "$matched_audit" == "1" ]] \
  || die "case C: expected tmux_codex_submit_lost audit signal; got: ${audit_records[*]:-<none>}"

log "all steps passed"
