#!/usr/bin/env bash
# Paired A/B on the multi-mutator parked-fiber lag width, at Kemal EC4.
#
# Why this exists: `ROADMAP.md` carried "the EC4 pause is the parked-fiber lag
# scan" and proposed scanning a fully parked fiber from its own saved SP. The
# best that proposal can do is a lag of ~0, so a narrow lag measures its
# **upper bound** without touching the root scan - and an upper bound that
# lands in the noise closes the item without an STW protocol change.
#
# Arms alternate order across trials (ABBA). A fixed order is not a paired
# design: on this host the second arm of every pair inherited a warm CPU from
# the first, and that alone read as +24% throughput for whichever arm ran
# second. With the order alternated the same effect is 1.03x [0.93, 1.13].
#
#   TRIALS=8 DURATION=10 bench/lag_width_ab.sh
set -u

BIN="${BIN:-/tmp/gcry-lagsrv}"
PORT="${PORT:-3313}"
TRIALS="${TRIALS:-8}"
DURATION="${DURATION:-10}"
CONNS="${CONNS:-100}"
PAR="${PAR:-4}"
OUT="${OUT:-/tmp/gcry-lag-width-ab.txt}"

command -v wrk >/dev/null || { echo "ERROR: wrk not found"; exit 1; }
if [ ! -x "$BIN" ]; then
  echo "Building the EC4 server ($BIN)..."
  (cd "$(dirname "$0")/kemal" &&
    shards install --production >/dev/null 2>&1
    crystal build -Dgc_none -Dpreview_mt -Dexecution_context --release \
      src/server.cr -o "$BIN") || exit 1
fi

: >"$OUT"

run_arm() {
  local lag="$1" label="$2" err pid rps line
  err=$(mktemp)
  GCRY_LAG_DUMP=1 GCRY_STW_STACK_LAG="$lag" EC_PARALLELISM="$PAR" PORT="$PORT" \
    "$BIN" >/dev/null 2>"$err" &
  pid=$!
  sleep 3
  rps=$(wrk -c "$CONNS" -d "$DURATION" -t 4 "http://127.0.0.1:$PORT/json" 2>&1 |
    awk '/Requests\/sec/{print $2}')
  kill -INT "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  line=$(grep -m1 LAGDUMP "$err")
  rm -f "$err"
  echo "$label rps=$rps $line" | tee -a "$OUT"
}

echo "=== lag width A/B: $TRIALS trials (ABBA), ${DURATION}s, -c$CONNS, EC=$PAR ==="
for t in $(seq 1 "$TRIALS"); do
  if [ $((t % 2)) -eq 1 ]; then
    run_arm 262144 "trial$t shipped"
    run_arm 4096 "trial$t narrow"
  else
    run_arm 4096 "trial$t narrow"
    run_arm 262144 "trial$t shipped"
  fi
done

python3 - "$OUT" <<'PY'
import re, statistics, sys

rows = {}
for line in open(sys.argv[1]):
    m = re.match(r"trial(\d+) (\w+) ", line)
    if not m:
        continue
    kv = dict(re.findall(r"(\w+)=([\d.]+)", line))
    rows.setdefault(int(m.group(1)), {})[m.group(2)] = kv

pairs = [v for v in rows.values() if "shipped" in v and "narrow" in v]
if len(pairs) < 3:
    print("INCONCLUSIVE fewer than 3 complete pairs")
    raise SystemExit(1)


def ci(vals):
    m = statistics.mean(vals)
    if len(vals) < 2:
        return m, 0.0
    h = 1.96 * statistics.stdev(vals) / len(vals) ** 0.5
    return m, h


ratio = [float(p["narrow"]["rps"]) / float(p["shipped"]["rps"]) for p in pairs]
dp50 = [(float(p["shipped"]["pause_p50_ns"]) - float(p["narrow"]["pause_p50_ns"])) / 1e6
        for p in pairs]
read = [(float(p["shipped"]["read"]) / float(p["shipped"]["collections"]),
         float(p["narrow"]["read"]) / float(p["narrow"]["collections"])) for p in pairs]
nominal = [float(p["shipped"]["nominal"]) / float(p["shipped"]["collections"]) for p in pairs]

m, h = ci(ratio)
print(f"\npairs: {len(pairs)}")
print(f"throughput narrow/shipped: {m:.4f} [{m - h:.4f}, {m + h:.4f}]")
m, h = ci(dp50)
print(f"pause p50 removed by the narrow lag: {m:+.3f} ms [{m - h:.3f}, {m + h:.3f}], "
      f"{sum(1 for d in dp50 if d > 0)}/{len(dp50)} trials positive")
print(f"scanned after the skip: shipped {statistics.mean(r[0] for r in read) / 2**20:.2f} MiB, "
      f"narrow {statistics.mean(r[1] for r in read) / 2**20:.2f} MiB per collection")
print(f"nominal lag window:     {statistics.mean(nominal) / 2**20:.2f} MiB per collection")
print("\nThe narrow arm is the proposal's ceiling, not a shippable default: the lag is what")
print("covers a stale `stack_top` on a fiber in transit, and narrowing it narrows that")
print("cover. What the proposal needs instead is proof that a fiber is on no thread, and")
print("`fiber_lag_sp_known` reports how often that proof is available.")
PY
