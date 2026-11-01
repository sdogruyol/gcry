#!/usr/bin/env bash
# Probe only (probe/primes-040-*): crystal-metric against several gcry trees,
# each arm traced (GCRY_TRACE, collect_end lines), interleaved per rep.
#   PROBE_ARMS="base=<sha> bp16=<sha>:p16 ..." PROBE_BENCHES="Primes" PROBE_REPS=20
set -euo pipefail
cd "$(dirname "$0")/../.."
exe="" py=python3
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) exe=.exe py=python ;; esac
root=$(pwd -W 2>/dev/null || pwd)
pad_src='@[NoInline]\ndef __placement_pad\n  asm(".skip %d, 0x90" :::: "volatile")\nend\n\n__placement_pad\n\n'
mkdir -p bin probe-out
armargs=()
for spec in $PROBE_ARMS; do
  name=${spec%%=*} rest=${spec#*=}
  envkv=""
  case "$rest" in *"|"*) envkv=${rest#*|} rest=${rest%%|*} ;; esac
  sha=${rest%%:*} pad=""
  [ "$rest" != "$sha" ] && pad=${rest#*:}
  d=../pb-$name
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
  (cd "$d" && crystal build -Dgc_none ${flags[@]+"${flags[@]}"} --release main.cr -o "$root/bin/pb-$name$exe")
  armargs+=("$name=$root/bin/pb-$name$exe${envkv:+|$envkv}")
done
$py bench/runner_ab/probe_pace.py "$root/probe-out" "${PROBE_REPS:-20}" "$PROBE_BENCHES" "${armargs[@]}"
