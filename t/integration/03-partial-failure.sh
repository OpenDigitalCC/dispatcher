#!/bin/bash
# 03-partial-failure.sh
#
# Tests behaviour when one or more hosts in a multi-host run are unreachable.
# Confirms:
#   - reachable hosts return results even when others fail
#   - dispatcher exit code is non-zero if any host failed
#   - failure reason is reported per-host, not swallowed
#   - timeout is bounded (test will fail if dispatcher hangs)
#
# Prerequisites:
#   - Both agents running at test start
#   - You can reach both agents via the dispatcher
#   - env-dump script installed on both agents
#
# NOTE: This test uses a fake hostname to simulate an unreachable host.
# It does NOT require taking a real agent offline.

set -uo pipefail
source "$(dirname "$0")/lib.sh"

FAKE_HOST="no-such-host-xyz.invalid"
TIMEOUT_LIMIT=30   # seconds - dispatcher should not hang longer than this

# ============================================================
describe "Single unreachable host"
# ============================================================

START=$(date +%s)
run_dispatcher run "$FAKE_HOST" env-dump
ELAPSED=$(elapsed_seconds "$START")

assert_exit 1 "$RC" "dispatcher exits non-zero for unreachable host"

# Should report some kind of connection error, not just silence
if [ -n "$OUT$ERR" ]; then
    pass "some output produced (not silent failure)"
else
    fail "some output produced" "both stdout and stderr were empty"
fi

if [ "$ELAPSED" -le "$TIMEOUT_LIMIT" ]; then
    pass "completed within ${TIMEOUT_LIMIT}s (took ${ELAPSED}s)"
else
    fail "completed within ${TIMEOUT_LIMIT}s" "took ${ELAPSED}s - dispatcher may be hanging"
fi

# ============================================================
describe "Unreachable host mixed with reachable host - results"
# ============================================================

START=$(date +%s)
run_dispatcher run "$FAKE_HOST" "$AGENT_DEBIAN" env-dump
ELAPSED=$(elapsed_seconds "$START")

assert_exit 1 "$RC" "dispatcher exits non-zero (mixed success/fail)"

# The Debian agent result should appear despite the fake host failing
assert_contains "$OUT$ERR" "$AGENT_DEBIAN" "reachable host appears in output"

if [ "$ELAPSED" -le "$TIMEOUT_LIMIT" ]; then
    pass "completed within ${TIMEOUT_LIMIT}s (took ${ELAPSED}s)"
else
    fail "completed within ${TIMEOUT_LIMIT}s" "took ${ELAPSED}s"
fi

# ============================================================
describe "Unreachable host mixed with reachable host - JSON"
# ============================================================

run_dispatcher run "$FAKE_HOST" "$AGENT_DEBIAN" env-dump --json

assert_exit 1 "$RC" "dispatcher exits non-zero"
assert_json_valid "$OUT" "output is valid JSON"

# Both hosts should appear as entries in results
if echo "$OUT" | grep -qF "$AGENT_DEBIAN"; then
    pass "reachable host present in JSON results"
else
    fail "reachable host present in JSON results" "output: $OUT"
fi

if echo "$OUT" | grep -qF "$FAKE_HOST"; then
    pass "unreachable host present in JSON results"
else
    fail "unreachable host present in JSON results" \
        "unreachable host may have been silently dropped from output: $OUT"
fi

# ============================================================
describe "Unreachable host does not suppress reachable host's stdout"
# ============================================================

# Run env-dump on both - the Debian agent should return real env output
run_dispatcher run "$FAKE_HOST" "$AGENT_DEBIAN" env-dump

# env-dump outputs KEY=VALUE lines - PATH should always appear
assert_contains "$OUT$ERR" "PATH=" "env-dump output from reachable host visible"

# ============================================================
describe "Two reachable hosts - both succeed, exit 0"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" "$AGENT_OPENWRT" env-dump

assert_exit 0 "$RC" "exit 0 when all hosts succeed"
assert_contains "$OUT" "$AGENT_DEBIAN"  "Debian result present"
assert_contains "$OUT" "$AGENT_OPENWRT" "OpenWrt result present"

# ============================================================
describe "One host returns non-zero exit code"
# ============================================================

# exit-code script exits with the code passed as argument
run_dispatcher run "$AGENT_DEBIAN" exit-code -- 42

assert_exit 1 "$RC" "dispatcher exits non-zero when script returns non-zero"
assert_contains "$OUT$ERR" "42" "exit code 42 visible in output"

# ============================================================
describe "Non-zero exit on one host does not hide the other host's output"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" "$AGENT_OPENWRT" exit-code -- 1

assert_exit 1 "$RC" "dispatcher exits non-zero"
# Both hosts should appear in output even though both failed
assert_contains "$OUT$ERR" "$AGENT_DEBIAN"  "Debian appears in output"
assert_contains "$OUT$ERR" "$AGENT_OPENWRT" "OpenWrt appears in output"

summary
