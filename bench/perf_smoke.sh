#!/usr/bin/env bash
# Short Kemal A/B smoke for CI.
#
# Variance protocol:
#   1. Run wrk N× per (binary, path) pair
#   2. Discard min and max → keep N-2 middle values
#   3. Report median of remaining
#   4. Compute noise ratio = IQR / median
#   5. Compare gcry vs Boehm (existing % of Boehm gate)
#   6. Compare gcry result against historical baseline
#   7. Store results in bench/log/<date>/run-<n>/
#
# Fails if:
#   - gcry /json thr < MIN_PCT% of Boehm
#   - gcry median drops >5% vs baseline AND noise ratio < 0.15
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
VAR_THRESHOLD="${VAR_THRESHOLD:-0.05}"
NOISE_CAP="${NOISE_CAP:-0.15}"
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

  # Build comma-separated list for Python
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

# ── compute % of Boehm (gate) ────────────────────────────────────────

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
echo "=== Summary ==="
echo "  /      gcry = ${PCT_ROOT}% of Boehm  (gate >= ${MIN_PCT}%)"
echo "  /json  gcry = ${PCT_JSON}% of Boehm  (gate >= ${MIN_PCT}%)"

# ── baseline comparison ──────────────────────────────────────────────

BASELINE="$ROOT/bench/baseline.json"
ALERT=""

compare_baseline() {
  local label="$1" pct="$2" path_label="$3"
  local gcry_median gcry_noise
  gcry_median="$(python3 -c "import json; print(json.load(open('$RUN_DIR/gcry-${path_label}.json'))['median'])")"
  gcry_noise="$(python3 -c "import json; print(json.load(open('$RUN_DIR/gcry-${path_label}.json'))['noise_ratio'])")"

  local baseline_val
  baseline_val="$(python3 -c "
import json
try:
    d = json.load(open('$BASELINE'))
    print(d['${label}'])
except:
    print('none')
")" || baseline_val="none"

  if [ "$baseline_val" != "none" ] && [ "$baseline_val" != "0" ]; then
    local drop_pct
    drop_pct="$(python3 -c "
b = float('$baseline_val')
g = float('$gcry_median')
print(f'{(b-g)/b*100:.2f}') if b > 0 else print('0')
")"
    local is_noisy
    is_noisy="$(python3 -c "
print('1') if float('$gcry_noise') > float('$NOISE_CAP') else print('0')
")"
    local threshold_dropped
    threshold_dropped="$(python3 -c "
d = float('$drop_pct')
print('1') if d > float('$VAR_THRESHOLD') * 100 else print('0')
")"

    if [ "$threshold_dropped" = "1" ] && [ "$is_noisy" = "0" ]; then
      ALERT="${ALERT}  ⚠  gcry ${label} RPS dropped ${drop_pct}% vs baseline (${baseline_val}→${gcry_median}), noise=${gcry_noise}\n"
      echo "  baseline $label: $baseline_val → $gcry_median (drop ${drop_pct}%, noise ${gcry_noise}) ⚠" >&2
    else
      echo "  baseline $label: $baseline_val → $gcry_median (change ${drop_pct}%) ✓" >&2
    fi
  else
    echo "  baseline $label: not set yet (gcry=$gcry_median)" >&2
  fi
}

if [ -f "$BASELINE" ]; then
  echo ""
  echo "=== Baseline comparison ==="
  compare_baseline "json_rps" "$PCT_JSON" "json"
  compare_baseline "root_rps" "$PCT_ROOT" "root"
fi

# ── save baseline on first run ───────────────────────────────────────

if [ ! -f "$BASELINE" ]; then
  echo ""
  echo "=== Saving initial baseline ==="
  GCRY_ROOT_MED="$(python3 -c "import json; print(json.load(open('$RUN_DIR/gcry-root.json'))['median'])")"
  GCRY_JSON_MED="$(python3 -c "import json; print(json.load(open('$RUN_DIR/gcry-json.json'))['median'])")"
  cat > "$BASELINE" <<EOF
{
  "root_rps": $GCRY_ROOT_MED,
  "json_rps": $GCRY_JSON_MED,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "noise_cap": $NOISE_CAP,
  "var_threshold": $VAR_THRESHOLD
}
EOF
  echo "  baseline saved: root=$GCRY_ROOT_MED json=$GCRY_JSON_MED"
fi

# ── log run metadata ─────────────────────────────────────────────────

echo "{\"pct_root\": $PCT_ROOT, \"pct_json\": $PCT_JSON, \"min_pct\": $MIN_PCT, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$RUN_DIR/summary.json"

# ── gates ────────────────────────────────────────────────────────────

FAIL=0

# Gate 1: % of Boehm /json
if python3 -c "import sys; exit(0 if float('$PCT_JSON') >= float('$MIN_PCT') else 1)"; then
  echo "  /json gate: ${PCT_JSON}% >= ${MIN_PCT}% ✓"
else
  echo "FAIL: gcry /json = ${PCT_JSON}% < ${MIN_PCT}% of Boehm"
  FAIL=1
fi

# Gate 2: % of Boehm / (non-critical, warn only)
if ! python3 -c "import sys; exit(0 if float('$PCT_ROOT') >= float('$MIN_PCT') else 1)"; then
  echo "WARN: gcry / = ${PCT_ROOT}% < ${MIN_PCT}% of Boehm (non-critical path)"
fi

# Gate 3: baseline regression
if [ -n "$ALERT" ]; then
  echo ""
  echo "=== Performance regression alert ==="
  echo -e "$ALERT"
  if echo "$ALERT" | grep -q "json_rps"; then
    echo "FAIL: /json regression detected (see above)"
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