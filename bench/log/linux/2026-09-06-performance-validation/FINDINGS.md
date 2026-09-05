# PR #34 performance implementation validation

Linux x86_64, Crystal 1.21.0. These are correctness checks, not performance
trials. Full transcripts are adjacent; expected red controls and invariant
self-tests are retained in the logs.

| Check | Configuration | Result |
|---|---|---|
| Unit suites | header; bitmap with headers; headerless | 259 / 259 / 245 examples, zero failures; one platform pending each |
| Process suites | `-Dgc_none`; bitmap with headers; headerless | 32 examples each, zero failures |
| Focused invariants | headerless cursor, refill, atomic queue | zero failures |
| ASan | `-Dasan -Dgcry_headerless spec/all_specs.cr`, leak checking disabled | 231 examples, zero failures |
| Parallel marking / termination | headerless process GC | pass, including deliberately broken termination control |
| Mark audit, fork, OOM without hang | headerless process GC | pass |
| STW multi-thread properties, index race | headerless process GC | pass |
| Thread-birth and scheduler roots | headerless process GC | pass, including controls |
| Dormant-flush race | headerless process GC, first index draft | safe arm 0/6 failed; unsafe control 6/6 failed |
| Page-release corruption, heap counters | intended header configuration | pass, including engagement / counter controls |
| Lint and knob documentation | 123 files; 163 knobs | pass |
| Darwin type-check | aarch64 and x86_64 cross-compilation | pass; no native Darwin performance claim |

## Tests that caught problems

The first refill-index draft failed explicit-free and post-collection reuse.
Its mapping-base addresses were being passed to a payload-containment lookup,
which correctly rejected metadata addresses. Exact mapping-key lookup fixed it.

The atomic enqueue regression was red before the optimization, then passed in
both representations. It also checks that pointerful edges are still followed.

A later lock review found that exact mapping lookup must follow the existing
stopped-world index protocol. The regression holds the index lock while the
world is stopped: the first version hangs and was killed at a three-second
SIGKILL deadline; the fix reads the stable index without taking that lock.
A plain SIGTERM deadline could not stop the spinning test, so it was explicitly
killed and the bounded reproduction repeated with SIGKILL. All five refill
specs and the headerless process suite pass after the fix. The final release smoke has 0/1 safe-arm failures and 1/1 unsafe-control failures.
The final index race reports zero foreign unlocked readers with the safe ordering,
and 12,531 with its deliberately late-clear control. See `refill-final-lock-gates.txt`.
Application trials were interrupted for this fix and restarted from fresh builds.

## Harness limitation

Forcing `page-release-corruption` to compile headerless reports no corruption
but fails engagement. The harness explicitly sets `GCRY_BITMAP_ALLOC=0` in all
arms and expects header freelist page-unlink behavior. A headerless binary
cannot honor that setting. The failed invocation is retained in
`refill-gates.txt`; it is not counted as a pass. The intended header build passes.
Do not lower engagement thresholds or claim that this gate certifies a bitmap
free-page walk. Bitmap validation uses the applicable cursor, collection,
dormant-release, index, process and sanitizer checks above.

## Scope of the evidence

An existing 24-hour soak continues on a different checkout. It is neither
stopped nor claimed as validation of this implementation. New measurements
avoid deliberate competing build/stress loads, but disclose that background
process. Native aarch64/Darwin runs and an independent confirmation session are
still required before changing portable header defaults. The root-discovery,
controller and wider mark-stack proposals remain conditional, not unfinished
implementation obligations.


## Final retirement and publication check

`refill-retire-red.txt` records the missed reuse before the correction: a
second thread cached an empty pool while the first cursor still owned a chunk
with a bit freed behind its current word. Retiring that cursor now publishes
its available capacity. All six focused regressions pass in both layouts;
full suites and ASan were repeated on the final code, with counts above.

The final generation publication uses release/acquire ordering, covering prior
occupancy/ownership writes on weakly ordered CPUs. `final-retire-gates.txt`
records the repeated STW properties/index/fork checks, and `final-darwin.txt`
records both Darwin cross type-checks. Native ARM performance is still unmeasured.


## Final smoke checks

Formatting, lint (123 files) and knob documentation (163 knobs) pass. The final
bitmap-with-headers process suite passes 32 examples; focused headerless
invariants pass. The headerless soak smoke passes its normal 4 MiB RSS-growth
ceiling (+1,004 KiB measured). The bitmap-with-headers EC4 Kemal soft soak passes
all five eight-second trials with zero soft or hard errors. These are new smoke
checks of this source, separate from the existing 24-hour soak on another tree.
Seven Python measurement tests pass. Final headerless HTTP confirmation has
60 error-free trials and matching collector/server source hashes; its throughput
interval remains inconclusive.

## Native ARM follow-up

The first native CI run exposed a pre-existing header stress defect: the
reviewed baseline and performance head both fail an existing accounting
assertion in 10/10 exact-command trials after the new pressure test. The
baseline also reproduces a buffer failure. Both bitmap representations pass
all ten trials each. See the [diagnosis and reproducer](../2026-09-06-native-arm/FINDINGS.md).

The cursor-specific process test is now pending in header mode, with an
explicit opt-in preserving the header reproducer. After this test-only scope
change, the local header suite passes 32 examples with one pending; both bitmap
suites pass 32 with none pending. Existing header assertions are unchanged.
Native ARM CI now includes both bitmap process suites; Darwin already did.
The header defect remains unresolved and blocks any header-default decision.
