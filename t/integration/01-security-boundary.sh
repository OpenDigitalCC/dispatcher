#!/bin/bash
# 01-security-boundary.sh
#
# Confirms the allowlist security boundary holds.
# These are the most critical tests - a failure here is a serious defect.
#
# Requires: 1 reachable agent minimum.

set -uo pipefail
source "$(dirname "$0")/lib.sh"

require_agents 1

# ============================================================
assert_agents_reachable
describe "Script not in allowlist - first agent"
# ============================================================

run_dispatcher run "$AGENT1" nonexistent-script-xyz

assert_exit 1 "$RC" "dispatcher exits non-zero"
assert_contains "$OUT$ERR" "not permitted" "error mentions 'not permitted'"
assert_not_contains "$OUT" "OK" "output does not show OK"

# ============================================================
assert_agents_reachable
describe "Script not in allowlist - JSON output"
# ============================================================

run_dispatcher run "$AGENT1" nonexistent-script-xyz --json

assert_exit 1 "$RC" "dispatcher exits non-zero"
assert_json_valid "$OUT" "output is valid JSON"
assert_json_field "$OUT" "ok" "1" "outer ok is 1 (run completed, result is per-host)"

if echo "$OUT" | grep -q '"error"'; then
    pass "JSON result contains error field"
else
    fail "JSON result contains error field" "no 'error' key found in: $OUT"
fi

if echo "$OUT" | grep -q '"exit":-1\|"exit": -1'; then
    pass "JSON result shows exit -1"
else
    fail "JSON result shows exit -1" "output: $OUT"
fi

# ============================================================
assert_agents_reachable
describe "Script not in allowlist - all reachable agents"
# ============================================================

for agent in "${AGENTS[@]}"; do
    run_dispatcher run "$agent" nonexistent-script-xyz
    assert_exit 1 "$RC" "$agent: exits non-zero"
    assert_contains "$OUT$ERR" "not permitted" "$agent: error mentions 'not permitted'"
done

# ============================================================
assert_agents_reachable
describe "Script name with shell metacharacters"
# ============================================================
# These must never execute anything, even if a matching path existed.

for bad_name in '../etc/passwd' 'foo;bar' 'foo$(id)' 'a b' 'foo/bar'; do
    run_dispatcher run "$AGENT1" "$bad_name" 2>/dev/null || true
    assert_exit 1 "$RC" "rejected: '$bad_name'"
done

# ============================================================
assert_agents_reachable
describe "Script name with dot (not in allowed pattern)"
# ============================================================

run_dispatcher run "$AGENT1" "script.sh"

assert_exit 1 "$RC" "dispatcher exits non-zero for 'script.sh'"
assert_contains "$OUT$ERR" "not permitted" "dot in name rejected"

summary
