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

# Parallel EC needs its own binary: the server's `ExecutionContext.default
# .resize(N)` is a no-op unless the build carries -Dpreview_mt
# -Dexecution_context, so an EC4 run against the EC1 binary silently measures
# EC1 again. Separate output names keep the two from overwriting each other.
#
#   CRYSTAL_BUILD_FLAGS="-Dpreview_mt -Dexecution_context" \
#   BENCH_BIN=kemal-gcry-sound-mt EC_PARALLELISM=4 ./bench/root_phase_ab.sh
BUILD_FLAGS="${CRYSTAL_BUILD_FLAGS:-}"
BIN_NAME="${BENCH_BIN:-kemal-gcry-sound}"

# Driving a server other than the bundled Kemal one (the fat app, say). The
# collector knobs are gcry-level env vars, so anything linked against gcry can
# be measured — it just has to be built and launched on its own terms.
#
#   BENCH_SKIP_BUILD=1 BENCH_SERVER_BIN=../acikturkiye/bin/acikturkiye-gcry \
#   BENCH_SERVER_DIR=../acikturkiye BENCH_ENV_FILE=.env.demo \
#   BENCH_PORT_ENV=ACIKTURKIYE_SERVER_PORT BENCH_READY_PATH=/api/v1/ \
#   BENCH_LOAD_PATH=/api/v1/ ./bench/root_phase_ab.sh
SERVER_BIN="${BENCH_SERVER_BIN:-$BIN/$BIN_NAME}"
SERVER_DIR="${BENCH_SERVER_DIR:-}"
ENV_FILE="${BENCH_ENV_FILE:-}"
PORT_ENV="${BENCH_PORT_ENV:-PORT}"
READY_PATH="${BENCH_READY_PATH:-/}"
LOAD_PATH="${BENCH_LOAD_PATH:-/json}"

# Extra environment applied to every config (KEY=VAL per line) — app settings
# like ACIKTURKIYE_ENV=demo, not collector knobs.
SERVER_ENV=()
if [ -n "${BENCH_SERVER_ENV:-}" ]; then
  while IFS= read -r kv; do
    [ -n "$kv" ] && SERVER_ENV+=("$kv")
  done <<< "$BENCH_SERVER_ENV"
fi

# Request headers for the ready check and the load pass (`Name: value` per
# line) — the fat app's API needs auth on every request.
HDR=()
if [ -n "${BENCH_HEADERS:-}" ]; then
  while IFS= read -r h; do
    [ -n "$h" ] && HDR+=(-H "$h")
  done <<< "$BENCH_HEADERS"
fi

if [ "${BENCH_SKIP_BUILD:-0}" = "1" ]; then
  echo "Using prebuilt server: $SERVER_BIN"
  [ -x "$SERVER_BIN" ] || { echo "ERROR: $SERVER_BIN not executable"; exit 1; }
else
  cd "$KEMAL"
  shards install --production 2>/dev/null || shards install
  echo "Building $BIN_NAME ${BUILD_FLAGS:+($BUILD_FLAGS)}..."
  # $BUILD_FLAGS unquoted on purpose: a list of flags, not one word.
  crystal build -Dgc_none $BUILD_FLAGS --release src/server.cr -o "$BIN/$BIN_NAME"
  cd "$ROOT"
