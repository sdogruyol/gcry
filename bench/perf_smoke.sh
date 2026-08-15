#!/usr/bin/env bash
# Short Kemal A/B smoke for CI.
#
# Variance protocol (same-host, same-run):
#   1. Run wrk N× per (binary, path) pair
#   2. Discard min and max → keep N-2 middle values
#   3. Report median of remaining
#   4. Compute noise ratio = IQR / median
#   5. Gate: gcry median RPS as % of Boehm on this machine
#   6. Store per-run JSON under bench/log/<date>/ (artifact only; not a cross-host baseline)
#
# Absolute RPS is NOT compared across hosts (CI ≠ macOS ≠ WSL). The only
# portable thr gate is % of Boehm measured in the same job.
#
# Fails if:
#   - gcry /json thr < MIN_PCT% of Boehm
#   - gcry post-GC RSS × Boehm > MAX_RSS_X (same-host, after /json load)
#   - gcry pause_p50_ms > MAX_PAUSE_P50_MS (from /gc-stats after load)
#
# Floors/ceilings are intentionally loose for CI host noise. Tip quiet holds
# ~85% thr @ ~0.8× RSS @ ~0.6 ms pause_p50; CI defaults leave headroom.
#
# That headroom is also the hole: a regression that lands inside a floor is
# invisible. `bench/perf_compare.py` compares the same summary against a
# recorded baseline and runs at the end of this script — report-only until a
# baseline with a measured tolerance exists (PERF_GATE_BASELINE=1 to gate).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
LOG="$ROOT/bench/log"
KEMAL="$ROOT/bench/kemal"
PORT="${PORT:-3011}"
DURATION="${WRK_DURATION:-5}"
CONNECTIONS="${WRK_CONNECTIONS:-50}"
MIN_PCT="${MIN_PCT:-70}"
MAX_RSS_X="${MAX_RSS_X:-1.5}"
MAX_PAUSE_P50_MS="${MAX_PAUSE_P50_MS:-3.0}"
BASE="http://127.0.0.1:${PORT}"
RUNS="${BENCH_RUNS:-5}"

command -v wrk >/dev/null || { echo "ERROR: wrk not found"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }
mkdir -p "$BIN"

cd "$KEMAL"
shards install --production 2>/dev/null || shards install

echo "Building kemal-boehm..."
crystal build --release src/server.cr -o "$BIN/kemal-boehm-smoke"
echo "Building kemal-gcry..."
crystal build -Dgc_none --release src/server.cr -o "$BIN/kemal-gcry-smoke"

# ── helpers ──────────────────────────────────────────────────────────

parse_rps() {
  awk '/Requests\/sec/ {print $2; exit}'
}

rss_kib() {
  local pid="$1"
  if [ -r "/proc/$pid/status" ]; then
    awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status"
  else
    ps -o rss= -p "$pid" | tr -d ' '
  fi
}

