#!/usr/bin/env bash
# gcry against a base revision, and both against Boehm, on crystal-metric: all
# arms built in this job and run process-fresh, interleaved in random order per
# rep (bench/runner_ab/ab.py). Meant for GitHub runners (the `perf-ab`
# workflow), whose cores are quiet where a shared development host is not.
#
#   AB_BASE=origin/master AB_REPS=10 AB_BENCHES="Primes JsonParsePure" \
#     bench/runner_ab/ab.sh
#
# Arms: `base` (gcry src at AB_BASE), `var` (gcry src of this checkout) and,
# unless AB_BOEHM=0, `boehm` (the same crystal-metric built without
# `-Dgc_none`, i.e. stock Crystal), so cells read as % of Boehm like the
# README's tables. Only `src/` differs between `base` and `var`: the bench and
# this script come from the checkout.
#
# Runs on Linux, macOS and Windows (Git Bash; the native `crystal.exe` gets
# Windows paths, and memory is PeakWorkingSetSize — see ab.py). Raw runs and
# the summary go to AB_OUT (default bench/log/_ab). Nothing is gated.
set -euo pipefail
cd "$(dirname "$0")/../.."
base="${AB_BASE:-origin/master}"
out="${AB_OUT:-bench/log/_ab}"
exe="" py=python3
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) exe=.exe py=python ;;
esac
# Native Windows tools do not understand /d/a/... paths; `pwd -W` gives D:/a/...
root=$(pwd -W 2>/dev/null || pwd)
git fetch -q origin "${base#origin/}" --depth=1 2>/dev/null || true
rev=$(git rev-parse --verify -q "$base^{commit}" || git rev-parse FETCH_HEAD)
rm -rf ../ab-base && git worktree add -q --detach ../ab-base "$rev"
# build SRC_ROOT OUT [crystal flags...]: crystal-metric from this checkout,
# with SRC_ROOT/src vendored as its `gcry` dependency.
build() {
  local src=$1 o=$2
  shift 2
  rm -rf ../ab-build && mkdir -p ../ab-build
  cp -r bench/crystal_metric/. ../ab-build/
  rm -rf ../ab-build/lib && mkdir -p ../ab-build/lib/gcry && cp -r "$src/src" ../ab-build/lib/gcry/src
  (cd ../ab-build && crystal build "$@" --release main.cr -o "$root/bin/$o$exe")
}
mkdir -p bin "$out"
build ../ab-base ab-base -Dgc_none
build . ab-var -Dgc_none
arms=(--arm "base=$root/bin/ab-base$exe" --arm "var=$root/bin/ab-var$exe")
if [ "${AB_BOEHM:-1}" != 0 ]; then
  build . ab-boehm
  arms+=(--arm "boehm=$root/bin/ab-boehm$exe")
fi
# AB_VAR_ENV="K=V K=V" adds a `var_env` arm: the `var` binary under that
# environment, e.g. GCRY_REALLOC_IN_PLACE=0 to see what one default costs.
if [ -n "${AB_VAR_ENV:-}" ]; then
  arms+=(--arm "var_env=$root/bin/ab-var$exe")
  for kv in $AB_VAR_ENV; do arms+=(--arm-env var_env "$kv"); done
fi
crystal --version
# shellcheck disable=SC2086 # AB_BENCHES is a space-separated list
"$py" bench/runner_ab/ab.py --out "$out" --reps "${AB_REPS:-10}" "${arms[@]}" \
  ${AB_BENCHES:-Primes JsonParsePure Binarytrees JsonGenerate}

# Kemal (bench/kemal), AB_KEMAL_TRIALS>0, Linux and macOS (needs wrk). Every
# arm is the checkout's server.cr; only lib/gcry/src is swapped, as above.
if [ "${AB_KEMAL_TRIALS:-0}" != 0 ]; then
  (cd bench/kemal && shards install)
  kbuild() {
    local src=$1 o=$2
    shift 2
    rm -rf bench/kemal/lib/gcry && mkdir -p bench/kemal/lib/gcry && cp -r "$src/src" bench/kemal/lib/gcry/src
    (cd bench/kemal && crystal build "$@" --release src/server.cr -o "$root/bin/$o")
  }
  kbuild ../ab-base kemal-base -Dgc_none
  kbuild . kemal-var -Dgc_none
  kbuild . kemal-boehm
  "$py" bench/runner_ab/kemal_ab.py --out "$out" --trials "$AB_KEMAL_TRIALS" \
    --arm "boehm=$root/bin/kemal-boehm" --arm "base=$root/bin/kemal-base" --arm "var=$root/bin/kemal-var"
fi
