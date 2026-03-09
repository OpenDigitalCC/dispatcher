#!/bin/bash
# setup-agent-scripts.sh
#
# Install test scripts on a dispatcher agent and enable them in scripts.conf.
# Run this on each agent host before running the integration tests.
#
# Usage:
#   sudo bash setup-agent-scripts.sh
#
# What it does:
#   - Writes test scripts to /opt/dispatcher-scripts/
#   - Appends entries to /etc/dispatcher-agent/scripts.conf (if not present)
#   - Sends SIGHUP to reload the allowlist
#
# Safe to run multiple times - checks before appending.

set -euo pipefail

SCRIPT_DIR="/opt/dispatcher-scripts"
CONF="/etc/dispatcher-agent/scripts.conf"

mkdir -p "$SCRIPT_DIR"

# --- write test scripts ---

cat > "$SCRIPT_DIR/env-dump.sh" << 'EOF'
#!/bin/sh
exec 0</dev/null
env | sort
EOF

cat > "$SCRIPT_DIR/big-output.sh" << 'EOF'
#!/bin/sh
exec 0</dev/null
i=1
while [ "$i" -le 1000 ]; do
    echo "line $i of output from $(hostname)"
    i=$((i + 1))
done
EOF

cat > "$SCRIPT_DIR/sleep-test.sh" << 'EOF'
#!/bin/sh
exec 0</dev/null
echo "sleeping on $(hostname)"
sleep 30
echo "done"
EOF

cat > "$SCRIPT_DIR/args-echo.sh" << 'EOF'
#!/bin/sh
exec 0</dev/null
echo "argc: $#"
i=1
for arg in "$@"; do
    echo "[$i] $arg"
    i=$((i + 1))
done
EOF

cat > "$SCRIPT_DIR/exit-code.sh" << 'EOF'
#!/bin/sh
# Returns the exit code passed as $1, or 0 if none given.
exec 0</dev/null
code="${1:-0}"
echo "exiting with code $code"
exit "$code"
EOF

cat > "$SCRIPT_DIR/context-dump.sh" << 'EOF'
#!/bin/sh
# Reads JSON context from stdin and echoes it to stdout unchanged.
# Used to verify username, token, reqid forwarding.
cat
EOF

cat > "$SCRIPT_DIR/lock-test.sh" << 'EOF'
#!/bin/sh
# Sleeps for the number of seconds given as $1 (default 10).
# Used to hold a lock while a concurrent dispatch is attempted.
exec 0</dev/null
secs="${1:-10}"
echo "lock-test holding for ${secs}s on $(hostname)"
sleep "$secs"
echo "lock-test done"
EOF

cat > "$SCRIPT_DIR/allowlist-reload-check.sh" << 'EOF'
#!/bin/sh
# Simple script added after initial setup to verify SIGHUP reload works.
exec 0</dev/null
echo "allowlist-reload-check: ok on $(hostname)"
EOF

cat > "$SCRIPT_DIR/sleep-5.sh" << 'EOF'
#!/bin/sh
# Sleeps 5 seconds. Used for timeout testing (should complete within 10s timeout).
exec 0</dev/null
echo "sleep-5: starting on $(hostname)"
sleep 5
echo "sleep-5: done"
EOF

cat > "$SCRIPT_DIR/sleep-15.sh" << 'EOF'
#!/bin/sh
# Sleeps 15 seconds. Used to trigger the 10s read timeout.
# Will continue running on the agent after the dispatcher times out.
exec 0</dev/null
echo "sleep-15: starting on $(hostname)"
sleep 15
echo "sleep-15: done"
EOF

cat > "$SCRIPT_DIR/sleep-90.sh" << 'EOF'
#!/bin/sh
# Sleeps 90 seconds. Used to verify read_timeout = 120 allows long runs.
exec 0</dev/null
echo "sleep-90: starting on $(hostname)"
sleep 90
echo "sleep-90: done"
EOF

