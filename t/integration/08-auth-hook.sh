#!/bin/bash
# 08-auth-hook.sh
#
# Tests the agent-side auth hook end-to-end.
#
# The auth hook is an executable on the agent that is called before every
# run request, after allowlist validation. Its exit code determines whether
# the request is allowed (0) or denied (1/2/3).
#
# This test installs a temporary hook on AGENT1, exercises it, then removes
# it and restores the agent to its original state.
#
# Hook behaviour tested:
#   - Exit 0: request passes through
#   - Exit 1: request denied, dispatcher reports denial
#   - Exit 2: request denied with bad-credentials reason
#   - Token-based policy: specific token denied, others pass
#
# Requires: 1 reachable agent with SSH access from the dispatcher host,
# OR run this script directly on the agent host with sudo.
#
# NOTE: This test modifies agent.conf on AGENT1. It restores the original
# on exit (success or failure) via a trap.

set -uo pipefail
source "${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib.sh"

require_agents 1

AGENT_CONF="/etc/dispatcher-agent/agent.conf"
HOOK_PATH="/etc/dispatcher-agent/test-auth-hook.sh"
HOOK_BACKUP="/etc/dispatcher-agent/test-auth-hook.sh.bak"
CONF_BACKUP="/etc/dispatcher-agent/agent.conf.bak"

# --- helper: run a command on the agent ---
# If AGENT1 is localhost (running locally), use sudo directly.
# Otherwise, use ssh. Set AGENT_SSH_USER if needed (default: root).
AGENT_SSH_USER="${AGENT_SSH_USER:-root}"

agent_run() {
    if [ "$AGENT1" = "localhost" ] || [ "$AGENT1" = "$(hostname)" ]; then
        sudo bash -c "$*"
    else
        ssh "${AGENT_SSH_USER}@${AGENT1}" "sudo bash -c '$*'"
    fi
}

agent_write() {
    # agent_write <remote_path> <content>
    local path="$1" content="$2"
    if [ "$AGENT1" = "localhost" ] || [ "$AGENT1" = "$(hostname)" ]; then
        echo "$content" | sudo tee "$path" > /dev/null
    else
        echo "$content" | ssh "${AGENT_SSH_USER}@${AGENT1}" "sudo tee '$path' > /dev/null"
    fi
}

# --- check SSH connectivity before proceeding ---
if ! agent_run "true" 2>/dev/null; then
    skip "Auth hook tests" \
        "cannot reach $AGENT1 via SSH as $AGENT_SSH_USER - set AGENT_SSH_USER or run locally"
    summary
    exit 0
fi

# --- cleanup trap ---
cleanup() {
    agent_run "rm -f '$HOOK_PATH'" 2>/dev/null || true
    # Remove auth_hook line from agent.conf if we added it
    agent_run "grep -v '^auth_hook' '$AGENT_CONF' > '${AGENT_CONF}.tmp' && mv '${AGENT_CONF}.tmp' '$AGENT_CONF'" \
        2>/dev/null || true
    # Reload
    agent_run "systemctl reload dispatcher-agent 2>/dev/null || pkill -HUP -f 'dispatcher-agent serve' || true" \
        2>/dev/null || true
}
trap cleanup EXIT

# --- install hook that checks DISPATCHER_TOKEN ---
agent_write "$HOOK_PATH" '#!/bin/sh
# Test auth hook: deny token "denied-token" with exit 2,
# deny token "restricted-token" with exit 3,
# allow everything else.
case "$DISPATCHER_TOKEN" in
    denied-token)     echo "bad credentials" >&2; exit 2 ;;
    restricted-token) echo "insufficient privilege" >&2; exit 3 ;;
    *)                exit 0 ;;
esac'

agent_run "chmod 0755 '$HOOK_PATH'"

# Add auth_hook to agent.conf if not already present
if ! agent_run "grep -q '^auth_hook' '$AGENT_CONF'" 2>/dev/null; then
    agent_run "echo 'auth_hook = $HOOK_PATH' >> '$AGENT_CONF'"
fi

# Reload agent to pick up hook config
agent_run "systemctl reload dispatcher-agent 2>/dev/null \
    || pkill -HUP -f 'dispatcher-agent serve' \
    || pkill -HUP -x dispatcher-agent" 2>/dev/null || true
sleep 2

# ============================================================
assert_agents_reachable
describe "Auth hook: request without token passes (exit 0 from hook)"
# ============================================================

run_dispatcher run "$AGENT1" env-dump

assert_exit 0 "$RC" "request without token passes hook"

# ============================================================
assert_agents_reachable
describe "Auth hook: valid token passes"
# ============================================================

run_dispatcher run "$AGENT1" env-dump --token valid-token

assert_exit 0 "$RC" "valid token passes hook"

# ============================================================
assert_agents_reachable
describe "Auth hook: denied token rejected (exit 2)"
# ============================================================

run_dispatcher run "$AGENT1" env-dump --token denied-token

assert_exit 1 "$RC" "dispatcher exits non-zero"
if echo "$OUT$ERR" | grep -qiE "denied|authoris|not authoris|credential"; then
    pass "denial reason reported"
else
    fail "denial reason reported" "got: $(echo "$OUT$ERR" | head -3)"
fi
assert_not_contains "$OUT$ERR" "PATH=" "env-dump did not execute"

# ============================================================
assert_agents_reachable
describe "Auth hook: denied token rejected - JSON output"
# ============================================================

run_dispatcher run "$AGENT1" env-dump --token denied-token --json

assert_exit 1 "$RC" "dispatcher exits non-zero"
assert_json_valid "$OUT" "valid JSON on denial"

EXIT=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
results=data.get('results',[])
print(results[0].get('exit','') if results else '')
" "$OUT" 2>/dev/null)
[ "$EXIT" = "-1" ] && pass "exit is -1 for hook-denied request" \
                    || fail "exit is -1 for hook-denied request" "got: $EXIT"

# ============================================================
assert_agents_reachable
describe "Auth hook: restricted token rejected (exit 3)"
# ============================================================

run_dispatcher run "$AGENT1" env-dump --token restricted-token

assert_exit 1 "$RC" "dispatcher exits non-zero"
assert_not_contains "$OUT$ERR" "PATH=" "env-dump did not execute"

# ============================================================
assert_agents_reachable
describe "Auth hook: hook does not affect other agents"
# ============================================================

if [ "${#AGENTS[@]}" -ge 2 ]; then
    # AGENT2 has no hook - denied-token should work fine there
    run_dispatcher run "$AGENT2" env-dump --token denied-token
    assert_exit 0 "$RC" "denied-token passes on agent without hook"
    assert_contains "$OUT" "PATH=" "env-dump ran on agent without hook"
else
    skip "Cross-agent hook isolation" "only 1 agent reachable"
fi

summary
