#!/bin/bash
# dispatcher-demonstrator.sh
#
# Demonstrates dispatcher capabilities: stdout, stderr, exit codes,
# argument passing, JSON stdin context, and agent-side information.
#
# Add to /etc/dispatcher-agent/scripts.conf:
#   dispatcher-demonstrator  /opt/dispatcher-scripts/dispatcher-demonstrator.sh
#
# Then run from the dispatcher host (replace <agent> with your agent hostname):
#
#   sudo dispatcher run <agent> dispatcher-demonstrator -- stdout
#   sudo dispatcher run <agent> dispatcher-demonstrator -- stderr
#   sudo dispatcher run <agent> dispatcher-demonstrator -- exit-ok
#   sudo dispatcher run <agent> dispatcher-demonstrator -- exit-fail
#   sudo dispatcher run <agent> dispatcher-demonstrator -- args hello world
#   sudo dispatcher run <agent> dispatcher-demonstrator -- args "$(date)" "from $(_hostname)"
#   sudo dispatcher run <agent> dispatcher-demonstrator -- log-context
#   sudo dispatcher run <agent> dispatcher-demonstrator -- log-fields
#   sudo dispatcher run <agent> dispatcher-demonstrator -- log-fields -- --env prod
#   sudo dispatcher run <agent> dispatcher-demonstrator -- agent-info

set -euo pipefail

SYSLOG_TAG="dispatcher-demo"

# --- JSON extraction (bash only, no jq or python3 required) ---

# Extract a string value from flat JSON by field name.
# Handles both quoted and unquoted values. Sufficient for the
# known fixed structure of the dispatcher context object.
json_field() {
    local field="$1" json="$2"
    echo "$json" | grep -o "\"${field}\":[^,}]*" | head -1 \
        | sed 's/^"[^"]*":[[:space:]]*//' \
        | sed 's/^"\(.*\)"$/\1/' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# --- interactive usage (not invoked via dispatcher) ---

usage() {
    cat << 'EOF'

dispatcher-demonstrator.sh

This script is designed to be run via the dispatcher, not directly.
It demonstrates dispatcher capabilities through a set of named subcommands.

To enable, add to /etc/dispatcher-agent/scripts.conf on this host:

  dispatcher-demonstrator  /opt/dispatcher-scripts/dispatcher-demonstrator.sh

Then run the following from the dispatcher host (replace <agent> with this
hostname):

  Subcommand       Dispatcher command
  ───────────────────────────────────────────────────────────────────────────
  stdout           sudo dispatcher run <agent> dispatcher-demonstrator -- stdout
                   Shows that script stdout is returned to the dispatcher.

  stderr           sudo dispatcher run <agent> dispatcher-demonstrator -- stderr
                   Shows that script stderr is also captured and returned.

  exit-ok          sudo dispatcher run <agent> dispatcher-demonstrator -- exit-ok
                   Shows a clean exit 0 reported as OK on the dispatcher.

  exit-fail        sudo dispatcher run <agent> dispatcher-demonstrator -- exit-fail
                   Shows exit 42 reported as FAIL with the exit code.

  args             sudo dispatcher run <agent> dispatcher-demonstrator -- args hello world
                   Shows args arriving intact at the agent.

  args (dynamic)   sudo dispatcher run <agent> dispatcher-demonstrator -- args "$(date)" "from $(_hostname)"
                   Shows dynamic args evaluated on the dispatcher host,
                   arriving as static strings at the agent.

  log-context      sudo dispatcher run <agent> dispatcher-demonstrator -- log-context
                   Logs the full JSON context to syslog on the agent.
                   Check: journalctl -t dispatcher-demo (or /var/log/syslog)

  log-fields       sudo dispatcher run <agent> dispatcher-demonstrator -- log-fields
                   Extracts and logs individual context fields to syslog.

  log-fields (args) sudo dispatcher run <agent> dispatcher-demonstrator -- log-fields -- --env prod
                   Shows args appearing in both $@ and the JSON context.

  agent-info       sudo dispatcher run <agent> dispatcher-demonstrator -- agent-info
                   Returns hostname, platform, and uptime from the agent.
                   Contrast with: sudo dispatcher run <agent> dispatcher-demonstrator -- args "$(uptime)"
                   which sends the dispatcher's uptime as an argument.
  ───────────────────────────────────────────────────────────────────────────

EOF
    exit 0
}

# --- portable command fallbacks ---
# hostname and whoami may be absent on minimal systems (e.g. OpenWRT BusyBox)

_hostname() {
    if command -v hostname >/dev/null 2>&1; then
        hostname
    else
        cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown"
    fi
}

_whoami() {
    if command -v whoami >/dev/null 2>&1; then
        whoami
    else
        id -un 2>/dev/null || id -u 2>/dev/null || echo "unknown"
    fi
}

# --- read stdin (JSON context from dispatcher) ---
# Must be read before any subcommand runs. If stdin is a tty
# (interactive), skip reading and show usage instead.

if [ -t 0 ]; then
    usage
fi

CONTEXT=$(cat)

# --- subcommand dispatch ---

CMD="${1:-}"
shift || true   # remaining $@ are the script args passed after --

case "$CMD" in

    stdout)
        echo "Hello from $(_hostname) - this is stdout returned to the dispatcher."
        ;;

    stderr)
        echo "This line goes to stdout." >&1
        echo "This line goes to stderr - also captured and returned." >&2
        ;;

    exit-ok)
        echo "Exiting cleanly with exit code 0."
        exit 0
        ;;

    exit-fail)
        echo "About to exit with code 42." >&2
        exit 42
        ;;

    args)
        echo "Received $# arg(s):"
        i=1
        for arg in "$@"; do
            echo "  [$i] $arg"
            i=$((i + 1))
        done
        ;;

    log-context)
        echo "$CONTEXT" | logger -t "$SYSLOG_TAG"
        echo "Full JSON context logged to syslog on $(_hostname) under tag: $SYSLOG_TAG"
        ;;

    log-fields)
        reqid=$(json_field "reqid"    "$CONTEXT")
        user=$(json_field  "username" "$CONTEXT")
        script=$(json_field "script"  "$CONTEXT")

        logger -t "$SYSLOG_TAG" "reqid=$reqid user=$user script=$script args=$*"
        echo "Fields logged to syslog on $(_hostname) under tag: $SYSLOG_TAG"
        echo "  reqid:    $reqid"
        echo "  user:     $user"
        echo "  script:   $script"
        echo "  args:     $*"
        ;;

    agent-info)
        echo "hostname:  $(_hostname)"
        echo "platform:  $(uname -s -r -m)"
        echo "uptime:    $(uptime)"
        echo "whoami:    $(_whoami)"
        echo ""
        echo "Note: run with -- \"\$(uptime)\" to send the dispatcher's uptime instead."
        ;;

    *)
        echo "Unknown subcommand: '$CMD'" >&2
        echo "Run this script directly (without dispatcher) to see available subcommands." >&2
        exit 1
        ;;

esac
