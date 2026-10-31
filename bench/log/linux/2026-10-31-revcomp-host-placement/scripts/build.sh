#!/usr/bin/env bash
# build.sh REV OUTNAME [PREPAD] [COUNTERS]: crystal-metric (bench from the
# revcomp-host-040 worktree) with gcry src at REV, optionally prepadded by
# PREPAD bytes of nops ahead of all code (as bench/runner_ab/ab.sh `pN`), and
# with the gc_counters hook when COUNTERS=1. Binary -> bins/OUTNAME, nm -> syms/.
set -euo pipefail
S=/home/naruto/playground/.scratch/RevcompHost
WT=$S/wt
rev=$1 out=$2 prepad=${3:-0} counters=${4:-0}
work=$S/work/$out
rm -rf "$work" && mkdir -p "$work/lib/gcry" "$S/bins" "$S/syms"
cp -r "$WT/bench/crystal_metric/." "$work/"
git -C "$WT" archive "$rev" src | tar -x -C "$work/lib/gcry"
flags=()
if [ "$counters" = 1 ]; then
  { cat "$WT/bench/runner_ab/gc_counters.cr" "$work/main.cr"; } > "$work/main.tmp" && mv "$work/main.tmp" "$work/main.cr"
fi
if [ "$prepad" != 0 ]; then
  printf '@[NoInline]\ndef __placement_pad\n  asm(".skip %d, 0x90" :::: "volatile")\nend\n\n__placement_pad\n\nrequire "prelude"\n' "$prepad" > "$work/pad_prelude.cr"
  flags+=(--prelude ./pad_prelude)
fi
cd "$work"
crystal build -Dgc_none ${flags[@]+"${flags[@]}"} --release main.cr -o "$S/bins/$out"
nm -n "$S/bins/$out" > "$S/syms/$out.txt"
rm -rf "$work"
