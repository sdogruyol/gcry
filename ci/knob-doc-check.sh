#!/usr/bin/env bash
# Every `GCRY_*` the collector reads must appear in docs/HARDENING.md.
#
# The env reference had drifted by 33 knobs before this existed — everything
# added in v0.20.0 and everything added on 2026-08-22 — which is the failure
# mode a reference has: nothing breaks when it goes stale, so nothing says so.
set -euo pipefail

src_knobs=$(grep -rhoE 'GCRY_[A-Z0-9_]+' src/ --include='*.cr' | sort -u)
doc_knobs=$(grep -ohE 'GCRY_[A-Z0-9_]+' docs/HARDENING.md | sort -u)
missing=$(comm -23 <(echo "$src_knobs") <(echo "$doc_knobs"))

if [ -n "$missing" ]; then
  echo "FAIL: read by src/ and absent from docs/HARDENING.md:"
  echo "$missing" | sed 's/^/  /'
  exit 1
fi

echo "ok — all $(echo "$src_knobs" | wc -l | tr -d ' ') GCRY_* knobs the source reads are in docs/HARDENING.md"
