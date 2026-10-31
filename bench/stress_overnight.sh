#!/usr/bin/env bash
# The release overnight stress, kept in the tree so each release runs the same
# set and its summary compares line for line with the last one. The weekly
# `.github/workflows/stress.yml` runs it on the GitHub runners too.
#
#   bench/stress_overnight.sh [--only=ERE] [--skip=ERE] <gcry-tree> <outdir> [scale]
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
# Each run holds the host-wide heavy lock (HEAVY_LOCK, default
# $TMPDIR/gcry-heavy.lock), so other work interleaves between runs. A runner
# has nothing to share with, so `HEAVY_LOCK=` (set and empty) runs unlocked,
# and so does a host without `flock` (macOS, Git Bash), saying so once.
#
# `scale` multiplies every run count (default 1; 0.1 for a smoke of the script
# itself, at least one run per loop). `--only` and `--skip` select loops by
# name, an extended regex matched against the whole name (`--only='fuzz-60s|
# property-test'`), so one set can be split across jobs that each fit a CI
# runner's 6 h. A harness is built only when a selected loop runs it.
#
# Linux, macOS and Windows (Git Bash with mingw make, as CI's Windows gates
# run). A loop that cannot run on this OS, or whose prerequisite is missing,
# prints `<name> skipped: <reason>` instead of a count; the reasons are the
# `unsupported` table below. On Windows `crystal spec` is not used: it deletes
# its binary under a handle that outlives the process and fails green runs
# (ci/windows.ps1), so the process-spec loops build the suite once into
# bin/ and run that, as ci/windows.ps1 does.
#
# The second compiler's loop, `process-spec-crystal-1.22`, takes its compiler
# from STRESS_CRYSTAL_1_22 (the directory holding `crystal`; default the mise
# install of 1.22.2) and is skipped, with the path, when there is none.
#
# Output: <outdir>/summary.txt, one line per loop:
#   <time> <name> runs=N pass=N fail=N stall=N crystal_scheduler_deadlock=N (S s)
# and <outdir>/<name>-{fail,stall,sched}-<i>-seed<seed>.log for every run that
# did not pass. Exit status 1 when any run failed or stalled or a harness did
# not build, after every selected loop has run; a classified scheduler
# deadlock is counted and reported, and is not a failure. 0.38.0's set took
# about 3.5 hours on a 12-vCPU host.
set -u
only='' skip=''
while [ $# -gt 0 ]; do
  case $1 in
    --only=*) only=${1#--only=} ;;
    --skip=*) skip=${1#--skip=} ;;
    --) shift; break ;;
    -*) echo "unknown option $1" >&2; exit 64 ;;
    *) break ;;
  esac
  shift
done
[ $# -ge 2 ] || { echo "usage: $0 [--only=ERE] [--skip=ERE] <gcry-tree> <outdir> [scale]" >&2; exit 64; }
tree=$1 out=$2 scale=${3:-1}
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$tree" || exit 1
SUM="$out/summary.txt"
: > "$SUM"
# Seconds-resolution ISO time: `date -Is` is GNU, and macOS's date has no `-I`.
now() { date +%Y-%m-%dT%H:%M:%S%z; }

case $(uname -s) in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) os=$(uname -s) ;;
esac

if [ -n "${HEAVY_LOCK+set}" ] && [ -z "$HEAVY_LOCK" ]; then
  LOCK=''
elif command -v flock >/dev/null 2>&1; then
  LOCK=${HEAVY_LOCK:-${TMPDIR:-/tmp}/gcry-heavy.lock}
else
  LOCK=''
  echo "$(now) no flock on this host: running without the heavy lock" >&2
fi
# locked <command...>: under the heavy lock when there is one.
locked() {
  if [ -n "$LOCK" ]; then flock "$LOCK" "$@"; else "$@"; fi
}

C122=${STRESS_CRYSTAL_1_22:-$HOME/.local/share/mise/installs/crystal/1.22.2/bin}
has_crystal() { [ -x "$1/crystal" ] || [ -x "$1/crystal.exe" ]; }

failed=0

# runs <n>: the scaled run count, at least 1.
runs() { awk -v n="$1" -v s="$scale" 'BEGIN { r = int(n * s + 0.5); print (r < 1 ? 1 : r) }'; }

# selected <name>: whether --only and --skip leave this loop in.
selected() {
  if [ -n "$only" ] && ! [[ $1 =~ ^($only)$ ]]; then return 1; fi
  if [ -n "$skip" ] && [[ $1 =~ ^($skip)$ ]]; then return 1; fi
  return 0
}

# unsupported <name>: why this loop cannot run here; prints nothing when it can.
unsupported() {
  case $os:$1 in
    *:process-spec-crystal-1.22)
      has_crystal "$C122" || echo "no Crystal 1.22 compiler in $C122 (set STRESS_CRYSTAL_1_22)" ;;
  esac
}

# spec_entry <entry.cr>: a file that `require`s every process_spec/**/*_spec.cr,
# for Windows. Through `require`, a `skip_file` skips its own file only; handed
# to `crystal build` as main sources it would skip every one after it too
# (ci/windows.ps1).
spec_entry() {
  find process_spec -name '*_spec.cr' | LC_ALL=C sort | sed 's|^|require "../|; s|$|"|' > "$1"
}

