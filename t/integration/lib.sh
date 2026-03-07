#!/bin/bash
# lib.sh - shared functions for dispatcher integration tests
#
# Source this file at the top of each test script:
#   source "$(dirname "$0")/lib.sh"

# --- configuration ---
# Override these by setting environment variables before running tests.

AGENT_DEBIAN="${AGENT_DEBIAN:-sjm-explore}"
AGENT_OPENWRT="${AGENT_OPENWRT:-OpenWrt}"
DISPATCHER="${DISPATCHER:-dispatcher}"   # path or name if on PATH

# --- counters ---

_PASS=0
_FAIL=0
_SKIP=0
_TEST_NAME=""

# --- output helpers ---

_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
_bold()   { printf '\033[1m%s\033[0m\n'  "$*"; }

describe() {
    _TEST_NAME="$*"
    printf '\n'
    _bold "--- $* ---"
}

pass() {
    _PASS=$((_PASS + 1))
    _green "  PASS: ${1:-$_TEST_NAME}"
}

fail() {
    _FAIL=$((_FAIL + 1))
    _red   "  FAIL: ${1:-$_TEST_NAME}"
    if [ -n "${2:-}" ]; then
        printf '        %s\n' "$2"
    fi
}

skip() {
    _SKIP=$((_SKIP + 1))
    _yellow "  SKIP: ${1:-$_TEST_NAME}"
    if [ -n "${2:-}" ]; then
        printf '        %s\n' "$2"
    fi
}

summary() {
    printf '\n'
    _bold "Results: $_PASS passed, $_FAIL failed, $_SKIP skipped"
    if [ "$_FAIL" -gt 0 ]; then
        return 1
    fi
    return 0
}

# --- assertion helpers ---

# assert_exit <expected> <actual> <label>
assert_exit() {
    local expected="$1" actual="$2" label="${3:-exit code}"
    if [ "$actual" -eq "$expected" ]; then
        pass "$label (exit $actual)"
    else
        fail "$label" "expected exit $expected, got $actual"
    fi
}

# assert_contains <string> <substring> <label>
assert_contains() {
    local haystack="$1" needle="$2" label="${3:-contains}"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$label"
    else
        fail "$label" "expected to contain: $needle"
        printf '        actual output: %s\n' "$(echo "$haystack" | head -5)"
    fi
}

# assert_not_contains <string> <substring> <label>
assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-not contains}"
    if echo "$haystack" | grep -qF "$needle"; then
        fail "$label" "expected NOT to contain: $needle"
    else
        pass "$label"
    fi
}

# assert_json_field <json> <field> <expected_value> <label>
# Extracts a top-level string or number field using grep/sed only (no jq).
assert_json_field() {
    local json="$1" field="$2" expected="$3" label="${4:-json field $field}"
    local actual
    actual=$(echo "$json" | grep -o "\"${field}\":[^,}]*" | head -1 \
        | sed 's/^"[^"]*":[[:space:]]*//' \
        | sed 's/^"\(.*\)"$/\1/' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label" "expected '$expected', got '$actual'"
    fi
}

# assert_json_valid <json> <label>
assert_json_valid() {
    local json="$1" label="${2:-valid JSON}"
    if python3 -c "import sys,json; json.load(sys.stdin)" <<< "$json" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "output is not valid JSON"
        printf '        output: %s\n' "$(echo "$json" | head -3)"
    fi
}

# run_dispatcher <args...> - runs dispatcher, sets OUT, ERR, RC
run_dispatcher() {
    OUT=$(sudo "$DISPATCHER" "$@" 2>/tmp/_disp_err); RC=$?
    ERR=$(cat /tmp/_disp_err)
}

# elapsed_seconds <start_seconds> - returns wall time since start
elapsed_seconds() {
    echo $(( $(date +%s) - $1 ))
}
