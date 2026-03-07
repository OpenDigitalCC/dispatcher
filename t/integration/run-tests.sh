#!/bin/bash
# run-tests.sh
#
# Run dispatcher integration tests.
#
# Usage:
#   sudo bash run-tests.sh [test-file ...]
#
# If no test files are given, runs all tests in order.
# Individual tests can be run directly from the suite directory, e.g.:
#   sudo bash 02-argument-integrity.sh
#
# Agents are discovered automatically from "dispatcher list-agents".
# No hostnames need to be configured.
#
# Environment variables:
#   DISPATCHER   dispatcher binary name or path (default: dispatcher)

set -uo pipefail
cd "$(dirname "$0")"

source ./lib.sh

TESTS=(
    01-security-boundary.sh
    02-argument-integrity.sh
    03-partial-failure.sh
    04-json-output.sh
    05-parallelism.sh
    06-auth-context.sh
)

if [ "$#" -gt 0 ]; then
    TESTS=("$@")
fi

printf '\n'
printf '=%.0s' {1..60}
printf '\n'
printf 'Dispatcher Integration Tests\n'
printf '  DISPATCHER = %s\n' "$DISPATCHER"
printf '=%.0s' {1..60}
printf '\n'

# Verify dispatcher binary is accessible
if ! sudo "$DISPATCHER" list-agents > /dev/null 2>&1; then
    printf '\nERROR: Cannot run "dispatcher list-agents"\n'
    printf 'Check the dispatcher is installed and you have sudo access.\n'
    exit 1
fi

# Discover and ping all registered agents once before any tests run.
# Populates AGENTS, AGENT1, AGENT2 which are exported to all test files.
discover_agents

if [ "${#AGENTS[@]}" -eq 0 ]; then
    printf 'ERROR: No agents reachable. Cannot run tests.\n'
    exit 1
fi

PASS_FILES=0
FAIL_FILES=0

for test_file in "${TESTS[@]}"; do
    printf '\n'
    printf '#%.0s' {1..60}
    printf '\n'
    printf '# %s\n' "$test_file"
    printf '#%.0s' {1..60}
    printf '\n'

    # Source rather than bash so the AGENTS array is inherited.
    # Each test file calls summary() which returns non-zero on failure.
    # Reset per-file counters before sourcing.
    _PASS=0; _FAIL=0; _SKIP=0
    if ( source "$test_file" ); then
        PASS_FILES=$((PASS_FILES + 1))
    else
        FAIL_FILES=$((FAIL_FILES + 1))
    fi
done

printf '\n'
printf '=%.0s' {1..60}
printf '\n'
printf 'Suite complete: %d test files passed, %d failed\n' "$PASS_FILES" "$FAIL_FILES"
printf '=%.0s' {1..60}
printf '\n'

if [ "$FAIL_FILES" -gt 0 ]; then
    exit 1
fi
exit 0