cat > "$SCRIPT_DIR/daemonise-test.sh" << 'EOF'
#!/bin/sh
# Immediately daemonises and returns a job reference via stdout.
# The background job writes its completion to a temp file.
# Demonstrates the async pattern for callers that cannot block.
REQID="job-$$-$(date +%s)"
OUTFILE="/tmp/dispatcher-job-${REQID}.out"

# Fork into background, redirect all output to file
(
    echo "daemonise-test: background job $REQID starting"
    sleep 10
    echo "daemonise-test: background job $REQID complete"
) > "$OUTFILE" 2>&1 &

# Return immediately with job reference
echo "{\"job_id\":\"$REQID\",\"output_file\":\"$OUTFILE\"}"
EOF

chmod 0755 \
    "$SCRIPT_DIR/env-dump.sh" \
    "$SCRIPT_DIR/big-output.sh" \
    "$SCRIPT_DIR/sleep-test.sh" \
    "$SCRIPT_DIR/args-echo.sh" \
    "$SCRIPT_DIR/exit-code.sh" \
    "$SCRIPT_DIR/context-dump.sh" \
    "$SCRIPT_DIR/lock-test.sh" \
    "$SCRIPT_DIR/allowlist-reload-check.sh" \
    "$SCRIPT_DIR/sleep-5.sh" \
    "$SCRIPT_DIR/sleep-15.sh" \
    "$SCRIPT_DIR/sleep-90.sh" \
    "$SCRIPT_DIR/daemonise-test.sh"

echo "Scripts written to $SCRIPT_DIR"

# --- append allowlist entries if missing ---

append_if_missing() {
    local name="$1" path="$2"
    if grep -qE "^${name}\s*=" "$CONF" 2>/dev/null; then
        echo "  $name already in $CONF"
    else
        echo "$name = $path" >> "$CONF"
        echo "  Added: $name = $path"
    fi
}

echo "Updating $CONF ..."
append_if_missing "env-dump"                  "$SCRIPT_DIR/env-dump.sh"
append_if_missing "big-output"               "$SCRIPT_DIR/big-output.sh"
append_if_missing "sleep-test"               "$SCRIPT_DIR/sleep-test.sh"
append_if_missing "args-echo"                "$SCRIPT_DIR/args-echo.sh"
append_if_missing "exit-code"                "$SCRIPT_DIR/exit-code.sh"
append_if_missing "context-dump"             "$SCRIPT_DIR/context-dump.sh"
append_if_missing "lock-test"                "$SCRIPT_DIR/lock-test.sh"
append_if_missing "sleep-5"                  "$SCRIPT_DIR/sleep-5.sh"
append_if_missing "sleep-15"                 "$SCRIPT_DIR/sleep-15.sh"
append_if_missing "sleep-90"                 "$SCRIPT_DIR/sleep-90.sh"
append_if_missing "daemonise-test"           "$SCRIPT_DIR/daemonise-test.sh"
append_if_missing "dispatcher-demonstrator"  "$SCRIPT_DIR/dispatcher-demonstrator.sh"
# allowlist-reload-check is intentionally NOT added here.
# Test 09 adds it manually after setup to verify SIGHUP reload works.

# --- reload allowlist ---

if command -v systemctl >/dev/null 2>&1 && systemctl is-active dispatcher-agent >/dev/null 2>&1; then
    systemctl reload dispatcher-agent 2>/dev/null \
        || systemctl kill --signal=HUP dispatcher-agent
    echo "Sent HUP to dispatcher-agent via systemctl - allowlist reloaded"
elif pgrep -x dispatcher-agent > /dev/null 2>&1; then
    pkill -HUP -x dispatcher-agent
    echo "Sent SIGHUP to dispatcher-agent - allowlist reloaded"
elif pgrep -f 'dispatcher-agent serve' > /dev/null 2>&1; then
    pkill -HUP -f 'dispatcher-agent serve'
    echo "Sent SIGHUP to dispatcher-agent - allowlist reloaded"
else
    echo "WARNING: dispatcher-agent not running - start it before testing"
fi

echo "Done. Verify with: sudo dispatcher-agent ping-self"
