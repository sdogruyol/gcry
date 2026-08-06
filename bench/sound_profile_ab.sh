#!/usr/bin/env bash
# What does gcry cost when it is not allowed to guess?
#
# Measures Kemal /json throughput + post-GC RSS for four configurations on one
# host, in one run:
#
#   boehm       Crystal default (the denominator)
#   tuned       gcry process defaults — every root heuristic armed
#   sound       GCRY_SOUND=1 — root-completeness heuristics off
#               (interiors + misaligned interiors followed, type_id gate off,
#                STW stack/pthread lag 0, parked-fiber scrub off, blacklist off)
#   sound+cons  GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1 — also drops the
#               object-body layout tables, i.e. fully conservative scanning
#
# The last two are the numbers that belong in a correctness claim. See
# docs/SOUND-DEFAULTS.md.
#
# Same variance protocol as perf_smoke.sh: N runs per config, discard min and
# max, report the median of the rest. Absolute req/s is host noise; the only
# portable score is % of Boehm measured in the same job.
#
#   BENCH_RUNS=5 WRK_DURATION=10 WRK_CONNECTIONS=100 ./bench/sound_profile_ab.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
LOG="$ROOT/bench/log"
KEMAL="$ROOT/bench/kemal"
PORT="${PORT:-3017}"
DURATION="${WRK_DURATION:-10}"
CONNECTIONS="${WRK_CONNECTIONS:-100}"
PATH_UNDER_TEST="${BENCH_PATH:-/json}"
BASE="http://127.0.0.1:${PORT}"
RUNS="${BENCH_RUNS:-5}"

command -v wrk >/dev/null || { echo "ERROR: wrk not found"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }
mkdir -p "$BIN"

cd "$KEMAL"
shards install --production 2>/dev/null || shards install

echo "Building kemal-boehm..."
crystal build --release src/server.cr -o "$BIN/kemal-boehm-sound"
echo "Building kemal-gcry..."
crystal build -Dgc_none --release src/server.cr -o "$BIN/kemal-gcry-sound"
cd "$ROOT"

parse_rps() { awk '/Requests\/sec/ {print $2; exit}'; }

rss_kib() {
  local pid="$1"
  if [ -r "/proc/$pid/status" ]; then
    awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status"
  else
    ps -o rss= -p "$pid" | tr -d ' '
  fi
}

wait_ready() {
  for _ in $(seq 1 40); do
    curl -sf -o /dev/null "$BASE/" && return 0
    sleep 0.25
  done
  return 1
}

# single_run <binary> <env-assignments...>  → req/s on stdout
single_run() {
  local bin="$1"; shift
  env PORT="$PORT" "$@" "$bin" >/dev/null 2>&1 &
  local pid=$!
  wait_ready || { kill $pid 2>/dev/null || true; echo 0; return; }
  wrk -c "$CONNECTIONS" -d "${DURATION}s" "${BASE}${PATH_UNDER_TEST}" | parse_rps
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  sleep 0.4
}

# instrumented_run <binary> <label> <is_gcry> <env-assignments...> → JSON
# One load pass, then GET /gc-collect, then read RSS. Also captures the
# collector's own view of its root-soundness so the log proves which
# configuration actually ran (not merely which env var was exported).
instrumented_run() {
  local bin="$1" label="$2" is_gcry="$3"; shift 3
  env PORT="$PORT" "$@" "$bin" >/dev/null 2>&1 &
  local pid=$!
  wait_ready || { kill $pid 2>/dev/null || true; echo '{}'; return; }
  local rps
  rps="$(wrk -c "$CONNECTIONS" -d "${DURATION}s" "${BASE}${PATH_UNDER_TEST}" | parse_rps)"
  curl -sf "$BASE/gc-collect" >/dev/null || true
  sleep 0.4
  local rss; rss="$(rss_kib "$pid")"
  local stats='{}'
  if [ "$is_gcry" = "1" ]; then
    stats="$(curl -sf "$BASE/gc-stats" || echo '{}')"
  fi
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  sleep 0.4
  STATS="$stats" python3 -c "
import json, os
s = json.loads(os.environ.get('STATS') or '{}')
print(json.dumps({
    'label': '$label',
    'rps': float('$rps'),
    'rss_kib': int('$rss'),
    'root_soundness': s.get('root_soundness'),
    'pause_p50_ms': round(float(s.get('pause_p50_ns') or 0) / 1e6, 4),
    'pause_p99_ms': round(float(s.get('pause_p99_ns') or 0) / 1e6, 4),
    'collections': s.get('collections'),
    'knobs': {k: s.get(k) for k in (
        'allow_interior_pointers', 'scan_unaligned_candidates', 'type_id_gate',
        'type_id_gate_stacks', 'stw_multi_stack_lag', 'stw_multi_pthread_lag',
        'scrub_fibers_enabled', 'blacklist_enabled', 'layout_precise')},
}))
"
}

