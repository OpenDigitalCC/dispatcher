#!/bin/bash
# 03-partial-failure.sh
#
# Tests behaviour when one or more hosts in a multi-host run are unreachable.
# Confirms:
#   - reachable hosts return results even when others fail
#   - ctrl-exec exit code is non-zero if any host failed
#   - failure reason is reported per-host, not swallowed
#   - timeout is bounded (test will fail if ctrl-exec hangs)
#
# Uses a DNS-invalid hostname to simulate an unreachable host without
# needing to take a real agent offline.
#
# Requires: 1 reachable agent minimum. Multi-host tests require 2.

set -uo pipefail
source "${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib.sh"

require_agents 1

FAKE_HOST="no-such-host-xyz.invalid"
TIMEOUT_LIMIT=30   # seconds - ctrl-exec should not hang longer than this

# ============================================================
assert_agents_reachable
describe "Single unreachable host"
# ============================================================

START=$(date +%s)
run_dispatcher run "$FAKE_HOST" env-dump
ELAPSED=$(elapsed_seconds "$START")

assert_exit 1 "$RC" "ctrl-exec exits non-zero for unreachable host"

if [ -n "$OUT$ERR" ]; then
    pass "some output produced (not silent failure)"
else
    fail "some output produced" "both stdout and stderr were empty"
fi

if [ "$ELAPSED" -le "$TIMEOUT_LIMIT" ]; then
    pass "completed within ${TIMEOUT_LIMIT}s (took ${ELAPSED}s)"
else
    fail "completed within ${TIMEOUT_LIMIT}s" "took ${ELAPSED}s - ctrl-exec may be hanging"
fi

# ============================================================
assert_agents_reachable
describe "Unreachable host mixed with reachable host - results"
# ============================================================

START=$(date +%s)
run_dispatcher run "$FAKE_HOST" "$AGENT1" env-dump
ELAPSED=$(elapsed_seconds "$START")

assert_exit 1 "$RC" "ctrl-exec exits non-zero (mixed success/fail)"
assert_contains "$OUT$ERR" "$AGENT1" "reachable host appears in output"

if [ "$ELAPSED" -le "$TIMEOUT_LIMIT" ]; then
    pass "completed within ${TIMEOUT_LIMIT}s (took ${ELAPSED}s)"
else
    fail "completed within ${TIMEOUT_LIMIT}s" "took ${ELAPSED}s"
fi

# ============================================================
assert_agents_reachable
describe "Unreachable host mixed with reachable host - JSON"
# ============================================================

run_dispatcher run "$FAKE_HOST" "$AGENT1" env-dump --json

assert_exit 1 "$RC" "ctrl-exec exits non-zero"
assert_json_valid "$OUT" "output is valid JSON"

if echo "$OUT" | grep -qF "$AGENT1"; then
    pass "reachable host present in JSON results"
else
    fail "reachable host present in JSON results" "output: $OUT"
fi

if echo "$OUT" | grep -qF "$FAKE_HOST"; then
    pass "unreachable host present in JSON results"
else
    fail "unreachable host present in JSON results" \
        "unreachable host may have been silently dropped: $OUT"
fi

# ============================================================
assert_agents_reachable
describe "Unreachable host does not suppress reachable host stdout"
# ============================================================

run_dispatcher run "$FAKE_HOST" "$AGENT1" env-dump

assert_contains "$OUT$ERR" "PATH=" "env-dump output from reachable host visible"

# ============================================================
assert_agents_reachable
describe "One host returns non-zero exit code"
# ============================================================

run_dispatcher run "$AGENT1" exit-code -- 42

assert_exit 1 "$RC" "ctrl-exec exits non-zero when script returns non-zero"
assert_contains "$OUT$ERR" "42" "exit code 42 visible in output"

# ============================================================
if [ "${#AGENTS[@]}" -ge 2 ]; then
    assert_agents_reachable
    describe "Two reachable agents - both succeed, exit 0"
    # ============================================================

    run_dispatcher run "$AGENT1" "$AGENT2" env-dump

    assert_exit 0 "$RC" "exit 0 when all hosts succeed"
    assert_contains "$OUT" "$AGENT1" "first agent result present"
    assert_contains "$OUT" "$AGENT2" "second agent result present"

    # ============================================================
    assert_agents_reachable
    describe "Non-zero exit on one host does not hide the other host's output"
    # ============================================================

    run_dispatcher run "$AGENT1" "$AGENT2" exit-code -- 1

    assert_exit 1 "$RC" "ctrl-exec exits non-zero"
    assert_contains "$OUT$ERR" "$AGENT1" "first agent appears in output"
    assert_contains "$OUT$ERR" "$AGENT2" "second agent appears in output"
else
    skip "Two-agent tests" "only 1 agent reachable"
fi

summary
