#!/usr/bin/env bash
# Probe: regressions 79 and 86 built debug and --release in the three
# layouts, RUNS runs each. Usage: probe-wipe.sh MODE... (debug|release)
# Env: CR (crystal; not CC, which Crystal takes for the linker), RUNS (5), EXPECT_RED=1 (the red tree: 86 release must fail).
set -u
CR=${CR:-crystal}
RUNS=${RUNS:-5}
mkdir -p bin
fails=0
for mode in "$@"; do
  mflag=""; [ "$mode" = release ] && mflag="--release"
  for layout in default headers freelist; do
    lflag=""; [ "$layout" != default ] && lflag="-Dgcry_block_headers"
    bitmap=1; [ "$layout" = freelist ] && bitmap=0
    for spec in 79 86; do
      src=$(ls process_spec/regression/${spec}_*_spec.cr)
      bin="bin/p${spec}-${mode}-${layout}"
      echo "::group::build $spec $mode $layout"
      "$CR" build -Dgc_none $mflag $lflag "$src" -o "$bin" --error-trace || { echo "BUILD FAIL $spec $mode $layout"; fails=$((fails+1)); echo "::endgroup::"; continue; }
      echo "::endgroup::"
      for i in $(seq 1 "$RUNS"); do
        out=$(GCRY_BITMAP_ALLOC=$bitmap "./$bin" 2>&1); rc=$?
        line=$(printf '%s\n' "$out" | grep -E 'stale79|stale86|guard86|Expected|examples' | tr '\n' ' ')
        echo "RESULT spec=$spec mode=$mode layout=$layout run=$i rc=$rc :: $line"
        if [ $rc -ne 0 ]; then
          fails=$((fails+1))
          printf '%s\n' "$out" | tail -40
        fi
      done
    done
  done
done
echo "TOTAL FAILURES $fails"
if [ "${EXPECT_RED:-0}" = 1 ]; then
  [ "$fails" -gt 0 ] || { echo "RED TREE PASSED: the check cannot fail"; exit 1; }
  exit 0
fi
[ "$fails" -eq 0 ]
