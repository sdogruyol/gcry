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
#
# A config key may also be written `key@binary` to run a *different build* under
# this same harness, interleaved with the rest. That is how a master-vs-branch
# control is taken on the default path: the added work lands directly in
# roots_ns, so the trace bounds it far tighter than throughput can.
#
#   git worktree add /tmp/gcry-master master
#   (cd /tmp/gcry-master/bench/kemal && shards install &&
#    crystal build -Dgc_none --release src/server.cr -o "$PWD/../../../bin/kemal-master")
#   BENCH_CONFIGS='branch
#   master@kemal-master' ./bench/root_phase_ab.sh
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
  local key="$1" rep="$2" bin="$3"; shift 3
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
    # A config may ask for the server to run with address-space randomisation
    # off (`key BENCH_NO_ASLR=1`). The null control showed the residual spread
    # is per-process rather than environmental, and layout randomisation is the
    # obvious per-process draw — this is how that gets tested rather than
    # assumed.
    if [ "${BENCH_NO_ASLR:-0}" = "1" ]; then
      exec setarch "$(uname -m)" -R "$bin"
    fi
    exec "$bin"
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
  # Post-GC RSS. A phase breakdown cannot show retention, and retention is the
  # only reason some of these knobs are on by default — scrub_fibers was turned
  # on for RSS, not for time. Two collects: the first leaves finalizer-queued
  # objects for the second to reclaim.
  curl -sf -o /dev/null ${HDR[@]+"${HDR[@]}"} "$BASE/gc-collect" || true
  curl -sf -o /dev/null ${HDR[@]+"${HDR[@]}"} "$BASE/gc-collect" || true
  awk '/^VmRSS:/ {print $2}' "/proc/$SERVER_PID/status" \
    > "$RUN_DIR/$key-rep$rep-rss.txt" 2>/dev/null || true
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
# Record the machine. A cut taken on a 4-core i3 was compared against figures
# from a 16-core 9950X for a whole session before anyone noticed, because
# nothing in the log said which host produced it.
CPU_MODEL="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
CPU_COUNT="$(nproc 2>/dev/null || echo 0)"
L3_SHARED="$(cat /sys/devices/system/cpu/cpu0/cache/index3/shared_cpu_list 2>/dev/null || echo unknown)"
echo "host: $CPU_MODEL  ncpu=$CPU_COUNT  L3 shared by: $L3_SHARED"
python3 -c "
import json, os
print(json.dumps({
    'bin': '$BIN_NAME', 'build_flags': '${BUILD_FLAGS:-}',
    'ec_parallelism': os.environ.get('EC_PARALLELISM', '1'),
    'reps': $REPS, 'duration_s': $DURATION, 'connections': $CONNECTIONS,
    'cpu_model': '''$CPU_MODEL''', 'ncpu': $CPU_COUNT,
    'l3_shared_cpu_list': '$L3_SHARED',
}, indent=2))" > "$RUN_DIR/meta.json"

KEYS=()
ENVS=()
BINS=()
while read -r key rest; do
  [ -n "$key" ] || continue
  case "$key" in \#*) continue ;; esac
  # `key@binary` drives a *different build* under this same harness, so a
  # master-vs-branch control is one interleaved job rather than two runs
  # compared across time. The named binary must already exist in bin/ — build
  # it from a `git worktree` checkout; only $BIN_NAME is built here.
  alt=0
  case "$key" in
    *@*) BINS+=("$BIN/${key#*@}"); key="${key%@*}"; alt=1 ;;
    *) BINS+=("$SERVER_BIN") ;;
  esac
  KEYS+=("$key")
  ENVS+=("$rest")
  printf '%s\n' "$rest" > "$RUN_DIR/$key.env"
  printf '%s\n' "${BINS[-1]}" > "$RUN_DIR/$key.bin"
  # A `key@binary` row is a different build on purpose — usually an older one,
  # since the point is to control against master. The stale-binary check below
  # must not fire on it; it exists for the rows that are supposed to be *this*
  # checkout.
  [ "$alt" = "1" ] && : > "$RUN_DIR/$key.altbin"
done <<< "$CONFIGS"

for i in "${!KEYS[@]}"; do
  [ -x "${BINS[$i]}" ] || {
    echo "ERROR: ${BINS[$i]} not executable (key=${KEYS[$i]})" >&2; exit 1; }
