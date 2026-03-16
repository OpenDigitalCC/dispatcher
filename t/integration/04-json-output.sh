#!/bin/bash
# 04-json-output.sh
#
# Verifies --json output structure is correct and complete for all modes.
# An API consumer or monitoring tool depends on this being stable and parseable.
#
# Requires: 1 reachable agent minimum. Multi-host JSON tests require 2.
# Scripts needed: env-dump, args-echo, exit-code.

set -uo pipefail
source "${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib.sh"

require_agents 1

json_get() {
    python3 -c "
import sys, json
data = json.loads(sys.argv[1])
val = data.get(sys.argv[2], '__MISSING__')
print(val if not isinstance(val, (list,dict)) else json.dumps(val))
" "$1" "$2" 2>/dev/null
}

json_result_field() {
    python3 -c "
import sys, json
data = json.loads(sys.argv[1])
results = data.get('results', [])
idx = int(sys.argv[2])
if idx < len(results):
    val = results[idx].get(sys.argv[3], '__MISSING__')
    print(val if not isinstance(val, (list,dict)) else json.dumps(val))
else:
    print('__MISSING__')
" "$1" "$2" "$3" 2>/dev/null
}

# ============================================================
assert_agents_reachable
describe "run --json: top-level structure"
# ============================================================

run_dispatcher run "$AGENT1" env-dump --json

assert_exit 0 "$RC" "clean exit"
assert_json_valid "$OUT" "valid JSON"

OK=$(json_get "$OUT" "ok")
[ "$OK" = "1" ] && pass "top-level 'ok' is 1" \
                || fail "top-level 'ok' is 1" "got: $OK"

RESULTS=$(json_get "$OUT" "results")
[ "$RESULTS" != "__MISSING__" ] && pass "top-level 'results' field present" \
                                 || fail "top-level 'results' field present" "output: $OUT"

# ============================================================
assert_agents_reachable
describe "run --json: per-host result fields"
# ============================================================

run_dispatcher run "$AGENT1" env-dump --json

for field in host exit stdout stderr reqid rtt; do
    VAL=$(json_result_field "$OUT" 0 "$field")
    if [ "$VAL" != "__MISSING__" ]; then
        pass "result[0] has field: $field"
    else
        fail "result[0] has field: $field" "missing from: $OUT"
    fi
done

# ============================================================
assert_agents_reachable
describe "run --json: field types and values on success"
# ============================================================

run_dispatcher run "$AGENT1" env-dump --json

HOST=$(json_result_field "$OUT" 0 "host")
EXIT=$(json_result_field "$OUT" 0 "exit")
STDOUT=$(json_result_field "$OUT" 0 "stdout")
REQID=$(json_result_field "$OUT" 0 "reqid")
RTT=$(json_result_field "$OUT" 0 "rtt")

[ "$HOST" = "$AGENT1" ] && pass "host field matches agent name" \
                         || fail "host field matches agent name" "got: $HOST"

[ "$EXIT" = "0" ] && pass "exit field is 0 on success" \
                   || fail "exit field is 0 on success" "got: $EXIT"

echo "$STDOUT" | grep -q "PATH=" \
    && pass "stdout field contains script output" \
    || fail "stdout field contains script output" "stdout: $STDOUT"

[ -n "$REQID" ] && [ ${#REQID} -ge 8 ] \
    && pass "reqid field is non-empty (len ${#REQID})" \
    || fail "reqid field is non-empty" "got: $REQID"

echo "$RTT" | grep -qE '^[0-9]+(\.[0-9]+)?ms$' \
    && pass "rtt field looks like a duration: $RTT" \
    || fail "rtt field looks like a duration" "got: $RTT"

# ============================================================
assert_agents_reachable
describe "run --json: non-zero exit code reported correctly"
# ============================================================

run_dispatcher run "$AGENT1" exit-code --json -- 42

assert_exit 1 "$RC" "ctrl-exec exits non-zero"
assert_json_valid "$OUT" "valid JSON even on failure"

EXIT=$(json_result_field "$OUT" 0 "exit")
[ "$EXIT" = "42" ] && pass "exit code 42 in JSON result" \
                    || fail "exit code 42 in JSON result" "got: $EXIT"

# ============================================================
assert_agents_reachable
describe "run --json: script not permitted"
# ============================================================

run_dispatcher run "$AGENT1" nonexistent-script-xyz --json

assert_exit 1 "$RC" "ctrl-exec exits non-zero"
assert_json_valid "$OUT" "valid JSON on denial"

ERROR=$(json_result_field "$OUT" 0 "error")
echo "$ERROR" | grep -qi "not permitted" \
    && pass "error field contains 'not permitted'" \
    || fail "error field contains 'not permitted'" "got: $ERROR"

EXIT=$(json_result_field "$OUT" 0 "exit")
[ "$EXIT" = "-1" ] && pass "exit is -1 for denied script" \
                    || fail "exit is -1 for denied script" "got: $EXIT"

# ============================================================
if [ "${#AGENTS[@]}" -ge 2 ]; then
    assert_agents_reachable
    describe "run --json: multi-host - both results present"
    # ============================================================

    run_dispatcher run "$AGENT1" "$AGENT2" env-dump --json

    assert_exit 0 "$RC" "clean exit"
    assert_json_valid "$OUT" "valid JSON"

    if echo "$OUT" | grep -qF "$AGENT1" && echo "$OUT" | grep -qF "$AGENT2"; then
        pass "both agents in results"
    else
        fail "both agents in results" "output: $OUT"
    fi

    RESULT_COUNT=$(python3 -c \
        "import sys,json; print(len(json.loads(sys.argv[1]).get('results',[])))" \
        "$OUT" 2>/dev/null)
    [ "$RESULT_COUNT" = "2" ] && pass "results array has 2 entries" \
                               || fail "results array has 2 entries" "got: $RESULT_COUNT"
else
    skip "Multi-host JSON test" "only 1 agent reachable"
fi

# ============================================================
assert_agents_reachable
describe "ping --json: structure"
# ============================================================

run_dispatcher ping "$AGENT1" --json

assert_exit 0 "$RC" "clean exit"
assert_json_valid "$OUT" "valid JSON"

for field in host status rtt expiry version; do
    VAL=$(python3 -c "
import sys,json
data=json.loads(sys.argv[1])
results=data.get('results', [data])
print(results[0].get(sys.argv[2],'__MISSING__'))
" "$OUT" "$field" 2>/dev/null)
    if [ "$VAL" != "__MISSING__" ] && [ -n "$VAL" ]; then
        pass "ping result has field: $field ($VAL)"
    else
        fail "ping result has field: $field" "output: $OUT"
    fi
done

summary
