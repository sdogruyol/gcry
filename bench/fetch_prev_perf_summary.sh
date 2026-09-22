#!/usr/bin/env bash
# The previous green master run's perf summary, for `perf_compare.py --prev`.
#
# The single-run gate fires at 3.3 sd, ~14 pp of `/json` throughput on the
# GitHub runner class, because a narrower band trades the false-alarm rate back.
# Two runs in a row on the wrong side of 2 sd costs 0.05% per pair instead, and
# catches ~9 pp — but it needs the previous run's numbers, and CI keeps no state
# between runs. It does keep artifacts: `perf-smoke-report` is uploaded by this
# very job, so the history is already there to read.
#
# Everything here degrades to "no previous run" rather than failing. A missing
# artifact, an expired one, a rate limit or a layout change must cost the
# sensitivity check and nothing else — a perf job that goes red because it could
# not download a file is worse than one that only judges a single run.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${PERF_PREV_OUT:-/tmp/gcry-prev-perf-summary.json}"
# Which job's artifact, and whose numbers inside it. Defaults are the Linux
# perf job because it is the one that gates; the Darwin job uploads
# `perf-smoke-report-macos` and will want this the day it has a baseline,
# and a second copy of this script is how the two drift apart.
ARTIFACT="${PERF_PREV_ARTIFACT:-perf-smoke-report}"
RUNNER="${PERF_PREV_RUNNER:-ubuntu-latest}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v gh >/dev/null || { echo "no gh: skipping the previous-run check"; exit 0; }
command -v python3 >/dev/null || { echo "no python3: skipping"; exit 0; }

# The layout the baseline was recorded on. A previous run built with another
# object layout is not a previous run for this purpose — the same reason
# `perf_compare.py` refuses to gate across a layout flip.
LAYOUT="$(python3 -c "
import json
try:
    print(json.load(open('$ROOT/bench/baseline/perf_smoke.json'))['provenance'].get('layout') or '')
except Exception:
    print('')
" 2>/dev/null)"

RUNS="$(gh run list --branch master --workflow CI --status success --limit 6 \
          --json databaseId -q '.[].databaseId' 2>/dev/null || true)"
if [ -z "$RUNS" ]; then
  echo "no green master runs to read: skipping the previous-run check"
  exit 0
fi

for id in $RUNS; do
  [ "${id}" = "${GITHUB_RUN_ID:-}" ] && continue
  rm -rf "$WORK/art"
  mkdir -p "$WORK/art"
  gh run download "$id" -n "$ARTIFACT" -D "$WORK/art" >/dev/null 2>&1 || continue
  found="$(python3 - "$WORK/art" "$LAYOUT" "$RUNNER" <<'PY'
import json, pathlib, sys
root, layout, runner = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
best = None
# `_run/summary.json` since 2026-09-13; the nested path is what the old
# whole-tree artifacts carry, and they stay downloadable for 30 days.
for pattern in ("_run/summary.json", "summary.json", "linux/*/summary.json", "*/*/summary.json"):
    for f in root.glob(pattern):
        try:
            s = json.loads(f.read_text())
        except Exception:
            continue
        if s.get("runner") != runner:
            continue
        if layout and s.get("layout") != layout:
            continue
        if best is None or f.stat().st_mtime > best.stat().st_mtime:
            best = f
    if best:
        break
print(best or "")
PY
)"
  if [ -n "$found" ] && [ -f "$found" ]; then
    cp "$found" "$OUT"
    echo "previous run $id: $(basename "$(dirname "$found")")"
    [ -n "${GITHUB_ENV:-}" ] && echo "PERF_PREV_SUMMARY=$OUT" >> "$GITHUB_ENV"
    exit 0
  fi
done

echo "no usable previous summary in the last runs: skipping the previous-run check"
exit 0