# build <bin/name>: build the harness a loop runs, once per invocation of this
# script. Fails when it does not build; every loop that needs it then reports
# BUILD FAILED and counts as failed.
built=' '
build() {
  case $built in *" $1 "*) return 0 ;; esac
  local ok=0
  case $1 in
    bin/fuzz) locked crystal build bench/fuzz.cr -o bin/fuzz || ok=1 ;;
    bin/property_test) locked crystal build bench/property_test.cr -o bin/property_test || ok=1 ;;
    # Without -Dgc_none: the library-heap arm, as `make mt-property-test` builds it.
    bin/mt_property_test) locked crystal build bench/mt_property_test.cr -o bin/mt_property_test || ok=1 ;;
    bin/stw_mt_property_test) locked crystal build -Dgc_none bench/stw_mt_property_test.cr -o bin/stw_mt_property_test || ok=1 ;;
    bin/stw_mt_property_test_rel) locked crystal build -Dgc_none --release bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_rel || ok=1 ;;
    bin/stw_mt_property_test_hdr) locked crystal build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_hdr || ok=1 ;;
    bin/pattern_fuzz) locked crystal build -Dgc_none bench/pattern_fuzz.cr -o bin/pattern_fuzz || ok=1 ;;
    bin/thread_storm_rel) locked crystal build -Dgc_none --release bench/thread_storm.cr -o bin/thread_storm_rel || ok=1 ;;
    bin/claim_stress_rel) locked crystal build -Dgc_none --release bench/claim_stress.cr -o bin/claim_stress_rel || ok=1 ;;
    # Windows' process_spec binaries (see the header).
    bin/process_spec) spec_entry bin/stress_process_spec.cr && locked crystal build -Dgc_none bin/stress_process_spec.cr -o bin/process_spec || ok=1 ;;
    bin/process_spec_hdr) spec_entry bin/stress_process_spec.cr && locked crystal build -Dgc_none -Dgcry_block_headers bin/stress_process_spec.cr -o bin/process_spec_hdr || ok=1 ;;
    bin/process_spec_122) spec_entry bin/stress_process_spec.cr && locked env PATH="$C122:$PATH" crystal build -Dgc_none bin/stress_process_spec.cr -o bin/process_spec_122 || ok=1 ;;
    *) echo "build: no recipe for $1" >&2; ok=1 ;;
  esac
  [ $ok = 0 ] && built="$built$1 "
  return $ok
}

# loop <name> <runs> <limit-s> <command...>: `@SEED@` in the command is
# replaced by a fresh seed per run (and is harmless where a harness takes none).
loop() {
  local name=$1
  selected "$name" || return 0
  local why a
  why=$(unsupported "$name")
  if [ -n "$why" ]; then
    echo "$(now) $name skipped: $why" | tee -a "$SUM"
    return 0
  fi
  for a in "${@:4}"; do
    case $a in
      bin/*) build "$a" || { echo "$(now) $name BUILD FAILED: $a" | tee -a "$SUM"; failed=1; return 0; } ;;
    esac
  done
  local n; n=$(runs "$2"); local limit=$3; shift 3
  local pass=0 fail=0 stall=0 sched=0 i rc seed t0 cmd log
  t0=$(date +%s)
  for i in $(seq 1 "$n"); do
    seed=$((RANDOM * 32768 + RANDOM))
    cmd=()
    for a in "$@"; do cmd+=("${a//@SEED@/$seed}"); done
    log="$out/$name.run.log"
    locked bench/run_bounded.sh "$limit" "$log" -- "${cmd[@]}"
    rc=$?
    case $rc in
      0) pass=$((pass + 1)) ;;
      2) stall=$((stall + 1)); cp "$log" "$out/$name-stall-$i-seed$seed.log" ;;
      3) sched=$((sched + 1)); cp "$log" "$out/$name-sched-$i-seed$seed.log" ;;
      *) fail=$((fail + 1)); cp "$log" "$out/$name-fail-$i-seed$seed.log" ;;
    esac
  done
  rm -f "$out/$name.run.log"
  [ $((fail + stall)) -gt 0 ] && failed=1
  echo "$(now) $name runs=$n pass=$pass fail=$fail stall=$stall crystal_scheduler_deadlock=$sched ($(($(date +%s) - t0)) s)" | tee -a "$SUM"
}

mkdir -p bin
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
if [ "$os" = windows ]; then
  loop process-spec 4 1200 bin/process_spec
  loop process-spec-invariants 2 1200 env GCRY_DEBUG_INVARIANTS=1 bin/process_spec
  loop process-spec-headers-freelist 2 1200 env GCRY_BITMAP_ALLOC=0 bin/process_spec_hdr
  loop process-spec-crystal-1.22 2 1200 env PATH="$C122:$PATH" bin/process_spec_122
else
  loop process-spec 4 1200 crystal spec -Dgc_none process_spec
  loop process-spec-invariants 2 1200 env GCRY_DEBUG_INVARIANTS=1 crystal spec -Dgc_none process_spec
  loop process-spec-headers-freelist 2 1200 env GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec
  loop process-spec-crystal-1.22 2 1200 env PATH="$C122:$PATH" crystal spec -Dgc_none process_spec
fi
echo "$(now) done" | tee -a "$SUM"
exit $failed
