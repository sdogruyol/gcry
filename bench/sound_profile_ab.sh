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

# Kill whatever server this shell last started. Idempotent, and safe to fire
# from a RETURN trap after the pid is already reaped — a RETURN trap is not
# scoped to the function that installed it, so it also runs on the next
# function return, when there is nothing left to kill.
SERVER_PID=""
stop_server() {
  [ -n "${SERVER_PID:-}" ] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}
trap stop_server EXIT INT TERM

# A server that never came up is not a slow config, it is a broken run. Abort
# rather than returning a sentinel: a 0 (or an empty JSON row) survives into
# the median and silently halves a config's score.
die_server() {
  echo "ERROR: server did not answer $BASE/ within 10s — bin=$1 env=${*:2}" >&2
  echo "       (port $PORT already held? stale server from an earlier run?)" >&2
  exit 1
}

# single_run <binary> <env-assignments...>  → req/s on stdout
single_run() {
  local bin="$1"; shift
  env PORT="$PORT" "$@" "$bin" >/dev/null 2>&1 &
  SERVER_PID=$!
  trap stop_server RETURN
  wait_ready || die_server "$bin" "$@"
  wrk -c "$CONNECTIONS" -d "${DURATION}s" "${BASE}${PATH_UNDER_TEST}" | parse_rps
  stop_server
  sleep 0.4
}

