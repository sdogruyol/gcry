#!/usr/bin/env bash
# build.sh KIND REV OUT [PREPAD]: KIND cm|kemal; REV a git rev of gcry (or "boehm");
# the bench sources come from the numbers-040 worktree (release-0.40.0 tip), only
# lib/gcry/src is swapped, as bench/runner_ab/ab.sh does. PREPAD = nop bytes ahead of
# all code (ab.sh's pN). Binary -> bins/OUT, nm -> syms/OUT.txt.
set -euo pipefail
S=/home/naruto/playground/.scratch/Numbers040
WT=$S/wt
export TMPDIR=$S/tmp
mkdir -p "$TMPDIR" "$S/bins" "$S/syms"
kind=$1 rev=$2 out=$3 prepad=${4:-0}
work=$S/work/$out
rm -rf "$work" && mkdir -p "$work"
flags=()
gcflag=(-Dgc_none)
[ "$rev" = boehm ] && { gcflag=(); rev=HEAD; }
if [ "$kind" = cm ]; then
  cp -r "$WT/bench/crystal_metric/." "$work/"
  rm -rf "$work/lib" && mkdir -p "$work/lib/gcry"
  git -C "$WT" archive "$rev" src | tar -x -C "$work/lib/gcry"
  dir=$work entry=main.cr
else
  mkdir -p "$work/performance"
  cp -R "$WT/bench/kemal" "$work/kemal"
  cp "$WT/bench/performance/header_policy.cr" "$work/performance/"
  cp -R /home/naruto/playground/gcry/bench/kemal/lib "$work/kemal/lib"
  cp /home/naruto/playground/gcry/bench/kemal/shard.lock "$work/kemal/"
  rm -rf "$work/kemal/lib/gcry" && mkdir -p "$work/kemal/lib/gcry"
  git -C "$WT" archive "$rev" src | tar -x -C "$work/kemal/lib/gcry"
  dir=$work/kemal entry=src/server.cr
fi
if [ "$prepad" != 0 ]; then
  printf '@[NoInline]\ndef __placement_pad\n  asm(".skip %d, 0x90" :::: "volatile")\nend\n\n__placement_pad\n\nrequire "prelude"\n' "$prepad" > "$(dirname "$dir/$entry")/pad_prelude.cr"
  flags+=(--prelude ./pad_prelude)
fi
cd "$dir"
crystal build ${gcflag[@]+"${gcflag[@]}"} ${flags[@]+"${flags[@]}"} --release "$entry" -o "$S/bins/$out"
nm -n "$S/bins/$out" > "$S/syms/$out.txt"
rm -rf "$work"