single_run() {
  local bin="$1" path="$2"
  PORT="$PORT" "$bin" >/dev/null 2>&1 &
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

# One load pass then post-GC RSS (+ pause_p50 for gcry). Writes JSON to stdout.
instrumented_json_run() {
  local bin="$1" label="$2"
  PORT="$PORT" "$bin" >/dev/null 2>&1 &
  local pid=$!
  trap 'kill $pid 2>/dev/null || true' RETURN
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null "$BASE/" && break
    sleep 0.2
  done
  local rps
  rps="$(wrk -c "$CONNECTIONS" -d "${DURATION}s" "${BASE}/json" | parse_rps)"
  curl -sf "$BASE/gc-collect" >/dev/null
  sleep 0.3
  local rss
  rss="$(rss_kib "$pid")"
  local pause_p50_ms="None"
  if [ "$label" = "gcry" ]; then
    pause_p50_ms="$(curl -sf "$BASE/gc-stats" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ns = float(d.get('pause_p50_ns') or 0)
print(round(ns / 1e6, 4))
")"
  fi
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  sleep 0.3
  python3 -c "
import json
print(json.dumps({
    'label': '$label',
    'rps': float('$rps'),
    'rss_kib': int('$rss'),
    'pause_p50_ms': $pause_p50_ms,
}))
"
}

# Writes JSON to stdout with run stats.
variance_run() {
  local bin="$1" path="$2"
  local -a vals=()
  echo "  → $RUNS runs …" >&2
  for i in $(seq 1 "$RUNS"); do
    local rps
    rps="$(single_run "$bin" "$path")"
    vals+=("$rps")
    echo "    run $i: $rps req/s" >&2
  done

  local py_args=""
  for v in "${vals[@]}"; do
    py_args="$py_args $v"
  done

  python3 -c "
import json, sys

vals = sorted([float(v) for v in sys.argv[1:]])
n = len(vals)
keep = vals[1:-1] if n >= 3 else vals
median = keep[len(keep) // 2]
q1 = keep[len(keep) // 4]
q3 = keep[(3 * len(keep)) // 4]
iqr = q3 - q1
noise = iqr / median if median > 0 else 0

print(json.dumps({
    'runs': vals,
    'median': round(median, 2),
    'p25': round(q1, 2),
    'p75': round(q3, 2),
    'iqr': round(iqr, 2),
    'noise_ratio': round(noise, 4),
}))
" $py_args
}

# ── collect data ─────────────────────────────────────────────────────

RUN_LABEL="$(date -u +%Y-%m-%d-%H%M%S)"
RUN_DIR="$LOG/linux/$RUN_LABEL"
mkdir -p "$RUN_DIR"

echo ""
echo "=== Boehm / ==="
BOEHM_ROOT="$(variance_run "$BIN/kemal-boehm-smoke" /)"
echo "$BOEHM_ROOT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'  median={d[\"median\"]} runs={d[\"runs\"]} noise={d[\"noise_ratio\"]}')"
echo "$BOEHM_ROOT" > "$RUN_DIR/boehm-root.json"

echo "=== Boehm /json ==="
BOEHM_JSON="$(variance_run "$BIN/kemal-boehm-smoke" /json)"
echo "$BOEHM_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'  median={d[\"median\"]} runs={d[\"runs\"]} noise={d[\"noise_ratio\"]}')"
echo "$BOEHM_JSON" > "$RUN_DIR/boehm-json.json"

echo "=== gcry / ==="
GCRY_ROOT="$(variance_run "$BIN/kemal-gcry-smoke" /)"
echo "$GCRY_ROOT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'  median={d[\"median\"]} runs={d[\"runs\"]} noise={d[\"noise_ratio\"]}')"
echo "$GCRY_ROOT" > "$RUN_DIR/gcry-root.json"

echo "=== gcry /json ==="
GCRY_JSON="$(variance_run "$BIN/kemal-gcry-smoke" /json)"
echo "$GCRY_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'  median={d[\"median\"]} runs={d[\"runs\"]} noise={d[\"noise_ratio\"]}')"
echo "$GCRY_JSON" > "$RUN_DIR/gcry-json.json"

# ── compute % of Boehm (same-host gate) ──────────────────────────────

PCT_ROOT="$(python3 -c "
import json
b = json.load(open('$RUN_DIR/boehm-root.json'))
g = json.load(open('$RUN_DIR/gcry-root.json'))
bp = b['median']
gp = g['median']
print(f'{gp/bp*100:.1f}' if bp > 0 else '0')
")"

PCT_JSON="$(python3 -c "
import json
b = json.load(open('$RUN_DIR/boehm-json.json'))
g = json.load(open('$RUN_DIR/gcry-json.json'))
bp = b['median']
gp = g['median']
print(f'{gp/bp*100:.1f}' if bp > 0 else '0')
")"

echo ""
echo "=== Summary (same-host % of Boehm) ==="
echo "  /      gcry = ${PCT_ROOT}% of Boehm  (informational; gate is /json)"
echo "  /json  gcry = ${PCT_JSON}% of Boehm  (gate >= ${MIN_PCT}%)"

# ── EC1 RSS × + pause_p50 (post-/json load) ──────────────────────────

echo ""
echo "=== Instrumented /json (post-GC RSS + pause) ==="
BOEHM_INST="$(instrumented_json_run "$BIN/kemal-boehm-smoke" boehm)"
echo "$BOEHM_INST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'  boehm: rps={d[\"rps\"]} rss_kib={d[\"rss_kib\"]}')"
echo "$BOEHM_INST" > "$RUN_DIR/boehm-json-instrumented.json"

GCRY_INST="$(instrumented_json_run "$BIN/kemal-gcry-smoke" gcry)"
echo "$GCRY_INST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'  gcry:  rps={d[\"rps\"]} rss_kib={d[\"rss_kib\"]} pause_p50_ms={d[\"pause_p50_ms\"]}')"
echo "$GCRY_INST" > "$RUN_DIR/gcry-json-instrumented.json"

RSS_X="$(python3 -c "
import json
b = json.load(open('$RUN_DIR/boehm-json-instrumented.json'))
g = json.load(open('$RUN_DIR/gcry-json-instrumented.json'))
br = float(b['rss_kib'])
gr = float(g['rss_kib'])
print(f'{gr/br:.3f}' if br > 0 else '999')
")"
PAUSE_P50_MS="$(python3 -c "
import json
g = json.load(open('$RUN_DIR/gcry-json-instrumented.json'))
print(g['pause_p50_ms'] if g['pause_p50_ms'] is not None else 0)
")"

echo "  RSS × = ${RSS_X}  (gate <= ${MAX_RSS_X})"
echo "  pause_p50 = ${PAUSE_P50_MS} ms  (gate <= ${MAX_PAUSE_P50_MS})"

python3 -c "
import json
summary = {
    'pct_root': float('$PCT_ROOT'),
    'pct_json': float('$PCT_JSON'),
    'min_pct': float('$MIN_PCT'),
    'rss_x': float('$RSS_X'),
    'max_rss_x': float('$MAX_RSS_X'),
    'pause_p50_ms': float('$PAUSE_P50_MS'),
    'max_pause_p50_ms': float('$MAX_PAUSE_P50_MS'),
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    # Which machine class this was measured on. The ratios are same-host, but a
    # baseline recorded on a GitHub runner still does not describe a laptop —
    # perf_compare.py says so out loud rather than comparing silently.
    'runner': '${RUNNER_LABEL:-$(uname -s)-$(uname -m)}',
}
open('$RUN_DIR/summary.json', 'w').write(json.dumps(summary) + '\n')
print(json.dumps(summary, indent=2))
"

# ── gates ────────────────────────────────────────────────────────────

FAIL=0

if python3 -c "import sys; exit(0 if float('$PCT_JSON') >= float('$MIN_PCT') else 1)"; then
  echo "  /json thr gate: ${PCT_JSON}% >= ${MIN_PCT}% ✓"
else
  echo "FAIL: gcry /json = ${PCT_JSON}% < ${MIN_PCT}% of Boehm"
  FAIL=1
fi

if ! python3 -c "import sys; exit(0 if float('$PCT_ROOT') >= float('$MIN_PCT') else 1)"; then
  echo "WARN: gcry / = ${PCT_ROOT}% < ${MIN_PCT}% of Boehm (non-critical path)"
fi

if python3 -c "import sys; exit(0 if float('$RSS_X') <= float('$MAX_RSS_X') else 1)"; then
  echo "  /json RSS gate: ${RSS_X}x <= ${MAX_RSS_X}x ✓"
else
  echo "FAIL: gcry /json RSS = ${RSS_X}x > ${MAX_RSS_X}x Boehm"
  FAIL=1
fi

if python3 -c "import sys; exit(0 if float('$PAUSE_P50_MS') <= float('$MAX_PAUSE_P50_MS') else 1)"; then
  echo "  pause_p50 gate: ${PAUSE_P50_MS} ms <= ${MAX_PAUSE_P50_MS} ms ✓"
else
  echo "FAIL: gcry pause_p50 = ${PAUSE_P50_MS} ms > ${MAX_PAUSE_P50_MS} ms"
  FAIL=1
fi

# ── baseline comparison ──────────────────────────────────────────────
#
# The gates above are floors, and they sit far below tip on purpose (CI host
# noise): 85% -> 70% clears every one of them. This compares the same numbers
# against a recorded baseline instead. Report-only by default — set
# PERF_GATE_BASELINE=1 to make a regression fail the run, which is worth doing
# only once the baseline carries a tolerance measured on this runner class.
BASELINE="${PERF_BASELINE:-$ROOT/bench/baseline/perf_smoke.json}"
if [ -f "$BASELINE" ]; then
  echo ""
  GATE_ARG=""
  [ "${PERF_GATE_BASELINE:-0}" = "1" ] && GATE_ARG="--gate"
  if ! python3 "$ROOT/bench/perf_compare.py" --baseline "$BASELINE" \
      --summary "$RUN_DIR/summary.json" $GATE_ARG; then
    FAIL=1
  fi
fi

echo ""
echo "=== Result ==="
if [ "$FAIL" = "1" ]; then
  echo "FAIL"
  exit 1
else
  echo "PASS"
fi
