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
# with SRC_ROOT/src vendored as its `gcry` dependency. PAD=N puts N bytes of
# nops in front of the benchmarks' code and PREPAD=N in front of all of it
# (`pad<N>` and `prepad<N>` arms below); MAIN=FILE builds FILE as the entry
# point instead of crystal-metric's `main.cr`.
# shellcheck disable=SC2059 # the placement probe's source is printf's format
build() {
  local src=$1 o=$2
  shift 2
  rm -rf ../ab-build && mkdir -p ../ab-build
  cp -r bench/crystal_metric/. ../ab-build/
  rm -rf ../ab-build/lib && mkdir -p ../ab-build/lib/gcry && cp -r "$src/src" ../ab-build/lib/gcry/src
  if [ -n "${MAIN:-}" ]; then cp "$MAIN" ../ab-build/main.cr; fi
  # A placement probe is one never-inlined function whose body is N bytes of
  # nops, called once. Crystal emits a function where codegen first reaches
  # a call to it, so the code emitted after the pad lands N bytes further on
  # (rounded up to the next function's 16-byte alignment) and nothing else
  # changes: the program, the collector and the work they do are the same.
  # PAD calls it first in `main.cr`, which moves the benchmarks and the
  # stdlib code they are first to use, but not the collector or anything
  # else the prelude reaches before `main.cr` runs. PREPAD calls it from a
  # prelude that requires the stock one after it (`--prelude`), so it comes
  # ahead of all of the program's code, gcry's allocation paths included.
  # Works with the MSVC toolchain too: `.skip` is LLVM's assembler directive,
  # and a release build's code is one `.text` section, which link.exe keeps
  # in order. `syms/<binary>.txt` shows where every function went.
  local pad='@[NoInline]\ndef __placement_pad\n  asm(".skip %d, 0x90" :::: "volatile")\nend\n\n__placement_pad\n\n'
  if [ -n "${PAD:-}" ]; then
    {
      printf "$pad" "$PAD"
      cat ../ab-build/main.cr
    } > ../ab-build/main.pad && mv ../ab-build/main.pad ../ab-build/main.cr
  fi
  local flags=()
  if [ -n "${PREPAD:-}" ]; then
    { printf "$pad" "$PREPAD" && echo 'require "prelude"'; } > ../ab-build/pad_prelude.cr
    flags+=(--prelude ./pad_prelude)
  fi
  # Windows writes a link map, the only symbol table its toolchain leaves.
  if [ -n "$exe" ]; then flags+=(--link-flags "/MAP:$root/bin/$o.map"); fi
  # `${flags[@]+...}`: macOS' bash 3.2 calls an empty array unbound under `set -u`.
  (cd ../ab-build && crystal build "$@" ${flags[@]+"${flags[@]}"} --release main.cr -o "$root/bin/$o$exe")
  # Every function's address in this binary, to tell placement probes apart
  # (`nm` on POSIX, the link map on Windows).
  mkdir -p "$out/syms"
  if [ -n "$exe" ]; then
    cp "$root/bin/$o.map" "$out/syms/$o.txt"
  else
    nm -n "$root/bin/$o" > "$out/syms/$o.txt"
  fi
}
mkdir -p bin "$out"
AB_BENCHES=${AB_BENCHES:-Primes JsonParsePure Binarytrees JsonGenerate}
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
# AB_PADS="16 80 p16 p2096" adds a placement-probe arm per count: the `var`
# source with N bytes of nops in front of the benchmarks' code (`N`, arm
# `pad<N>`) or of all the program's code, the collector's included (`pN`,
# arm `prepad<N>`); see `build`. Their spread is what code placement alone
# moves a bench by on this runner.
for n in ${AB_PADS:-}; do
  case "$n" in
    p*) PREPAD=${n#p} build . "ab-prepad${n#p}" -Dgc_none && arms+=(--arm "prepad${n#p}=$root/bin/ab-prepad${n#p}$exe") ;;
    *) PAD=$n build . "ab-pad$n" -Dgc_none && arms+=(--arm "pad$n=$root/bin/ab-pad$n$exe") ;;
  esac
done
crystal --version
# shellcheck disable=SC2086 # AB_BENCHES is a space-separated list
"$py" bench/runner_ab/ab.py --out "$out" --reps "${AB_REPS:-10}" "${arms[@]}" $AB_BENCHES

# AB_STATS=N: the default heap's counters at exit (bench/runner_ab/gc_counters.cr:
# collections, pauses, in-place grows, large reservations, maps and unmaps),
# N runs per bench of `base` and of `var`, into gc-counters.txt. Separate
# binaries, since the wrapper moves code; the collector's work doesn't depend
# on where code lands.
if [ "${AB_STATS:-0}" != 0 ]; then
  MAIN=bench/runner_ab/gc_counters.cr build ../ab-base ab-stats-base -Dgc_none
  MAIN=bench/runner_ab/gc_counters.cr build . ab-stats-var -Dgc_none
  for i in $(seq "$AB_STATS"); do
    for b in $AB_BENCHES; do
      for a in base var; do
        # crystal-metric exits 1 when a bench prints `err`.
        line=$("$root/bin/ab-stats-$a$exe" "$b" 2>&1 | grep -E "^($b:|GCSTATS)" | tr '\n' ' ' || true)
        echo "$a $b $i $line" | tee -a "$out/gc-counters.txt"
      done
    done
  done
fi

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
