#!/usr/bin/env bash
# bootstrap-cron-schedules smoke — regression guard for issue #320 Track C.
#
# What this asserts (against the bootstrap-memory-system.sh source):
#
#   1. The wiki-daily-ingest cron is registered at "0 6 * * *", not the
#      legacy "0 3 * * *" slot that raced with memory-daily-* on every
#      install (issue #320 root cause).
#
#   2. The per-agent memory-daily-* family is registered at "0 3 * * *".
#      This pins the producer-side schedule so future drift in either
#      half of the stagger pair is caught immediately.
#
#   3. No two cron specs share the same schedule.expr unless explicitly
#      enumerated in INTENTIONAL_COFIRE below. Future cron additions that
#      land on an existing slot will fail this test until the author
#      either picks a different slot or documents the co-fire as
#      intentional. The guard fires for the CRON_SPECS array
#      (admin-owned wiki-* family) and the per-agent memory-daily-*
#      schedule that step_memory_daily_cron_one hardcodes.
#
# This test parses the bootstrap script statically rather than running
# `bootstrap-memory-system.sh apply` against a mktemp BRIDGE_HOME — a
# real apply requires `agb cron create`, an agent roster, the librarian
# provisioner, and live `claude` CLI integration, none of which are
# reproducible in an isolated harness. Static parsing is sufficient for
# the regression contract because every cron schedule registered by the
# bootstrap is sourced from one of two literals in the script:
# CRON_SPECS (lines starting with `"<title>|<expr>|<tz>|<script>"` inside
# the array) and the `sched=` assignment in step_memory_daily_cron_one.
#
# The actual parser lives in parse_specs.py (sibling file). Inlining it
# as a heredoc trips a bash command-substitution quirk where unbalanced
# parens inside the heredoc body confuse the outer "$(...)" tokenizer
# even when the heredoc opener is quoted.
#
# Usage:   ./tests/bootstrap-cron-schedules/smoke.sh
# Exit 0 if every assertion PASSes; exit 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
BOOTSTRAP="$REPO_ROOT/bootstrap-memory-system.sh"
PARSER="$(dirname "${BASH_SOURCE[0]}")/parse_specs.py"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

# Schedules that are legitimately allowed to share a slot. Keep this list
# short and require a comment in the bootstrap source explaining the
# co-fire. The pair is encoded as "<title-a>=<expr>|<title-b>=<expr>"; an
# empty list means no co-fires are permitted.
INTENTIONAL_COFIRE=(
  # No intentional co-fires today. wiki-daily-ingest moved to 06:00 to
  # break the memory-daily-* race that motivated this test.
  ""
)

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$*"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '[smoke][fail] %s\n' "$*" >&2
}

if [[ ! -r "$BOOTSTRAP" ]]; then
  printf '[smoke][error] cannot find %s\n' "$BOOTSTRAP" >&2
  exit 1
fi

if [[ ! -r "$PARSER" ]]; then
  printf '[smoke][error] cannot find parser helper: %s\n' "$PARSER" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Run the parser. JSON shape:
#   {"specs": [{"title","expr","tz","script"}, ...],
#    "memory_daily_expr": "0 3 * * *"}
# or {"error": "..."} on failure.
# ---------------------------------------------------------------------------
SCHED_JSON="$("$PYTHON" "$PARSER" "$BOOTSTRAP" 2>&1)" || {
  fail "parser failed: $SCHED_JSON"
  printf '\n[smoke] %d pass / %d fail\n' "$PASS" "$FAIL"
  exit 1
}

if ! printf '%s' "$SCHED_JSON" | "$PYTHON" -c 'import json, sys; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
  fail "parser returned non-JSON: $SCHED_JSON"
  printf '\n[smoke] %d pass / %d fail\n' "$PASS" "$FAIL"
  exit 1
fi

PARSE_ERROR="$(printf '%s' "$SCHED_JSON" | "$PYTHON" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("error",""))')"
if [[ -n "$PARSE_ERROR" ]]; then
  fail "$PARSE_ERROR"
  printf '\n[smoke] %d pass / %d fail\n' "$PASS" "$FAIL"
  exit 1
fi

# ---------------------------------------------------------------------------
# Assertion 1 — wiki-daily-ingest is at 0 6 * * *.
# ---------------------------------------------------------------------------
WIKI_DAILY_EXPR="$(printf '%s' "$SCHED_JSON" | "$PYTHON" -c '
import json, sys
d = json.loads(sys.stdin.read())
for s in d["specs"]:
    if s["title"] == "wiki-daily-ingest":
        print(s["expr"]); break
')"

if [[ "$WIKI_DAILY_EXPR" == "0 6 * * *" ]]; then
  pass "wiki-daily-ingest schedule = '0 6 * * *' (post-#320 stagger)"
else
  fail "wiki-daily-ingest schedule expected '0 6 * * *', got '$WIKI_DAILY_EXPR' — issue #320 regression"
fi

# ---------------------------------------------------------------------------
# Assertion 2 — memory-daily-* family is at 0 3 * * *.
# ---------------------------------------------------------------------------
MEM_DAILY_EXPR="$(printf '%s' "$SCHED_JSON" | "$PYTHON" -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d.get("memory_daily_expr") or "")
')"

if [[ "$MEM_DAILY_EXPR" == "0 3 * * *" ]]; then
  pass "memory-daily-* schedule = '0 3 * * *' (producer side of the #320 stagger pair)"
else
  fail "memory-daily-* schedule expected '0 3 * * *', got '$MEM_DAILY_EXPR' — producer side moved without updating this test"
fi

# ---------------------------------------------------------------------------
# Assertion 3 — no two distinct cron specs share the same expr unless on
# the intentional co-fire allowlist.
# ---------------------------------------------------------------------------
COFIRE_BLOB="$(printf '%s\n' "${INTENTIONAL_COFIRE[@]:-}")"
DUPES="$(printf '%s' "$SCHED_JSON" | MEM_DAILY_EXPR="$MEM_DAILY_EXPR" COFIRE="$COFIRE_BLOB" "$PYTHON" -c '
import json, os, sys
d = json.loads(sys.stdin.read())
buckets = {}
for s in d["specs"]:
    buckets.setdefault(s["expr"], []).append(s["title"])

mem_expr = os.environ.get("MEM_DAILY_EXPR", "").strip()
if mem_expr:
    buckets.setdefault(mem_expr, []).append("memory-daily-<agent>")

# Build the allowlist as a set of frozenset({title,title}) pairs.
allowed = set()
for line in (os.environ.get("COFIRE") or "").splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    pair = line.split("|")
    titles = []
    for p in pair:
        p = p.strip()
        if "=" not in p:
            continue
        t, _ = p.split("=", 1)
        titles.append(t.strip())
    if len(titles) == 2:
        allowed.add(frozenset(titles))

dupes = []
for expr, titles in buckets.items():
    uniq = sorted(set(titles))
    if len(uniq) <= 1:
        continue
    bucket_ok = True
    for i in range(len(uniq)):
        for j in range(i + 1, len(uniq)):
            if frozenset({uniq[i], uniq[j]}) not in allowed:
                bucket_ok = False
                break
        if not bucket_ok:
            break
    if not bucket_ok:
        dupes.append(f"{expr}: {uniq}")

for d_ in dupes:
    print(d_)
')"

if [[ -z "$DUPES" ]]; then
  pass "no two cron specs share a schedule.expr (issue #320 same-slot regression guard)"
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    fail "schedule.expr collision — $line"
  done <<<"$DUPES"
fi

printf '\n[smoke] %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