# instrumented_run <binary> <label> <is_gcry> <env-assignments...> → JSON
# One load pass, then GET /gc-collect, then read RSS. Also captures the
# collector's own view of its root-soundness so the log proves which
# configuration actually ran (not merely which env var was exported).
instrumented_run() {
  local bin="$1" label="$2" is_gcry="$3"; shift 3
  local envdesc="$*"
  env PORT="$PORT" "$@" "$bin" >/dev/null 2>&1 &
  local pid=$!
  SERVER_PID=$pid
  trap stop_server RETURN
  wait_ready || die_server "$bin" "$@"
  local rps
  rps="$(wrk -c "$CONNECTIONS" -d "${DURATION}s" "${BASE}${PATH_UNDER_TEST}" | parse_rps)"
  curl -sf "$BASE/gc-collect" >/dev/null || true
  sleep 0.4
  local rss; rss="$(rss_kib "$pid")"
  local stats='{}'
  if [ "$is_gcry" = "1" ]; then
    stats="$(curl -sf "$BASE/gc-stats" || echo '{}')"
  fi
  stop_server
  sleep 0.4
  STATS="$stats" ENVDESC="$envdesc" python3 -c "
import json, os
s = json.loads(os.environ.get('STATS') or '{}')
print(json.dumps({
    'label': '$label',
    'env': os.environ.get('ENVDESC', ''),
    'rps': float('$rps'),
    'rss_kib': int('$rss'),
    'soundness': s.get('soundness'),
    'root_soundness': s.get('root_soundness'),
    'barrier_soundness': s.get('barrier_soundness'),
    'pause_p50_ms': round(float(s.get('pause_p50_ns') or 0) / 1e6, 4),
    'pause_p99_ms': round(float(s.get('pause_p99_ns') or 0) / 1e6, 4),
    'collections': s.get('collections'),
    'knobs': {k: s.get(k) for k in (
        'allow_interior_pointers', 'scan_unaligned_candidates',
        'scan_static_roots', 'type_id_gate', 'type_id_gate_stacks',
        'stw_multi_stack_lag', 'stw_multi_pthread_lag', 'scrub_fibers_enabled',
        'blacklist_enabled', 'nursery_enabled', 'incremental_auto',
        'layout_precise')},
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
if d.get('soundness'):
    extra = f\"  soundness={d['soundness']}  pause_p50={d['pause_p50_ms']}ms\"
print(f\"  rss={d['rss_kib']} KiB{extra}\")"
}

# Which configurations to run, one per line: `key [ENV=V ...]`. The key
# `boehm` runs the Boehm binary; every other key runs the gcry binary with the
# listed environment. Default is the four that answer "what does the sound
# profile cost as a whole".
#
# Override to decompose it knob by knob — in ONE job, so every config sees the
# same host conditions and the comparison is internal to the run:
#
#   BENCH_CONFIGS='boehm
#   tuned
#   unaligned GCRY_UNALIGNED_CANDIDATES=1
#   interior GCRY_INTERIOR=1' ./bench/sound_profile_ab.sh
CONFIGS="${BENCH_CONFIGS:-$(cat <<'EOF'
boehm
tuned
sound GCRY_SOUND=1
sound-cons GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1
EOF
)}"

KEYS=()
while read -r key rest; do
  [ -n "$key" ] || continue
  case "$key" in \#*) continue ;; esac
  KEYS+=("$key")
  # $rest is deliberately unquoted: it is a list of ENV=V words, not one word.
  if [ "$key" = "boehm" ]; then
    run_config "$key" "$BIN/kemal-boehm-sound" 0 $rest
  else
    run_config "$key" "$BIN/kemal-gcry-sound" 1 $rest
  fi
done <<< "$CONFIGS"

echo ""
python3 - "$RUN_DIR" "${KEYS[@]}" <<'PY'
import json, os, sys

run_dir = sys.argv[1]
keys = sys.argv[2:]
# Titles for the built-in configs; an ad-hoc key is titled by its own name.
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

# Boehm is the denominator when it was run; a knob-decomposition list that
# omits it is scored against its own first config instead.
base_key = "boehm" if "boehm" in data else keys[0]
base_rps = data[base_key]["thr"]["median"]
base_rss = float(data[base_key]["inst"]["rss_kib"])

rows = []
for k in keys:
    rps = data[k]["thr"]["median"]
    rss = float(data[k]["inst"]["rss_kib"])
    rows.append({
        "key": k,
        "title": titles.get(k, k),
        "env": data[k]["inst"].get("env", ""),
        "rps": rps,
        "pct": round(rps / base_rps * 100, 1) if base_rps else 0.0,
        "rss_kib": int(rss),
        "rss_x": round(rss / base_rss, 3) if base_rss else 0.0,
        "pause_p50_ms": data[k]["inst"].get("pause_p50_ms"),
        "pause_p99_ms": data[k]["inst"].get("pause_p99_ms"),
        "soundness": data[k]["inst"].get("soundness"),
        "root_soundness": data[k]["inst"].get("root_soundness"),
        "barrier_soundness": data[k]["inst"].get("barrier_soundness"),
        "noise_ratio": data[k]["thr"]["noise_ratio"],
        "spread_pct": data[k]["thr"]["spread_pct"],
        "knobs": data[k]["inst"].get("knobs"),
    })

has_tuned = "tuned" in data
tuned_rps = data["tuned"]["thr"]["median"] if has_tuned else 0.0
for r in rows:
    r["vs_tuned_pct"] = (
        round((r["rps"] / tuned_rps - 1) * 100, 2) if tuned_rps else None
    )

print("=== Summary (same host, same run) ===")
head = f"{'config':34} {'req/s':>10} {'% Boehm':>9} {'RSS x':>8} {'p50 ms':>8}"
head += f" {'vs tuned':>9}" if has_tuned else ""
print(head + "  roots")
for r in rows:
    p50 = "-" if not r["pause_p50_ms"] else f"{r['pause_p50_ms']:.2f}"
    line = f"{r['title']:34} {r['rps']:>10.0f} {r['pct']:>8.1f}% {r['rss_x']:>8.2f} {p50:>8}"
    line += f" {r['vs_tuned_pct']:>+8.2f}%" if has_tuned else ""
    print(line + f"  {r['soundness'] or '-'}")

# Which knobs each config actually moved, read back off the live heap. A
# per-knob decomposition where the knob silently failed to apply would
# otherwise look like "this knob is free".
if has_tuned:
    tuned_knobs = data["tuned"]["inst"].get("knobs") or {}
    print("\nknob deltas vs tuned:")
    for r in rows:
        if r["key"] in (base_key, "tuned") or not r["knobs"]:
            continue
        diff = {k: v for k, v in r["knobs"].items() if tuned_knobs.get(k) != v}
        print(f"  {r['key']:16} {diff or '(NONE — identical to tuned)'}")

# Guard: a config that asked for the sound profile and did not get it is not a
# measurement, it is a duplicate of `tuned`. Keyed off the environment that was
# actually passed, so an ad-hoc BENCH_CONFIGS list is held to the same terms.
for r in rows:
    if "GCRY_SOUND=1" not in r["env"]:
        continue
    expect = "sound"
    if "GCRY_NURSERY=" in r["env"] or "GCRY_INCREMENTAL=1" in r["env"]:
        expect = "sound-roots-only"
    if r["soundness"] != expect:
        print(f"\nERROR: config '{r['key']}' reported soundness={r['soundness']!r} "
              f"(expected {expect!r}) for env: {r['env']}")
        sys.exit(1)

out = {
    "rows": rows,
    "base": base_key,
    "path": os.environ.get("BENCH_PATH", "/json"),
}
with open(os.path.join(run_dir, "summary.json"), "w") as f:
    f.write(json.dumps(out, indent=2) + "\n")

# Spread rides along in the table: a gap smaller than the spread that produced
# it is not a result, and the reader should not have to go find that out.
print("\nMarkdown (for docs/SOUND-DEFAULTS.md):\n")
print("| Config | req/s | % of Boehm | RSS × | pause p50 | spread |")
print("|--------|------:|-----------:|------:|----------:|-------:|")
for r in rows:
    p50 = "—" if not r["pause_p50_ms"] else f"{r['pause_p50_ms']:.2f} ms"
    pct = "—" if r["key"] == base_key else f"**{r['pct']:.1f}%**"
    rssx = "—" if r["key"] == base_key else f"**{r['rss_x']:.2f}×**"
    print(f"| {r['title']} | {r['rps']:.0f} | {pct} | {rssx} | {p50} | {r['spread_pct']:.2f}% |")
PY

echo ""
echo "log: $RUN_DIR"
