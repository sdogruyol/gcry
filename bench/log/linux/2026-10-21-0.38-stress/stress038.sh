#!/usr/bin/env bash
# Overnight stress of release-0.38.0. Usage: stress038.sh <tree> <outdir>
# Every run is bounded by bench/run_bounded.sh: 0 pass, 1 fail, 2 stall,
# 3 known Crystal Parallel-scheduler deadlock (crystal-lang/crystal#17486).
set -u
T=$1; O=$2; mkdir -p "$O/logs"; cd "$T" || exit 1
B=$T/bin; mkdir -p "$B"
S="$O/summary.txt"; : > "$S"
note() { echo "$(date -u +%FT%TZ) $*" | tee -a "$S"; }

build() { note "build $*"; "$@" >> "$O/build.log" 2>&1 || { note "BUILD FAILED: $*"; exit 1; }; }
build crystal build -Dgc_none --release bench/claim_stress.cr -o "$B/claim_stress"
build crystal build -Dgc_none bench/claim_stress.cr -o "$B/claim_stress_dbg"
build crystal build -Dgc_none --release bench/stw_mt_property_test.cr -o "$B/stw_mt"
build crystal build -Dgc_none bench/mt_property_test.cr -o "$B/mt_prop"
build crystal build -Dgc_none bench/thread_storm.cr -o "$B/thread_storm"
build crystal build -Dgc_none -Dgcry_block_headers bench/nursery_tlab_smoke.cr -o "$B/nursery_tlab_smoke"
build crystal build -Dgc_none -Dwithout_mt bench/fork_reinit.cr -o "$B/fork_reinit"
build crystal build -Dgc_none --release bench/soak.cr -o "$B/soak"

# loop <name> <runs> <limit-s> <env...> -- <cmd with @SEED@>
loop() {
  local name=$1 runs=$2 limit=$3; shift 3
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  local p=0 f=0 s=0 u=0 base=1000
  for i in $(seq 1 "$runs"); do
    local seed=$((base + i)) log="$O/logs/$name-$((base + i)).log" cmd=()
    for a in "$@"; do cmd+=("${a//@SEED@/$seed}"); done
    env "${envs[@]}" GCRY_SEGV_REPORT=1 bench/run_bounded.sh "$limit" "$log" -- "${cmd[@]}" > /dev/null 2>&1
    case $? in
      0) p=$((p + 1)); rm -f "$log" ;;
      3) u=$((u + 1)); gzip -f "$log" ;;
      2) s=$((s + 1)); gzip -f "$log" ;;
      *) f=$((f + 1)); gzip -f "$log" ;;
    esac
  done
  note "$name: runs=$runs pass=$p fail=$f stall=$s upstream_deadlock=$u"
}

loop claim-lazy 200 60 -- "$B/claim_stress" --seconds=5 --workers=4 --seed=@SEED@
loop claim-instop 100 60 GCRY_DISABLE_LAZY_SWEEP=1 -- "$B/claim_stress" --seconds=5 --workers=4 --seed=@SEED@
loop claim-2w-instop-dbg 50 60 GCRY_DISABLE_LAZY_SWEEP=1 -- "$B/claim_stress_dbg" --seconds=2 --workers=2 --seed=@SEED@
loop claim-invariants 30 120 GCRY_DEBUG_INVARIANTS=1 -- "$B/claim_stress_dbg" --seconds=3 --workers=4 --seed=@SEED@
loop stw-mt 300 240 GCRY_POISON_FREED=1 GCRY_STW_WATCHDOG_MS=10000 -- "$B/stw_mt" --seed=@SEED@ --iterations=200 --workers=2,4
loop mt-prop 50 600 -- "$B/mt_prop" --seed=@SEED@ --iterations=500 --workers=2,4,8
loop thread-storm 30 300 -- "$B/thread_storm" --iterations=1000 --workers=10
loop nursery-tlab 1000 60 GCRY_BITMAP_ALLOC=0 -- "$B/nursery_tlab_smoke"
loop fork 50 60 -- "$B/fork_reinit"
# Two hours of soak: RSS must stay flat (the harness fails on growth).
loop soak 1 7500 -- "$B/soak" --duration=7200 --telemetry="$O/soak.log"
note DONE
