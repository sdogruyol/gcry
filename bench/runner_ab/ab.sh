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
# this script come from the checkout. Optional: AB_VAR_ENV (`var` under extra
# environment), AB_PADS (placement probes of `var` or `base`), AB_STATS (heap
# counters of `base` and `var`) and AB_KEMAL_TRIALS (with AB_KEMAL_PATHS); each
# is described where it's used. AB_BENCHES=- skips crystal-metric, for a
# Kemal-only run.
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

# A placement probe is one never-inlined function whose body is N bytes of
# nops, called once. Crystal emits a function where codegen first reaches a
# call to it, so the code emitted after the pad lands N bytes further on
# (rounded up to the next function's 16-byte alignment) and nothing else
# changes: the program, the collector and the work they do are the same.
# PAD calls it first in the entry file (crystal-metric's `main.cr`, Kemal's
# `server.cr`), which moves the benchmark and the stdlib code it is first to
# use, but not the collector or anything else the prelude reaches before the
# entry file runs. PREPAD calls it from a prelude that requires the stock one
# after it (`--prelude`), so it comes ahead of all of the program's code,
# gcry's allocation paths included. Works with the MSVC toolchain too:
# `.skip` is LLVM's assembler directive, and a release build's code is one
# `.text` section, which link.exe keeps in order. `syms/<binary>.txt` shows
# where every function went.
pad_src='@[NoInline]\ndef __placement_pad\n  asm(".skip %d, 0x90" :::: "volatile")\nend\n\n__placement_pad\n\n'

# prep DIR ENTRY: apply PAD, PREPAD and COUNTERS to the copy of a program in
# DIR whose entry file is DIR/ENTRY, and set `flags` for its build (run in
# DIR). COUNTERS=1 puts bench/runner_ab/gc_counters.cr (the heap's counters
# printed at exit) ahead of the entry file's code. The pad prelude goes next
# to the entry file: crystal resolves `--prelude ./x` from there.
# shellcheck disable=SC2059 # the placement probe's source is printf's format
prep() {
  local dir=$1 entry=$2
  if [ -n "${COUNTERS:-}" ]; then
    { cat bench/runner_ab/gc_counters.cr "$dir/$entry"; } > "$dir/$entry.tmp" && mv "$dir/$entry.tmp" "$dir/$entry"
  fi
  if [ -n "${PAD:-}" ]; then
    { printf "$pad_src" "$PAD" && cat "$dir/$entry"; } > "$dir/$entry.tmp" && mv "$dir/$entry.tmp" "$dir/$entry"
  fi
  flags=()
  if [ -n "${PREPAD:-}" ]; then
    { printf "$pad_src" "$PREPAD" && echo 'require "prelude"'; } > "$(dirname "$dir/$entry")/pad_prelude.cr"
    flags+=(--prelude ./pad_prelude)
  fi
}

# syms OUT: every function's address in bin/OUT, to tell placement probes
# apart (`nm` on POSIX, the link map on Windows, written by the build).
syms() {
  mkdir -p "$out/syms"
  if [ -n "$exe" ]; then
    cp "$root/bin/$1.map" "$out/syms/$1.txt"
  else
    nm -n "$root/bin/$1" > "$out/syms/$1.txt"
  fi
}

# build SRC_ROOT OUT [crystal flags...]: crystal-metric from this checkout,
# with SRC_ROOT/src vendored as its `gcry` dependency, under PAD, PREPAD and
# COUNTERS (`prep`).
build() {
  local src=$1 o=$2
  shift 2
  rm -rf ../ab-build && mkdir -p ../ab-build
  cp -r bench/crystal_metric/. ../ab-build/
  rm -rf ../ab-build/lib && mkdir -p ../ab-build/lib/gcry && cp -r "$src/src" ../ab-build/lib/gcry/src
  prep ../ab-build main.cr
  # Windows writes a link map, the only symbol table its toolchain leaves.
  if [ -n "$exe" ]; then flags+=(--link-flags "/MAP:$root/bin/$o.map"); fi
  # `${flags[@]+...}`: macOS' bash 3.2 calls an empty array unbound under `set -u`.
  (cd ../ab-build && crystal build "$@" ${flags[@]+"${flags[@]}"} --release main.cr -o "$root/bin/$o$exe")
  syms "$o"
}

