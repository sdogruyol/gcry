#!/bin/bash
# The GCRY_SOUND=1 profile smoke and correctness suite, as `test (x86_64)`
# runs them on Linux. Bash, so the same script serves macOS and Git Bash on
# Windows.
set -e
mkdir -p bin
# `CRYSTAL` picks the compiler, as in the Makefile: on Windows arm64 the pinned
# native one is not the first `crystal` on Git Bash's PATH.
b() { "${CRYSTAL:-crystal}" build -Dgc_none "$@" --error-trace; }
b samples/sound_profile.cr -o bin/sound_profile
./bin/sound_profile
GCRY_SOUND=1 ./bin/sound_profile
GCRY_SOUND=1 GCRY_SCRUB_FIBERS=1 ./bin/sound_profile
b -Dgcry_block_headers samples/sound_profile.cr -o bin/sound_profile_hdr
GCRY_SOUND=1 GCRY_NURSERY=262144 ./bin/sound_profile_hdr
b samples/stress.cr -o bin/stress
b samples/json_churn.cr -o bin/json_churn
b samples/alloc.cr -o bin/alloc
b bench/pattern_fuzz.cr -o bin/pattern_fuzz
b bench/thread_storm.cr -o bin/thread_storm
b bench/finalizer_complex.cr -o bin/finalizer_complex
b -Dgcry_block_headers bench/nursery_headers.cr -o bin/nursery_headers
b bench/stw_mt_property_test.cr -o bin/stw_mt_property_test
export GCRY_STW_WATCHDOG_MS=10000
GCRY_SOUND=1 ./bin/stress 300
GCRY_SOUND=1 ./bin/json_churn 800
GCRY_SOUND=1 ./bin/alloc 500
GCRY_SOUND=1 ./bin/pattern_fuzz --seed=1 --phases=20 --objects-per-phase=1000
GCRY_SOUND=1 ./bin/thread_storm --iterations=100 --workers=4
GCRY_SOUND=1 ./bin/finalizer_complex
GCRY_SOUND=1 ./bin/nursery_headers
# Bounded: this harness can hit Crystal 1.21's Parallel-scheduler deadlock
# (crystal-lang/crystal#17486), which reproduces under Boehm and is not gcry's.
# It took a whole Linux job to its timeout on 2026-10-01 with the STW watchdog
# silent. `bench/run_bounded.sh` captures the stall and exits 3 for that shape
# (gdb on Linux, `sample` on macOS), so it is retried on the next seed; any
# other stall or failure fails the suite.
stw_ok=0
for seed in 1 2 3; do
  rc=0
  GCRY_SOUND=1 bench/run_bounded.sh 300 bin/sound-stw-mt.log -- \
    ./bin/stw_mt_property_test --seed=$seed --iterations=50 --workers=2,4 || rc=$?
  if [ "$rc" -eq 0 ]; then stw_ok=1; break; fi
  tail -40 bin/sound-stw-mt.log
  if [ "$rc" -ne 3 ]; then echo "sound suite: stw_mt_property_test seed $seed failed (rc $rc)"; exit 1; fi
  echo "sound suite: seed $seed hit the upstream scheduler deadlock (not counted); next seed"
done
[ "$stw_ok" -eq 1 ] || { echo "sound suite: three upstream deadlocks in a row"; exit 1; }
GCRY_SOUND=1 GCRY_STRESS=1 GCRY_STRESS_EVERY=32 ./bin/stress 100
GCRY_SOUND=1 ./bin/pattern_fuzz --seed=2 --phases=20 --objects-per-phase=1000
echo "sound suite: ok"