# variance_run <binary> <env...> → JSON with median
variance_run() {
  local bin="$1"; shift
  local -a vals=()
  for i in $(seq 1 "$RUNS"); do
    local rps; rps="$(single_run "$bin" "$@")"
    vals+=("$rps")
    echo "    run $i: $rps req/s" >&2
  done
  python3 -c "
import json, sys
vals = sorted(float(v) for v in sys.argv[1:])
# Median over the trimmed set (drop min and max), spread over the full set —
# taking IQR from the trimmed set too is degenerate at small N (3 runs leaves
# one value, so q1 == q3 and the run always looks noiseless).
keep = vals[1:-1] if len(vals) >= 3 else vals
median = keep[len(keep) // 2]
q1, q3 = vals[len(vals) // 4], vals[(3 * len(vals)) // 4]
print(json.dumps({
    'runs': vals,
    'median': round(median, 2),
    'spread_pct': round((vals[-1] - vals[0]) / median * 100, 2) if median else 0,
    'iqr': round(q3 - q1, 2),
    'noise_ratio': round((q3 - q1) / median, 4) if median else 0,
}))
" "${vals[@]}"
}

RUN_LABEL="$(date -u +%Y-%m-%d-%H%M%S)-sound-profile"
RUN_DIR="$LOG/linux/$RUN_LABEL"
mkdir -p "$RUN_DIR"

echo ""
echo "path=$PATH_UNDER_TEST  runs=$RUNS  duration=${DURATION}s  connections=$CONNECTIONS"

run_config() {
  local key="$1" bin="$2" is_gcry="$3"; shift 3
  echo ""
  echo "=== $key ==="
  variance_run "$bin" "$@" > "$RUN_DIR/$key-thr.json"
  python3 -c "
import json
d = json.load(open('$RUN_DIR/$key-thr.json'))
print(f\"  median={d['median']} req/s  spread={d['spread_pct']}%  noise={d['noise_ratio']}\")"
  instrumented_run "$bin" "$key" "$is_gcry" "$@" > "$RUN_DIR/$key-inst.json"
  python3 -c "
import json
d = json.load(open('$RUN_DIR/$key-inst.json'))
extra = ''
if d.get('root_soundness'):
    extra = f\"  root_soundness={d['root_soundness']}  pause_p50={d['pause_p50_ms']}ms\"
print(f\"  rss={d['rss_kib']} KiB{extra}\")"
}

run_config boehm      "$BIN/kemal-boehm-sound" 0
run_config tuned      "$BIN/kemal-gcry-sound"  1
run_config sound      "$BIN/kemal-gcry-sound"  1 GCRY_SOUND=1
run_config sound-cons "$BIN/kemal-gcry-sound"  1 GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1

echo ""
python3 - "$RUN_DIR" <<'PY'
import json, os, sys

run_dir = sys.argv[1]
keys = ["boehm", "tuned", "sound", "sound-cons"]
titles = {
    "boehm": "Boehm (baseline)",
    "tuned": "gcry tuned (defaults)",
    "sound": "gcry sound roots",
    "sound-cons": "gcry sound + conservative bodies",
}

data = {}
for k in keys:
    thr = json.load(open(os.path.join(run_dir, f"{k}-thr.json")))
    inst = json.load(open(os.path.join(run_dir, f"{k}-inst.json")))
    data[k] = {"thr": thr, "inst": inst}

base_rps = data["boehm"]["thr"]["median"]
base_rss = float(data["boehm"]["inst"]["rss_kib"])

rows = []
for k in keys:
    rps = data[k]["thr"]["median"]
    rss = float(data[k]["inst"]["rss_kib"])
    rows.append({
        "key": k,
        "title": titles[k],
        "rps": rps,
        "pct": round(rps / base_rps * 100, 1) if base_rps else 0.0,
        "rss_kib": int(rss),
        "rss_x": round(rss / base_rss, 3) if base_rss else 0.0,
        "pause_p50_ms": data[k]["inst"].get("pause_p50_ms"),
        "pause_p99_ms": data[k]["inst"].get("pause_p99_ms"),
        "root_soundness": data[k]["inst"].get("root_soundness"),
        "noise_ratio": data[k]["thr"]["noise_ratio"],
        "spread_pct": data[k]["thr"]["spread_pct"],
        "knobs": data[k]["inst"].get("knobs"),
    })

print("=== Summary (same host, same run) ===")
print(f"{'config':34} {'req/s':>10} {'% Boehm':>9} {'RSS x':>8} {'p50 ms':>8}  roots")
for r in rows:
    p50 = "-" if not r["pause_p50_ms"] else f"{r['pause_p50_ms']:.2f}"
    print(f"{r['title']:34} {r['rps']:>10.0f} {r['pct']:>8.1f}% {r['rss_x']:>8.2f} {p50:>8}  {r['root_soundness'] or '-'}")

# Guard: a run where the sound config did not actually apply is not a
# measurement, it is a duplicate of `tuned`.
for k in ("sound", "sound-cons"):
    got = data[k]["inst"].get("root_soundness")
    if got != "sound":
        print(f"\nERROR: config '{k}' reported root_soundness={got!r} (expected 'sound')")
        sys.exit(1)

out = {"rows": rows, "path": os.environ.get("BENCH_PATH", "/json")}
with open(os.path.join(run_dir, "summary.json"), "w") as f:
    f.write(json.dumps(out, indent=2) + "\n")

print("\nMarkdown (for docs/SOUND-DEFAULTS.md):\n")
print("| Config | req/s | % of Boehm | RSS × | pause p50 |")
print("|--------|------:|-----------:|------:|----------:|")
for r in rows:
    p50 = "—" if not r["pause_p50_ms"] else f"{r['pause_p50_ms']:.2f} ms"
    pct = "—" if r["key"] == "boehm" else f"**{r['pct']:.1f}%**"
    rssx = "—" if r["key"] == "boehm" else f"**{r['rss_x']:.2f}×**"
    print(f"| {r['title']} | {r['rps']:.0f} | {pct} | {rssx} | {p50} |")
PY

echo ""
echo "log: $RUN_DIR"