done

# Reps interleaved and rotated, NOT all of one config's reps then the next.
#
# Blocked execution confounds config with time. In the throughput harness on
# this host it was worth ~2-3% (see bench/sound_profile_ab.sh and the FINDINGS
# it writes) — an order of magnitude more than the ~0.3% SEM this instrument
# can otherwise resolve, and it is bias, so more reps never remove it. Rotating
# the within-round order removes the residual position bias that interleaving
# alone leaves behind.
n_keys=${#KEYS[@]}
for rep in $(seq 1 "$REPS"); do
  echo ""
  echo "=== rep $rep/$REPS ==="
  for off in $(seq 0 $((n_keys - 1))); do
    i=$(( (off + rep - 1) % n_keys ))
    key="${KEYS[$i]}"
    echo "  $key ${ENVS[$i]:+(${ENVS[$i]})}"
    # ${ENVS[$i]} unquoted on purpose: a list of ENV=V words, not one word.
    probe "$key" "$rep" "${BINS[$i]}" ${ENVS[$i]}
    n="$(grep -c collect_end "$RUN_DIR/$key-rep$rep.ndjson" || true)"
    echo "    $n collections"
  done
done

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
    # Median across reps, not one rep: a single post-GC RSS reading is one
    # sample of a noisy quantity, and this is the axis some of these knobs
    # exist for.
    rss = []
    for rep in range(1, reps + 1):
        p = os.path.join(run_dir, f"{k}-rep{rep}-rss.txt")
        if os.path.exists(p):
            v = open(p).read().strip()
            if v.isdigit():
                rss.append(int(v))
    data[k] = {
        "n": len(recs),
        "env": env,
        "soundness": label,
        "threads": threads,
        "rss_kib": statistics.median(rss) if rss else None,
        "rss_reps": rss,
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

base_rss = data["tuned"]["rss_kib"] if "tuned" in data else data[keys[0]]["rss_kib"]
if base_rss:
    print("\npost-GC RSS (median of reps; ΔRSS vs tuned) — the retention axis:")
    for k in keys:
        r = data[k]["rss_kib"]
        if not r:
            continue
        d = (r - base_rss) / base_rss * 100
        reps_s = ",".join(str(x) for x in data[k]["rss_reps"])
        print(f"  {k:18} {r:>8} KiB  {d:>+7.1f}%   reps: {reps_s}")

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
    # Telling the reader to stratify without shipping the tool is how the fat
    # app's numbers ended up being re-derived by hand each time.
    print("\n    Stratify with:")
    print(f"      bench/stratify_root_phase.py {os.path.relpath(run_dir)} --cut=<MiB>")
    print("    Pick --cut in the trough between the p50 and p90 modes above.")

out = {
    "reps": reps, "skip": skip,
    "configs": {k: data[k] for k in keys},
}
with open(os.path.join(run_dir, "summary.json"), "w") as f:
    f.write(json.dumps(out, indent=2) + "\n")

# A knob config that reports `sound` (or a sound config that does not) means
# the environment did not do what the row claims it did.
#
# `None` is a different failure and worth naming: /gc-stats answered but had no
# `soundness` key, which means the server is linked against a gcry old enough to
# predate it. That is a *stale binary*, and every number above was produced by a
# collector other than the one in the tree — the most expensive way to be wrong
# here, so it fails rather than warns.
for k in keys:
    env, got = data[k]["env"], data[k]["soundness"]
    want = "sound" if "GCRY_SOUND=1" in env else "tuned"
    alt = os.path.exists(os.path.join(run_dir, f"{k}.altbin"))
    if got is None:
        if alt:
            print(f"note: '{k}' is a foreign build (key@binary) and reports no 'soundness' "
                  f"— expected when controlling against an older revision; not checked.")
            continue
        print(f"\nERROR: config '{k}': /gc-stats has no 'soundness' field — the server "
              f"binary predates it. Rebuild it against this checkout; the phase numbers "
              f"above are from a different collector.")
        sys.exit(1)
    if got != want:
        print(f"\nERROR: config '{k}' reported soundness={got!r}, expected {want!r} (env: {env or 'none'})")
        sys.exit(1)
PY

echo ""
echo "log: $RUN_DIR"
