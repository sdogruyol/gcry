#!/usr/bin/env bash
# One trial: start server, wrk, gc-collect, RSS, gc-stats, stop.
# Usage: trial.sh <bin> <path> <arm-label> <outfile> [ENV=VAL ...]
set -uo pipefail
BIN="$1"; PATH_="$2"; ARM="$3"; OUT="$4"; shift 4
PORT="${PORT:-3001}"
DUR="${DUR:-10}"
CONN="${CONN:-50}"
URL="http://127.0.0.1:${PORT}${PATH_}"

fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
sleep 0.4

env PORT="$PORT" "$@" "$BIN" >/dev/null 2>&1 &
PID=$!

ready=0
for i in $(seq 1 100); do
  if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/"; then ready=1; break; fi
  sleep 0.1
done
if [[ $ready -eq 0 ]]; then
  echo "{\"arm\":\"$ARM\",\"path\":\"$PATH_\",\"error\":\"not_ready\"}" >> "$OUT"
  kill -9 $PID 2>/dev/null; exit 1
fi

WRKOUT="$(wrk -c "$CONN" -d "$DUR" "$URL" 2>&1)"
RPS="$(echo "$WRKOUT" | awk '/Requests\/sec:/ {print $2}')"
LAT="$(echo "$WRKOUT" | awk '/Latency/ {print $2; exit}')"

curl -sf -o /dev/null "http://127.0.0.1:${PORT}/gc-collect" || true
sleep 0.3
RSS="$(awk '/VmRSS/ {print $2}' /proc/$PID/status 2>/dev/null)"
STATS="$(curl -sf "http://127.0.0.1:${PORT}/gc-stats" 2>/dev/null || echo '{}')"
P50="$(echo "$STATS" | grep -o '"pause_p50_ns":[0-9]*' | cut -d: -f2)"

kill $PID 2>/dev/null; wait $PID 2>/dev/null
fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
sleep 0.3

echo "{\"arm\":\"$ARM\",\"path\":\"$PATH_\",\"rps\":${RPS:-0},\"lat_avg\":\"${LAT:-}\",\"rss_kib\":${RSS:-0},\"pause_p50_ns\":${P50:-0},\"ts\":$(date +%s)}" >> "$OUT"
echo "  [$ARM $PATH_] rps=$RPS rss=${RSS}KiB p50=${P50}ns"
