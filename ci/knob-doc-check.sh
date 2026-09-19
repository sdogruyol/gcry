#!/usr/bin/env bash
# Every `GCRY_*` the collector reads must appear in docs/HARDENING.md.
#
# The env reference had drifted by 33 knobs before this existed — everything
# added in v0.20.0 and everything added on 2026-08-22 — which is the failure
# mode a reference has: nothing breaks when it goes stale, so nothing says so.
set -euo pipefail

# `comm` compares bytes; `sort` compares by collation. Under a UTF-8 locale
# those disagree wherever `_` meets a letter — glibc's collation ignores the
# underscore, so `sort` emits `GCRY_PRECISE_FIBER_LEAF` before
# `GCRY_PRECISE_FIBERS` while `comm` expects the reverse ('S' 0x53 < '_' 0x5F).
# `comm` then exits 1 with "input is not in sorted order" and `set -e` turns a
# green tree red, which is what this gate did on an `en_US.UTF-8` box on
# 2026-09-19 while passing on CI. The failure direction was the harmless one
# here; the same mismatch can also let `comm` walk past a genuinely missing
# knob. Pinned, so the gate answers the same question on every host.
export LC_ALL=C

src_knobs=$(grep -rhoE 'GCRY_[A-Z0-9_]+' src/ --include='*.cr' | sort -u)
doc_knobs=$(grep -ohE 'GCRY_[A-Z0-9_]+' docs/HARDENING.md | sort -u)
missing=$(comm -23 <(echo "$src_knobs") <(echo "$doc_knobs"))

if [ -n "$missing" ]; then
  echo "FAIL: read by src/ and absent from docs/HARDENING.md:"
  echo "$missing" | sed 's/^/  /'
  exit 1
fi

echo "ok — all $(echo "$src_knobs" | wc -l | tr -d ' ') GCRY_* knobs the source reads are in docs/HARDENING.md"
