#!/bin/bash
# 06-auth-context.sh
#
# Confirms username and token are forwarded end-to-end:
# ctrl-exec CLI -> agent -> script stdin context.
#
# Also tests the $USER default behaviour and ENVEXEC_TOKEN env var.
#
# Requires: 1 reachable agent minimum.
# Scripts needed: context-dump, ctrl-exec-demonstrator.

set -uo pipefail
source "${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib.sh"

require_agents 1

# ============================================================
assert_agents_reachable
describe "username forwarded via --username"
# ============================================================

run_dispatcher run "$AGENT1" context-dump --username alice

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "alice"        "username 'alice' appears in context"
assert_contains "$OUT" '"username"'   "username key present"

# ============================================================
assert_agents_reachable
describe "token forwarded via --token"
# ============================================================

run_dispatcher run "$AGENT1" context-dump --token mytoken-123

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "mytoken-123" "token appears in context"
assert_contains "$OUT" '"token"'     "token key present"

# ============================================================
assert_agents_reachable
describe "username and token forwarded together"
# ============================================================

run_dispatcher run "$AGENT1" context-dump \
    --username alice --token mytoken-123

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "alice"       "username present"
assert_contains "$OUT" "mytoken-123" "token present"

# ============================================================
assert_agents_reachable
describe "username defaults to \$USER when not specified"
# ============================================================

EXPECTED_USER=$(id -un)
run_dispatcher run "$AGENT1" context-dump

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "$EXPECTED_USER" "\$USER ($EXPECTED_USER) appears in context"

# ============================================================
assert_agents_reachable
describe "token from ENVEXEC_TOKEN environment variable"
# ============================================================

ENVEXEC_TOKEN="env-token-456" run_dispatcher run "$AGENT1" context-dump

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "env-token-456" "env var token appears in context"

# ============================================================
assert_agents_reachable
describe "--token overrides ENVEXEC_TOKEN"
# ============================================================

OUT_OVERRIDE=$(sudo env ENVEXEC_TOKEN="env-token" "$DISPATCHER" run \
    "$AGENT1" context-dump --token cli-token 2>/dev/null)
RC_OVERRIDE=$?

assert_exit 0 "$RC_OVERRIDE" "clean exit"
assert_contains "$OUT_OVERRIDE" "cli-token"  "CLI token takes precedence"
assert_not_contains "$OUT_OVERRIDE" "env-token" "env token not used when CLI token given"

# ============================================================
assert_agents_reachable
describe "reqid is present and unique across two runs"
# ============================================================

OUT1=$(sudo "$DISPATCHER" run "$AGENT1" context-dump 2>/dev/null)
OUT2=$(sudo "$DISPATCHER" run "$AGENT1" context-dump 2>/dev/null)

# context-dump outputs the raw JSON context after the ctrl-exec header line.
# Extract the JSON portion only (the line starting with '{').
REQID1=$(echo "$OUT1" | grep '^{' | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('reqid',''))" 2>/dev/null)
REQID2=$(echo "$OUT2" | grep '^{' | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('reqid',''))" 2>/dev/null)

[ -n "$REQID1" ] && pass "reqid present in first run: $REQID1" \
                 || fail "reqid present in first run" "got empty"

[ -n "$REQID2" ] && pass "reqid present in second run: $REQID2" \
                 || fail "reqid present in second run" "got empty"

[ "$REQID1" != "$REQID2" ] && pass "reqids are distinct between runs" \
                             || fail "reqids are distinct between runs" "both were: $REQID1"

# ============================================================
assert_agents_reachable
describe "context via log-fields (demonstrator) - syslog verification"
# ============================================================

run_dispatcher run "$AGENT1" ctrl-exec-demonstrator \
    -- log-fields --username testop --token verify-token

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "testop"       "username echoed in log-fields output"
assert_contains "$OUT" "verify-token" "token echoed in log-fields output"
# log-fields echoes to stdout in "  reqid:    <value>" format
assert_contains "$OUT" "reqid:"       "reqid appears in log-fields output"
assert_contains "$OUT" "user:"        "user label in log-fields output"

printf '\n'
printf '  NOTE: Verify syslog on %s with:\n' "$AGENT1"
printf '        journalctl -t ctrl-exec-demo | tail -5\n'
printf '        Expect: reqid=... user=testop script=ctrl-exec-demonstrator\n'

summary