fi

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
  (
    [ -n "$SERVER_DIR" ] && cd "$SERVER_DIR"
    if [ -n "$ENV_FILE" ]; then
      set -a; . "$ENV_FILE"; set +a
      # The app's own env file may set GCRY_*. Strip it, so the config under
      # test is the only thing steering the collector — otherwise a knob row
      # silently measures whatever the deployment env happened to ask for.
      while IFS= read -r k; do [ -n "$k" ] && unset "$k"; done \
        < <(env | awk -F= '/^GCRY_/ {print $1}')
    fi
    export "$PORT_ENV=$PORT"
    export GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE="$trace"
    for kv in ${SERVER_ENV[@]+"${SERVER_ENV[@]}"}; do export "${kv?}"; done
    for kv in "$@"; do export "${kv?}"; done
    exec "$SERVER_BIN"
  ) >/dev/null 2>&1 &
  SERVER_PID=$!
  local ready=0
  for _ in $(seq 1 120); do
    curl -sf -o /dev/null ${HDR[@]+"${HDR[@]}"} "$BASE$READY_PATH" && { ready=1; break; }
    sleep 0.25
  done
  if [ "$ready" != "1" ]; then
    echo "ERROR: server did not answer $BASE$READY_PATH — key=$key env=$*" >&2
    exit 1
  fi
  wrk -c "$CONNECTIONS" -d "${DURATION}s" ${HDR[@]+"${HDR[@]}"} "$BASE$LOAD_PATH" >/dev/null 2>&1
  curl -sf ${HDR[@]+"${HDR[@]}"} "$BASE/gc-stats" > "$RUN_DIR/$key-rep$rep-stats.json" || true
  # Proof of the shape that actually ran: a binary built without -Dpreview_mt
  # resizes the default context to a no-op, so an EC4 run would otherwise be
  # indistinguishable from EC1 in the log.
  awk '/^Threads:/ {print $2}' "/proc/$SERVER_PID/status" \
    > "$RUN_DIR/$key-rep$rep-threads.txt" 2>/dev/null || true
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
echo "bin=$BIN_NAME  build_flags=${BUILD_FLAGS:-none}  EC_PARALLELISM=${EC_PARALLELISM:-1}"
python3 -c "
import json, os
print(json.dumps({
    'bin': '$BIN_NAME', 'build_flags': '${BUILD_FLAGS:-}',
    'ec_parallelism': os.environ.get('EC_PARALLELISM', '1'),
    'reps': $REPS, 'duration_s': $DURATION, 'connections': $CONNECTIONS,
}, indent=2))" > "$RUN_DIR/meta.json"

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
    threads_path = os.path.join(run_dir, f"{k}-rep1-threads.txt")
    threads = None
    if os.path.exists(threads_path):
        threads = open(threads_path).read().strip() or None
    data[k] = {
        "n": len(recs),
        "env": env,
        "soundness": label,
        "threads": threads,
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
print("(microseconds; Δwork = roots+scrub+stacks vs tuned; thr = server threads)\n")
# Two deltas, because neither alone is honest:
#
#   Δwork  = roots + scrub + stacks. `roots_ns` is `monotonic_ns - t0 -
#            scrub_ns`, so it excludes scrub — and scrub is one of the knobs.
#            `stacks_ns` is a SEPARATE additive phase, not a sub-timing of
#            roots: GCRY_STW_PTHREAD_LAG=0 leaves roots flat and moves stacks
#            15×, which a roots-only (or roots+scrub) basis reports as ~free.
#   Δpause = what the mutator actually waits for, and the number a latency
#            claim has to cite.
def work_of(m):
    return m["roots_ns"] + m["scrub_ns"] + m["stacks_ns"]


base_work, base_pause = work_of(base), base["pause_ns"]
hdr = f"{'config':18} {'n':>5} " + " ".join(f"{p[:-3]:>9}" for p in PHASES)
print(hdr + f" {'Δwork':>9} {'Δpause':>9} {'thr':>4}  label")
for k in keys:
    d = data[k]
    cells = " ".join(f"{d['median'][p]/1000:>9.1f}" for p in PHASES)
    work = work_of(d["median"])
    dwork = ((work - base_work) / base_work * 100) if base_work else 0.0
    dpause = ((d["median"]["pause_ns"] - base_pause) / base_pause * 100) if base_pause else 0.0
    d["work_ns"] = work
    d["delta_work_pct"] = round(dwork, 2)
    d["delta_pause_pct"] = round(dpause, 2)
    print(f"{k:18} {d['n']:>5} {cells} {dwork:>+8.1f}% {dpause:>+8.1f}% "
          f"{d['threads'] or '-':>4}  {d['soundness'] or '-'}")

print("\nroot-phase spread (IQR as % of median) — how tight each config's own samples are:")
for k in keys:
    d = data[k]
    m = d["median"]["roots_ns"]
    print(f"  {k:18} {d['iqr']['roots_ns']/m*100:>6.1f}%" if m else f"  {k:18}      -")

# A median only summarises a unimodal sample. The fat app has two collection
# regimes (heap ~43 MiB and heap ~60+ MiB) whose root cost differs 15×, and
# each config lands a different share of its samples in each — which made the
# raw medians say the sound profile was *cheaper* than tuned. Refuse to let
# that read as a result.
suspect = [k for k in keys
           if data[k]["median"]["roots_ns"]
           and data[k]["iqr"]["roots_ns"] / data[k]["median"]["roots_ns"] > 0.5]
if suspect:
    print("\n*** WARNING: multimodal samples — these medians are NOT comparable ***")
    print(f"    configs with IQR > 50% of median: {', '.join(suspect)}")
    print("    The run mixes collection regimes. Stratify (heap_size is the usual")
    print("    discriminator) and compare within a stratum before quoting anything.")
    for k in suspect:
        hs = sorted(r.get("heap_size", 0) for r in samples(k))
        print(f"      {k:18} heap MiB p10/p50/p90: "
              f"{hs[len(hs)//10]/1048576:.0f} / {hs[len(hs)//2]/1048576:.0f} / "
              f"{hs[9*len(hs)//10]/1048576:.0f}")

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
