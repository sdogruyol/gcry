#!/usr/bin/env bash
# What does each root-completeness heuristic cost *where it is spent*?
#
# End-to-end throughput cannot answer this on a noisy host: the sound profile's
# effect on req/s is smaller than the run-to-run spread, and no number of runs
# fixes a host whose spread is 10-25% (see FINDINGS in the log dir this
# writes). So measure the collector instead of the process around it.
#
# `GCRY_TRACE=1` emits one collect_end record per collection with a full phase
# breakdown. A 30s Kemal run yields ~200 of them, so each config produces a
# distribution rather than the single last-collection snapshot `/gc-stats`
# exposes. The load generator's variance moves how *many* collections happen,
# not what each one costs.
#
# This measures pause composition, NOT throughput. It says where the sound
# profile spends its extra time and how the knobs rank against each other; it
# does not license a "costs N% of throughput" claim on its own.
#
#   BENCH_REPS=3 WRK_DURATION=20 ./bench/root_phase_ab.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
LOG="$ROOT/bench/log"
KEMAL="$ROOT/bench/kemal"
PORT="${PORT:-3027}"
BASE="http://127.0.0.1:${PORT}"
DURATION="${WRK_DURATION:-20}"
CONNECTIONS="${WRK_CONNECTIONS:-100}"
REPS="${BENCH_REPS:-3}"
# The first collections run against a heap that is still growing, so they are
# not samples of the steady state the rest of the run measures.
SKIP="${BENCH_SKIP_COLLECTS:-5}"

command -v wrk >/dev/null || { echo "ERROR: wrk not found"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }
mkdir -p "$BIN"

cd "$KEMAL"
shards install --production 2>/dev/null || shards install
echo "Building kemal-gcry..."
crystal build -Dgc_none --release src/server.cr -o "$BIN/kemal-gcry-sound"
cd "$ROOT"

SERVER_PID=""
stop_server() {
  [ -n "${SERVER_PID:-}" ] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}
trap stop_server EXIT INT TERM

RUN_LABEL="$(date -u +%Y-%m-%d-%H%M%S)-root-phase"
RUN_DIR="$LOG/linux/$RUN_LABEL"
mkdir -p "$RUN_DIR"

# One config × one rep: run under trace, capture the collector's own label.
probe() {
  local key="$1" rep="$2"; shift 2
  local trace="$RUN_DIR/$key-rep$rep.ndjson"
  env PORT="$PORT" GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE="$trace" \
    "$@" "$BIN/kemal-gcry-sound" >/dev/null 2>&1 &
  SERVER_PID=$!
  local ready=0
  for _ in $(seq 1 40); do
    curl -sf -o /dev/null "$BASE/" && { ready=1; break; }
    sleep 0.25
  done
  if [ "$ready" != "1" ]; then
    echo "ERROR: server did not answer $BASE/ — key=$key env=$*" >&2
    exit 1
  fi
  wrk -c "$CONNECTIONS" -d "${DURATION}s" "$BASE/json" >/dev/null 2>&1
  curl -sf "$BASE/gc-stats" > "$RUN_DIR/$key-rep$rep-stats.json" || true
  stop_server
  sleep 0.4
}

CONFIGS="${BENCH_CONFIGS:-$(cat <<'EOF'
tuned
sound GCRY_SOUND=1
unaligned GCRY_UNALIGNED_CANDIDATES=1
interior GCRY_INTERIOR=1
no-type-id-gate GCRY_DISABLE_TYPE_ID_GATE=1
no-stw-lag GCRY_STW_STACK_LAG=0 GCRY_STW_PTHREAD_LAG=0
no-scrub GCRY_DISABLE_SCRUB_FIBERS=1
no-blacklist GCRY_DISABLE_BLACKLIST=1
EOF
)}"

echo ""
echo "reps=$REPS  duration=${DURATION}s  connections=$CONNECTIONS  skip=$SKIP collects/rep"

