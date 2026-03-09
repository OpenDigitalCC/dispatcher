#!/bin/bash
# 11-api-status.sh
#
# Tests the dispatcher-api HTTP server on port 7445.
#
# Covers:
#   1. POST /run - reqid present in response alongside results
#   2. GET /status/{reqid} - record contains expected fields
#   3. GET /status/{reqid} - unknown reqid returns 404
#   4. Results purged after TTL (tested with a patched short TTL if possible,
#      otherwise documented as a manual check)
#
# Prerequisites:
#   - dispatcher-api must be running on port 7445
#   - API_HOST defaults to localhost; override with API_HOST=<host>
#   - API_PORT defaults to 7445; override with API_PORT=<port>
#   - Uses curl; install with: apt install curl / opkg install curl
#
# Note: the API is plain HTTP by default. If TLS is configured, set
# API_SCHEME=https and ensure the cert is trusted or pass -k via CURL_OPTS.

set -uo pipefail
source "${_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib.sh"

require_agents 1

API_HOST="${API_HOST:-localhost}"
API_PORT="${API_PORT:-7445}"
API_SCHEME="${API_SCHEME:-http}"
API_BASE="${API_SCHEME}://${API_HOST}:${API_PORT}"
CURL_OPTS="${CURL_OPTS:--s -f}"   # -s silent, -f fail on HTTP errors

# --- helper: curl the API ---
api_get() {
    local path="$1"
    API_OUT=$(curl $CURL_OPTS -X GET "${API_BASE}${path}" 2>&1)
    API_RC=$?
}

api_get_raw() {
    # Returns HTTP status code separately; does not use -f
    local path="$1"
    API_HTTP_STATUS=$(curl -s -o /tmp/_api_body -w "%{http_code}" \
        -X GET "${API_BASE}${path}" 2>/dev/null)
    API_OUT=$(cat /tmp/_api_body 2>/dev/null)
    API_RC=0
}

