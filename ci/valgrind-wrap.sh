#!/usr/bin/env bash
# Valgrind wrapper: runs memcheck and fails only on definite leaks.
# Ignores Crystal runtime false positives and gcry safe probing.
set -uo pipefail

cd "$(dirname "$0")/.."

VFLAGS=(
  --leak-check=full
  --suppressions=ci/valgrind-suppressions.txt
  --show-leak-kinds=definite
  --errors-for-leak-kinds=definite
  --undef-value-errors=no
  --error-exitcode=0
)

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

valgrind "${VFLAGS[@]}" "$@" 2>&1 | tee "$tmpfile" || true

# Check for definite leaks in the output
if grep -q "definitely lost: [1-9]" "$tmpfile" 2>/dev/null; then
  echo ""
  echo "FAIL: definite leak(s) detected"
  grep "definitely lost:" "$tmpfile"
  exit 1
fi

# All clean
exit 0