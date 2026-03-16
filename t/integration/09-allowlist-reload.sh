#!/bin/bash
# 09-allowlist-reload.sh
#
# Tests that SIGHUP reloads the allowlist without restarting the agent,
# and that a newly added script becomes callable immediately after reload.
#
# Also tests that a script removed from the allowlist after reload is no
# longer callable, without the agent restarting.
#
# Requires: 1 reachable agent with SSH access.
# The allowlist-reload-check script must exist on the agent filesystem
# (written by setup-agent-scripts.sh) but NOT yet in scripts.conf.

set -uo pipefail
source "${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib.sh"

require_agents 1

AGENT_CONF_DIR="/etc/ctrl-exec-agent"
ALLOWLIST="$AGENT_CONF_DIR/scripts.conf"
SCRIPT_DIR="/opt/ctrl-exec-scripts"
AGENT_SSH_USER="${AGENT_SSH_USER:-root}"

agent_run() {
    if [ "$AGENT1" = "localhost" ] || [ "$AGENT1" = "$(hostname)" ]; then
        sudo bash -c "$*"
    else
        ssh "${AGENT_SSH_USER}@${AGENT1}" "sudo bash -c '$*'"
    fi
}

agent_reload() {
    agent_run "systemctl reload ctrl-exec-agent 2>/dev/null \
        || pkill -HUP -f 'ctrl-exec-agent serve' \
        || pkill -HUP -x ctrl-exec-agent" 2>/dev/null || true
    sleep 1
}

# Check SSH access
if ! agent_run "true" 2>/dev/null; then
    skip "Allowlist reload tests" \
        "cannot reach $AGENT1 via SSH as $AGENT_SSH_USER - set AGENT_SSH_USER or run locally"
    summary
    exit 0
fi

# Ensure the script file exists on the agent
if ! agent_run "test -f '$SCRIPT_DIR/allowlist-reload-check.sh'" 2>/dev/null; then
    skip "Allowlist reload tests" \
        "allowlist-reload-check.sh not found on $AGENT1 - run setup-agent-scripts.sh first"
    summary
    exit 0
fi

# Cleanup: remove test entry from allowlist on exit
cleanup() {
    agent_run "grep -v '^allowlist-reload-check' '$ALLOWLIST' \
        > '${ALLOWLIST}.tmp' && mv '${ALLOWLIST}.tmp' '$ALLOWLIST'" 2>/dev/null || true
    agent_reload
}
trap cleanup EXIT

# ============================================================
assert_agents_reachable
describe "Reload: script not yet in allowlist is rejected"
# ============================================================

# Ensure it's not in the allowlist to start
agent_run "grep -v '^allowlist-reload-check' '$ALLOWLIST' \
    > '${ALLOWLIST}.tmp' && mv '${ALLOWLIST}.tmp' '$ALLOWLIST'" 2>/dev/null || true
agent_reload

run_dispatcher run "$AGENT1" allowlist-reload-check

assert_exit 1 "$RC" "script not in allowlist rejected before reload"
assert_contains "$OUT$ERR" "not permitted" "correct error before reload"

# ============================================================
assert_agents_reachable
describe "Reload: script callable after adding to allowlist and SIGHUP"
# ============================================================

# Add to allowlist
agent_run "echo 'allowlist-reload-check = $SCRIPT_DIR/allowlist-reload-check.sh' >> '$ALLOWLIST'"
agent_reload

run_dispatcher run "$AGENT1" allowlist-reload-check

assert_exit 0 "$RC" "script callable after reload"
assert_contains "$OUT" "allowlist-reload-check: ok" "correct output after reload"

# ============================================================
assert_agents_reachable
describe "Reload: agent PID unchanged after SIGHUP (no restart)"
# ============================================================

PID_BEFORE=$(agent_run "pgrep -f 'ctrl-exec-agent serve' | head -1" 2>/dev/null)
agent_reload
sleep 1
PID_AFTER=$(agent_run "pgrep -f 'ctrl-exec-agent serve' | head -1" 2>/dev/null)

if [ -n "$PID_BEFORE" ] && [ "$PID_BEFORE" = "$PID_AFTER" ]; then
    pass "agent PID unchanged: $PID_BEFORE (no restart occurred)"
else
    fail "agent PID unchanged" \
        "before: $PID_BEFORE  after: $PID_AFTER (agent may have restarted)"
fi

# ============================================================
assert_agents_reachable
describe "Reload: script rejected after removal from allowlist and SIGHUP"
# ============================================================

# Remove from allowlist
agent_run "grep -v '^allowlist-reload-check' '$ALLOWLIST' \
    > '${ALLOWLIST}.tmp' && mv '${ALLOWLIST}.tmp' '$ALLOWLIST'"
agent_reload

run_dispatcher run "$AGENT1" allowlist-reload-check

assert_exit 1 "$RC" "script rejected after removal"
assert_contains "$OUT$ERR" "not permitted" "correct error after removal"

# ============================================================
assert_agents_reachable
describe "Reload: existing scripts unaffected by reload"
# ============================================================

# env-dump should still work throughout
run_dispatcher run "$AGENT1" env-dump

assert_exit 0 "$RC" "existing script still works after reload cycle"
assert_contains "$OUT" "PATH=" "env-dump output intact"

summary
