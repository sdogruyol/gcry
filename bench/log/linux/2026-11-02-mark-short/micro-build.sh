#!/usr/bin/env bash
# build.sh <gcry-src-root> <out>: main_mark.cr against a gcry tree.
set -euo pipefail
src=$1 out=$2
work=${MS_SCRATCH:-$PWD}/micro/work-$(basename "$out")
rm -rf "$work" && mkdir -p "$work/lib"
cp -r "$src/bench/crystal_metric/." "$work/"
rm -rf "$work/lib" && mkdir -p "$work/lib"
ln -sfn "$src" "$work/lib/gcry"
cp ${MS_SCRATCH:-$PWD}/micro/main_mark.cr "$work/"
cd "$work" && crystal build -Dgc_none --release main_mark.cr -o "$out"
