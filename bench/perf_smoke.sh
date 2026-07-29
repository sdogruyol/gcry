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
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
LOG="$ROOT/bench/log"
KEMAL="$ROOT/bench/kemal"
PORT="${PORT:-3011}"
DURATION="${WRK_DURATION:-5}"
CONNECTIONS="${WRK_CONNECTIONS:-50}"
MIN_PCT="${MIN_PCT:-70}"
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

echo "{\"pct_root\": $PCT_ROOT, \"pct_json\": $PCT_JSON, \"min_pct\": $MIN_PCT, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$RUN_DIR/summary.json"

# ── gates ────────────────────────────────────────────────────────────

FAIL=0

if python3 -c "import sys; exit(0 if float('$PCT_JSON') >= float('$MIN_PCT') else 1)"; then
  echo "  /json gate: ${PCT_JSON}% >= ${MIN_PCT}% ✓"
else
  echo "FAIL: gcry /json = ${PCT_JSON}% < ${MIN_PCT}% of Boehm"
  FAIL=1
fi

if ! python3 -c "import sys; exit(0 if float('$PCT_ROOT') >= float('$MIN_PCT') else 1)"; then
  echo "WARN: gcry / = ${PCT_ROOT}% < ${MIN_PCT}% of Boehm (non-critical path)"
fi

echo ""
echo "=== Result ==="
if [ "$FAIL" = "1" ]; then
  echo "FAIL"
  exit 1
else
  echo "PASS"
fi
