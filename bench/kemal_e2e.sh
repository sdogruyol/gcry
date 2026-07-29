#!/usr/bin/env bash
# Kemal E2E under gcry process GC (Phase 6.4).
#
# 1. Hit every endpoint; assert status + body shape
# 2. Concurrent wrk load (default 60s; set KEMAL_E2E_DURATION=600 for 10 min DoD)
# 3. Re-check endpoints after load (no crash / hang)
#
# Usage:
#   ./bench/kemal_e2e.sh
#   KEMAL_E2E_DURATION=600 ./bench/kemal_e2e.sh
#   make kemal-e2e
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
KEMAL="$ROOT/bench/kemal"
PORT="${PORT:-3021}"
DURATION="${KEMAL_E2E_DURATION:-60}"
CONNECTIONS="${WRK_CONNECTIONS:-100}"
BASE="http://127.0.0.1:${PORT}"

command -v wrk >/dev/null || { echo "ERROR: wrk not found"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }
mkdir -p "$BIN"

cd "$KEMAL"
shards install --production 2>/dev/null || shards install

echo "Building kemal-gcry-e2e..."
crystal build -Dgc_none --release src/server.cr -o "$BIN/kemal-gcry-e2e"

PORT="$PORT" "$BIN/kemal-gcry-e2e" >/dev/null 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 50); do
  curl -sf -o /dev/null "$BASE/" && break
  sleep 0.1
done
curl -sf -o /dev/null "$BASE/" || { echo "ERROR: server did not start"; exit 1; }

check_endpoints() {
  local label="$1"
  echo "== endpoint checks ($label) =="

  local body
  body="$(curl -sf "$BASE/")"
  [[ "$body" == "Hello World" ]] || { echo "FAIL / : got '$body'"; exit 1; }
  echo "  ok  GET /"

  body="$(curl -sf "$BASE/json")"
  python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d.get('ok') is True
assert 'id' in d and 'user' in d and 'items' in d
assert len(d['items'])==8
" "$body"
  echo "  ok  GET /json"

  body="$(curl -sf "$BASE/gc-collect")"
  python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d.get('ok') is True
assert 'collections' in d
" "$body"
  echo "  ok  GET /gc-collect"

  body="$(curl -sf "$BASE/gc-stats")"
  python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert isinstance(d, dict) and len(d) > 0
" "$body"
  echo "  ok  GET /gc-stats"

  body="$(curl -sf "$BASE/metrics")"
  echo "$body" | grep -q 'gcry_' || { echo "FAIL /metrics: missing gcry_ lines"; exit 1; }
  echo "  ok  GET /metrics"
}

check_endpoints "before load"

echo "== wrk -c ${CONNECTIONS} -d ${DURATION}s /json =="
wrk -c "$CONNECTIONS" -d "${DURATION}s" "$BASE/json"
echo "== wrk -c ${CONNECTIONS} -d ${DURATION}s / =="
# Second path for idle-path sanity; use shorter duration if long run (cap at 30s).
IDLE_DUR="$DURATION"
if [[ "$DURATION" -gt 30 ]]; then
  IDLE_DUR=30
fi
wrk -c "$CONNECTIONS" -d "${IDLE_DUR}s" "$BASE/"

# Force a collect mid-run after load.
curl -sf "$BASE/gc-collect" >/dev/null

check_endpoints "after load"

echo
echo "kemal_e2e OK (duration=${DURATION}s)"
