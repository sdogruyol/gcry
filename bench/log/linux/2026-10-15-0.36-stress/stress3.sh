#!/usr/bin/env bash
# Round 2: the fast fuzzers at volume, the header layout, and the debug
# invariants. Same loop/lock/log shape as stress.sh.
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
flock "$LOCK" crystal build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_hdr
flock "$LOCK" crystal build -Dgc_none --release bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_rel
flock "$LOCK" crystal build -Dgc_none --release bench/thread_storm.cr -o bin/thread_storm_rel

loop stw-mt-property-test-headers-freelist 200 bash -c 'GCRY_BITMAP_ALLOC=0 bench/run_bounded.sh 60 /home/naruto/playground/.scratch/stress/out3/hdr.log -- bin/stw_mt_property_test_hdr --seed=$((RANDOM)) --iterations=200 --workers=2,4; rc=$?; [ $rc -eq 3 ] && echo SCHED >> /home/naruto/playground/.scratch/stress/out3/sched.count; [ $rc -eq 0 ] || [ $rc -eq 3 ]'
loop mt-property-test 200 bash -c 'bin/mt_property_test --seed=$((RANDOM)) --iterations=500 --workers=2,4,8'
loop thread-storm 300 bin/thread_storm --iterations=1000 --workers=10
loop thread-storm-release 300 bin/thread_storm_rel --iterations=2000 --workers=16
loop fuzz-60s 30 bash -c 'bin/fuzz --seconds=60 --seed=$((RANDOM * 32768 + RANDOM))'
loop pattern-fuzz 30 bash -c 'bin/pattern_fuzz --seed=$((RANDOM)) --phases=200 --objects-per-phase=5000'
loop process-spec-invariants 3 env GCRY_DEBUG_INVARIANTS=1 crystal spec -Dgc_none process_spec
loop process-spec-headers-freelist 3 env GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec
echo "$(date -Is) done" | tee -a "$SUM"
