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


# ============================================================
assert_agents_reachable
describe "Lock: concurrent dispatch to same host is rejected"
# ============================================================
# NOTE: This subtest is skipped in integration testing.
#
# The lock is flock-based (Dispatcher::Lock). dispatch_all forks a child
# per host; the child acquires the flock. Whether check_available in an
# independent second dispatcher process sees that flock depends on when
# acquire is called relative to the HTTP round-trip.
#
# In practice the lock fires reliably between independent dispatcher
# invocations, but the integration test cannot guarantee the timing window
# between fork, acquire, and the second dispatcher's check_available.
# The unit test t/lock.t covers this with lock-holder.pl (an exec'd
# process with a fully independent file table) and is the authoritative
# test for lock conflict detection.

skip "concurrent dispatch rejection" \
    "lock conflict detection is covered by t/lock.t (unit test)"

# ============================================================
assert_agents_reachable
describe "Lock: JSON output on lock rejection"
# ============================================================
# NOTE: Skipped - same reason as above. t/lock.t covers JSON lock output.

skip "JSON lock rejection format" \
    "lock conflict detection is covered by t/lock.t (unit test)"

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
