#!/bin/bash
# 06-auth-context.sh
#
# Confirms username and token are forwarded end-to-end:
# dispatcher CLI -> agent -> script stdin context.
#
# Also tests the $USER default behaviour and DISPATCHER_TOKEN env var.
#
# Prerequisites: context-dump and dispatcher-demonstrator on both agents.

set -uo pipefail
source "$(dirname "$0")/lib.sh"

# ============================================================
describe "username forwarded via --username"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" context-dump --username alice

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "alice" "username 'alice' appears in context"
assert_contains "$OUT" '"username"' "username key present"

# ============================================================
describe "token forwarded via --token"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" context-dump --token mytoken-123

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "mytoken-123" "token appears in context"
assert_contains "$OUT" '"token"' "token key present"

# ============================================================
describe "username and token forwarded together"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" context-dump \
    --username alice --token mytoken-123

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "alice"       "username present"
assert_contains "$OUT" "mytoken-123" "token present"

# ============================================================
describe "username defaults to \$USER when not specified"
# ============================================================

EXPECTED_USER=$(id -un)
run_dispatcher run "$AGENT_DEBIAN" context-dump

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "$EXPECTED_USER" "\$USER ($EXPECTED_USER) appears in context"

# ============================================================
describe "token from DISPATCHER_TOKEN environment variable"
# ============================================================

DISPATCHER_TOKEN="env-token-456" run_dispatcher run "$AGENT_DEBIAN" context-dump

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "env-token-456" "env var token appears in context"

# ============================================================
describe "--token overrides DISPATCHER_TOKEN"
# ============================================================

OUT_OVERRIDE=""
OUT_OVERRIDE=$(DISPATCHER_TOKEN="env-token" sudo "$DISPATCHER" run \
    "$AGENT_DEBIAN" context-dump --token cli-token 2>/dev/null)
RC_OVERRIDE=$?

assert_exit 0 "$RC_OVERRIDE" "clean exit"
assert_contains "$OUT_OVERRIDE" "cli-token" "CLI token takes precedence"
assert_not_contains "$OUT_OVERRIDE" "env-token" "env token not used when CLI token given"

# ============================================================
describe "reqid is present and unique across two runs"
# ============================================================

OUT1=$(sudo "$DISPATCHER" run "$AGENT_DEBIAN" context-dump 2>/dev/null)
OUT2=$(sudo "$DISPATCHER" run "$AGENT_DEBIAN" context-dump 2>/dev/null)

REQID1=$(echo "$OUT1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reqid',''))" 2>/dev/null)
REQID2=$(echo "$OUT2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reqid',''))" 2>/dev/null)

if [ -n "$REQID1" ]; then
    pass "reqid present in first run: $REQID1"
else
    fail "reqid present in first run" "got empty"
fi

if [ -n "$REQID2" ]; then
    pass "reqid present in second run: $REQID2"
else
    fail "reqid present in second run" "got empty"
fi

if [ "$REQID1" != "$REQID2" ]; then
    pass "reqids are distinct between runs"
else
    fail "reqids are distinct between runs" "both were: $REQID1"
fi

# ============================================================
describe "context via log-fields (demonstrator) - syslog verification"
# ============================================================
# This requires checking agent syslog after the run.
# We run first, then check - requires SSH access to agent or remote syslog.

run_dispatcher run "$AGENT_DEBIAN" dispatcher-demonstrator \
    -- log-fields --username testop --token verify-token

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "testop"        "username echoed in log-fields output"
assert_contains "$OUT" "verify-token"  "token echoed in log-fields output"
assert_contains "$OUT" "reqid="        "reqid appears in log-fields output"
assert_contains "$OUT" "user="         "user label in log-fields output"

printf '\n'
printf '  NOTE: Verify syslog on %s with:\n' "$AGENT_DEBIAN"
printf '        journalctl -t dispatcher-demo | tail -5\n'
printf '        Expect: reqid=... user=testop script=dispatcher-demonstrator\n'

summary
