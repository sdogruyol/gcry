#!/usr/bin/env bash
# buildpad.sh <arm> <N>: crystal-metric against arms/<arm> with N bytes of nops
# ahead of all code (the perf-ab `pN` probe: a pad prelude, bench/runner_ab/ab.sh `prep`).
# Output bin/cm-<arm>-p<N>. Run under the heavy lock.
set -euo pipefail
S=/home/naruto/playground/.scratch/MarkCost-2
name=$1 n=$2
src=$S/arms/$name work=$S/cm/$name-p$n
rm -rf "$work" && mkdir -p "$work"
cp -r "$src/bench/crystal_metric/." "$work/"
rm -rf "$work/lib" && mkdir -p "$work/lib" && ln -sfn "$src" "$work/lib/gcry"
cd "$work"
printf '@[NoInline]\ndef __placement_pad\n  asm(".skip %d, 0x90" :::: "volatile")\nend\n\n__placement_pad\n\nrequire "prelude"\n' "$n" > pad_prelude.cr
taskset -c 0-3 crystal build -Dgc_none --release --prelude ./pad_prelude main.cr -o "$S/bin/cm-$name-p$n"
echo built $S/bin/cm-$name-p$n
