# Measurement infrastructure verification

These are two-round, two-second HTTP smoke trials, **not performance evidence**.
The same-binary null has a very wide interval; no throughput claim is made.

- `python3 -m unittest discover -s bench/performance -p 'test_*.py'`: five
  checks pass (ratio estimator/CI, tick conversion, invalid/duplicate/incomplete
  trials, request-error census, socket reuse versus a live listener).
- Focused collector specs: 19 examples pass (cursor, metrics, collection).
- Headerless process graph smoke: fanout 3 remains 6,000 edges on 2,000 objects
  after churn at survival 0.25 and 0.75, in fresh child processes. Atomic
  trace-only control reports 1,000 objects and zero edges.
- HTTP runner: six valid trials across Boehm, an identical-binary null, and
  the instrumented headerless build, with no request errors. All five optional
  root sub-timers are present and nonzero in the gcry snapshots.
- The first runner smoke was rejected after a socket TIME_WAIT collision;
  port checks now use SO_REUSEADDR and trials advance ports. Invalid trials
  were retained; they were not substituted into these results.

Build provenance is in `smoke-manifest.json` (CPU description condensed to its
first processor entry); raw trials are in `smoke-trials.jsonl`. Full logs and
snapshots from this smoke are at `/tmp/gcry-measurement-smoke-fixed` locally.
The manifest records a dirty source tree because this is pre-commit verification.

The next performance comparison must use the measurement commit as its baseline
and the reviewed #34 head as a cumulative control. Existing historic results
remain untouched. The new medium-buffer regression was observed to fail before
implementation: its second 2,049-byte allocation records zero cursor hits.

Headerless process suite: 31 examples pass. Lint: 120 files, zero failures.
Knob documentation check: all 163 source knobs documented.
