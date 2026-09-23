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
#     --runner macos-latest --commit <sha> --warn-only pct_json \
#     /tmp/gcry-perf-summaries/*.json
#
# `--warn-only pct_json` on macOS only: its `/json` throughput spread is ~4x
# Linux's (sd 15.4 pp, n=16, 2026-09-23), too wide to gate at 3.3 sd.
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
# Staging on the cache directory, not the default temp dir: `gh` writes each
# artifact's zip to `$TMPDIR`, and on a host whose `/tmp` is a quota'd tmpfs
# every download failed with "disk quota exceeded" (2026-09-23). The zips are
# small; the directory holding them is what has to have room.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/gcry-perf-collect"
mkdir -p "$CACHE"
WORK="$(mktemp -d "$CACHE/work.XXXXXX")"
export TMPDIR="$WORK"
trap 'rm -rf "$WORK"' EXIT

runs="$(gh run list --branch "$BRANCH" --workflow CI --limit "$LIMIT" \
  --json databaseId,conclusion --jq '.[] | select(.conclusion=="success") | .databaseId')"

kept=0
skipped=0
failed=0
first_error=""
for id in $runs; do
  rm -rf "$WORK/art"
  mkdir -p "$WORK/art"
  # A run without this artifact is normal (the job did not exist yet, or was
  # skipped) and is not a failure. Anything else is — and it used to be
  # swallowed, so on 2026-09-23 a full /tmp quota ("disk quota exceeded" on
  # every download) printed "collected 0" as though CI had nothing to give.
  if ! err="$(gh run download "$id" -n "$ARTIFACT" -D "$WORK/art" 2>&1 >/dev/null)"; then
    case "$err" in
      *"no artifact matches"*|*"no valid artifacts"*|*"not found"*) ;;
      *) failed=$((failed + 1)); [ -z "$first_error" ] && first_error="run $id: $err" ;;
    esac
    continue
  fi
  verdict="$(python3 - "$WORK/art" "$RUNNER" "$LAYOUT" "$OUT_DIR" "$id" <<'PY'
import json, pathlib, shutil, sys
root, runner, layout, out, run_id = sys.argv[1:6]
root, out = pathlib.Path(root), pathlib.Path(out)
# Every summary in the artifact, then the newest that matches — not the first
# one globbed. An artifact that carried the checked-in history as well as the
# run's own summary (the macOS job's did, until 2026-09-23) put a stale file
# first, and judging the first file skipped the run. A run whose artifact has
# summaries but none matching is still a skip; one with none at all is "none".
found = [f for f in root.rglob("summary.json")]
best = None
for f in found:
    try:
        s = json.loads(f.read_text())
    except Exception:
        continue
    if s.get("runner") != runner or (layout and s.get("layout") != layout):
        continue
    if best is None or s.get("timestamp", "") > best[1].get("timestamp", ""):
        best = (f, s)
if best:
    shutil.copy(best[0], out / ("{}.json".format(run_id)))
    print("keep")
elif found:
    print("skip")
else:
    print("none")
PY
)"
  case "$verdict" in
    keep) kept=$((kept + 1)) ;;
    skip) skipped=$((skipped + 1)) ;;
  esac
done

# One sampling protocol, the newest run's. Summaries written before 2026-09-22
# carry no `wrk_duration_s`/`bench_runs`, and `record` cannot tell them from
# the current protocol's, so the documented `*.json` recording would have
# mixed ten 5 s, 3-run summaries into sixteen 10 s, 7-run ones on 2026-09-23.
# The ones dropped are counted, like the runner and layout skips.
dropped="$(python3 - "$OUT_DIR" <<'PY'
import json, pathlib, sys
files = sorted(pathlib.Path(sys.argv[1]).glob("*.json"))
rows = [(f, json.loads(f.read_text())) for f in files]
key = lambda s: tuple(s.get(k) for k in ("wrk_duration_s", "wrk_connections", "bench_runs"))
if rows:
    newest = key(max(rows, key=lambda r: r[1].get("timestamp", ""))[1])
    gone = [f for f, s in rows if key(s) != newest]
    for f in gone:
        f.unlink()
    print("{} {}".format(len(gone), "wrk_duration_s={} wrk_connections={} bench_runs={}".format(*newest)))
else:
    print("0 -")
PY
)"
kept=$((kept - ${dropped%% *}))
echo "collected $kept summary/summaries into $OUT_DIR (runner=$RUNNER layout=$LAYOUT artifact=$ARTIFACT protocol: ${dropped#* })"
[ "$skipped" -gt 0 ] && echo "skipped $skipped on runner or layout mismatch"
[ "${dropped%% *}" -gt 0 ] && echo "dropped ${dropped%% *} sampled under an older protocol"
if [ "$failed" -gt 0 ]; then
  echo "FAILED to download $failed artifact(s), so the count above is not what CI holds"
  echo "  first: $first_error"
  exit 1
fi
# The recording rule this repo settled on: fewer than three runs writes no
# tolerance at all, and the tolerance is 3.3 standard deviations, which needs
# enough samples for a standard deviation to mean something. Twenty is where
# the Linux recordings stopped moving.
if [ "$kept" -lt 20 ]; then
  echo "that is fewer than the 20 a recording should use; run again when CI has more"
fi
exit 0
