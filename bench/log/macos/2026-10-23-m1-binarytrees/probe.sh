#!/usr/bin/env bash
# Binarytrees on a GitHub runner: where gcry's mutator time goes against
# Boehm's, per instruction. Run from the repository root by the probe
# workflow (probe.yml in this directory, copied to .github/workflows on a
# `probe/` branch); output in $AB_OUT (the artifact).
#
# PROBE_ARMS: "name:flag,flag name2:flag ...", each a crystal-metric build of
# this checkout (`boehm` is stock Crystal: no flags); `probe.patch`, if
# present, is applied first (compile flags, all off by default, so `tip` is
# the checkout's gcry). PROBE_REFS: "name=ref ...", arms whose `src/` is
# taken from that commit instead of the checkout. Per arm:
#   - pcprof (pcprof.c, preloaded): PROBE_PROF_RUNS runs of Binarytrees,
#     sampled every 100 us; `prof-<arm>.txt` is pcprof.py's report, the hot
#     functions annotated per instruction;
#   - hardware counters, 5 runs: `time -l` on macOS (instructions retired,
#     cycles elapsed on Apple silicon), `perf stat` on Linux where it runs;
#   - the timed A/B (bench/runner_ab/ab.py), AB_REPS reps, Binarytrees.
# `tip` also gets its optimised LLVM IR for the allocation entry points
# (`ir-tip.ll.gz`), to compare the LLVM of Crystal's macOS release with
# Linux's.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
here=bench/log/macos/2026-10-23-m1-binarytrees
out="${AB_OUT:-bench/log/_ab}"
reps="${AB_REPS:-15}"
prof_runs="${PROBE_PROF_RUNS:-10}"
[ -f "$here/probe.patch" ] && git apply "$here/probe.patch"
mkdir -p "$out" bin
root=$(pwd)
os=$(uname -s)
cpu=$(uname -m)
arm_specs="${PROBE_ARMS:-boehm: tip:-Dgc_none}"
ref_of() {
  local spec
  for spec in ${PROBE_REFS:-}; do
    if [ "${spec%%=*}" = "$1" ]; then
      echo "${spec#*=}"
      return
    fi
  done
}
build() { # name flags...
  local name=$1
  shift
  local d="../pb-$name"
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    cp -r bench/crystal_metric/. "$d/"
    rm -rf "$d/lib" && mkdir -p "$d/lib/gcry"
    local ref
    ref=$(ref_of "$name")
    if [ -n "$ref" ]; then
      git archive "$ref" src | tar -x -C "$d/lib/gcry"
    else
      cp -r src "$d/lib/gcry/src"
    fi
  fi
  (cd "$d" && crystal build "$@" --release main.cr -o "$root/bin/main-$name")
}
# macOS ships bash 3.2: no associative arrays.
flags_of() {
  local spec
  for spec in $arm_specs; do
    if [ "${spec%%:*}" = "$1" ]; then
      echo "${spec#*:}" | tr , ' '
      return
    fi
  done
}
arms=()
for spec in $arm_specs; do
  name=${spec%%:*}
  case "$name" in
    a64_*) [ "$cpu" = arm64 ] || [ "$cpu" = aarch64 ] || continue ;;
    mac_*) [ "$os" = Darwin ] || continue ;;
  esac
  arms+=("$name")
  # shellcheck disable=SC2046 # flags are space-separated on purpose
  build "$name" $(flags_of "$name")
done
crystal --version | tee "$out/crystal-version.txt"
case "$os" in
  Darwin)
    sysctl -n hw.ncpu machdep.cpu.brand_string hw.memsize hw.pagesize hw.cachelinesize | tee "$out/machine.txt"
    sw_vers | tee -a "$out/machine.txt"
    cc -O2 -dynamiclib -o bin/pcprof.dylib "$here/pcprof.c"
    preload=DYLD_INSERT_LIBRARIES
    lib="$root/bin/pcprof.dylib"
    ;;
  Linux)
    (nproc; grep -m1 'model name' /proc/cpuinfo || lscpu | grep -i 'model name'; getconf PAGESIZE) | tee "$out/machine.txt"
    cc -O2 -shared -fPIC -o bin/pcprof.so "$here/pcprof.c" -lrt -ldl
    preload=LD_PRELOAD
    lib="$root/bin/pcprof.so"
    ;;
esac
for a in "${arms[@]}"; do
  nm -n "bin/main-$a" | gzip > "$out/nm-$a.txt.gz"
  [ "$a" = boehm ] && continue
  # The allocation entry points, whole, hot or not.
  : > "$out/disasm-$a.txt"
  for sym in '__crystal_malloc64' '*GC::malloc<UInt64>:Pointer(Void)' '*GC::malloc_atomic<UInt64>:Pointer(Void)' \
    '*Gcry::Heap#malloc<UInt64>:Pointer(Void)' '*Gcry::Heap#malloc_atomic<UInt64>:Pointer(Void)'; do
    if [ "$os" = Darwin ]; then
      objdump --no-show-raw-insn --disassemble-symbols="_$sym" "bin/main-$a" >> "$out/disasm-$a.txt" 2>&1 || true
    else
      objdump --no-show-raw-insn --disassemble="$sym" "bin/main-$a" >> "$out/disasm-$a.txt" 2>&1 || true
    fi
  done
