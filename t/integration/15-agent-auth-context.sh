#!/bin/bash
# 15-agent-auth-context.sh
#
# Verifies that the agent-side auth hook receives the correct context fields
# for every run request: action, script, username, token, and source_ip.
#
# Design:
#   The auth-context-check hook (installed by setup-agent-scripts.sh
#   --install-auth-test) writes all received DISPATCHER_* env vars to a
#   status file on the agent at /tmp/dispatcher-auth-test-status on every
#   call. The allowlisted script auth-status-dump retrieves that file via a
#   subsequent dispatch, without requiring SSH access to the agent.
#
#   A passing dispatch with known values populates the status file. The
#   source IP is read back from it, so no hardcoding is needed.
#
#   Denial tests send a wrong or missing field. The hook writes the status
#   file before applying policy, so the test can confirm what was received
#   even for denied requests.
#
# Requires:
#   setup-agent-scripts.sh --install-auth-test run on AGENT1 before this test.
#   The test detects whether auth-status-dump is configured and skips cleanly
#   if the setup step has not been run.
#
# Cleanup:
#   This test does not modify agent state. The hook and agent.conf changes
#   are installed and removed by setup-agent-scripts.sh --install-auth-test
#   and --remove-auth-test respectively.

set -uo pipefail
source "${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib.sh"

require_agents 1

# --- detect whether --install-auth-test has been run ---
#
# Probe the allowlist via dispatcher list-scripts (or equivalent).
# If auth-status-dump is not in the allowlist, the hook setup has not been
# run and all tests in this file are skipped.

if ! sudo "$DISPATCHER" list-scripts "$AGENT1" 2>/dev/null | grep -q "^auth-status-dump"; then
    skip "Agent auth context tests" \
        "auth-status-dump not in allowlist on $AGENT1 — run: sudo bash setup-agent-scripts.sh --install-auth-test"
    summary
    exit 0
fi

# --- helper: read status file from agent via dispatch ---

read_status_file() {
    run_dispatcher run "$AGENT1" auth-status-dump \
        --username "test-user" --token "test-token-value"
    echo "$OUT"
}

parse_field() {
    # parse_field <status_output> <field_name>
    echo "$1" | grep "^${2}=" | cut -d= -f2-
}

# ============================================================
assert_agents_reachable
describe "Auth context: passing request with known values"
# ============================================================

run_dispatcher run "$AGENT1" args-echo \
    --username "test-user" --token "test-token-value" -- first second

assert_exit 0 "$RC" "dispatch with correct values succeeds"
assert_contains "$OUT" "[1] first" "script executed (args present)"

# ============================================================
describe "Auth context: status file populated after passing request"
# ============================================================

STATUS=$(read_status_file)

assert_exit 0 "$RC" "auth-status-dump retrieved status file"

if echo "$STATUS" | grep -q "^DISPATCHER_ACTION="; then
    pass "DISPATCHER_ACTION present in status file"
else
    fail "DISPATCHER_ACTION present in status file" "status: $STATUS"
fi

# ============================================================
describe "Auth context: DISPATCHER_ACTION is 'run'"
# ============================================================

ACTION=$(parse_field "$STATUS" "DISPATCHER_ACTION")
[ "$ACTION" = "run" ] \
    && pass "DISPATCHER_ACTION = run" \
    || fail "DISPATCHER_ACTION = run" "got: '$ACTION'"

# ============================================================
describe "Auth context: DISPATCHER_SCRIPT matches requested script"
# ============================================================

# The status file was written during the args-echo call above.
SCRIPT=$(parse_field "$STATUS" "DISPATCHER_SCRIPT")
[ "$SCRIPT" = "args-echo" ] \
    && pass "DISPATCHER_SCRIPT = args-echo" \
    || fail "DISPATCHER_SCRIPT = args-echo" "got: '$SCRIPT'"

# ============================================================
describe "Auth context: DISPATCHER_USERNAME forwarded correctly"
# ============================================================

USERNAME=$(parse_field "$STATUS" "DISPATCHER_USERNAME")
[ "$USERNAME" = "test-user" ] \
    && pass "DISPATCHER_USERNAME = test-user" \
    || fail "DISPATCHER_USERNAME = test-user" "got: '$USERNAME'"

# ============================================================
describe "Auth context: DISPATCHER_TOKEN forwarded correctly"
# ============================================================

