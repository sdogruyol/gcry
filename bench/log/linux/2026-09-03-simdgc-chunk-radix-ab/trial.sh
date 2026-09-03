#!/usr/bin/env bash
# One trial: start server, wrk, read in-load gc-stats, /gc-collect, RSS,
# then 4 extra forced collects sampling phase_mark each time, stop.
# Usage: trial.sh <bin> <path> <arm-label> <outfile> [ENV=VAL ...]
set -uo pipefail
BIN="$1"; PATH_="$2"; ARM="$3"; OUT="$4"; shift 4
PORT="${PORT:-3001}"
DUR="${DUR:-10}"
CONN="${CONN:-50}"
URL="http://127.0.0.1:${PORT}${PATH_}"
SPD="$(dirname "$0")"

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
ERRS="$(echo "$WRKOUT" | awk '/Socket errors/ {print; exit}')"

# in-load snapshot: last collection that ran *under* wrk load + cumulative pause
PRE="$(curl -sf "http://127.0.0.1:${PORT}/gc-stats" 2>/dev/null || echo '{}')"

# forced collect #1, then RSS
curl -sf -o /dev/null "http://127.0.0.1:${PORT}/gc-collect" || true
sleep 0.3
RSS="$(awk '/VmRSS/ {print $2}' /proc/$PID/status 2>/dev/null)"
POST="$(curl -sf "http://127.0.0.1:${PORT}/gc-stats" 2>/dev/null || echo '{}')"

# forced collects #2..#5, sampling phase_mark each time (quiesced heap)
IDLE="[]"
IDLES=""
for k in 2 3 4 5; do
  curl -sf -o /dev/null "http://127.0.0.1:${PORT}/gc-collect" || true
  S="$(curl -sf "http://127.0.0.1:${PORT}/gc-stats" 2>/dev/null || echo '{}')"
  IDLES="$IDLES$S"$'\n'
done

kill $PID 2>/dev/null; wait $PID 2>/dev/null
fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
sleep 0.3

ARM="$ARM" PATHV="$PATH_" RPS="${RPS:-0}" LAT="${LAT:-}" RSS="${RSS:-0}" \
ERRS="$ERRS" PRE="$PRE" POST="$POST" IDLES="$IDLES" OUT="$OUT" \
python3 "$SPD/record.py"