done

if [ "${PROBE_MRS:-0}" = 1 ] && { [ "$cpu" = arm64 ] || [ "$cpu" = aarch64 ]; }; then
  echo "== mrs.c: the thread-pointer read behind K stores"
  cc -O2 -o bin/mrs "$here/mrs.c" -lpthread && bin/mrs | tee "$out/mrs.txt"
fi

echo "== pcprof, $prof_runs runs per arm"
mkdir -p "$out/pcprof"
for i in $(seq 1 "$prof_runs"); do
  for a in "${arms[@]}"; do
    env "$preload=$lib" PCPROF_OUT="$out/pcprof/$a" "bin/main-$a" Binarytrees > /dev/null 2>&1 || true
  done
done
for a in "${arms[@]}"; do
  python3 "$here/pcprof.py" "bin/main-$a" 8 "$out/pcprof/$a".* > "$out/prof-$a.txt" || true
  head -40 "$out/prof-$a.txt"
done
tar -czf "$out/pcprof.tar.gz" -C "$out" pcprof && rm -rf "$out/pcprof"

echo "== hardware counters, 5 runs per arm"
: > "$out/counters.txt"
perf_ok=0
if [ "$os" = Linux ]; then
  sudo apt-get install -y -qq "linux-tools-$(uname -r)" linux-tools-common > /dev/null 2>&1 || true
  sudo sysctl -q kernel.perf_event_paranoid=-1 || true
  perf stat -e instructions,cycles true > /dev/null 2>&1 && perf_ok=1
fi
for rep in 1 2 3 4 5; do
  for a in "${arms[@]}"; do
    echo "ARM $a rep $rep" >> "$out/counters.txt"
    if [ "$os" = Darwin ]; then
      /usr/bin/time -l "bin/main-$a" Binarytrees >> "$out/counters.txt" 2>&1 || true
    elif [ "$perf_ok" = 1 ]; then
      perf stat -e instructions,cycles,l1d_cache_refill,stall_backend "bin/main-$a" Binarytrees >> "$out/counters.txt" 2>&1 \
        || perf stat -e instructions,cycles "bin/main-$a" Binarytrees >> "$out/counters.txt" 2>&1 || true
    else
      /usr/bin/time -v "bin/main-$a" Binarytrees >> "$out/counters.txt" 2>&1 || true
    fi
  done
done

echo "== optimised IR of the allocation entry points (tip)"
if [ -d ../pb-tip ]; then
  # shellcheck disable=SC2046
  (cd ../pb-tip && crystal build $(flags_of tip) --release --emit llvm-ir main.cr -o "$root/bin/ir-tip") || true
  ll=$(ls bin/ir-tip.ll ../pb-tip/*.ll 2>/dev/null | head -1 || true)
  if [ -n "$ll" ]; then
    awk '/^define .*(Heap#malloc|GC::malloc|__crystal_malloc|TreeNode)/{p=1} p{print} p&&/^}/{p=0}' "$ll" | gzip > "$out/ir-tip.ll.gz"
  fi
fi

echo "== timed A/B, $reps reps"
ab=()
for a in "${arms[@]}"; do ab+=(--arm "$a=$root/bin/main-$a"); done
# PROBE_ENVPAD: "n n ...", byte counts; each arm in PROBE_ENVPAD_ARMS (default
# all) runs again with an environment variable of n bytes, which moves the
# initial stack pointer (the strings sit above it) and nothing else. Arm
# `<arm>-e<n>`. PROBE_PRELOAD_ARMS: those arms again with pcprof preloaded
# but not sampling (no PCPROF_OUT: no thread, no mapping), arm `<arm>-pre`,
# for what loading a library alone moves.
for n in ${PROBE_ENVPAD:-}; do
  for a in ${PROBE_ENVPAD_ARMS:-${arms[*]}}; do
    ab+=(--arm "$a-e$n=$root/bin/main-$a" --arm-env "$a-e$n" "ENVPAD=$(head -c "$n" /dev/zero | tr '\0' x)")
  done
done
for a in ${PROBE_PRELOAD_ARMS:-}; do
  ab+=(--arm "$a-pre=$root/bin/main-$a" --arm-env "$a-pre" "$preload=$lib")
done
# PROBE_ENV_ARMS: "name:arm:K=V,K=V ...", *arm*'s binary under extra
# environment.
for spec in ${PROBE_ENV_ARMS:-}; do
  name=${spec%%:*}
  rest=${spec#*:}
  ab+=(--arm "$name=$root/bin/main-${rest%%:*}")
  IFS=, read -ra kvs <<< "${rest#*:}"
  for kv in "${kvs[@]}"; do ab+=(--arm-env "$name" "$kv"); done
done
# shellcheck disable=SC2086 # AB_BENCHES is a space-separated list
python3 bench/runner_ab/ab.py --out "$out" --reps "$reps" "${ab[@]}" ${AB_BENCHES:-Binarytrees}
