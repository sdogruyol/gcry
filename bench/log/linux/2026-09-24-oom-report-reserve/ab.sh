#!/usr/bin/env bash
# Paired A/B of two Kemal binaries on /json. Order alternates per trial.
set -eu
A_BIN="$1"; B_BIN="$2"
PORT="${PORT:-3043}"; BASE="http://127.0.0.1:${PORT}"
DURATION="${WRK_DURATION:-10}"; CONNECTIONS="${WRK_CONNECTIONS:-50}"; TRIALS="${TRIALS:-12}"
OUT="${OUT:-$HOME/.cache/ab/ab.jsonl}"
export PATH=$HOME/.cache/wrkdeb/bin:$PATH

run_arm() {
  PORT="$PORT" "$1" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 40); do curl -sf -o /dev/null "$BASE/" && break; sleep 0.2; done
  wrk -c "$CONNECTIONS" -d 3s "${BASE}/json" >/dev/null 2>&1
  local rps
  rps="$(wrk -c "$CONNECTIONS" -d "${DURATION}s" "${BASE}/json" | awk '/Requests\/sec/ {print $2; exit}')"
  local rss=0
  [ -r "/proc/$pid/status" ] && rss="$(awk '/^VmHWM:/ {print $2; exit}' "/proc/$pid/status")"
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true; sleep 0.5
  echo "$rps $rss"
}

: > "$OUT"
for i in $(seq 1 "$TRIALS"); do
  if [ $((i % 2)) -eq 1 ]; then
    read -r a_rps a_rss <<<"$(run_arm "$A_BIN")"; read -r b_rps b_rss <<<"$(run_arm "$B_BIN")"
  else
    read -r b_rps b_rss <<<"$(run_arm "$B_BIN")"; read -r a_rps a_rss <<<"$(run_arm "$A_BIN")"
  fi
  printf '{"trial":%d,"a_rps":%s,"b_rps":%s,"a_hwm":%s,"b_hwm":%s}\n' "$i" "$a_rps" "$b_rps" "$a_rss" "$b_rss" >> "$OUT"
  echo "trial $i: a $a_rps b $b_rps"
done
python3 - "$OUT" <<'PY'
import json, statistics, sys, math
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
d = [r["b_rps"] / r["a_rps"] for r in rows]
n = len(d); m = statistics.mean(d); sd = statistics.stdev(d)
se = sd / math.sqrt(n); t = (m - 1) / se if se else 0
print(f"b/a throughput: {m:.4f} [{m-2.2*se:.4f}, {m+2.2*se:.4f}] ~95% CI, n={n}, t={t:.2f}")
h = [r["b_hwm"] / r["a_hwm"] for r in rows if r["a_hwm"]]
print(f"b/a peak RSS:   {statistics.mean(h):.4f}")
print(f"a median rps {statistics.median(r['a_rps'] for r in rows):.0f}, b median {statistics.median(r['b_rps'] for r in rows):.0f}")
PY
