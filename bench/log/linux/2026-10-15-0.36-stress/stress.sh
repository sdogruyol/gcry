#!/usr/bin/env bash
# Overnight stress of one gcry tree: each gate/fuzzer N times under the shared
# heavy lock, `<name> <failures>/<runs>` per loop, failing runs' tails kept.
# Usage: stress.sh <gcry-tree> <outdir>
set -u
tree=$1 out=$2
mkdir -p "$out"
cd "$tree" || exit 1
LOCK=/home/naruto/playground/.scratch/heavy.lock
LOG="$out/failures.log"; SUM="$out/summary.txt"
: > "$LOG"; : > "$SUM"
loop() {
  local name=$1 runs=$2; shift 2
  local fails=0 i out t0
  t0=$(date +%s)
  for i in $(seq 1 "$runs"); do
    if ! out="$(flock "$LOCK" timeout 1200 "$@" 2>&1)"; then
      fails=$((fails + 1))
      { echo "=== $name run $i FAILED $(date -Is) ==="; echo "$out" | tail -60; } >> "$LOG"
    fi
  done
  echo "$(date -Is) $name ${fails}/${runs} failed ($(( $(date +%s) - t0 )) s)" | tee -a "$SUM"
}
mkdir -p bin
# Build once; the loops run binaries with fresh seeds.
flock "$LOCK" crystal build bench/fuzz.cr -o bin/fuzz
flock "$LOCK" crystal build bench/property_test.cr -o bin/property_test
flock "$LOCK" crystal build bench/mt_property_test.cr -o bin/mt_property_test
flock "$LOCK" crystal build -Dgc_none bench/stw_mt_property_test.cr -o bin/stw_mt_property_test
flock "$LOCK" crystal build -Dgc_none bench/pattern_fuzz.cr -o bin/pattern_fuzz
flock "$LOCK" crystal build -Dgc_none bench/thread_storm.cr -o bin/thread_storm

loop fuzz 40 bash -c 'bin/fuzz --seconds=30 --seed=$((RANDOM * 32768 + RANDOM))'
loop property-test 20 bash -c 'bin/property_test --seed=$((RANDOM)) --iterations=100000'
loop mt-property-test 20 bash -c 'bin/mt_property_test --seed=$((RANDOM)) --iterations=500 --workers=2,4,8'
loop stw-mt-property-test 30 bash -c 'bin/stw_mt_property_test --seed=$((RANDOM)) --iterations=200 --workers=2,4,8'
loop pattern-fuzz 20 bash -c 'bin/pattern_fuzz --seed=$((RANDOM)) --phases=200 --objects-per-phase=5000'
loop thread-storm 20 bin/thread_storm --iterations=1000 --workers=10
loop realloc-move-stress 10 make realloc-move-stress
loop chunk-list-drift 6 make chunk-list-drift
loop large-cache-race 10 make large-cache-race
loop counter-loss 10 make counter-loss
loop thread-churn-uaf 4 make thread-churn-uaf
loop soak-smoke 6 make soak-smoke
loop soft-soak-ec4-smoke 4 make soft-soak-ec4-smoke
loop process-spec 6 crystal spec -Dgc_none process_spec
echo "$(date -Is) done" | tee -a "$SUM"
