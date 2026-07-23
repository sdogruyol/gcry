#!/usr/bin/env bash
# Record Kemal wrk for PREV tag vs current tree (same host, back-to-back).
# Measures both / and /json. Usage:
#   PREV=v0.2.0 LABEL=0.3.0 ./bench/record_kemal.sh
#   make bench-kemal-record PREV=v0.2.0 LABEL=0.3.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREV="${PREV:-}"
LABEL="${LABEL:-}"
PORT="${PORT:-3001}"
WRK_CONNECTIONS="${WRK_CONNECTIONS:-100}"
WRK_DURATION="${WRK_DURATION:-30}"
BASE_URL="${WRK_BASE_URL:-http://127.0.0.1:${PORT}}"
PATHS="${WRK_PATHS:-/ /json}"
WORKTREE="${TMPDIR:-/tmp}/gcry-perf-${PREV}"

if [[ -z "$PREV" || -z "$LABEL" ]]; then
  echo "usage: PREV=v0.2.0 LABEL=0.3.0 $0" >&2
  exit 1
fi

command -v wrk >/dev/null || { echo "wrk not found" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }

mkdir -p bin
fuser -k "${PORT}/tcp" 2>/dev/null || true
sleep 0.3

cleanup() {
  fuser -k "${PORT}/tcp" 2>/dev/null || true
  if [[ -d "$WORKTREE" ]]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  fi
}
trap cleanup EXIT

start_server() {
  local bin="$1" log="$2"
  PORT="$PORT" "$bin" >"$log" 2>&1 &
  echo $!
}

wait_ready() {
  local i
  for i in $(seq 1 60); do
    if curl -sf -o /dev/null "${BASE_URL}/"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

stop_server() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fuser -k "${PORT}/tcp" 2>/dev/null || true
  sleep 0.3
}

parse_rps() { grep -E 'Requests/sec:' "$1" | awk '{print $2}'; }
parse_lat_avg() { awk '/Latency/ {print $2; exit}' "$1"; }
parse_lat_max() { awk '/Latency/ {print $4; exit}' "$1"; }

delta_rps() {
  python3 -c "pr=float('$1'); cr=float('$2'); print(f'{(cr-pr)/pr*100:+.1f}%')"
}

delta_lat() {
  python3 -c "
import re
pl=float(re.match(r'([0-9.]+)', '$1').group(1))
cl=float(re.match(r'([0-9.]+)', '$2').group(1))
print(f'{(cl-pl)/pl*100:+.1f}%')
"
}

path_slug() {
  local p="$1"
  if [[ "$p" == "/" ]]; then
    echo "root"
  else
    echo "${p#/}" | tr '/' '-'
  fi
}

CRYSTAL_VER="$(crystal --version | head -1 | awk '{print $2}')"
HOST="$(uname -srm)"
DATE_UTC="$(date -u +%Y-%m-%d)"

echo "=== previous $PREV (worktree) ==="
rm -rf "$WORKTREE"
git worktree add --detach "$WORKTREE" "$PREV" >/dev/null
(
  cd "$WORKTREE/bench/kemal"
  shards install >/dev/null
  crystal build -Dgc_none --release src/server.cr -o "$ROOT/bin/kemal-gcry-prev"
)

echo "=== current $LABEL (working tree) ==="
(
  cd bench/kemal
  shards install >/dev/null
  crystal build -Dgc_none --release src/server.cr -o ../../bin/kemal-gcry-curr
)

echo
echo "=== paste into docs/PERF.md History ==="

for path in $PATHS; do
  slug="$(path_slug "$path")"
  url="${BASE_URL}${path}"

  echo
  echo "--- path ${path} (prev ${PREV}) ---"
  pid="$(start_server ./bin/kemal-gcry-prev "/tmp/kemal-prev-${LABEL}-${slug}.log")"
  if ! wait_ready; then
    echo "prev server failed for ${path}" >&2
    stop_server "$pid"
    exit 1
  fi
  # Confirm path exists (older tags may lack /json).
  if ! curl -sf -o /dev/null "$url"; then
    echo "SKIP ${path}: not available on ${PREV}"
    stop_server "$pid"
    continue
  fi
  wrk -c "$WRK_CONNECTIONS" -d "$WRK_DURATION" "$url" | tee "/tmp/wrk-prev-${LABEL}-${slug}.txt"
  stop_server "$pid"

  echo "--- path ${path} (curr ${LABEL}) ---"
  pid="$(start_server ./bin/kemal-gcry-curr "/tmp/kemal-curr-${LABEL}-${slug}.log")"
  if ! wait_ready; then
    echo "curr server failed for ${path}" >&2
    stop_server "$pid"
    exit 1
  fi
  wrk -c "$WRK_CONNECTIONS" -d "$WRK_DURATION" "$url" | tee "/tmp/wrk-curr-${LABEL}-${slug}.txt"
  stop_server "$pid"

  PREV_RPS="$(parse_rps "/tmp/wrk-prev-${LABEL}-${slug}.txt")"
  PREV_LAVG="$(parse_lat_avg "/tmp/wrk-prev-${LABEL}-${slug}.txt")"
  PREV_LMAX="$(parse_lat_max "/tmp/wrk-prev-${LABEL}-${slug}.txt")"
  CURR_RPS="$(parse_rps "/tmp/wrk-curr-${LABEL}-${slug}.txt")"
  CURR_LAVG="$(parse_lat_avg "/tmp/wrk-curr-${LABEL}-${slug}.txt")"
  CURR_LMAX="$(parse_lat_max "/tmp/wrk-curr-${LABEL}-${slug}.txt")"
  DR="$(delta_rps "$PREV_RPS" "$CURR_RPS")"
  DL="$(delta_lat "$PREV_LAVG" "$CURR_LAVG")"
  RPS_INT="${CURR_RPS%%.*}"

  echo "| ${LABEL} | ${path} | ${DATE_UTC} | ${CRYSTAL_VER} | ${HOST} | **${RPS_INT}** | ${CURR_LAVG} | ${CURR_LMAX} | **${DR}** | **${DL}** | Same host vs ${PREV}. |"
  echo "  prev: req/s=${PREV_RPS} lat.avg=${PREV_LAVG} lat.max=${PREV_LMAX}"
  echo "  curr: req/s=${CURR_RPS} lat.avg=${CURR_LAVG} lat.max=${CURR_LMAX}"
  echo "  CHANGELOG: Kemal wrk ${path} vs ${PREV}: ${DR} req/s, ${DL} lat.avg (see docs/PERF.md)."
done
