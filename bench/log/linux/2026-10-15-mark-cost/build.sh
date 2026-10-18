#!/usr/bin/env bash
# build.sh <name> [boehm]: build crystal-metric against arms/<name> (a gcry source snapshot).
# Output: bin/cm-<name>; with MAIN=<file> (copied into the build dir) bin/cm-<name>-<MAIN stem>.
# Run under the heavy lock.
set -euo pipefail
S=/home/naruto/playground/.scratch/MarkCost
name=$1 kind=${2:-gcry}
src=$S/arms/$name
work=$S/cm/$name
rm -rf "$work" && mkdir -p "$work/lib"
cp -r "$src/bench/crystal_metric/." "$work/"
rm -rf "$work/lib" && mkdir -p "$work/lib"
ln -sfn "$src" "$work/lib/gcry"
cd "$work"
main=main.cr out=$S/bin/cm-$name
if [[ -n ${MAIN:-} ]]; then cp "$MAIN" "$work/"; main=$(basename "$MAIN"); out=$S/bin/cm-$name-${main%.cr}; fi
if [[ $kind == boehm ]]; then
  taskset -c 0-3 crystal build --release $main -o "$out"
else
  taskset -c 0-3 crystal build -Dgc_none ${EXTRA_FLAGS:-} --release $main -o "$out"
fi
echo built $out
