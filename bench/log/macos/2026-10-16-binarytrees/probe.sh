#!/usr/bin/env bash
# Binarytrees on a GitHub runner: where gcry's time goes against Boehm's.
# Run from the repository root by the `Perf A/B` workflow of a probe branch
# (its run step replaced by this script); output in $AB_OUT (the artifact).
# It applies `probe.patch` to src/ first: compile flags in the allocation
# hit path, all off unless asked for, so `tip` is the checkout's gcry.
#
# PROBE_ARMS: "name:flag,flag name2:flag ...", each a crystal-metric build of
# this checkout (`boehm` is stock Crystal: no flags). Default below; an arm
# whose name starts with `a64_` is built only on arm64, `mac_` only on macOS.
# PROBE_ENV_ARMS: "name:K=V,K=V ..." adds `tip` under extra environment to the
# timed A/B. PROBE_BT_ARMS: arms that also build bt.cr (build/walk split and
# counters), rusage, a trace and (macOS) `sample`. PROBE_TLS=1 adds tls.cr.
# The disassembly of the allocation entry points of every gcry arm goes to
# disasm-<arm>.txt, with the calls each makes listed in calls-<arm>.txt.
#
# Run 1 (2026-10-16, FINDINGS) used this script's first version, commit
# 1d0bf6a0: arms boehm, tip, tls2x, getspec, with tls.cr.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
here=bench/log/macos/2026-10-16-binarytrees
out="${AB_OUT:-bench/log/_ab}"
reps="${AB_REPS:-15}"
git apply "$here/probe.patch"
mkdir -p "$out" bin
root=$(pwd)
os=$(uname -s)
cpu=$(uname -m)
arm_specs="${PROBE_ARMS:-boehm: tip:-Dgc_none getspec:-Dgc_none,-Dgcry_probe_getspec mac_tsd:-Dgc_none,-Dgcry_probe_tsd shl:-Dgc_none,-Dgcry_probe_shl getspec_shl:-Dgc_none,-Dgcry_probe_getspec,-Dgcry_probe_shl noatomic:-Dgc_none,-Dgcry_probe_noatomic a64_lse:-Dgc_none,--mattr=+lse}"
env_specs="${PROBE_ENV_ARMS:-thr8:GCRY_THRESHOLD=8388608 thr32:GCRY_THRESHOLD=33554432 pace100:GCRY_THRESHOLD_PACE=100}"
bt_arms="${PROBE_BT_ARMS:-boehm tip getspec_shl}"
build() { # name prog flags...
  local name=$1 prog=$2
  shift 2
  local d="../pb-$name"
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    cp -r bench/crystal_metric/. "$d/"
    rm -rf "$d/lib" && mkdir -p "$d/lib/gcry" && cp -r src "$d/lib/gcry/src"
    cp "$here/bt.cr" "$here/tls.cr" "$d/"
  fi
  (cd "$d" && crystal build "$@" --release "$prog.cr" -o "$root/bin/$prog-$name")
}
# macOS ships bash 3.2: no associative arrays, so an arm's flags are looked
# up in the spec list each time.
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
  build "$name" main $(flags_of "$name")
done
crystal --version | tee "$out/crystal-version.txt"
case "$os" in
  Darwin) sysctl -n hw.ncpu machdep.cpu.brand_string hw.memsize hw.pagesize | tee "$out/machine.txt" ;;
  Linux) (nproc; grep -m1 'model name' /proc/cpuinfo || lscpu | grep -i 'model name'; getconf PAGESIZE) | tee "$out/machine.txt" ;;
esac

echo "== disassembly of the allocation entry points"
for a in "${arms[@]}"; do
  [ "$a" = boehm ] && continue
  : > "$out/disasm-$a.txt"
  for sym in '*Gcry::Heap#malloc<UInt64>:Pointer(Void)' '*GC::malloc<UInt64>:Pointer(Void)' '__crystal_malloc64'; do
    if [ "$os" = Darwin ]; then
      objdump --no-show-raw-insn --disassemble-symbols="_$sym" "bin/main-$a" >> "$out/disasm-$a.txt" 2>&1 || true
    else
      objdump --no-show-raw-insn --disassemble="$sym" "bin/main-$a" >> "$out/disasm-$a.txt" 2>&1 || true
    fi
  done
  grep -oE '(bl|blr|call[q]?|b|jmp[q]?)[[:space:]]+(0x)?[0-9a-f]+ <[^>]+>' "$out/disasm-$a.txt" | sed -E 's/.*<([^>+]+).*/\1/' | sort | uniq -c | sort -rn > "$out/calls-$a.txt" || true
done

if [ "${PROBE_TLS:-0}" = 1 ]; then
  echo "== microbench"
  for a in $bt_arms; do build "$a" tls $(flags_of "$a"); done
  for a in $bt_arms; do bin/tls-$a 50000000; done | tee "$out/tls.txt"
fi

echo "== bt: build/walk split and counters (7 reps, interleaved)"
# shellcheck disable=SC2086
for a in $bt_arms; do build "$a" bt $(flags_of "$a"); done
: > "$out/bt.txt"
for rep in 1 2 3 4 5 6 7; do
  for a in $bt_arms; do echo "ARM $a rep $rep $(bin/bt-$a)" | tee -a "$out/bt.txt"; done
  for spec in $env_specs; do
    IFS=, read -ra kvs <<< "${spec#*:}"
    echo "ARM tip-${spec%%:*} rep $rep $(env "${kvs[@]}" bin/bt-tip)" | tee -a "$out/bt.txt"
  done
done

echo "== rusage (5 reps)"
: > "$out/rusage.txt"
for rep in 1 2 3 4 5; do
  for a in $bt_arms; do
    echo "ARM $a rep $rep" >> "$out/rusage.txt"
    if [ "$os" = Darwin ]; then
      /usr/bin/time -l bin/main-$a Binarytrees >> "$out/rusage.txt" 2>&1 || true
    else
      /usr/bin/time -v bin/main-$a Binarytrees >> "$out/rusage.txt" 2>&1 || true
    fi
  done
done

echo "== Boehm's own stats, one run"
GC_PRINT_STATS=1 bin/main-boehm Binarytrees > "$out/boehm-stats.txt" 2>&1 || true
echo "== gcry trace, one run per arm"
for a in $bt_arms; do
  [ "$a" = boehm ] && continue
  GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE="$out/trace-$a.ndjson" bin/main-$a Binarytrees > /dev/null 2>&1 || true
done

if [ "$os" = Darwin ]; then
  echo "== sample, 2 runs each"
  for a in $bt_arms; do
    for i in 1 2; do
      (bin/main-$a Binarytrees > /dev/null 2>&1) &
      pid=$!
      sleep 0.05
      sample "$pid" 3 1 -mayDie -file "$out/sample-$a-$i.txt" > /dev/null 2>&1 || true
      wait "$pid" || true
    done
  done
fi

echo "== timed A/B, $reps reps"
ab=()
for a in "${arms[@]}"; do ab+=(--arm "$a=$root/bin/main-$a"); done
for spec in $env_specs; do
  name=${spec%%:*}
  ab+=(--arm "$name=$root/bin/main-tip")
  IFS=, read -ra kvs <<< "${spec#*:}"
  for kv in "${kvs[@]}"; do ab+=(--arm-env "$name" "$kv"); done
done
# shellcheck disable=SC2086 # AB_BENCHES is a space-separated list
python3 bench/runner_ab/ab.py --out "$out" --reps "$reps" "${ab[@]}" ${AB_BENCHES:-Binarytrees}
