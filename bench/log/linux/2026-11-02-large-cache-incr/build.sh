#!/usr/bin/env bash
# build.sh SRC_TREE OUT [counters]: crystal-metric with SRC_TREE/src as gcry
set -euo pipefail
S=/home/naruto/playground/.scratch/LargeCacheIncr
src=$1 o=$2
d=$S/build-$o
rm -rf "$d" && mkdir -p "$d/lib/gcry"
cp -r $S/wt/bench/crystal_metric/. "$d/"
rm -rf "$d/lib" && mkdir -p "$d/lib/gcry" && cp -r "$src/src" "$d/lib/gcry/src"
if [ "${3:-}" = counters ]; then cat $S/wt/bench/runner_ab/gc_counters.cr "$d/main.cr" > "$d/m.tmp" && mv "$d/m.tmp" "$d/main.cr"; fi
cd "$d" && crystal build -Dgc_none --release main.cr -o "$S/bin/$o"
