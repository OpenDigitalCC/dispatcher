#!/bin/bash
# 04-json-output.sh
#
# Verifies --json output structure is correct and complete for all modes.
# An API consumer or monitoring tool depends on this being stable and parseable.
#
# Prerequisites: env-dump, args-echo, exit-code scripts on both agents.

set -uo pipefail
source "$(dirname "$0")/lib.sh"

# python3 is used for JSON validation and field extraction
# (more reliable than grep for nested structures)

json_get() {
    # json_get <json> <field>  - extracts top-level field value
    python3 -c "
import sys, json
data = json.loads(sys.argv[1])
val = data.get(sys.argv[2], '__MISSING__')
print(val if not isinstance(val, (list,dict)) else json.dumps(val))
" "$1" "$2" 2>/dev/null
}

json_result_field() {
    # json_result_field <json> <index> <field>
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
describe "run --json: top-level structure"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" env-dump --json

assert_exit 0 "$RC" "clean exit"
assert_json_valid "$OUT" "valid JSON"

OK=$(json_get "$OUT" "ok")
if [ "$OK" = "1" ]; then
    pass "top-level 'ok' is 1"
else
    fail "top-level 'ok' is 1" "got: $OK"
fi

RESULTS=$(json_get "$OUT" "results")
if [ "$RESULTS" != "__MISSING__" ]; then
    pass "top-level 'results' field present"
else
    fail "top-level 'results' field present" "output: $OUT"
fi

# ============================================================
describe "run --json: per-host result fields"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" env-dump --json

# Check all expected fields in the first result
for field in host exit stdout stderr reqid rtt; do
    VAL=$(json_result_field "$OUT" 0 "$field")
    if [ "$VAL" != "__MISSING__" ]; then
        pass "result[0] has field: $field"
    else
        fail "result[0] has field: $field" "missing from: $OUT"
    fi
done

# ============================================================
describe "run --json: field types and values on success"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" env-dump --json

HOST=$(json_result_field "$OUT" 0 "host")
EXIT=$(json_result_field "$OUT" 0 "exit")
STDOUT=$(json_result_field "$OUT" 0 "stdout")
REQID=$(json_result_field "$OUT" 0 "reqid")
RTT=$(json_result_field "$OUT" 0 "rtt")

if [ "$HOST" = "$AGENT_DEBIAN" ]; then
    pass "host field matches agent name"
else
    fail "host field matches agent name" "got: $HOST"
fi

if [ "$EXIT" = "0" ]; then
    pass "exit field is 0 on success"
else
    fail "exit field is 0 on success" "got: $EXIT"
fi

if echo "$STDOUT" | grep -q "PATH="; then
    pass "stdout field contains script output"
else
    fail "stdout field contains script output" "stdout: $STDOUT"
fi

if [ -n "$REQID" ] && [ ${#REQID} -ge 8 ]; then
    pass "reqid field is non-empty (len ${#REQID})"
else
    fail "reqid field is non-empty" "got: $REQID"
fi

if echo "$RTT" | grep -qE '^[0-9]+(\.[0-9]+)?ms$'; then
    pass "rtt field looks like a duration: $RTT"
else
    fail "rtt field looks like a duration" "got: $RTT"
fi

# ============================================================
describe "run --json: non-zero exit code reported correctly"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" exit-code -- 42 --json

assert_exit 1 "$RC" "dispatcher exits non-zero"
assert_json_valid "$OUT" "valid JSON even on failure"

EXIT=$(json_result_field "$OUT" 0 "exit")
if [ "$EXIT" = "42" ]; then
    pass "exit code 42 in JSON result"
else
    fail "exit code 42 in JSON result" "got: $EXIT"
fi

# ============================================================
describe "run --json: script not permitted"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" nonexistent-script-xyz --json

assert_exit 1 "$RC" "dispatcher exits non-zero"
assert_json_valid "$OUT" "valid JSON on denial"

ERROR=$(json_result_field "$OUT" 0 "error")
if echo "$ERROR" | grep -qi "not permitted"; then
    pass "error field contains 'not permitted'"
else
    fail "error field contains 'not permitted'" "got: $ERROR"
fi

EXIT=$(json_result_field "$OUT" 0 "exit")
if [ "$EXIT" = "-1" ]; then
    pass "exit is -1 for denied script"
else
    fail "exit is -1 for denied script" "got: $EXIT"
fi

# ============================================================
describe "run --json: multi-host - both results present"
# ============================================================

run_dispatcher run "$AGENT_DEBIAN" "$AGENT_OPENWRT" env-dump --json

assert_exit 0 "$RC" "clean exit"
assert_json_valid "$OUT" "valid JSON"

# Both hosts should appear
if echo "$OUT" | grep -qF "$AGENT_DEBIAN" && echo "$OUT" | grep -qF "$AGENT_OPENWRT"; then
    pass "both agents in results"
else
    fail "both agents in results" "output: $OUT"
fi

RESULT_COUNT=$(python3 -c "import sys,json; print(len(json.loads(sys.argv[1]).get('results',[])))" "$OUT" 2>/dev/null)
if [ "$RESULT_COUNT" = "2" ]; then
    pass "results array has 2 entries"
else
    fail "results array has 2 entries" "got: $RESULT_COUNT"
fi

# ============================================================
describe "ping --json: structure"
# ============================================================

run_dispatcher ping "$AGENT_DEBIAN" --json

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
