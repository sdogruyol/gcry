#!/usr/bin/env bash
# Probe only (probe/pace-growth-*): crystal-metric against gcry trees, each arm
# traced (GCRY_TRACE, collect_end lines), interleaved per rep. One build per
# distinct sha[:pad]; arms differ by environment.
#   PROBE_ARMS="tip=<sha> g1=<sha>|GCRY_PACE_VARIANT=1,GCRY_PACE_FLOOR=0 ..."
#   PROBE_BENCHES="Primes Knuckeotide" PROBE_REPS=12
set -euo pipefail
cd "$(dirname "$0")/../.."
exe="" py=python3
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) exe=.exe py=python ;; esac
root=$(pwd -W 2>/dev/null || pwd)
pad_src='@[NoInline]\ndef __placement_pad\n  asm(".skip %d, 0x90" :::: "volatile")\nend\n\n__placement_pad\n\n'
mkdir -p bin probe-out
armargs=()
declare -A built=()
for spec in $PROBE_ARMS; do
  name=${spec%%=*} rest=${spec#*=}
  envkv=""
  case "$rest" in *"|"*) envkv=${rest#*|} rest=${rest%%|*} ;; esac
  sha=${rest%%:*} pad=""
  [ "$rest" != "$sha" ] && pad=${rest#*:}
  key=${sha:0:12}${pad:+-$pad}
  if [ -z "${built[$key]:-}" ]; then
    d=../pb-$key
    rm -rf "$d" && mkdir -p "$d"
    cp -r bench/crystal_metric/. "$d/"
    rm -rf "$d/lib" && mkdir -p "$d/lib/gcry"
    git archive -o "$d/src.tar" "$sha" src && tar -xf "$d/src.tar" -C "$d/lib/gcry" && rm "$d/src.tar"
    flags=()
    if [ -n "$pad" ]; then
      # shellcheck disable=SC2059
      { printf "$pad_src" "${pad#p}" && echo 'require "prelude"'; } > "$d/pad_prelude.cr"
      flags+=(--prelude ./pad_prelude)
    fi
    (cd "$d" && crystal build -Dgc_none ${flags[@]+"${flags[@]}"} --release main.cr -o "$root/bin/pb-$key$exe")
    built[$key]=1
  fi
  armargs+=("$name=$root/bin/pb-$key$exe${envkv:+|$envkv}")
done
$py bench/runner_ab/probe_pace.py "$root/probe-out" "${PROBE_REPS:-12}" "$PROBE_BENCHES" "${armargs[@]}"