# AB_PADS="16 80 p16 p2096 bp16" adds a placement-probe arm per count: the
# `var` source with N bytes of nops in front of the benchmark's code (`N`, arm
# `pad<N>`) or of all the program's code, the collector's included (`pN`, arm
# `prepad<N>`); see `prep`. A `b` in front pads the `base` source instead
# (`bN`, `bpN`: arms `basepad<N>`, `baseprepad<N>`), so two revisions' spreads
# are measured in the same interleaved run. Their spread is what code
# placement alone moves a bench by on this runner. `pad_arm SPEC` sets the
# arm's name (`pname`) and source (`psrc`), and `padded CMD...` runs CMD under
# that arm's PAD or PREPAD.
pad_arm() {
  local n=$1
  pname="" psrc=.
  case "$n" in b*) psrc=../ab-base pname=base n=${n#b} ;; esac
  case "$n" in
    p*) pname="${pname}prepad${n#p}" pkind=PREPAD pn=${n#p} ;;
    *) pname="${pname}pad$n" pkind=PAD pn=$n ;;
  esac
}
padded() {
  if [ "$pkind" = PREPAD ]; then PREPAD=$pn "$@"; else PAD=$pn "$@"; fi
}

mkdir -p bin "$out"
AB_BENCHES=${AB_BENCHES:-Primes JsonParsePure Binarytrees JsonGenerate}
if [ "$AB_BENCHES" != - ]; then
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
  for spec in ${AB_PADS:-}; do
    pad_arm "$spec"
    padded build "$psrc" "ab-$pname" -Dgc_none
    arms+=(--arm "$pname=$root/bin/ab-$pname$exe")
  done
  crystal --version
  # shellcheck disable=SC2086 # AB_BENCHES is a space-separated list
  "$py" bench/runner_ab/ab.py --out "$out" --reps "${AB_REPS:-10}" "${arms[@]}" $AB_BENCHES
fi

# AB_STATS=N: the default heap's counters at exit (bench/runner_ab/gc_counters.cr:
# collections, pauses, in-place grows, large reservations, maps and unmaps),
# N runs per bench of `base` and of `var`, into gc-counters.txt. Separate
# binaries, since the hook moves code; the collector's work doesn't depend
# on where code lands.
if [ "${AB_STATS:-0}" != 0 ] && [ "$AB_BENCHES" != - ]; then
  COUNTERS=1 build ../ab-base ab-stats-base -Dgc_none
  COUNTERS=1 build . ab-stats-var -Dgc_none
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
# AB_KEMAL_PATHS (default "/json,/") picks the routes. AB_PADS adds the same
# placement-probe arms as for crystal-metric (PAD pads `server.cr`), and
# AB_STATS=N adds N counter runs of `base` and `var` per path into
# kemal-gc-counters.txt (kemal_ab.py --stats).
if [ "${AB_KEMAL_TRIALS:-0}" != 0 ]; then
  (cd bench/kemal && shards install)
  # kbuild SRC_ROOT OUT [crystal flags...]: bench/kemal, copied, with
  # SRC_ROOT/src as its `gcry`, under PAD, PREPAD and COUNTERS (`prep`).
  kbuild() {
    local src=$1 o=$2
    shift 2
    # server.cr requires ../../performance/header_policy, hence the layout.
    local k=../kab-build/kemal
    rm -rf ../kab-build && mkdir -p ../kab-build/performance && cp -r bench/kemal $k
    cp bench/performance/header_policy.cr ../kab-build/performance/
    rm -rf $k/lib/gcry && mkdir -p $k/lib/gcry && cp -r "$src/src" $k/lib/gcry/src
    prep $k src/server.cr
    (cd $k && crystal build "$@" ${flags[@]+"${flags[@]}"} --release src/server.cr -o "$root/bin/$o")
    syms "$o"
  }
  kbuild ../ab-base kemal-base -Dgc_none
  kbuild . kemal-var -Dgc_none
  kbuild . kemal-boehm
  karms=(--arm "boehm=$root/bin/kemal-boehm" --arm "base=$root/bin/kemal-base" --arm "var=$root/bin/kemal-var")
  for spec in ${AB_PADS:-}; do
    pad_arm "$spec"
    padded kbuild "$psrc" "kemal-$pname" -Dgc_none
    karms+=(--arm "$pname=$root/bin/kemal-$pname")
  done
  kstats=()
  if [ "${AB_STATS:-0}" != 0 ]; then
    COUNTERS=1 kbuild ../ab-base kemal-stats-base -Dgc_none
    COUNTERS=1 kbuild . kemal-stats-var -Dgc_none
    kstats=(--stats "$AB_STATS" --stats-arm "base=$root/bin/kemal-stats-base" --stats-arm "var=$root/bin/kemal-stats-var")
  fi
  crystal --version
  "$py" bench/runner_ab/kemal_ab.py --out "$out" --trials "$AB_KEMAL_TRIALS" --paths "${AB_KEMAL_PATHS:-/json,/}" \
    "${karms[@]}" ${kstats[@]+"${kstats[@]}"}
fi
