#!/usr/bin/env bash
# Collect green perf summaries from CI artifacts, for `perf_compare.py --record`.
#
# Recording a baseline needs N green runs on one runner class, and the runs are
# already there: every perf job uploads its `summary.json`. Assembling them was
# a hand job — the 48-run Linux baseline of 2026-09-14 was downloaded run by
# run — and a hand job is one nobody repeats, which is how a baseline goes
# stale through two default flips without anyone noticing (0.24.0, 0.26.0).
#
# It is also the missing half of the Darwin perf step added 2026-09-22: that
# job reports until it has a baseline, and a baseline needs this.
#
#   bench/collect_perf_summaries.sh                       # Linux, last 60 runs
#   ARTIFACT=perf-smoke-report-macos RUNNER=macos-latest \
#     bench/collect_perf_summaries.sh                     # Darwin
#
# Then, with the count it prints:
#
#   bench/perf_compare.py --record --out bench/baseline/perf_smoke_macos.json \
#     --runner macos-latest --commit <sha> /tmp/gcry-perf-summaries/*.json
#
# Summaries whose layout or runner does not match are skipped and counted, for
# the same reason `perf_compare.py` refuses to gate across either: mixing them
# widens the tolerance with a difference that is not the collector's.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="${ARTIFACT:-perf-smoke-report}"
RUNNER="${RUNNER:-ubuntu-latest}"
LIMIT="${LIMIT:-60}"
OUT_DIR="${OUT_DIR:-/tmp/gcry-perf-summaries}"
BRANCH="${BRANCH:-master}"
# The layout to keep. Defaults to what this checkout compiles by default, which
# is the one a baseline recorded now would have to describe.
LAYOUT="${LAYOUT:-headerless}"

command -v gh >/dev/null || { echo "need gh"; exit 1; }
command -v python3 >/dev/null || { echo "need python3"; exit 1; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

runs="$(gh run list --branch "$BRANCH" --workflow CI --limit "$LIMIT" \
  --json databaseId,conclusion --jq '.[] | select(.conclusion=="success") | .databaseId')"

kept=0
skipped=0
for id in $runs; do
  rm -rf "$WORK/art"
  mkdir -p "$WORK/art"
  gh run download "$id" -n "$ARTIFACT" -D "$WORK/art" >/dev/null 2>&1 || continue
  verdict="$(python3 - "$WORK/art" "$RUNNER" "$LAYOUT" "$OUT_DIR" "$id" <<'PY'
import json, pathlib, shutil, sys
root, runner, layout, out, run_id = sys.argv[1:6]
root, out = pathlib.Path(root), pathlib.Path(out)
for pattern in ("_run/summary.json", "summary.json", "*/*/summary.json", "*/summary.json"):
    for f in root.glob(pattern):
        try:
            s = json.loads(f.read_text())
        except Exception:
            continue
        if s.get("runner") != runner or (layout and s.get("layout") != layout):
            print("skip")
            raise SystemExit
        shutil.copy(f, out / ("{}.json".format(run_id)))
        print("keep")
        raise SystemExit
print("none")
PY
)"
  case "$verdict" in
    keep) kept=$((kept + 1)) ;;
    skip) skipped=$((skipped + 1)) ;;
  esac
done

echo "collected $kept summary/summaries into $OUT_DIR (runner=$RUNNER layout=$LAYOUT artifact=$ARTIFACT)"
[ "$skipped" -gt 0 ] && echo "skipped $skipped on runner or layout mismatch"
# The recording rule this repo settled on: fewer than three runs writes no
# tolerance at all, and the tolerance is 3.3 standard deviations, which needs
# enough samples for a standard deviation to mean something. Twenty is where
# the Linux recordings stopped moving.
if [ "$kept" -lt 20 ]; then
  echo "that is fewer than the 20 a recording should use; run again when CI has more"
fi
exit 0
