#!/usr/bin/env bash
# Does making the heap's counters atomic cost throughput? Paired A/B, one
# binary, the arms differing only in `GCRY_HEAP_COUNTERS_ATOMIC`.
#
# Why this exists (ROADMAP.md, "The process heap's counters lose updates"):
# `note_alloc_bytes` and friends use plain `set(get + 1)` unless
# `heap_counters_atomic` is set, and `heap.cr` calls that safe on the grounds of
# "single mutator + rare SYSMON". It is not: with the invariant checker on, the
# process heap's `live_objects` reads permanently one below the walk in 3 runs
# of 40, in a program whose only threads are main and the monitor. A lost
# increment never comes back, and `bytes_since_gc` drifting low delays a
# collection by exactly the bytes it forgot.
#
# The scope correction shipped (the invariant is stated only of a heap that
# keeps its counter) made the checker honest without making the counter right.
# Turning the atomic path on unconditionally costs a LOCK RMW on the allocation
# hot path, which is the reason it is off — so the decision needs this number
# beside it, not an opinion about it.
#
# Paired and alternating: trial i runs both arms back to back, and the order
# flips on odd trials, so host drift over the run cancels instead of landing on
# one arm. Reports the paired mean difference with a 95% CI.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEMAL="$ROOT/bench/kemal"
BIN="$ROOT/bin"
PORT="${PORT:-3041}"
BASE="http://127.0.0.1:${PORT}"
DURATION="${WRK_DURATION:-10}"
CONNECTIONS="${WRK_CONNECTIONS:-50}"
TRIALS="${TRIALS:-10}"
OUT="${OUT:-/tmp/gcry-counters-ab.jsonl}"

command -v wrk >/dev/null || { echo "ERROR: wrk not found"; exit 1; }
mkdir -p "$BIN"

cd "$KEMAL"
shards install --production >/dev/null 2>&1 || shards install >/dev/null
"$ROOT/bench/assert_gcry_lib.sh" lib/gcry "$ROOT"
echo "Building kemal-gcry (release)..."
crystal build -Dgc_none --release src/server.cr -o "$BIN/kemal-counters-ab"
cd "$ROOT"

run_arm() {
  local atomic="$1"
  GCRY_HEAP_COUNTERS_ATOMIC="$atomic" PORT="$PORT" "$BIN/kemal-counters-ab" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 40); do
    curl -sf -o /dev/null "$BASE/" && break
    sleep 0.2
  done
  # A discarded warm-up pass, because without one the *first* arm of every
  # trial reads low — measured 80.7k then 94.8k on a smoke whose arms were
  # identical apart from order. Alternating the order cancels that in the mean
  # but not in the variance, and the variance is what decides whether ten
  # trials can see a few percent.
  wrk -c "$CONNECTIONS" -d 3s "${BASE}/json" >/dev/null 2>&1
  local rps
  rps="$(wrk -c "$CONNECTIONS" -d "${DURATION}s" "${BASE}/json" | awk '/Requests\/sec/ {print $2; exit}')"
  curl -sf "$BASE/gc-collect" >/dev/null 2>&1 || true
  sleep 0.3
  local rss=0
  [ -r "/proc/$pid/status" ] && rss="$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status")"
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  sleep 0.5
  echo "$rps $rss"
}

: > "$OUT"
echo "=== heap counters: atomic vs plain, $TRIALS paired trials, ${DURATION}s x $CONNECTIONS conns ==="
for i in $(seq 1 "$TRIALS"); do
  if [ $((i % 2)) -eq 1 ]; then
    read -r a_rps a_rss <<<"$(run_arm 1)"
    read -r p_rps p_rss <<<"$(run_arm 0)"
  else
    read -r p_rps p_rss <<<"$(run_arm 0)"
    read -r a_rps a_rss <<<"$(run_arm 1)"
  fi
  printf '{"trial":%d,"atomic_rps":%s,"plain_rps":%s,"atomic_rss_kib":%s,"plain_rss_kib":%s}\n' \
    "$i" "$a_rps" "$p_rps" "$a_rss" "$p_rss" >> "$OUT"
  printf 'trial %2d: atomic %10s  plain %10s  ratio %s\n' "$i" "$a_rps" "$p_rps" \
    "$(python3 -c "print(f'{$a_rps/$p_rps:.4f}')")"
done

python3 - "$OUT" <<'PY'
import json, statistics, sys, math
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
d = [r["atomic_rps"] / r["plain_rps"] for r in rows]
n = len(d)
mean = statistics.mean(d)
sd = statistics.stdev(d) if n > 1 else 0.0
half = 1.96 * sd / math.sqrt(n) if n > 1 else 0.0
print()
print(f"paired ratio atomic/plain: {mean:.4f} [{mean-half:.4f}, {mean+half:.4f}] 95% CI, n={n}")
print(f"cost of atomic counters:   {(1-mean)*100:+.2f}% throughput"
      f" [{(1-mean-half)*100:+.2f}%, {(1-mean+half)*100:+.2f}%]")
rss = [r["atomic_rss_kib"] / r["plain_rss_kib"] for r in rows if r["plain_rss_kib"]]
if rss:
    print(f"post-GC RSS ratio:         {statistics.mean(rss):.4f}")
print()
if mean - half > 1.0:
    print("VERDICT atomic is faster outside the CI — implausible, so this run measured noise")
elif mean + half < 1.0:
    print("VERDICT atomic costs throughput measurably; the trade is real and the decision "
          "has to weigh a lost increment against it")
else:
    print("VERDICT no measurable cost at this workload's resolution — the reason the atomic "
          "path is off does not survive the measurement")
PY