KEYS=()
while read -r key rest; do
  [ -n "$key" ] || continue
  case "$key" in \#*) continue ;; esac
  KEYS+=("$key")
  echo ""
  echo "=== $key ${rest:+($rest)} ==="
  printf '%s\n' "$rest" > "$RUN_DIR/$key.env"
  for rep in $(seq 1 "$REPS"); do
    # $rest unquoted on purpose: a list of ENV=V words, not one word.
    probe "$key" "$rep" $rest
    n="$(grep -c collect_end "$RUN_DIR/$key-rep$rep.ndjson" || true)"
    echo "  rep $rep: $n collections"
  done
done <<< "$CONFIGS"

echo ""
python3 - "$RUN_DIR" "$SKIP" "$REPS" "${KEYS[@]}" <<'PY'
import json, os, statistics, sys

run_dir, skip, reps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
keys = sys.argv[4:]
PHASES = ["roots_ns", "static_ns", "stacks_ns", "scrub_ns", "mark_ns",
          "sweep_ns", "pause_ns"]


def samples(key):
    """Every steady-state collect_end record for a config, across all reps."""
    out = []
    for rep in range(1, reps + 1):
        path = os.path.join(run_dir, f"{key}-rep{rep}.ndjson")
        recs = []
        with open(path) as f:
            for line in f:
                if '"collect_end"' not in line:
                    continue
                try:
                    recs.append(json.loads(line))
                except ValueError:
                    continue  # a truncated last line on kill is not a sample
        out.extend(recs[skip:])
    return out


data = {}
for k in keys:
    recs = samples(k)
    env = open(os.path.join(run_dir, f"{k}.env")).read().strip()
    label = None
    stats_path = os.path.join(run_dir, f"{k}-rep1-stats.json")
    if os.path.exists(stats_path):
        try:
            label = json.load(open(stats_path)).get("soundness")
        except ValueError:
            pass
    data[k] = {
        "n": len(recs),
        "env": env,
        "soundness": label,
        "median": {p: statistics.median([r.get(p, 0) for r in recs]) for p in PHASES},
        "iqr": {
            p: (
                statistics.quantiles([r.get(p, 0) for r in recs], n=4)[2]
                - statistics.quantiles([r.get(p, 0) for r in recs], n=4)[0]
            )
            if len(recs) >= 4 else 0.0
            for p in PHASES
        },
    }

base = data["tuned"]["median"] if "tuned" in data else data[keys[0]]["median"]

print("=== Per-collection phase cost, median over all steady-state collections ===")
print("(microseconds; Δ is vs tuned on the root phase)\n")
hdr = f"{'config':18} {'n':>5} " + " ".join(f"{p[:-3]:>9}" for p in PHASES)
print(hdr + f" {'Δroots':>9}  label")
for k in keys:
    d = data[k]
    cells = " ".join(f"{d['median'][p]/1000:>9.1f}" for p in PHASES)
    droot = d["median"]["roots_ns"] - base["roots_ns"]
    dpct = (droot / base["roots_ns"] * 100) if base["roots_ns"] else 0.0
    print(f"{k:18} {d['n']:>5} {cells} {dpct:>+8.1f}%  {d['soundness'] or '-'}")

print("\nroot-phase spread (IQR as % of median) — how tight each config's own samples are:")
for k in keys:
    d = data[k]
    m = d["median"]["roots_ns"]
    print(f"  {k:18} {d['iqr']['roots_ns']/m*100:>6.1f}%" if m else f"  {k:18}      -")

out = {
    "reps": reps, "skip": skip,
    "configs": {k: data[k] for k in keys},
}
with open(os.path.join(run_dir, "summary.json"), "w") as f:
    f.write(json.dumps(out, indent=2) + "\n")

# A knob config that reports `sound` (or a sound config that does not) means
# the environment did not do what the row claims it did.
for k in keys:
    env, got = data[k]["env"], data[k]["soundness"]
    want = "sound" if "GCRY_SOUND=1" in env else "tuned"
    if got != want:
        print(f"\nERROR: config '{k}' reported soundness={got!r}, expected {want!r} (env: {env or 'none'})")
        sys.exit(1)
PY

echo ""
echo "log: $RUN_DIR"
