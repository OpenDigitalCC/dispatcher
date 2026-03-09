#!/bin/bash
# 07-concurrency-lock.sh
#
# Tests the flock-based concurrency control that prevents the same script
# running twice simultaneously on the same host.
#
# Confirms:
#   - A second dispatch of the same script to the same host is rejected
#     immediately while the first is still running
#   - The error message is clear and the exit code is non-zero
#   - The first run completes successfully and is unaffected
#   - Concurrent dispatch to DIFFERENT hosts is not blocked
#   - After the first run completes, the same script can be run again
#
# Requires: 1 reachable agent minimum.
# Scripts needed: lock-test (sleeps for a configurable duration).

set -uo pipefail
source "${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib.sh"

require_agents 1

LOCK_HOLD=10   # seconds lock-test holds the lock

# ============================================================
assert_agents_reachable
describe "Lock: concurrent dispatch to same host is rejected"
# ============================================================

# Start a long-running script in the background
sudo "$DISPATCHER" run "$AGENT1" lock-test -- "$LOCK_HOLD" \
    > /tmp/_lock_first_out 2>&1 &
FIRST_PID=$!

# Give it a moment to acquire the lock
sleep 2

# Attempt a second dispatch of the same script to the same host
run_dispatcher run "$AGENT1" lock-test -- "$LOCK_HOLD"

assert_exit 1 "$RC" "second dispatch exits non-zero"

# The error should mention locking, not a connection or script error
if echo "$OUT$ERR" | grep -qiE "lock|already.running|conflict"; then
    pass "error message mentions lock/conflict"
else
    fail "error message mentions lock/conflict" \
        "got: $(echo "$OUT$ERR" | head -3)"
fi

# The second attempt should have returned quickly, not waited the full hold time
# We check by seeing if the first job is still running
if kill -0 "$FIRST_PID" 2>/dev/null; then
    pass "first run still in progress (lock held correctly)"
else
    fail "first run still in progress" \
        "first job finished before second was rejected - lock may not have fired"
fi

# Wait for first run to complete and check it succeeded
wait "$FIRST_PID"
FIRST_RC=$?
FIRST_OUT=$(cat /tmp/_lock_first_out)

assert_exit 0 "$FIRST_RC" "first run completes successfully"
assert_contains "$FIRST_OUT" "lock-test done" "first run output intact"

# ============================================================
assert_agents_reachable
describe "Lock: JSON output on lock rejection"
# ============================================================

sudo "$DISPATCHER" run "$AGENT1" lock-test -- "$LOCK_HOLD" \
    > /tmp/_lock_first_out 2>&1 &
FIRST_PID=$!
sleep 2

run_dispatcher run "$AGENT1" lock-test --json

assert_exit 1 "$RC" "exits non-zero"
assert_json_valid "$OUT" "lock rejection produces valid JSON"

if echo "$OUT" | grep -qiE '"error"'; then
    pass "JSON contains error field"
else
    fail "JSON contains error field" "output: $OUT"
fi

wait "$FIRST_PID" || true

# ============================================================
assert_agents_reachable
describe "Lock: same script on different hosts not blocked"
# ============================================================
# Lock is per host:script pair. Two different hosts should run concurrently.

if [ "${#AGENTS[@]}" -ge 2 ]; then
    START=$(date +%s)
    run_dispatcher run "$AGENT1" "$AGENT2" lock-test -- 5
    ELAPSED=$(elapsed_seconds "$START")

    assert_exit 0 "$RC" "both hosts succeed"
    assert_contains "$OUT" "$AGENT1" "agent 1 result present"
    assert_contains "$OUT" "$AGENT2" "agent 2 result present"

    # Both ran concurrently so elapsed should be ~5s not ~10s
    [ "$ELAPSED" -lt 9 ] \
        && pass "completed in ~5s confirming parallel execution (${ELAPSED}s)" \
        || fail "completed in ~5s confirming parallel execution" "took ${ELAPSED}s"
else
    skip "Cross-host lock test" "only 1 agent reachable"
fi

# ============================================================
assert_agents_reachable
describe "Lock: released after first run - second attempt succeeds"
# ============================================================

# Run once to completion
run_dispatcher run "$AGENT1" lock-test -- 2
assert_exit 0 "$RC" "first run succeeds"

# Run again immediately - lock should be released
run_dispatcher run "$AGENT1" lock-test -- 2
assert_exit 0 "$RC" "second run succeeds after lock released"
assert_contains "$OUT" "lock-test done" "second run output intact"

summary
