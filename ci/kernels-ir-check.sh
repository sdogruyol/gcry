#!/usr/bin/env bash
# Did the vector kernels actually vectorise, per target — and can we ask
# without that target's hardware?
#
# Yes, both: `--cross-compile --emit llvm-ir` runs the whole pipeline for a
# target and stops before linking, so an x86 box can read the aarch64 IR and
# an aarch64 box the x86 IR. The plan carried "aarch64 IR gate — CI only, no
# local arm64 host" as an open item on that misreading; the gate needs the
# target's *compiler*, never its CPU.
#
# What is asserted and why each line is load-bearing:
#
#   x86_64    `vpandn` / `vpshufb`   the AVX2 sweep's inline asm survived
#             `llvm.ctpop.v4i64`     AVX2 popcount vectorised (a scalar loop
#                                    carrying feature flags emits ctpop.i64)
#             `llvm.ctpop.v8i64`     the same for AVX-512
#             `<4 x i64>`/`<8 x i64>` the vector types themselves
#
#   aarch64   `+neon` / `+sve`       both tiers were compiled in
#             `llvm.ctpop.v2i64`     the NEON popcount vectorised
#             `<2 x i64>`            the vector type
#             `whilelo` / `cnt z`    the SVE kernels' inline asm survived
#
# Each arch also asserts the *other* one's fingerprints are absent. Without
# that a grep for a string the file never contains reads the same as a grep
# for one it should contain and does not: the negative half is what shows the
# patterns discriminate at all.
set -euo pipefail

CRYSTAL="${CRYSTAL:-crystal}"
BIN="${BIN:-bin}"
failures=0

emit() { # target-triple, output stem
  "$CRYSTAL" build --release --cross-compile --target "$1" --emit llvm-ir \
    spec/kernels_spec.cr -o "$BIN/$2" >/dev/null
}

want() { # file, pattern, why
  if grep -Fq "$2" "$1"; then
    printf '  ok      %-24s %s\n' "$2" "$3"
  else
    printf '  MISSING %-24s %s\n' "$2" "$3"
    failures=$((failures + 1))
  fi
}

reject() { # file, pattern, why
  if grep -Fq "$2" "$1"; then
    printf '  PRESENT %-24s %s\n' "$2" "$3"
    failures=$((failures + 1))
  else
    printf '  ok      %-24s absent, as it must be (%s)\n' "$2" "$3"
  fi
}

mkdir -p "$BIN"

echo "== x86_64-linux-gnu =="
emit x86_64-linux-gnu kernels_ir_x86
x86="$BIN/kernels_ir_x86.ll"
want "$x86" 'vpandn' 'AVX2 sweep asm'
want "$x86" 'vpshufb' 'AVX2 sweep asm'
want "$x86" 'llvm.ctpop.v4i64' 'AVX2 popcount vectorised'
want "$x86" 'llvm.ctpop.v8i64' 'AVX-512 popcount vectorised'
want "$x86" '<4 x i64>' 'AVX2 vector type'
want "$x86" '<8 x i64>' 'AVX-512 vector type'
reject "$x86" 'whilelo' 'aarch64 SVE asm'
reject "$x86" '"target-features"="+sve"' 'the aarch64 SVE tier'
# NOT `<2 x i64>`: that is SSE2's vector type as much as NEON's, and SSE2 is
# baseline on x86-64, so it appears in both files. A negative control has to
# name something only one target can emit.

echo "== aarch64-linux-gnu =="
emit aarch64-linux-gnu kernels_ir_aarch64
arm="$BIN/kernels_ir_aarch64.ll"
want "$arm" '"target-features"="+neon"' 'NEON tier compiled in'
want "$arm" '"target-features"="+sve"' 'SVE tier compiled in'
want "$arm" 'llvm.ctpop.v2i64' 'NEON popcount vectorised'
want "$arm" '<2 x i64>' 'NEON vector type'
want "$arm" 'whilelo' 'SVE kernel asm'
want "$arm" 'cnt z' 'SVE popcount asm'
reject "$arm" 'vpshufb' 'AVX2 sweep asm'
reject "$arm" '<8 x i64>' 'AVX-512 vector type'

echo ""
if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures IR assertion(s) — a kernel stopped vectorising for a target,"
  echo "or the pattern it is recognised by changed. Read the .ll rather than"
  echo "relaxing the grep: these are the only evidence the tiers are real."
  exit 1
fi
echo "ok — both targets vectorise, and neither carries the other's instructions"
