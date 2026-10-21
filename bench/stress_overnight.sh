#!/usr/bin/env bash
# The release overnight stress, kept in the tree so each release runs the same
# set and its summary compares line for line with the last one.
#
#   bench/stress_overnight.sh <gcry-tree> <outdir> [scale]
#
# Every run goes through bench/run_bounded.sh, with its own seed in its log's
# name: a hang is captured (every thread's stack, of the harness and not of a
# wrapper — run_bounded.sh captures the leaves of the command's process tree)
# and killed with its whole tree, and the known Crystal Parallel-scheduler
# deadlock (crystal-lang/crystal#17486, exit 3) is counted apart from a gcry
# failure. Until 0.38.0 half of the loops ran under a bare `timeout`, and the
# one hang of that night left no capture
# (`bench/log/linux/2026-10-21-0.38-stress/`).
#
# Each run holds the host-wide heavy lock (HEAVY_LOCK, default the scratch
# lock), so other work interleaves between runs. `scale` multiplies every run
# count (default 1; 0.1 for a smoke of the script itself, at least one run per
# loop). Output: <outdir>/summary.txt, one line per loop:
#   <time> <name> runs=N pass=N fail=N stall=N crystal_scheduler_deadlock=N (S s)
# and <outdir>/<name>-{fail,stall,sched}-<i>-seed<seed>.log for every run that
# did not pass. 0.38.0's set took about 3.5 hours on a 12-vCPU host.
set -u
tree=$1 out=$2 scale=${3:-1}
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$tree" || exit 1
LOCK=${HEAVY_LOCK:-/home/naruto/playground/.scratch/heavy.lock}
SUM="$out/summary.txt"
: > "$SUM"

# runs <n>: the scaled run count, at least 1.
runs() { awk -v n="$1" -v s="$scale" 'BEGIN { r = int(n * s + 0.5); print (r < 1 ? 1 : r) }'; }

# loop <name> <runs> <limit-s> <command...>: `@SEED@` in the command is
# replaced by a fresh seed per run (and is harmless where a harness takes none).
loop() {
  local name=$1 n; n=$(runs "$2"); local limit=$3; shift 3
  local pass=0 fail=0 stall=0 sched=0 i rc seed t0 a cmd log
  t0=$(date +%s)
  for i in $(seq 1 "$n"); do
    seed=$((RANDOM * 32768 + RANDOM))
    cmd=()
    for a in "$@"; do cmd+=("${a//@SEED@/$seed}"); done
    log="$out/$name.run.log"
    flock "$LOCK" bench/run_bounded.sh "$limit" "$log" -- "${cmd[@]}"
    rc=$?
    case $rc in
      0) pass=$((pass + 1)) ;;
      2) stall=$((stall + 1)); cp "$log" "$out/$name-stall-$i-seed$seed.log" ;;
      3) sched=$((sched + 1)); cp "$log" "$out/$name-sched-$i-seed$seed.log" ;;
      *) fail=$((fail + 1)); cp "$log" "$out/$name-fail-$i-seed$seed.log" ;;
    esac
  done
  rm -f "$out/$name.run.log"
  echo "$(date -Is) $name runs=$n pass=$pass fail=$fail stall=$stall crystal_scheduler_deadlock=$sched ($(( $(date +%s) - t0 )) s)" | tee -a "$SUM"
}

mkdir -p bin
build() { flock "$LOCK" "$@" || { echo "$(date -Is) BUILD FAILED: $*" | tee -a "$SUM"; exit 1; }; }
build crystal build bench/fuzz.cr -o bin/fuzz
build crystal build bench/property_test.cr -o bin/property_test
# Without -Dgc_none: the library-heap arm, as `make mt-property-test` builds it.
build crystal build bench/mt_property_test.cr -o bin/mt_property_test
build crystal build -Dgc_none bench/stw_mt_property_test.cr -o bin/stw_mt_property_test
build crystal build -Dgc_none --release bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_rel
build crystal build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_hdr
build crystal build -Dgc_none bench/pattern_fuzz.cr -o bin/pattern_fuzz
build crystal build -Dgc_none --release bench/thread_storm.cr -o bin/thread_storm_rel
build crystal build -Dgc_none --release bench/claim_stress.cr -o bin/claim_stress_rel

loop fuzz-60s 30 120 bin/fuzz --seconds=60 --seed=@SEED@
loop property-test 20 300 bin/property_test --seed=@SEED@ --iterations=100000
loop mt-property-test 100 300 bin/mt_property_test --seed=@SEED@ --iterations=500 --workers=2,4,8
loop stw-mt-property-test 200 90 bin/stw_mt_property_test --seed=@SEED@ --iterations=200 --workers=2,4,8
loop stw-mt-property-test-release 300 90 bin/stw_mt_property_test_rel --seed=@SEED@ --iterations=400 --workers=2,4,8
loop stw-mt-property-test-headers-freelist 150 90 env GCRY_BITMAP_ALLOC=0 bin/stw_mt_property_test_hdr --seed=@SEED@ --iterations=200 --workers=2,4
loop pattern-fuzz 30 300 bin/pattern_fuzz --seed=@SEED@ --phases=200 --objects-per-phase=5000
loop pattern-fuzz-headers-freelist 30 300 env GCRY_BITMAP_ALLOC=0 bin/pattern_fuzz --seed=@SEED@ --phases=200 --objects-per-phase=5000
loop claim-stress-lazy 200 90 bin/claim_stress_rel --seconds=5 --workers=4 --seed=@SEED@
loop claim-stress-in-stop 300 90 env GCRY_DISABLE_LAZY_SWEEP=1 bin/claim_stress_rel --seconds=5 --workers=4 --seed=@SEED@
loop thread-storm-release 200 120 bin/thread_storm_rel --iterations=2000 --workers=16
loop parallel-mark-process 20 600 make parallel-mark-process
loop parallel-mark-termination 6 600 make parallel-mark-termination
loop mark-audit 6 600 make mark-audit
loop chunk-list-drift 6 600 make chunk-list-drift
loop large-cache-race 10 600 make large-cache-race
loop counter-loss 10 600 make counter-loss
loop claim-stress-gate 4 600 make claim-stress
loop realloc-move-stress 6 600 make realloc-move-stress
loop thread-churn-uaf 4 600 make thread-churn-uaf
loop soak-smoke 6 600 make soak-smoke
loop soft-soak-ec4-smoke 4 900 make soft-soak-ec4-smoke
loop process-spec 4 1200 crystal spec -Dgc_none process_spec
loop process-spec-invariants 2 1200 env GCRY_DEBUG_INVARIANTS=1 crystal spec -Dgc_none process_spec
loop process-spec-headers-freelist 2 1200 env GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec
if [ -x "$HOME/.local/share/mise/installs/crystal/1.22.0/bin/crystal" ]; then
  loop process-spec-crystal-1.22 2 1200 env PATH="$HOME/.local/share/mise/installs/crystal/1.22.0/bin:$PATH" crystal spec -Dgc_none process_spec
fi
echo "$(date -Is) done" | tee -a "$SUM"
