#!/bin/bash
# run-tests.sh
#
# Run dispatcher integration tests.
#
# Usage:
#   sudo bash run-tests.sh [test-file ...]
#
# If no test files are given, runs all tests in order.
# Individual tests can be run directly, e.g.:
#   sudo bash 02-argument-integrity.sh
#
# Environment variables (override defaults in lib.sh):
#   AGENT_DEBIAN    hostname of the Debian agent   (default: sjm-explore)
#   AGENT_OPENWRT   hostname of the OpenWrt agent  (default: OpenWrt)
#   DISPATCHER      dispatcher binary name or path  (default: dispatcher)
#
# Example with overrides:
#   AGENT_DEBIAN=myhost sudo bash run-tests.sh

set -uo pipefail
cd "$(dirname "$0")"

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

PASS_FILES=0
FAIL_FILES=0

printf '\n'
printf '=%.0s' {1..60}
printf '\n'
printf 'Dispatcher Integration Tests\n'
printf '  AGENT_DEBIAN  = %s\n' "${AGENT_DEBIAN:-sjm-explore}"
printf '  AGENT_OPENWRT = %s\n' "${AGENT_OPENWRT:-OpenWrt}"
printf '  DISPATCHER    = %s\n' "${DISPATCHER:-dispatcher}"
printf '=%.0s' {1..60}
printf '\n'

# Verify dispatcher is reachable before starting
if ! sudo "${DISPATCHER:-dispatcher}" list-agents > /dev/null 2>&1; then
    printf '\nERROR: Cannot run "dispatcher list-agents" - is the dispatcher installed and are you root/sudo?\n'
    exit 1
fi

for test_file in "${TESTS[@]}"; do
    printf '\n'
    printf '#%.0s' {1..60}
    printf '\n'
    printf '# %s\n' "$test_file"
    printf '#%.0s' {1..60}
    printf '\n'

    if bash "$test_file"; then
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
