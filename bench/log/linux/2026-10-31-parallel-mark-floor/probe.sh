#!/usr/bin/env bash
# Parallel-mark floor probe on a GitHub runner (ROADMAP "macOS: Binarytrees
# runs at 88% of Boehm on M1", the "~3 points of Boehm's parallel markers"
# part). Run from the repository root by probe.yml (this directory, copied to
# .github/workflows on a `probe/` branch). Builds crystal-metric twice from
# the checkout — stock Crystal (Boehm) and `-Dgc_none` (gcry) — and runs
# bench/runner_ab/ab.py over the arms in PROBE_ENV_ARMS ("name:bin:K=V,K=V",
# bin `boehm` or `gcry`; an empty env is written `name:bin:`), AB_REPS reps of
# AB_BENCHES. Output in $AB_OUT (the artifact).
set -euo pipefail
cd "$(dirname "$0")/../../../.."
out="${AB_OUT:-bench/log/_ab}"
mkdir -p "$out" bin
root=$(pwd)
exe=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe=".exe" ;; esac
build() { # name flags...
  local name=$1 d="../pf-$1"
  shift
  rm -rf "$d" && mkdir -p "$d"
  cp -r bench/crystal_metric/. "$d/"
  rm -rf "$d/lib" && mkdir -p "$d/lib/gcry" && cp -r src "$d/lib/gcry/src"
  (cd "$d" && crystal build ${1+"$@"} --release main.cr -o "$root/bin/main-$name$exe")
}
crystal --version | tee "$out/crystal-version.txt"
build boehm
build gcry -Dgc_none
{ uname -a; getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu; } > "$out/host.txt" 2>&1 || true
ab=()
for spec in ${PROBE_ENV_ARMS}; do
  name=${spec%%:*}
  rest=${spec#*:}
  ab+=(--arm "$name=$root/bin/main-${rest%%:*}$exe")
  kvs=${rest#*:}
  if [ -n "$kvs" ]; then
    IFS=, read -ra kv_list <<< "$kvs"
    for kv in "${kv_list[@]}"; do ab+=(--arm-env "$name" "$kv"); done
  fi
done
# shellcheck disable=SC2086 # AB_BENCHES is a space-separated list
python3 bench/runner_ab/ab.py --out "$out" --reps "${AB_REPS:-30}" "${ab[@]}" ${AB_BENCHES:-Binarytrees}
