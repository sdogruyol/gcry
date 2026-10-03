#!/usr/bin/env bash
# gcry against a base revision on crystal-metric, both built in this job and
# run interleaved in random order per rep: Σ mark from GCRY_TRACE, and the
# benchmark's own timed section. Meant for GitHub runners (the `perf-ab`
# workflow), whose cores are quiet where a shared development host is not.
#
#   AB_BASE=origin/master AB_REPS=10 AB_BENCHES="Primes JsonParsePure" \
#     bench/runner_ab/ab.sh
#
# Output lines start with `AB `; nothing is gated.
set -euo pipefail
cd "$(dirname "$0")/../.."
base="${AB_BASE:-origin/master}"
git fetch -q origin "${base#origin/}" --depth=1 2>/dev/null || true
rev=$(git rev-parse --verify -q "$base" || git rev-parse FETCH_HEAD)
rm -rf ../ab-base && git worktree add -q --detach ../ab-base "$rev"
build() {
  d=$(mktemp -d)
  cp -r bench/crystal_metric/. "$d/"
  rm -rf "$d/lib" && mkdir -p "$d/lib/gcry" && cp -r "$1/src" "$d/lib/gcry/src"
  (cd "$d" && crystal build -Dgc_none --release main.cr -o "$2")
}
mkdir -p bin
build ../ab-base "$PWD/bin/ab-base"
build . "$PWD/bin/ab-var"
echo "AB base $(git -C ../ab-base rev-parse --short HEAD) vs $(git rev-parse --short HEAD)"
python3 bench/runner_ab/ab.py "${AB_REPS:-10}" ${AB_BENCHES:-Primes JsonParsePure Binarytrees JsonGenerate}
