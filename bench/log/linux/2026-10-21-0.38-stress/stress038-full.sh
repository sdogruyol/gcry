#!/usr/bin/env bash
# Overnight stress of one gcry tree (0.38.0; stress037.sh plus the claim arms). Each loop: N runs, each under the
# host-wide heavy lock and bounded; `<name> <failures>/<runs>` per loop, and
# every failing run's tail kept. Property tests that run a Parallel execution
# context go through bench/run_bounded.sh, which captures a stall and
# classifies Crystal's Parallel-scheduler deadlock (exit 3, upstream #17486)
# apart from a gcry failure.
# Usage: stress038-full.sh <gcry-tree> <outdir>
set -u
tree=$1 out=$2
mkdir -p "$out"
cd "$tree" || exit 1
LOCK=/home/naruto/playground/.scratch/heavy.lock
LOG="$out/failures.log"; SUM="$out/summary.txt"
: > "$LOG"; : > "$SUM"
loop() {
  local name=$1 runs=$2; shift 2
  local fails=0 i o t0
  t0=$(date +%s)
  for i in $(seq 1 "$runs"); do
    if ! o="$(flock "$LOCK" timeout 1200 "$@" 2>&1)"; then
      fails=$((fails + 1))
      { echo "=== $name run $i FAILED $(date -Is) ==="; echo "$o" | tail -60; } >> "$LOG"
    fi
  done
  echo "$(date -Is) $name ${fails}/${runs} failed ($(( $(date +%s) - t0 )) s)" | tee -a "$SUM"
}
# Bounded loop for Parallel-context harnesses: exit 0 pass, 1 fail, 2 stall,
# 3 known scheduler deadlock (counted apart, capture kept).
bloop() {
  local name=$1 runs=$2; shift 2
  local pass=0 fail=0 stall=0 sched=0 i rc t0 s
  t0=$(date +%s)
  for i in $(seq 1 "$runs"); do
    s=$RANDOM
    flock "$LOCK" bench/run_bounded.sh 90 "$out/$name.run.log" -- "$@" --seed=$s
    rc=$?
    case $rc in
      0) pass=$((pass + 1)) ;;
      1) fail=$((fail + 1)); cp "$out/$name.run.log" "$out/$name-fail-$i-seed$s.log" ;;
      2) stall=$((stall + 1)); cp "$out/$name.run.log" "$out/$name-stall-$i-seed$s.log" ;;
      3) sched=$((sched + 1)); cp "$out/$name.run.log" "$out/$name-sched-$i-seed$s.log" ;;
    esac
  done
  echo "$(date -Is) $name runs=$runs pass=$pass fail=$fail stall=$stall crystal_scheduler_deadlock=$sched ($(( $(date +%s) - t0 )) s)" | tee -a "$SUM"
}
mkdir -p bin
flock "$LOCK" crystal build bench/fuzz.cr -o bin/fuzz
flock "$LOCK" crystal build bench/property_test.cr -o bin/property_test
flock "$LOCK" crystal build bench/mt_property_test.cr -o bin/mt_property_test
flock "$LOCK" crystal build -Dgc_none bench/stw_mt_property_test.cr -o bin/stw_mt_property_test
flock "$LOCK" crystal build -Dgc_none --release bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_rel
flock "$LOCK" crystal build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_hdr
flock "$LOCK" crystal build -Dgc_none bench/pattern_fuzz.cr -o bin/pattern_fuzz
flock "$LOCK" crystal build -Dgc_none --release bench/thread_storm.cr -o bin/thread_storm_rel
flock "$LOCK" crystal build -Dgc_none --release bench/claim_stress.cr -o bin/claim_stress_rel

loop fuzz-60s 30 bash -c 'bin/fuzz --seconds=60 --seed=$((RANDOM * 32768 + RANDOM))'
loop property-test 20 bash -c 'bin/property_test --seed=$((RANDOM)) --iterations=100000'
loop mt-property-test 100 bash -c 'bin/mt_property_test --seed=$((RANDOM)) --iterations=500 --workers=2,4,8'
bloop stw-mt-property-test 200 bin/stw_mt_property_test --iterations=200 --workers=2,4,8
bloop stw-mt-property-test-release 300 bin/stw_mt_property_test_rel --iterations=400 --workers=2,4,8
loop stw-mt-property-test-headers-freelist 150 bash -c 'GCRY_BITMAP_ALLOC=0 bin/stw_mt_property_test_hdr --seed=$((RANDOM)) --iterations=200 --workers=2,4'
loop pattern-fuzz 30 bash -c 'bin/pattern_fuzz --seed=$((RANDOM)) --phases=200 --objects-per-phase=5000'
loop pattern-fuzz-headers-freelist 30 bash -c 'GCRY_BITMAP_ALLOC=0 bin/pattern_fuzz --seed=$((RANDOM)) --phases=200 --objects-per-phase=5000'
bloop claim-stress-lazy 200 bin/claim_stress_rel --seconds=5 --workers=4
bloop claim-stress-in-stop 300 env GCRY_DISABLE_LAZY_SWEEP=1 bin/claim_stress_rel --seconds=5 --workers=4
loop thread-storm-release 200 bin/thread_storm_rel --iterations=2000 --workers=16
loop parallel-mark-process 20 make parallel-mark-process
loop parallel-mark-termination 6 make parallel-mark-termination
loop mark-audit 6 make mark-audit
loop chunk-list-drift 6 make chunk-list-drift
loop large-cache-race 10 make large-cache-race
loop counter-loss 10 make counter-loss
loop realloc-move-stress 6 make realloc-move-stress
loop thread-churn-uaf 4 make thread-churn-uaf
loop soak-smoke 6 make soak-smoke
loop soft-soak-ec4-smoke 4 make soft-soak-ec4-smoke
loop process-spec 4 crystal spec -Dgc_none process_spec
loop process-spec-invariants 2 env GCRY_DEBUG_INVARIANTS=1 crystal spec -Dgc_none process_spec
loop process-spec-headers-freelist 2 env GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec
loop process-spec-crystal-1.22 2 env PATH=$HOME/.local/share/mise/installs/crystal/1.22.0/bin:$PATH crystal spec -Dgc_none process_spec
echo "$(date -Is) done" | tee -a "$SUM"
