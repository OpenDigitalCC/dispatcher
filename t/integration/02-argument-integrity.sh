#!/bin/bash
# 02-argument-integrity.sh
#
# Confirms arguments arrive at the agent exactly as sent - no shell
# interpretation, no truncation, no reordering.
# Also verifies the JSON context carries them correctly.
#
# Requires: 1 reachable agent minimum.
# Scripts needed: args-echo, context-dump.

set -uo pipefail
source "$(dirname "$0")/lib.sh"

require_agents 1

# ============================================================
assert_agents_reachable
describe "Plain arguments - basic"
# ============================================================

run_dispatcher run "$AGENT1" args-echo -- hello world

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "argc: 2"     "arg count correct"
assert_contains "$OUT" "[1] hello"   "first arg intact"
assert_contains "$OUT" "[2] world"   "second arg intact"

# ============================================================
assert_agents_reachable
describe "Argument containing spaces"
# ============================================================

run_dispatcher run "$AGENT1" args-echo -- "hello world" "foo bar"

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "argc: 2"           "two args, not four"
assert_contains "$OUT" "[1] hello world"   "space preserved in arg 1"
assert_contains "$OUT" "[2] foo bar"       "space preserved in arg 2"

# ============================================================
assert_agents_reachable
describe "Argument containing single quotes"
# ============================================================

run_dispatcher run "$AGENT1" args-echo -- "it's here" "don't expand"

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "[1] it's here"    "single quote intact"
assert_contains "$OUT" "[2] don't expand" "single quote intact arg 2"

# ============================================================
assert_agents_reachable
describe "Argument containing double quotes"
# ============================================================

run_dispatcher run "$AGENT1" args-echo -- 'say "hello"'

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" '[1] say "hello"' "double quotes intact"

# ============================================================
assert_agents_reachable
describe "Argument containing shell metacharacters"
# ============================================================

run_dispatcher run "$AGENT1" args-echo -- '$(id)' '`whoami`' 'a;b' 'a|b' 'a>b'

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" "argc: 5"      "five args received"
assert_contains "$OUT" '[1] $(id)'    "dollar-paren not expanded"
assert_contains "$OUT" '[2] `whoami`' "backtick not expanded"
assert_contains "$OUT" "[3] a;b"      "semicolon not expanded"
assert_contains "$OUT" "[4] a|b"      "pipe not expanded"
assert_contains "$OUT" "[5] a>b"      "redirect not expanded"

# Confirm none of these actually ran on the agent
assert_not_contains "$OUT" "root"  "id/whoami did not execute"
assert_not_contains "$OUT" "uid="  "id did not execute"

# ============================================================
assert_agents_reachable
describe "Argument containing path traversal patterns"
# ============================================================

run_dispatcher run "$AGENT1" args-echo -- "../../../etc/passwd" "/etc/shadow"

assert_exit 0 "$RC" "clean exit - args are just strings"
assert_contains "$OUT" "[1] ../../../etc/passwd" "traversal string passed as literal"
assert_contains "$OUT" "[2] /etc/shadow"         "path passed as literal"

# ============================================================
assert_agents_reachable
describe "Large number of arguments"
# ============================================================

args=()
for i in $(seq 1 50); do args+=("arg$i"); done

run_dispatcher run "$AGENT1" args-echo -- "${args[@]}"

assert_exit 0 "$RC" "clean exit with 50 args"
assert_contains "$OUT" "argc: 50"   "all 50 args counted"
assert_contains "$OUT" "[1] arg1"   "first arg present"
assert_contains "$OUT" "[50] arg50" "fiftieth arg present"

# ============================================================
assert_agents_reachable
describe "Empty argument list"
# ============================================================

run_dispatcher run "$AGENT1" args-echo

assert_exit 0 "$RC" "clean exit with no args"
assert_contains "$OUT" "argc: 0" "zero args reported"

# ============================================================
assert_agents_reachable
describe "Arguments via JSON context - username and token forwarding"
# ============================================================

run_dispatcher run "$AGENT1" context-dump \
    --username testuser --token secret-token-42

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" '"username"'      "username key present in context"
assert_contains "$OUT" "testuser"        "username value forwarded"
assert_contains "$OUT" '"token"'         "token key present in context"
assert_contains "$OUT" "secret-token-42" "token value forwarded"
assert_contains "$OUT" '"reqid"'         "reqid present in context"
assert_contains "$OUT" '"script"'        "script name present in context"
assert_contains "$OUT" '"timestamp"'     "timestamp present in context"

# ============================================================
assert_agents_reachable
describe "Arguments appear in JSON context on agent"
# ============================================================

run_dispatcher run "$AGENT1" context-dump -- firstarg secondarg

assert_exit 0 "$RC" "clean exit"
assert_contains "$OUT" '"args"'    "args key present in context"
assert_contains "$OUT" "firstarg"  "first arg in context"
assert_contains "$OUT" "secondarg" "second arg in context"

summary
