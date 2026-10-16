#!/usr/bin/env bash
# Binarytrees on a GitHub runner: where gcry's time goes against Boehm's.
# Run from the repository root by the `Perf A/B` workflow of a probe branch
# (its run step replaced by this script); output in $AB_OUT (the artifact).
# It applies `probe.patch` to src/ first: two compile flags in the hit path's
# `cursor_set_cached`, off unless asked for, so `tip` is the checkout's gcry.
#
# Arms, all from this checkout's src/, differing only in compile flags:
#   boehm    stock Crystal
#   tip      gcry
#   tls2x    gcry, a second (redundant) TLS read in the allocation hit path
#   getspec  gcry, the hit path's cursor set from pthread_getspecific
# PROBE_ENV_ARMS="name:K=V,K=V name2:K=V" adds `tip` under extra environment
# to the timed A/B (default: the four knob arms below).
set -euo pipefail
cd "$(dirname "$0")/../../../.."
here=bench/log/macos/2026-10-16-binarytrees
out="${AB_OUT:-bench/log/_ab}"
reps="${AB_REPS:-15}"
git apply "$here/probe.patch"
mkdir -p "$out" bin
root=$(pwd)
os=$(uname -s)
build() { # name flags...
  local name=$1
  shift
  local d="../pb-$name"
  rm -rf "$d" && mkdir -p "$d/lib/gcry"
  cp -r bench/crystal_metric/. "$d/"
  rm -rf "$d/lib" && mkdir -p "$d/lib/gcry" && cp -r src "$d/lib/gcry/src"
  cp "$here/bt.cr" "$here/tls.cr" "$d/"
  (cd "$d" && crystal build "$@" --release main.cr -o "$root/bin/cm-$name" &&
    crystal build "$@" --release bt.cr -o "$root/bin/bt-$name" &&
    crystal build "$@" --release tls.cr -o "$root/bin/tls-$name")
}
arms=(boehm tip tls2x getspec)
build boehm
build tip -Dgc_none
build tls2x -Dgc_none -Dgcry_probe_tls2x
build getspec -Dgc_none -Dgcry_probe_getspec
crystal --version | tee "$out/crystal-version.txt"
case "$os" in
  Darwin) sysctl -n hw.ncpu machdep.cpu.brand_string hw.memsize hw.pagesize | tee "$out/machine.txt" ;;
  Linux) (nproc; grep -m1 'model name' /proc/cpuinfo || lscpu | grep -i 'model name'; getconf PAGESIZE) | tee "$out/machine.txt" ;;
esac

echo "== microbench"
for a in boehm tip getspec; do bin/tls-$a 50000000; done | tee "$out/tls.txt"

echo "== bt: build/walk split and counters (7 reps, interleaved)"
: > "$out/bt.txt"
for rep in 1 2 3 4 5 6 7; do
  for a in "${arms[@]}"; do echo "ARM $a rep $rep $(bin/bt-$a)" | tee -a "$out/bt.txt"; done
  for kv in pace100:GCRY_THRESHOLD_PACE=100 pace1000:GCRY_THRESHOLD_PACE=1000 thr64:GCRY_THRESHOLD=67108864 pfw0:GCRY_ALLOC_PFW=0; do
    echo "ARM tip-${kv%%:*} rep $rep $(env "${kv#*:}" bin/bt-tip)" | tee -a "$out/bt.txt"
  done
done

echo "== rusage (5 reps)"
: > "$out/rusage.txt"
for rep in 1 2 3 4 5; do
  for a in boehm tip getspec; do
    echo "ARM $a rep $rep" >> "$out/rusage.txt"
    if [ "$os" = Darwin ]; then
      /usr/bin/time -l bin/cm-$a Binarytrees >> "$out/rusage.txt" 2>&1 || true
    else
      /usr/bin/time -v bin/cm-$a Binarytrees >> "$out/rusage.txt" 2>&1 || true
    fi
  done
done

echo "== Boehm's own stats, one run"
GC_PRINT_STATS=1 bin/cm-boehm Binarytrees > "$out/boehm-stats.txt" 2>&1 || true
echo "== gcry trace, one run per arm"
for a in tip getspec; do
  GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE="$out/trace-$a.ndjson" bin/cm-$a Binarytrees > /dev/null 2>&1 || true
done

if [ "$os" = Darwin ]; then
  echo "== sample, 2 runs each"
  for a in tip boehm getspec; do
    for i in 1 2; do
      (bin/cm-$a Binarytrees > /dev/null 2>&1) &
      pid=$!
      sleep 0.05
      sample "$pid" 3 1 -mayDie -file "$out/sample-$a-$i.txt" > /dev/null 2>&1 || true
      wait "$pid" || true
    done
  done
fi

echo "== timed A/B, $reps reps"
ab=()
for a in "${arms[@]}"; do ab+=(--arm "$a=$root/bin/cm-$a"); done
for spec in ${PROBE_ENV_ARMS:-pace100:GCRY_THRESHOLD_PACE=100 pace1000:GCRY_THRESHOLD_PACE=1000 thr64:GCRY_THRESHOLD=67108864 pfw0:GCRY_ALLOC_PFW=0 reuse0:GCRY_DARWIN_REUSABLE=0}; do
  name=${spec%%:*}
  ab+=(--arm "$name=$root/bin/cm-tip")
  IFS=, read -ra kvs <<< "${spec#*:}"
  for kv in "${kvs[@]}"; do ab+=(--arm-env "$name" "$kv"); done
done
python3 bench/runner_ab/ab.py --out "$out" --reps "$reps" "${ab[@]}" ${AB_BENCHES:-Binarytrees}
