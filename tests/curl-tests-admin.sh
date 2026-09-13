#!/usr/bin/env bash
# Black-box functional tests for the admin routes (admin.js), driven by curl.
# Requires the server to already be running (see README "Setup").
#
# Usage:
#   CONFIG_API_KEY=... BASE_URL=http://localhost:4000 bash tests/curl-tests-admin.sh
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

PASS=0
FAIL=0
LAST_BODY=""

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

body_not_contains() {
  local desc="$1" needle="$2"
  if printf '%s' "$LAST_BODY" | grep -qF "$needle"; then
    echo "FAIL: $desc (body unexpectedly contained '$needle'): $LAST_BODY"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

echo "== admin route functional tests against $BASE_URL =="
echo

echo "-- auth enforcement on admin routes --"
request "GET /admin/stats with no API key" 401 "$BASE_URL/admin/stats"
request "GET /admin/export with no API key" 401 "$BASE_URL/admin/export"

echo
echo "-- seed some data via the regular config API --"
request "PUT /config/adminkey1" 200 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X PUT -d '{"value":"one"}' "$BASE_URL/config/adminkey1"
request "PUT /config/adminkey2" 200 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X PUT -d '{"value":"two"}' "$BASE_URL/config/adminkey2"

echo
echo "-- /admin/stats --"
request "GET /admin/stats" 200 -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/admin/stats"
body_contains "stats includes keyCount" '"keyCount"'
body_contains "stats includes uptimeSeconds" '"uptimeSeconds"'
body_contains "stats includes dataFile" '"dataFile"'

echo
echo "-- /admin/export --"
request "GET /admin/export" 200 -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/admin/export"
body_contains "export includes adminkey1" '"adminkey1":"one"'
body_contains "export includes adminkey2" '"adminkey2":"two"'

echo
echo "-- /admin/import (merge mode, default) --"
request "POST /admin/import merge" 200 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X POST -d '{"data":{"adminkey3":"three"}}' "$BASE_URL/admin/import"
body_contains "import reports imported count" '"imported":1'
body_contains "import reports merge mode" '"mode":"merge"'

request "GET /config/adminkey3 exists after merge import" 200 \
  -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config/adminkey3"
request "GET /config/adminkey1 still exists after merge import" 200 \
  -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config/adminkey1"

echo
echo "-- /admin/import rejects unsafe keys (prototype pollution guard) --"
request "POST /admin/import with __proto__ key" 400 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X POST -d '{"data":{"__proto__":{"polluted":true}}}' "$BASE_URL/admin/import"
body_contains "rejects __proto__" 'not allowed'

echo
echo "-- PUT /config/__proto__ also rejected (regular route guard) --"
request "PUT /config/__proto__" 400 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X PUT -d '{"value":{"polluted":true}}' "$BASE_URL/config/__proto__"
body_contains "PUT __proto__ rejected" 'not allowed'

echo
echo "-- /admin/import (replace mode) --"
request "POST /admin/import replace" 200 \
  -H "x-api-key: $CONFIG_API_KEY" -H "Content-Type: application/json" \
  -X POST -d '{"data":{"onlykey":"onlyvalue"},"mode":"replace"}' "$BASE_URL/admin/import"
body_contains "import reports replace mode" '"mode":"replace"'

request "GET /config after replace only has onlykey" 200 \
  -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config"
body_contains "replaced store contains onlykey" '"onlykey":"onlyvalue"'
body_not_contains "replaced store no longer contains adminkey1" 'adminkey1'

echo
echo "-- /admin/reload --"
request "POST /admin/reload" 200 -H "x-api-key: $CONFIG_API_KEY" -X POST "$BASE_URL/admin/reload"
body_contains "reload reports reloaded true" '"reloaded":true'
body_contains "reload reports correct keyCount" '"keyCount":1'

echo
echo "-- /admin/clear --"
request "DELETE /admin/clear" 200 -H "x-api-key: $CONFIG_API_KEY" -X DELETE "$BASE_URL/admin/clear"
body_contains "clear reports cleared count" '"cleared":1'

request "GET /config is empty after clear" 200 -H "x-api-key: $CONFIG_API_KEY" "$BASE_URL/config"
body_not_contains "cleared store has no onlykey" 'onlykey'

echo
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
