#!/bin/bash
# A/B the checked-out tree against origin/master on crystal-metric: both built
# here, run interleaved, Σ mark from GCRY_TRACE and the benchmark's own time.
set -e
git fetch -q origin master --depth=1
git worktree add -q ../base FETCH_HEAD
build() {
  d=$(mktemp -d)
  cp -r bench/crystal_metric/. "$d/"
  mkdir -p "$d/lib/gcry" && cp -r "$1/src" "$d/lib/gcry/src"
  (cd "$d" && crystal build -Dgc_none --release main.cr -o "$2")
}
mkdir -p bin
build ../base "$PWD/bin/base"
build . "$PWD/bin/var"
python3 ci/probe/ab.py "${AB_REPS:-10}" ${AB_BENCHES:-Primes JsonParsePure Binarytrees JsonGenerate}