TOKEN=$(parse_field "$STATUS" "DISPATCHER_TOKEN")
[ "$TOKEN" = "test-token-value" ] \
    && pass "DISPATCHER_TOKEN = test-token-value" \
    || fail "DISPATCHER_TOKEN = test-token-value" "got: '$TOKEN'"

# ============================================================
describe "Auth context: DISPATCHER_SOURCE_IP is non-empty"
# ============================================================

SOURCE_IP=$(parse_field "$STATUS" "DISPATCHER_SOURCE_IP")
if [ -n "$SOURCE_IP" ]; then
    pass "DISPATCHER_SOURCE_IP is non-empty: $SOURCE_IP"
else
    fail "DISPATCHER_SOURCE_IP is non-empty" "was empty or missing"
fi

# Record the observed dispatcher IP for the remainder of the test.
DISPATCHER_IP="$SOURCE_IP"

# ============================================================
assert_agents_reachable
describe "Auth context: wrong username is denied"
# ============================================================

run_dispatcher run "$AGENT1" args-echo \
    --username "wrong-user" --token "test-token-value" -- probe

assert_exit 1 "$RC" "wrong username: dispatcher exits non-zero"
assert_not_contains "$OUT" "[1] probe" "wrong username: script did not execute"

STATUS=$(read_status_file)
RECORDED_USER=$(parse_field "$STATUS" "DISPATCHER_USERNAME")
[ "$RECORDED_USER" = "wrong-user" ] \
    && pass "wrong username: hook received the incorrect value before denying" \
    || fail "wrong username: hook received the incorrect value before denying" \
            "got: '$RECORDED_USER'"

# ============================================================
assert_agents_reachable
describe "Auth context: wrong token is denied"
# ============================================================

run_dispatcher run "$AGENT1" args-echo \
    --username "test-user" --token "wrong-token" -- probe

assert_exit 1 "$RC" "wrong token: dispatcher exits non-zero"
assert_not_contains "$OUT" "[1] probe" "wrong token: script did not execute"

STATUS=$(read_status_file)
RECORDED_TOKEN=$(parse_field "$STATUS" "DISPATCHER_TOKEN")
[ "$RECORDED_TOKEN" = "wrong-token" ] \
    && pass "wrong token: hook received the incorrect value before denying" \
    || fail "wrong token: hook received the incorrect value before denying" \
            "got: '$RECORDED_TOKEN'"

# ============================================================
assert_agents_reachable
describe "Auth context: missing token is denied"
# ============================================================

run_dispatcher run "$AGENT1" args-echo \
    --username "test-user" -- probe

assert_exit 1 "$RC" "missing token: dispatcher exits non-zero"
assert_not_contains "$OUT" "[1] probe" "missing token: script did not execute"

STATUS=$(read_status_file)
RECORDED_TOKEN=$(parse_field "$STATUS" "DISPATCHER_TOKEN")
[ -z "$RECORDED_TOKEN" ] \
    && pass "missing token: hook received empty token before denying" \
    || fail "missing token: hook received empty token before denying" \
            "got: '$RECORDED_TOKEN'"

# ============================================================
assert_agents_reachable
describe "Auth context: missing username is denied"
# ============================================================

run_dispatcher run "$AGENT1" args-echo \
    --token "test-token-value" -- probe

assert_exit 1 "$RC" "missing username: dispatcher exits non-zero"
assert_not_contains "$OUT" "[1] probe" "missing username: script did not execute"

STATUS=$(read_status_file)
RECORDED_USER=$(parse_field "$STATUS" "DISPATCHER_USERNAME")
[ -z "$RECORDED_USER" ] \
    && pass "missing username: hook received empty username before denying" \
    || fail "missing username: hook received empty username before denying" \
            "got: '$RECORDED_USER'"

# ============================================================
assert_agents_reachable
describe "Auth context: source IP is consistent across requests"
# ============================================================

# Run a second passing request and confirm source IP matches the first.
run_dispatcher run "$AGENT1" args-echo \
    --username "test-user" --token "test-token-value" -- verify

assert_exit 0 "$RC" "second passing request succeeds"

STATUS=$(read_status_file)
SOURCE_IP2=$(parse_field "$STATUS" "DISPATCHER_SOURCE_IP")

[ "$SOURCE_IP2" = "$DISPATCHER_IP" ] \
    && pass "DISPATCHER_SOURCE_IP consistent: $DISPATCHER_IP" \
    || fail "DISPATCHER_SOURCE_IP consistent" \
            "first=$DISPATCHER_IP second=$SOURCE_IP2"

summary
