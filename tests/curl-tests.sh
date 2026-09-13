#!/usr/bin/env bash
# Black-box functional tests for config-server, driven entirely by curl.
# Requires the server to already be running (see README "Setup").
#
# Usage:
#   CONFIG_API_KEY=... BASE_URL=http://localhost:4000 bash tests/curl-tests.sh
#
# If CONFIG_API_KEY is not set in the environment, this script will try to
# read it from a .env file in the project root.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BASE_URL="${BASE_URL:-http://localhost:4000}"
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

if [ -z "${CONFIG_API_KEY:-}" ] && [ -f "$PROJECT_ROOT/.env" ]; then
  CONFIG_API_KEY="$(grep -E '^CONFIG_API_KEY=' "$PROJECT_ROOT/.env" | tail -n1 | cut -d= -f2-)"
fi

if [ -z "${CONFIG_API_KEY:-}" ]; then
  echo "CONFIG_API_KEY is not set and could not be read from .env — aborting." >&2
  exit 1
fi

WRONG_KEY="not-the-real-key-00000000000000000000"
PASS=0
FAIL=0
LAST_BODY=""

# request <description> <expected_status> <curl args...>
# Runs in the current shell (no command substitution) so PASS/FAIL counters
# persist. Response body is left in $LAST_BODY for follow-up assertions.
request() {
  local desc="$1" expected="$2"
  shift 2
  local status
  status="$(curl -s -o "$BODY_FILE" -w '%{http_code}' "$@")"
  LAST_BODY="$(cat "$BODY_FILE")"
  if [ "$status" = "$expected" ]; then
    echo "PASS: $desc (status $status)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected $expected, got $status) body=$LAST_BODY"
    FAIL=$((FAIL + 1))
  fi
}

# body_contains <description> <needle>
# Asserts $LAST_BODY (set by the preceding request call) contains <needle>.
body_contains() {
  local desc="$1" needle="$2"
  if printf '%s' "$LAST_BODY" | grep -qF "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (body did not contain '$needle'): $LAST_BODY"
    FAIL=$((FAIL + 1))
  fi
}

echo "== config-server functional tests against $BASE_URL =="
echo

echo "-- health check (no auth) --"
request "GET /health" 200 "$BASE_URL/health"
body_contains "health reports ok" '"status":"ok"'

echo
echo "-- auth enforcement --"
request "GET /config with no API key" 401 "$BASE_URL/config"
request "GET /config with wrong API key" 401 -H "x-api-key: $WRONG_KEY" "$BASE_URL/config"
request "GET /health ignores API key requirement even with wrong key" 200 -H "x-api-key: $WRONG_KEY" "$BASE_URL/health"

echo
echo "-- basic CRUD flow --"
request "GET /config/testkey before it exists" 404 \
  -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config/testkey"

request "PUT /config/testkey" 200 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X PUT -d '{"value":"hello-world"}' "$BASE_URL/config/testkey"
body_contains "PUT response echoes value" '"value":"hello-world"'

request "GET /config/testkey after set" 200 \
  -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config/testkey"
body_contains "GET single key returns value" '"value":"hello-world"'

request "GET /config (all keys) includes testkey" 200 \
  -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config"
body_contains "GET all keys contains testkey" '"testkey":"hello-world"'

request "PUT /config/testkey without value in body" 400 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X PUT -d '{}' "$BASE_URL/config/testkey"
body_contains "400 error message present" 'must include'

request "DELETE /config/testkey" 200 \
  -H "x-api-key: $CONFIG_API_KEY" -X DELETE "$BASE_URL/config/testkey"
body_contains "DELETE response confirms key" '"deleted":"testkey"'

request "GET /config/testkey after delete" 404 \
  -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config/testkey"

request "DELETE /config/testkey again (already gone)" 404 \
  -H "x-api-key: $CONFIG_API_KEY" -X DELETE "$BASE_URL/config/testkey"

echo
echo "-- non-string value (JSON object) --"
request "PUT /config/objkey with object value" 200 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X PUT -d '{"value":{"nested":true,"n":42}}' "$BASE_URL/config/objkey"
body_contains "PUT echoes nested object" '"nested":true'

request "GET /config/objkey returns nested object" 200 \
  -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config/objkey"
body_contains "GET returns nested object" '"n":42'

request "cleanup: DELETE /config/objkey" 200 \
  -H "x-api-key: $CONFIG_API_KEY" -X DELETE "$BASE_URL/config/objkey"

echo
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
