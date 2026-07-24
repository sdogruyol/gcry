#!/usr/bin/env bash
# Short Kemal A/B smoke for CI. Fails if gcry /json thr < MIN_PCT% of Boehm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
KEMAL="$ROOT/bench/kemal"
PORT="${PORT:-3011}"
DURATION="${WRK_DURATION:-5}"
CONNECTIONS="${WRK_CONNECTIONS:-50}"
MIN_PCT="${MIN_PCT:-70}"
BASE="http://127.0.0.1:${PORT}"

command -v wrk >/dev/null || { echo "wrk not found"; exit 1; }
mkdir -p "$BIN"

cd "$KEMAL"
shards install --production 2>/dev/null || shards install

echo "Building kemal-boehm..."
crystal build --release src/server.cr -o "$BIN/kemal-boehm-smoke"
echo "Building kemal-gcry..."
crystal build -Dgc_none --release src/server.cr -o "$BIN/kemal-gcry-smoke"

parse_rps() {
  # wrk prints "Requests/sec:  12345.67"
  awk '/Requests\/sec/ {print $2; exit}'
}

run_path() {
  local bin="$1" path="$2"
  PORT="$PORT" "$bin" &
  local pid=$!
  trap 'kill $pid 2>/dev/null || true' RETURN
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null "$BASE/" && break
    sleep 0.2
  done
  wrk -c "$CONNECTIONS" -d "${DURATION}s" "${BASE}${path}" | parse_rps
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  sleep 0.3
}

echo "=== Boehm /json ==="
BOEHM_RPS="$(run_path "$BIN/kemal-boehm-smoke" /json)"
echo "Boehm req/s: $BOEHM_RPS"

echo "=== gcry /json ==="
GCRY_RPS="$(run_path "$BIN/kemal-gcry-smoke" /json)"
echo "gcry req/s: $GCRY_RPS"

PCT="$(awk -v g="$GCRY_RPS" -v b="$BOEHM_RPS" 'BEGIN { if (b+0==0) { print 0; exit } printf "%.1f", (g/b)*100 }')"
echo "gcry /json = ${PCT}% of Boehm (gate >= ${MIN_PCT}%)"

awk -v p="$PCT" -v m="$MIN_PCT" 'BEGIN { exit !(p+0 >= m+0) }' || {
  echo "FAIL: ${PCT}% < ${MIN_PCT}%"
  exit 1
}
echo "PASS"
