#!/bin/bash
# 05-parallelism.sh
#
# Tests parallel execution across multiple hosts.
# Confirms:
#   - output from each host is kept together (not interleaved)
#   - each host gets its own stdout/stderr in --json output
#   - stdout from one host does not appear in another host's result
#
# Requires: 2 reachable agents.
# Scripts needed: env-dump, big-output, dispatcher-demonstrator.

set -uo pipefail
source "$(dirname "$0")/lib.sh"

require_agents 2

# ============================================================
assert_agents_reachable
describe "Parallelism: each host's output is distinct and separated"
# ============================================================

run_dispatcher run "$AGENT1" "$AGENT2" env-dump

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "$AGENT1" "first agent section present"
assert_contains "$OUT" "$AGENT2" "second agent section present"

# ============================================================
assert_agents_reachable
describe "Parallelism: JSON - stdout isolation between hosts"
# ============================================================

run_dispatcher run "$AGENT1" "$AGENT2" env-dump --json

assert_exit 0 "$RC" "clean exit"
assert_json_valid "$OUT" "valid JSON"

AGENT1_STDOUT=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(r.get('stdout',''))
" "$OUT" "$AGENT1" 2>/dev/null)

AGENT2_STDOUT=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(r.get('stdout',''))
" "$OUT" "$AGENT2" 2>/dev/null)

[ -n "$AGENT1_STDOUT" ] \
    && pass "agent 1 stdout is non-empty" \
    || fail "agent 1 stdout is non-empty" "got empty stdout for $AGENT1"

[ -n "$AGENT2_STDOUT" ] \
    && pass "agent 2 stdout is non-empty" \
    || fail "agent 2 stdout is non-empty" "got empty stdout for $AGENT2"

[ "$AGENT1_STDOUT" != "$AGENT2_STDOUT" ] \
    && pass "each host has distinct stdout (not cross-contaminated)" \
    || fail "each host has distinct stdout" \
        "both hosts returned identical output - possible result mixing"

# ============================================================
assert_agents_reachable
describe "Parallelism: large output from both hosts"
# ============================================================

run_dispatcher run "$AGENT1" "$AGENT2" big-output --json

assert_exit 0 "$RC" "clean exit with large output from both hosts"
assert_json_valid "$OUT" "valid JSON with large payload"

for agent_var in AGENT1 AGENT2; do
    agent="${!agent_var}"
    LINES=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(len(r.get('stdout','').splitlines()))
" "$OUT" "$agent" 2>/dev/null)
    printf '        %s stdout lines: %s\n' "$agent" "$LINES"
    [ "${LINES:-0}" -ge 900 ] \
        && pass "$agent big-output: ~1000 lines received" \
        || fail "$agent big-output: ~1000 lines received" "got $LINES lines"
done

# ============================================================
assert_agents_reachable
describe "Parallelism: total time is approximately max, not sum"
# ============================================================
# Both agents run big-output. True parallel execution should complete
# in roughly the time of the slowest single agent, not the sum.

START=$(date +%s)
run_dispatcher run "$AGENT1" "$AGENT2" big-output
ELAPSED=$(elapsed_seconds "$START")

printf '        Two-agent big-output took: %ds\n' "$ELAPSED"

assert_exit 0 "$RC" "clean exit"
[ "$ELAPSED" -lt 30 ] \
    && pass "completed in reasonable time (${ELAPSED}s)" \
    || fail "completed in reasonable time" "took ${ELAPSED}s - may be serial or very slow"

# ============================================================
assert_agents_reachable
describe "Timeout: long-running script completes within dispatcher timeout"
# ============================================================
# sleep-test sleeps 30 seconds. The dispatcher read timeout observed in logs
# is 60s (RTT=60139ms ERROR="500 read timeout"). A 30s sleep should succeed.
# This confirms the timeout is longer than 30s and the result is clean.

START=$(date +%s)
run_dispatcher run "$AGENT1" sleep-test
ELAPSED=$(elapsed_seconds "$START")

printf '        sleep-test on %s took: %ds\n' "$AGENT1" "$ELAPSED"

assert_exit 0 "$RC" "sleep-test completes within timeout"
[ "$ELAPSED" -ge 28 ] \
    && pass "elapsed time confirms script actually slept (~${ELAPSED}s)" \
    || fail "elapsed time confirms script actually slept" "only ${ELAPSED}s - did script run?"

# ============================================================
assert_agents_reachable
describe "Parallelism: stdout and stderr both captured per host"
# ============================================================

run_dispatcher run "$AGENT1" "$AGENT2" dispatcher-demonstrator \
    -- stderr --json

assert_exit 0 "$RC" "clean exit"
assert_json_valid "$OUT" "valid JSON"

for agent_var in AGENT1 AGENT2; do
    agent="${!agent_var}"
    AGENT_STDERR=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(r.get('stderr',''))
" "$OUT" "$agent" 2>/dev/null)
    echo "$AGENT_STDERR" | grep -q "stderr" \
        && pass "$agent: stderr captured" \
        || fail "$agent: stderr captured" "stderr was: $AGENT_STDERR"
done

summary
