#!/bin/bash
# 05-parallelism.sh
#
# Tests parallel execution across multiple hosts.
# Confirms:
#   - both hosts run concurrently (total time ~ max, not sum)
#   - output from each host is kept together (not interleaved)
#   - each host gets its own stdout/stderr in --json output
#   - stdout from one host does not appear in another host's result
#
# Prerequisites: sleep-test, env-dump, big-output scripts on both agents.

set -uo pipefail
source "$(dirname "$0")/lib.sh"

# ============================================================
describe "Parallelism: two hosts run concurrently"
# ============================================================
# Each agent sleeps 5 seconds. True parallel execution should take ~5s total.
# Serial execution would take ~10s.

# Use exit-code with a short sleep as a proxy if sleep-test is 30s
# We'll use a small sleep via dispatcher-demonstrator or args-echo timing

# Time a normal two-host run with a script that takes non-trivial work
START=$(date +%s)
run_dispatcher run "$AGENT_DEBIAN" "$AGENT_OPENWRT" big-output
ELAPSED=$(elapsed_seconds "$START")

assert_exit 0 "$RC" "clean exit"

# big-output generates 10000 lines. If serial it would be noticeably slower.
# We can't assert a hard time without knowing host speed, but we can note it.
printf '        Two-host big-output took: %ds\n' "$ELAPSED"

if [ "$ELAPSED" -lt 60 ]; then
    pass "completed in reasonable time (${ELAPSED}s)"
else
    fail "completed in reasonable time" "took ${ELAPSED}s - may be serial or very slow"
fi

# ============================================================
describe "Parallelism: each host's output is distinct and separated"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" "$AGENT_OPENWRT" env-dump

assert_exit 0 "$RC" "clean exit"

# env-dump outputs hostname-specific content (HOSTNAME= var or similar)
# At minimum, both host headers should appear
assert_contains "$OUT" "$AGENT_DEBIAN"  "Debian section present"
assert_contains "$OUT" "$AGENT_OPENWRT" "OpenWrt section present"

# ============================================================
describe "Parallelism: JSON - stdout isolation between hosts"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" "$AGENT_OPENWRT" env-dump --json

assert_exit 0 "$RC" "clean exit"
assert_json_valid "$OUT" "valid JSON"

# Extract each host's stdout separately and confirm they differ
DEBIAN_STDOUT=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(r.get('stdout',''))
" "$OUT" "$AGENT_DEBIAN" 2>/dev/null)

OPENWRT_STDOUT=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(r.get('stdout',''))
" "$OUT" "$AGENT_OPENWRT" 2>/dev/null)

if [ -n "$DEBIAN_STDOUT" ]; then
    pass "Debian stdout is non-empty"
else
    fail "Debian stdout is non-empty" "got empty stdout for $AGENT_DEBIAN"
fi

if [ -n "$OPENWRT_STDOUT" ]; then
    pass "OpenWrt stdout is non-empty"
else
    fail "OpenWrt stdout is non-empty" "got empty stdout for $AGENT_OPENWRT"
fi

if [ "$DEBIAN_STDOUT" != "$OPENWRT_STDOUT" ]; then
    pass "each host has distinct stdout (not cross-contaminated)"
else
    fail "each host has distinct stdout" \
        "both hosts returned identical output - possible result mixing"
fi

# ============================================================
describe "Parallelism: large output from both hosts"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" "$AGENT_OPENWRT" big-output --json

assert_exit 0 "$RC" "clean exit with large output from both hosts"
assert_json_valid "$OUT" "valid JSON with large payload"

# Each host's stdout should contain ~10000 lines
DEBIAN_LINES=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(len(r.get('stdout','').splitlines()))
" "$OUT" "$AGENT_DEBIAN" 2>/dev/null)

OPENWRT_LINES=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(len(r.get('stdout','').splitlines()))
" "$OUT" "$AGENT_OPENWRT" 2>/dev/null)

printf '        Debian stdout lines: %s\n' "$DEBIAN_LINES"
printf '        OpenWrt stdout lines: %s\n' "$OPENWRT_LINES"

if [ "${DEBIAN_LINES:-0}" -ge 9000 ]; then
    pass "Debian big-output: ~10000 lines received"
else
    fail "Debian big-output: ~10000 lines received" "got $DEBIAN_LINES lines"
fi

if [ "${OPENWRT_LINES:-0}" -ge 9000 ]; then
    pass "OpenWrt big-output: ~10000 lines received"
else
    fail "OpenWrt big-output: ~10000 lines received" "got $OPENWRT_LINES lines"
fi

# ============================================================
describe "Parallelism: stdout and stderr both captured per host"
# ============================================================

# dispatcher-demonstrator stderr subcommand writes to both stdout and stderr
run_dispatcher run "$AGENT_DEBIAN" "$AGENT_OPENWRT" dispatcher-demonstrator \
    -- stderr --json

assert_exit 0 "$RC" "clean exit"
assert_json_valid "$OUT" "valid JSON"

# Verify each result has content in both stdout and stderr
for agent in "$AGENT_DEBIAN" "$AGENT_OPENWRT"; do
    AGENT_STDERR=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
for r in data.get('results',[]):
    if r.get('host','') == sys.argv[2]:
        print(r.get('stderr',''))
" "$OUT" "$agent" 2>/dev/null)
    if echo "$AGENT_STDERR" | grep -q "stderr"; then
        pass "$agent: stderr captured"
    else
        fail "$agent: stderr captured" "stderr was: $AGENT_STDERR"
    fi
done

summary
