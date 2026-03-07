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
yes "line of output from $(hostname)" | head -10000
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

chmod 0755 \
    "$SCRIPT_DIR/env-dump.sh" \
    "$SCRIPT_DIR/big-output.sh" \
    "$SCRIPT_DIR/sleep-test.sh" \
    "$SCRIPT_DIR/args-echo.sh" \
    "$SCRIPT_DIR/exit-code.sh" \
    "$SCRIPT_DIR/context-dump.sh"

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
append_if_missing "env-dump"         "$SCRIPT_DIR/env-dump.sh"
append_if_missing "big-output"       "$SCRIPT_DIR/big-output.sh"
append_if_missing "sleep-test"       "$SCRIPT_DIR/sleep-test.sh"
append_if_missing "args-echo"        "$SCRIPT_DIR/args-echo.sh"
append_if_missing "exit-code"        "$SCRIPT_DIR/exit-code.sh"
append_if_missing "context-dump"     "$SCRIPT_DIR/context-dump.sh"
append_if_missing "dispatcher-demonstrator" "$SCRIPT_DIR/dispatcher-demonstrator.sh"

# --- reload allowlist ---

if pgrep -f dispatcher-agent > /dev/null 2>&1; then
    kill -HUP "$(pgrep -f dispatcher-agent | head -1)"
    echo "Sent SIGHUP to dispatcher-agent - allowlist reloaded"
else
    echo "WARNING: dispatcher-agent not running - start it before testing"
fi

echo "Done. Verify with: sudo dispatcher-agent ping-self"
