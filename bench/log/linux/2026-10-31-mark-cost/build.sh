#!/usr/bin/env bash
# build.sh <name> <srcdir> [boehm]: build crystal-metric against a gcry source tree.
set -euo pipefail
S=${MS_SCRATCH:-$PWD}
name=$1 src=$(realpath "$2") kind=${3:-gcry}
work=$S/cm/$name
rm -rf "$work" && mkdir -p "$work"
cp -r "$src/bench/crystal_metric/." "$work/"
rm -rf "$work/lib" && mkdir -p "$work/lib"
ln -sfn "$src" "$work/lib/gcry"
cd "$work"
main=main.cr out=$S/bin/cm-$name
if [[ -n ${MAIN:-} ]]; then cp "$MAIN" "$work/"; main=$(basename "$MAIN"); out=$S/bin/cm-$name-${main%.cr}; fi
if [[ $kind == boehm ]]; then
  crystal build --release $main -o "$out"
else
  crystal build -Dgc_none ${EXTRA_FLAGS:-} --release $main -o "$out"
fi
echo built $out