api_post() {
    local path="$1" body="$2"
    API_OUT=$(curl $CURL_OPTS -X POST \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${API_BASE}${path}" 2>&1)
    API_RC=$?
}

api_post_raw() {
    local path="$1" body="$2"
    API_HTTP_STATUS=$(curl -s -o /tmp/_api_body -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${API_BASE}${path}" 2>/dev/null)
    API_OUT=$(cat /tmp/_api_body 2>/dev/null)
    API_RC=0
}

# --- check API is reachable before proceeding ---
if ! curl -s --connect-timeout 3 "${API_BASE}/" >/dev/null 2>&1 && \
   ! curl -s --connect-timeout 3 "${API_BASE}/status/probe" >/dev/null 2>&1; then
    # A 404 from the API is still reachable; a connection refused is not
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 "${API_BASE}/status/probe" 2>/dev/null)
    if [ "$HTTP_CODE" = "000" ]; then
        skip "All API tests" \
            "dispatcher-api not reachable at ${API_BASE} - start it with: dispatcher-api"
        summary
        exit 0
    fi
fi

# ============================================================
describe "API: POST /run - reqid present in response"
# ============================================================
# Run env-dump via the API. The response should be the same JSON structure
# as the CLI --json output, but with reqid at the top level.

api_post_raw "/run" "{\"hosts\":[\"${AGENT1}\"],\"script\":\"env-dump\"}"

if echo "$API_OUT" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
    pass "POST /run returns valid JSON"
else
    fail "POST /run returns valid JSON" "output: $API_OUT"
fi

if [ "$API_HTTP_STATUS" = "200" ]; then
    pass "POST /run returns HTTP 200"
else
    fail "POST /run returns HTTP 200" "got: $API_HTTP_STATUS"
fi

RUN_REQID=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
print(data.get('reqid', ''))
" "$API_OUT" 2>/dev/null)

[ -n "$RUN_REQID" ] \
    && pass "top-level reqid present: $RUN_REQID" \
    || fail "top-level reqid present" "output: $API_OUT"

# Confirm results also present alongside reqid
RESULTS_LEN=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
print(len(data.get('results', [])))
" "$API_OUT" 2>/dev/null)

[ "${RESULTS_LEN:-0}" -ge 1 ] \
    && pass "results array present alongside reqid ($RESULTS_LEN entries)" \
    || fail "results array present alongside reqid" "output: $API_OUT"

# ============================================================
describe "API: GET /status/{reqid} - stored record has expected fields"
# ============================================================

if [ -z "$RUN_REQID" ]; then
    skip "Status record checks" "no reqid from POST /run"
else
    api_get_raw "/status/${RUN_REQID}"

    if [ "$API_HTTP_STATUS" = "200" ]; then
        pass "GET /status/${RUN_REQID} returns HTTP 200"
    else
        fail "GET /status/${RUN_REQID} returns HTTP 200" \
            "got: $API_HTTP_STATUS  body: $API_OUT"
    fi

    if echo "$API_OUT" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
        pass "status record is valid JSON"
    else
        fail "status record is valid JSON" "output: $API_OUT"
    fi

    for field in script hosts completed results; do
        VALUE=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
val = data.get('$field')
print('present' if val is not None else 'missing')
" "$API_OUT" 2>/dev/null)
        [ "$VALUE" = "present" ] \
            && pass "status record has field: $field" \
            || fail "status record has field: $field" \
                "missing from: $API_OUT"
    done

    # Confirm results contain the host we ran against
    HOST_IN_RESULTS=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
results = data.get('results', [])
hosts = [r.get('host','') for r in results]
print('yes' if '${AGENT1}' in hosts else 'no')
" "$API_OUT" 2>/dev/null)
    [ "$HOST_IN_RESULTS" = "yes" ] \
        && pass "results contain $AGENT1" \
        || fail "results contain $AGENT1" "output: $API_OUT"

    # completed should be a non-empty timestamp-like string
    COMPLETED=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
print(data.get('completed', ''))
" "$API_OUT" 2>/dev/null)
    [ -n "$COMPLETED" ] \
        && pass "completed timestamp present: $COMPLETED" \
        || fail "completed timestamp present" "output: $API_OUT"
fi

# ============================================================
describe "API: GET /status/{reqid} - unknown reqid returns 404"
# ============================================================

FAKE_REQID="deadbeef"
api_get_raw "/status/${FAKE_REQID}"

if [ "$API_HTTP_STATUS" = "404" ]; then
    pass "unknown reqid returns HTTP 404"
else
    fail "unknown reqid returns HTTP 404" \
        "got: $API_HTTP_STATUS  body: $API_OUT"
fi

# Body should have some error indication, not be empty
[ -n "$API_OUT" ] \
    && pass "404 response has non-empty body" \
    || fail "404 response has non-empty body" "body was empty"

# ============================================================
describe "API: GET /status/{reqid} - multi-host run stored correctly"
# ============================================================

if [ "${#AGENTS[@]}" -ge 2 ]; then
    HOSTS_JSON=$(printf '"%s",' "${AGENTS[@]}" | sed 's/,$//')
    api_post_raw "/run" "{\"hosts\":[${HOSTS_JSON}],\"script\":\"env-dump\"}"

    MULTI_REQID=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
print(data.get('reqid', ''))
" "$API_OUT" 2>/dev/null)

    if [ -n "$MULTI_REQID" ]; then
        api_get_raw "/status/${MULTI_REQID}"

        RESULT_COUNT=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
print(len(data.get('results', [])))
" "$API_OUT" 2>/dev/null)

        [ "${RESULT_COUNT:-0}" -eq "${#AGENTS[@]}" ] \
            && pass "status record contains ${#AGENTS[@]} results for multi-host run" \
            || fail "status record contains ${#AGENTS[@]} results for multi-host run" \
                "got $RESULT_COUNT"

        HOSTS_STORED=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
hosts = data.get('hosts', [])
print('yes' if len(hosts) == ${#AGENTS[@]} else 'no')
" "$API_OUT" 2>/dev/null)
        [ "$HOSTS_STORED" = "yes" ] \
            && pass "hosts field records all targets" \
            || fail "hosts field records all targets" "output: $API_OUT"
    else
        skip "Multi-host status check" "POST /run did not return reqid"
    fi
else
    skip "Multi-host status check" "only 1 agent reachable"
fi

# ============================================================
describe "API: results TTL - purge after expiry"
# ============================================================
# Full 24-hour TTL cannot be tested in a normal test run.
# We verify the behaviour is testable by checking whether the API
# binary supports a reduced TTL flag or env var, and document the
# manual approach if not.

# Check if dispatcher-api accepts a --ttl or TTL env var
TTL_SUPPORTED=0
if dispatcher-api --help 2>&1 | grep -qi "ttl"; then
    TTL_SUPPORTED=1
fi

if [ "$TTL_SUPPORTED" = "1" ]; then
    # Start a short-lived API instance, store a result, wait for purge
    # (Implementation depends on the actual --ttl interface)
    skip "TTL purge test" \
        "--ttl flag detected but automated purge test not yet implemented"
else
    skip "TTL purge test" \
        "24h TTL cannot be fast-forwarded without API support - verify manually: \
store a result, adjust system clock or wait, confirm GET /status/{reqid} returns 404"
fi

summary
