#!/usr/bin/env bash
# build.sh <arm>: build crystal-metric with main_probe.cr against arms/<arm>
# (a gcry source snapshot made by mkarms.sh). Output: bin/cm-<arm>.
# Run under the heavy lock.
set -euo pipefail
S=/home/naruto/playground/.scratch/ParallelMarkBatch
LOG=$(cd "$(dirname "$0")" && pwd)
name=$1
src=$S/arms/$name
work=$S/cm/$name
rm -rf "$work" && mkdir -p "$work"
cp -r "$src/bench/crystal_metric/." "$work/"
rm -rf "$work/lib" && mkdir -p "$work/lib"
ln -sfn "$src" "$work/lib/gcry"
cp "$LOG/main_probe.cr" "$work/"
cd "$work"
taskset -c 0-3 crystal build -Dgc_none ${EXTRA_FLAGS:-} --release main_probe.cr -o "$S/bin/cm-$name"
echo "built $S/bin/cm-$name"
