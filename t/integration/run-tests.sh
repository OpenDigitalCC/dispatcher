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
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SUITE_DIR"

source ./lib.sh

TESTS=(
    01-security-boundary.sh
    02-argument-integrity.sh
    03-partial-failure.sh
    04-json-output.sh
    05-parallelism.sh
    06-auth-context.sh
    07-concurrency-lock.sh
    08-auth-hook.sh
    09-allowlist-reload.sh
    10-timeout-behaviour.sh
    11-api-status.sh
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

# Per-file result records: "label|pass|fail|skip|status"
declare -a _SUMMARY_ROWS=()

for test_file in "${TESTS[@]}"; do
    printf '\n'
    printf '#%.0s' {1..60}
    printf '\n'
    printf '# %s\n' "$test_file"
    printf '#%.0s' {1..60}
    printf '\n'

    # Source rather than bash so the AGENTS array is inherited.
    # Each test file calls summary() which returns non-zero on failure.
    # Reset per-file counters before sourcing. A trap on EXIT writes counts
    # to a tempfile before the subshell exits (whether normally or via set -e),
    # allowing the runner to read them back for the summary table.
    _PASS=0; _FAIL=0; _SKIP=0
    _counts_file=$(mktemp)
    if (
        trap 'printf "%d %d %d" "$_PASS" "$_FAIL" "$_SKIP" > "'"$_counts_file"'"' EXIT
        source "$test_file"
    ); then
        PASS_FILES=$((PASS_FILES + 1))
        _row_status="PASS"
    else
        FAIL_FILES=$((FAIL_FILES + 1))
        _row_status="FAIL"
    fi
    # Read counts back from tempfile written by the subshell trap
    if [ -s "$_counts_file" ]; then
        read -r _PASS _FAIL _SKIP < "$_counts_file"
    fi
    rm -f "$_counts_file"
    # Derive a short label from filename: strip leading digits, dashes, .sh
    _label=$(basename "$test_file" .sh | sed 's/^[0-9]*-//')
    _SUMMARY_ROWS+=("${_label}|${_PASS}|${_FAIL}|${_SKIP}|${_row_status}")
done

# --- Summary table ---
printf '\n'
printf '=%.0s' {1..60}
printf '\n'
printf '%-32s  %4s  %4s  %4s  %s\n' "Test file" "PASS" "FAIL" "SKIP" "Status"
printf '%-32s  %4s  %4s  %4s  %s\n' "$(printf '%.0s-' {1..32})" "----" "----" "----" "------"
for _row in "${_SUMMARY_ROWS[@]}"; do
    IFS='|' read -r _lbl _p _f _s _st <<< "$_row"
    if [ "$_st" = "FAIL" ]; then
        _red   "$(printf '%-32s  %4s  %4s  %4s  %s' "$_lbl" "$_p" "$_f" "$_s" "$_st")"
    else
        _green "$(printf '%-32s  %4s  %4s  %4s  %s' "$_lbl" "$_p" "$_f" "$_s" "$_st")"
    fi
done
printf '\n'
printf 'Suite complete: %d test files passed, %d failed\n' "$PASS_FILES" "$FAIL_FILES"
printf '=%.0s' {1..60}
printf '\n'

if [ "$FAIL_FILES" -gt 0 ]; then
    exit 1
fi
exit 0
