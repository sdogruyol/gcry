# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [Unreleased]

## [0.27.0] - 2026-09-24

### Added

- **An idle process gives its memory back: `GCRY_IDLE_RELEASE_MS`, on by
  default at two minutes.** Once the process has allocated nothing for that
  long (`=0` turns it off, any other value moves it), a `gc-idle`
  thread runs one collection that releases as `GC.collect` does — the warm
  budget, the unmap grace and the garbage no sweep has seen yet — the idea
  behind Go's forced GC and G1's periodic collection. Kemal `/json` idles at
  14.2 MB instead of 20.4 MB (-30%, t=-52.6; the `/gc-collect` floor is
  13.4 MB, Boehm idles at 13.4 MB); throughput and pause p50 unchanged
  (+0.9%, +0.5%). The thread is not counted as a mutator, is exempt from the
  Linux suspend signal like the Monitor, and leaves finalizers to the next
  slow-path allocation on a mutator. It honours `GC.disable`, re-checked
  under the collector's lock. `make idle-release` gates it. It starts at the
  first collection. Two minutes is Go's forced-GC period: a short delay
  would release chunks the next burst faults straight back in. Linux and
  Darwin; off on Windows and under `-Dwithout_mt`.

### Fixed

- **A TLAB refill no longer raises `OutOfMemoryError` because some other
  thread is collecting.** After one miss, `tlab_refill` gave up whenever a
  collection was in flight — heap-wide, including the post-STW phase in
  which every other thread runs — so a transient miss there surfaced as an
  OOM with memory to spare. It now gives up only on the collecting thread
  itself; any other thread waits out the cycle and retries. Header layout
  with `GCRY_TLAB=1` only; found by running `stw_mt_property_test --tlab`
  beside the new idle collector (3 of 3 failed, now 5 of 5 pass).

- **A process that goes idle after a burst gives the burst back.** An emptied
  chunk past the warm budget is kept mapped for one cycle so a class running
  a chunk short does not unmap and re-map every collection — but the grace
  had no bound, and an idle process has no next cycle. A 200 MB burst
  followed by idle held 78.7 MB RSS against 6.3 MB after `GC.collect`. Grace
  is capped at one threshold of chunks now, which is all a cycle can reuse
  before the next major: 22.4 MB. Kemal `/json` steady state is unchanged
  (+0.31%, t=+0.43, n=10; grace never engages there). `make
  idle-rss-after-burst` gates it, with `GCRY_UNMAP_GRACE_UNBOUNDED=1` as the
  arm that must fail.

- **`GC.collect` could return having done nothing, one line wide.**
  `run_collection_body` set `@collecting = true` before it updated
  `@collector_pthread`, and `Heap#collect`'s re-entrancy guard reads that
  pair: in between, a thread that ran the *previous* cycle sees
  "collecting, and the owner is me" and returns silently — the defect the
  guard was rewritten to remove, in a window one statement wide. `make
  explicit-collect-barrier` caught it at 19 of 20 (CI run `35775763860`,
  1 failure in 25 runs; 0 in 20 local). The owner is stored first at all
  three sites that start a cycle, with a release fence before the flag
  and an acquire fence between the guard's two reads, and the return is
  counted as `collect_reentrant_skips` — which the gate now requires to
  be zero, since a silent return was the thing under test. `minor_collect`
  carries the same guard and got the same read-side ordering and counter.

- **`GCRY_RADIX_THP=1` never produced a huge page on the hosts that run
  it.** It only skipped `MADV_NOHUGEPAGE`, which is enough under THP
  `always` and does nothing under `madvise` — Ubuntu's default and the CI
  runners' — where a region must ask with `MADV_HUGEPAGE`: 0 kB of
  `AnonHugePages` with the knob on, as with it off. It requests them now
  (0 → 2048 kB), and the A/B it exists for is finally answered: on a
  78%-GC workload, pause per collection −1.40% (t=−1.30, noise) and RSS
  +3.27% (t=+12.45). The `MADV_NOHUGEPAGE` default costs the mark nothing
  measurable.

- **The chunk radix measured end to end, and what it follows.** On a
  graph-heavy GC-bound workload (`gc_phases --fanout=6 --shuffle`, 2.4 M
  edges) the default-on table cuts pause per collection **65%** and
  `ns_per_alloc` **59%** end to end, for +146 kB; on an edge-free one at
  the *same* 77% GC duty cycle it is worth −2%, inside the noise. The
  win follows chunk lookups during mark — edges times collections — not
  GC time, which bounds what an application sees and explains the
  smaller 2026-09-03 number.

- **The bitmap allocator's mechanism has its own numbers.** Its Kemal
  case was made in 2026-09; the two claims its phase gate names — sweep
  and per-allocation cost — never were. On the header build with the
  threshold pinned so only the mechanism differs: the streaming `occ &=
  mark` sweep is **~180x** cheaper than the header walk (7 236 → 41 µs
  per collection) and allocation **46.6%** cheaper end to end.

- **Parallel mark's per-object counters no longer false-share, and the
  scaling record is corrected.** `layout_precise_scans` /
  `layout_conservative_scans` were plain `+=` on shared `Heap` fields from
  every mark worker — slow, and lossy under concurrent writers. They are
  per worker now, one cache line each, summed on read (exact: 400 050
  serial, 400 051 at 4 workers), at no cost to the serial path (−1.0%,
  t=−0.66). That takes 2-worker mark from +34% to +20% against one worker
  and 4 from +39% to +28% on a graph-heavy workload — which also says
  parallel mark is **slower than serial at every count** on this tree,
  not −14.8% at 2 as recorded, and that the counters were a third of the
  regression rather than its ceiling. `GCRY_PARALLEL_MARK` stays
  experimental and its row now says to leave it at 1. What remains has a
  shape: swept by object size on the same graph, 2 workers go from +30.5%
  at 64 B to −27.7% at 512 B, and 4 workers reach **−50.5%** at 512 B —
  the cost is paid per object (every object crosses the shared stack's
  lock twice, with no prefetch), so parallel mark wins on large objects
  and loses on the small ones a Crystal heap is made of. The batch scan
  now prefetches the way the serial drain does (header and first payload
  line 16 objects ahead, `GCRY_PREFETCH` controls both): 512 B objects go
  from −28.9% to **−33.6%** at 2 workers and −46.4% to **−52.5%** at 4.
  A local-first drain was built, gated and measured alongside and did not
  pay (t≈0.9 at 64 B), so it is not in the tree.

- **Parallel-mark helpers no longer burn a core each between
  collections.** They spun on the epoch word for the life of the process:
  an idle program with `GCRY_PARALLEL_MARK=2/4/8` used 101% / 301% / 703%
  of a core. They spin briefly and then sleep in 200 µs steps: 4.3% /
  11.9% / 26.9%, with no measurable change to mark time where parallel
  mark pays (512 B objects, 2 and 4 workers, |t| < 1.5).

- **`make stw-ack-window` asks about the raw thread, not about the
  list.** Its shipped arm counted Crystal's threads before and after a
  ~400 ms window and blamed any difference on the signal handler. On
  2026-09-22 (run `35839647107`, one failure in 30+ runs) it read
  `acked=true … listed_delta=1` — but a handler that called into the
  runtime blocks on the `Thread.lock` the harness holds and can never
  acknowledge, which is what the red arm shows. Another thread had joined
  the list in the window. Both arms now count listed `Thread`s whose
  `@system_handle` is the raw thread's own: shipped 0, red arm 1.

- **The perf-summary collector no longer reports zero when it failed.**
  Downloads that errored — every one of them, on a host whose `/tmp` is a
  quota'd tmpfs — were swallowed and printed as `collected 0`; it now
  counts them, prints the first error and exits non-zero, and stages under
  `~/.cache` instead. And the macOS perf job uploads its own summary
  (`bench/log/_run/`) rather than the checked-in `bench/log/macos/`
  history, whose stale laptop files the collector was judging first:
  4 collected → 26. What the 16 at the current protocol say: Darwin RSS
  and pause spreads are as tight as Linux's, throughput's is ~4x and does
  not narrow with longer wrk runs, so the Darwin baseline will gate the
  first two and report the third — which a baseline can now say:
  `perf_compare.py --record --warn-only METRIC` marks a metric as
  reporting-only in that baseline, beside the global `pct_root`. And a
  recording refuses untagged summaries beside tagged ones (the collector's
  26 were 10 at 5 s × 3 runs plus 16 at 10 s × 7, which `record` accepted
  as one protocol); the collector keeps the newest run's protocol and
  counts what it dropped.

- **Windows CI no longer fails after the specs pass.** `crystal spec`
  deletes the image it just ran, and on the Windows runners a handle on it
  can outlive the process: the step failed as "you've found a bug in the
  Crystal compiler" with `0 failures` already printed — on 2026-09-10, and
  again on 2026-09-23 after per-invocation cache directories had made the
  path private, so sharing it was never the cause. `ci/windows.ps1` builds
  the specs under a name of their own and runs the binary, which leaves
  nothing to delete — through a generated entry of `require`s, as
  `crystal spec` does. Its first version passed the files to `crystal
  build` as main sources, and a `{% skip_file %}` in one main source skips
  every one after it: `spec/segv_report_spec.cr` (unix-only) took the 57
  examples sorting after it with it, and the run was green (281 → 224).
  Counts are back to 281/303 + 25.

### Changed

- **`GCRY_PAGE_DONTNEED=1` and `GCRY_MOSTLY_EMPTY=1` say when they do
  nothing.** Both free-page release paths stand down on every
  bitmap-allocated chunk, and the bitmap allocator is the only one on the
  headerless default and the default on `-Dgcry_block_headers` — so both
  knobs were silently inert for nearly everyone who set them (0 B released
  on either default, measured). They now print one line naming the way to
  the freelist they need, as `GCRY_BITMAP_ALLOC=0`, `GCRY_NURSERY` and
  `GCRY_TLAB=1` already do; `make ignored-knob-warnings` covers them. Not
  ported to bitmap chunks, on the same measurement: the default reaches
  14.0 MB on a sparse heap where the releasing freelist arm ends at 74.0 MB.

- **The Darwin perf job gates.** `bench/baseline/perf_smoke_macos.json`,
  recorded from 21 green macOS runs, gates post-GC RSS (≤ 1.28x Boehm) and
  pause p50 (≤ 0.68 ms); `/json` throughput is warn-only in that baseline
  (sd 18 pp, against Linux's 4.1) with a `MIN_PCT=45` collapse floor. The
  job also runs the two-runs-in-a-row check, and
  `fetch_prev_perf_summary.sh` takes `PERF_PREV_BASELINE` so it reads the
  layout from the platform's own baseline, and picks the newest summary by
  its `timestamp` rather than extraction mtime.

- **`make soak` and `make soak-smoke` construct their red direction per
  run.** The soak's one gate is an absolute RSS ceiling (+4096 kB over
  the warm-up plateau) that had only ever been seen to hold. `soak
  --leak-kb-per-s=N` retains N kB/s of strings in an array it never
  shifts, by wall time rather than per timer tick — Darwin's timer
  delivered ~60 of 100 ticks and its RSS follows the heap at ~0.65×, which
  put the first version at +4048 kB against a +4096 ceiling; both recipes
  run ten seconds of it at 2 MB/s (+26 MB on Linux) under `!` and require
  the telemetry to say `RSS grew`, so the arm must fail on the ceiling and
  not on anything else. Census
  **100 / 75 / 25 → 100 / 77 / 23.**

- **`make finalizer-complex` asserts what a finalizer runs on.** Its
  seven phases asserted a callback *ran*; none asserted what it ran on,
  and that is the half with a history — the Boehm rule in
  `enqueue_unreachable_finalizers` exists because `Socket#finalize` once
  ran on freed memory. A new phase 0 asks `heap.live?(ptr)` inside the
  callback. `Heap#finalizer_resurrect = false`
  (`GCRY_FINALIZER_NO_RESURRECT=1`, research only) restores the defect,
  and the recipe's `--broken` arm requires the callback to find its
  object swept. With the resurrection dropped, phase 0 fails and phases
  1–7 all stay green on a freed block. Census **→ 100 / 78 / 22.**

- **`make compiler-gc-contract` runs once with layouts off and must
  fail.** `GCRY_DISABLE_LAYOUT=1` registers no layouts, so the contract's
  layout-registration check is the one of twelve the collector can be
  made to fail, and the recipe requires it. With that the census's list
  of gates owed an arm is empty: `oom-test` and `thread-storm` are
  crash-only smokes beside gates that already own their defect
  (`oom-no-hang`, `thread-churn-uaf`), and are recorded as such rather
  than given an arm that would test the arm. Census **→ 100 / 79 / 21.**

- **A sampler for the TLAB+nursery arm.** The arm that crashed twice on
  CI ran as a no-op for a month behind the headerless default; eleven
  real runs since are all quiet, and at its 2-in-206 rate that is a 90%
  chance of silence with the defect still there — 95% confidence of
  absence needs ~308. `make tlab-nursery-sample` takes 100 samples at
  1.9 s each with fresh seeds and the CI arm's diagnostics, requires TLAB
  hits in every one, and keeps the logs of any crash: a job on x86_64 and
  30 samples on Darwin per CI run, `continue-on-error` like the thread
  sampler.

- **And it closed the item the same day.** Seven x86_64 batches of 100
  and six Darwin batches of 30 — 880 sampler runs, 0 crashed, 0 without
  TLAB hits — plus the 11 CI-arm runs make **891** quiet samples of an
  arm that crashed twice in ~206. P(all quiet | the defect is still
  there) ≈ 0.0002 against the ~308 the item set for 95%.

- **The benchmark regression gate is closed on its own numbers.**
  `PERF_GATE_BASELINE=1` has compared every `perf smoke` run against the
  48-run headerless baseline since 2026-09-13, with gates tighter than
  the fixed floors on all three metrics; **59 jobs since, 0 failures**,
  against 0.065 false reds expected at the design rate. Confirmation
  across runs (two consecutive samples outside 2 sd) needs state CI does
  not keep and is a separate item; Darwin still needs `wrk` and a
  baseline of its own.

- **Darwin gets the perf step, and the comparator stops trusting a
  baseline from another runner.** A cross-runner baseline printed a NOTE
  and gated anyway — the same mistake the file already refuses across a
  layout flip, and a macOS run would have been measured against
  `ubuntu-latest`'s spread. It is `STALE: … Reporting only` now. A
  baseline path that does not exist reports instead of raising a
  traceback, which is what the first Darwin run would have hit, and
  `perf_smoke.sh` picks its baseline per platform. The new `perf smoke
  (darwin)` job runs the same script report-only on the script's default
  floors and uploads its summary; no Darwin threshold is invented before
  it is measured. Three fixtures added to the comparator's selftest.

- **A noise ratio of zero from one sample is a blind instrument.**
  `perf_smoke.sh` discards min and max, so at `BENCH_RUNS=3` a single
  sample survives and `noise_ratio` — its IQR over itself — printed 0.0
  for a triple spanning 54 839 to 109 267 req/s. It reports `null` with
  the surviving count and the full spread now. The Darwin job takes
  seven samples, and the difference is not cosmetic: the same host read
  `/json` at **65.6%** of Boehm on one sample and **111.6%** on five.

- **`bench/collect_perf_summaries.sh`**: the baseline recording's missing
  half. Assembling N green summaries from CI artifacts was a hand job —
  the 48-run Linux baseline was downloaded run by run — and a hand job is
  one nobody repeats, which is how a baseline outlives two default flips.
  `ARTIFACT` and `RUNNER` select the job and whose numbers inside it,
  mismatched summaries are skipped and counted, and it says when it has
  fewer than twenty. `bench/fetch_prev_perf_summary.sh` takes the same
  two variables instead of hardcoding the Linux job.

- **The aarch64 CI step times its own commands.** That job grew from a
  443 s max to 705 s against a 1200 s bound in three days, and all of it
  is inside a single step — the finest granularity GitHub reports — so
  unlike the x86_64 job's growth it could not be diffed. Each of the
  step's 28 commands is timed now, with an `EXIT` trap printing the
  slowest, so a run that *fails* still reports the profile of what ran
  before it.

- **A perf summary records how it was sampled.** It carried `runner` and
  `layout` — the two mismatches the comparator refuses to gate across —
  and nothing about the sampling, so the nine Darwin samples taken either
  side of a `WRK_DURATION` change cannot be told apart and a recording
  from them would average two distributions. `wrk_duration_s`,
  `wrk_connections` and `bench_runs` are in the summary and in a
  recorded baseline's provenance now; a run sampled differently reports
  instead of gating, and a recording from mixed sampling is refused
  outright. Fixtures for both, each verified to redden the selftest when
  the rule is removed.

- **The `Thread` UAF sampler buys give-up windows, not runs.** The
  statement it makes is "0 deaths with a holder across N windows", and
  the runners buy N at rates that differ a hundredfold: six churn
  children on x86_64 build 120, while the aarch64 job's ten built 2–5 in
  each of its last four batches. It now runs extra churn children until
  the batch has `THREAD_UAF_MIN_WINDOWS` (100) or
  `THREAD_UAF_CHURN_BUDGET_S` (300 s) is gone, and the headline names
  which bound stopped it. Measured alongside: the amplified reproducer
  `GCRY_THREAD_UNSTAGE_ON_DEATH=1` is **0 of 40** bare and poisoned on
  this tree — its crashes were the large-object defect fixed on
  2026-09-13, not the thread family — while `make thread-churn-uaf
  --control` still reproduces 6–7 of 8.

- **`make thread-census-names` constructs the parked task its location
  arms read.** Two arms ask where a task is — the `parked in syscall N,
  returning to` line and the `returns through:` walk — and neither
  planted one: the probe spins on purpose, so the subject was whichever
  peer happened to be in a syscall, in practice Crystal's `SYSMON`. On
  2026-09-22 (run `35707265944`) neither was, and a green tree took a red
  job; locally the arm is 20 of 20, so the rate is the runner's. The
  probe now sleeps in 20 ms `nanosleep` calls under `--parked`, which
  both arms use; every other arm is untouched.

- **A gate that fails must name the range it asserts about.** `make
  tls-roots` went red once in 90 Windows jobs (run `35709742955`) and its
  output could say only that the slot is outside the *stack* — which it
  always is; that is the gate's premise. It now prints
  `Platform.tls_root_range`, the range gcry pushed for the TLS block, and
  which side the slot fell off by how many bytes, so the next red tells
  an anchor that moved from a window `VirtualQuery`'s clip cut short.
  `make thread-census-symbolize` took the `--parked` probe as well — it
  reads the same syscall frames as the two location arms and went red for
  want of one. And `bench/thread_churn_uaf.cr` keeps the whole `gcry:`
  report block from a sighting rather than its first line: the 2026-09-22
  out-of-span fault arrived as one address, with the region report that
  names the mapping dropped on the floor.

## [0.26.3] - 2026-09-21

### Fixed

- **Linux's stop-the-world capture table grows too, and the fixed 64
  cost about twentyfold on the pause.** A thread past the 64th slot had
  no recorded SP; since a Crystal thread's main fiber's stack *is* its OS
  stack, `fiber_stack_sp_scan_low` then found no SP for that stack and
  the scan window fell back to the guard page — the whole 8 MiB mapping
  instead of the frames above the SP, every collection. Measured at 98
  threads over 8 collections: **264 guard-page fallbacks and ~535 ms per
  collection** with the table pinned at 64, against **8 and ~29 ms** with
  it grown (one fallback per collection is the collector's own fiber).
  Roots were never lost there — the registers arrive in a signal
  `ucontext` on the thread's own stack and the unclamped scan walks them,
  which the gate's `held` arm checks — so this is pause time and scan
  work, not soundness.
  Linux now uses the same growable table as Darwin and Windows
  (`Gcry::StwSlots`), sized from the thread count at collection entry —
  under `Thread.lock`, before the first suspend signal, never freeing its
  predecessor — so the three copies of that quartet are one. The shared
  table gained what Linux needed: a **CAS claim**, because this
  platform's suspend handler keeps a fallback claim and those run on
  every thread at once (a plain store gave two threads one slot, which
  the stop epoch turned into a hang); a per-slot **served epoch** and
  **acknowledgement byte**, which is where they already lived, because
  the handler must not touch Crystal at all; and a register **count**
  rather than a flag, because `with_thread_gregs` hands the raw row and
  its length to `StackMaps`, which resolves DWARF register locations by
  index. `GCRY_STW_FIXED_SLOTS=1` works on Linux now and is the red arm
  for `make stw-capture-coverage` (which no longer skips here) and for
  the new `make stw-slot-precision`.

- **The thread census counted gcry's own mark helpers as unscanned
  mutators.** `parallel_mark.cr` creates its helpers with raw
  `pthread_create` on purpose — a `Crystal::Thread` would freeze in
  `stop_world` — so they are outside Crystal's list **by construction**,
  and `GCRY_THREAD_CENSUS=1` reported each of them as a thread running
  through the stopped world unscanned. With nothing else in the process,
  `GCRY_PARALLEL_MARK=4` reported `gap=3`. They touch mark state and
  block headers only, no `Fiber` and no managed allocation, so they can
  hold no mutator reference. They are named `gcry-mark` now and
  subtracted; `thread_census_unexplained` is the number
  `thread_census_gaps` was being read to mean, and it is the one that
  replaced it on `/gc-stats`.

- **`make knob-doc-check` was locale-dependent and reddened a green
  tree.** `sort` orders by collation and `comm` compares bytes; glibc's
  UTF-8 collation ignores `_`, so `sort` emits
  `GCRY_PRECISE_FIBER_LEAF` before `GCRY_PRECISE_FIBERS` while `comm`
  wants the reverse (`S` 0x53 < `_` 0x5F). `comm` exits 1 with "input is
  not in sorted order" and `set -e` fails the gate — on an
  `en_US.UTF-8` host, while passing on CI. The harmless direction; the
  same mismatch can walk `comm` past a genuinely missing knob. Pinned to
  `LC_ALL=C`.

### Changed

- **`make pause-budget`, `make rss-leak` and `make scrub-midswap` construct
  their red direction per run.** The pause gate's 200 ms p99 ceiling had
  never been seen to fire against a 22 ms tip: `GCRY_STW_TEST_STALL_MS=250`
  — the watchdog's own stall, inside the stop — puts every major at
  ~267 ms and the recipe requires phase 1 to fail. The leak gate's growth
  check has no collector knob that leaks honestly, so the harness does:
  `rss_leak --leaking` roots one object in five per cycle (+38% against
  the 10% ceiling, +40% at CI's 15%) and must exit non-zero; the recipe
  takes `RSS_LIMIT` / `RSS_RSS_LIMIT` so CI's parameters go through it.
  `scrub-midswap` already forked a `--mode=stale-off` child and required
  it to corrupt; the census's fork detector wanted a `GCRY_*` string, and
  `--mode=` is now the same criterion as `--child`. Census
  **100 / 71 / 29 → 100 / 74 / 26**, and the 26 are classified: 11
  defect-finders whose red is a defect, 2 compile-only typechecks, 4
  research targets, 9 gates still owed an arm. `make trace-smoke` then
  took one: `--unsampled` traces with `alloc_sample: 0` — documented as
  off — and the recipe requires the missing alloc/free to fail it, which
  also pins what `GCRY_TRACE_ALLOC_SAMPLE=0` means. **→ 100 / 75 / 25.**

- **`make nested-spawn-uaf` is a gate, on the stock compiler.** The
  original fiber-creation use-after-free repro (2026-08-15, three CI
  platforms) ran in no CI step; its header asked to be wired as the
  regression test once the defect was fixed, and v0.20.0 fixed it.
  Measured before wiring, at the 2026-08-17 settings on Crystal 1.21.0:
  shipped 0/24, and the fix's own disable `GCRY_DEAD_STACK_ROOTS=0`
  also 0/24 where it was 10/24 then — the v0.20.0 announcement's *0/23
  under 1.21.0; every reproduction needed 1.22.0-dev* seen from the other
  side. Of six candidate co-roots only the v0.19.0 register scan matters:
  `GCRY_DEAD_STACK_ROOTS=0 GCRY_DISABLE_GREG_ROOTS=1` crashes 7/12, the
  same `Deque(Fiber::Stack)` buffer freed under a live holder. The harness
  is parent/child now: six shipped children under poison + tag + census
  must survive and each must have walked a dying stack; the churn with
  both roots off must crash within max(4·RUNS, 8) tries. `--child` keeps
  every research knob. ~15 s, x86_64 CI beside `dead-stack-root`; Darwin
  and aarch64 wait on a measured rate. Census **100 / 70 / 30 → 100 /
  71 / 29**.

- **`make occupied-release` constructs its red direction per run, and
  gates.** The harness tried to *reach* the window that released a chunk
  with a live block in it (CI `34787711949`) with thread churn and a held
  flush, reached it 0 of 48 on a developer host, and the recipe ran both
  arms under `-` — the refusal it protects had no gate. The window has a
  single-thread shape: the settle bumps the pool version inside the stop,
  the lazy sweep leaves `@chunks` intact after `start_world`, and a chunk
  empty since last cycle is queued without a bump. `Heap#post_stw_hook`
  (research only, library heaps) puts a mutator on the collector's own
  thread at `:after_start_world` and `:before_flush`; one allocation at
  the first builds the pool and takes a block, exhausting that chunk at
  the second pops a queued chunk through the index it still has. Both
  arms require exactly one refusal and no `map_chunk` in the window;
  shipped writes the block and requires it to survive a rooted collect,
  `--broken` restores the pre-fix release and requires the chunk gone.
  Dropping the refusal, the knob, or the hook call each reddens it.
  `GCRY_EMPTY_FLUSH_DELAY_MS` and `Heap#empty_flush_delay_ms` are gone —
  no remaining user. In CI on x86_64 and Darwin, ~2 s. Census
  **100 / 69 / 31 → 100 / 70 / 30.**

- **A fault outside gcry's span now names the mapping it happened in.**
  The crash report's three out-of-span readings say what the address is
  *not* — not a gcry allocation, and whether a swept object is excluded —
  which was the whole of a 2026-09-19 sighting from the thread-churn
  gate: `SIGSEGV at 0x55816aff0`, one child in 24 on a CI runner, and
  nothing to compare with the next one. The report asks the kernel now:
  the mapping's range, its permissions, its size, how far below its top
  the address sits (the signature that identified a stack this collector
  could name as nothing on 2026-08-27) and its pathname when it has one —
  or "no mapping holds that address", because a stale pointer into a live
  mapping and a wild pointer are different defects. One extra line from
  `Platform.each_map_region`, allocation-free, on its own buffer because
  `RawOut::LIMIT` is 480 bytes and the readings already run close to it.
  `make segv-region-report` checks the numbers rather than the words and
  fails in all three arms without it.

- **The thread census names the threads outside Crystal's list.** It
  could say how many since 2026-08-17 and never which, and a count is
  not actionable: `test (aarch64 native)` reports a difference of
  exactly one on **every** collection of `scheduler_roots --control` —
  an arm that builds no execution context and starts no worker — in 40
  of 40 green runs, while the same binary on x86_64 reports none. That
  line reads as the open unscanned-mutator defect and has been
  unattributable for a month. On a gap the census now walks
  `/proc/self/task` and prints each task's kernel thread id and `comm`
  (raw `getdents64` plus the `comm` read into stack buffers — no
  allocation, callable inside the pause), with how many are gcry's own
  helpers and how many are left. Linux only; Darwin and Windows answer
  "could not look" rather than walking nothing and calling it empty.
  `GCRY_THREAD_CENSUS_NAMES=0` is the twin that restores the count-only
  census, and `make thread-census-names` runs both directions on five
  arms — including a planted raw pthread that must be named and must
  stay unexplained. Building it caught the gate twice: the plant arm
  passed with the `/proc` walk stubbed out until `thread_census_unwalked`
  existed, and the output assertion was matching the harness's own
  banner instead of the census line.
  The first CI run carrying it answered the question: on
  `test (aarch64 native)`, in a process that plants nothing, the tasks
  are `7009:thread_census_n 7010:SYSMON 7011:thread_census_n` — main,
  the monitor, and a third wearing the process's own `comm`, which is
  what a raw pthread inherits. Present at collection 0, on every binary,
  and not gcry's. Named, not yet identified.
  That run also showed the gate's own control arm to be wrong: it
  asserted `gaps == 0`, i.e. that a host has no thread outside Crystal's
  list, which is an absolute where the property belongs to the host.
  Every arm now measures a delta in one process and
  `attributed = gap_max - unexplained_max`, which carries the host's
  baseline in both terms — against a simulated pre-existing unlisted
  thread, `--mark` subtracts exactly gcry's three helpers and leaves the
  host's one standing.
  A helper naming itself was a third defect the runner caught: for one
  collection the newest helper still wore the `comm` it inherited from
  its creator and was counted as a mutator gcry had never heard of
  (`2 are gcry's own … leaving 2 unexplained`, then `3 … leaving 1`).
  `pthread_setname_np` takes a handle, so the naming moved to the
  creating side — the same placement, for the same reason, as
  `thread_staging.cr`'s record — which closes the window instead of
  narrowing it: the creator is the collector and cannot be inside
  `ensure_mark_pthreads` and inside a stop at once.
  And a fourth, also only visible on a gapping host: the census printed
  the first five gaps and then nothing, so on aarch64 the budget went to
  the host's own thread and a planted one was never printed even though
  the counters saw it. It now prints the first few and after that only
  when the gap **changes**, to a ceiling of 32 — a repeat is noise, a
  different gap is news. Three of the four were in the gate rather than
  the instrument; the counters were right in every one of those runs.

- **And it places them, not only names them.** A `comm` says a raw
  pthread is there; on aarch64 the extra task wears the process's own
  name, which is what a raw pthread inherits, so the name is where that
  trail ends. The census now also reports the syscall each task is
  parked in, the user pc it returns to, and the mapping that holds that
  pc — `task 373993:SYSMON is parked in syscall 230, returning to
  0x728a4a4ac802 in /usr/lib/x86_64-linux-gnu/libc.so.6+0x84802`. Both
  halves already existed: `linux_proc_sp.cr` has read
  `/proc/self/task/<tid>/syscall` since the parked-fiber audit and its
  parser was stepping *over* the pc to reach the sp, and
  `each_map_region` has named mappings since the SEGV region report.
  Allocation-free, and only when the gap is a shape the process has not
  reported before, to a ceiling of 4.
  The collector excludes itself: reading its own syscall file happens
  *inside* `read`, so it reported itself as `parked in syscall 0` — the
  report describing its own question.
  Three more gate arms (a task must land in a **named** mapping, the
  collector must identify itself, the twin must place nothing) and four
  breaks, all red. A fifth defect fell out of break-testing: the arms
  compared `gap_max` across the two phases, and a maximum is set by
  anything that was *ever* there — a thread alive during the baseline
  and gone afterwards leaves both maxima equal and the plant reads as
  having changed nothing (`did not widen the gap (1 -> 1)`, on a change
  that touched only a reporting path). `thread_census_gap_now` /
  `_unexplained_now`, the last sample rather than the largest, replaced
  the maxima in every assertion.

- **And it walks one frame further, because the pc named the sleep and
  not the sleeper.** On aarch64 the unlisted task and `SYSMON` report
  the *same* libc offset in the same syscall (`clock_nanosleep`, 115
  there and 230 on x86_64 — the reader agreeing with itself across two
  syscall tables), which says the task sleeps and nothing about who
  asked it to. The caller is one frame up. The census now scans the
  words at or above a parked thread's SP, keeps the ones that land in an
  executable mapping, and names them: `returns through:
  libc.so.6+0xa030c … bin/thread_census_names+0x1e2aeb`, and that last
  offset feeds `addr2line` straight to `crystal/system/unix/pthread.cr:111`.
  Conservative and reported as such — stale words count, so it is the
  set of frames a thread returns through and not a backtrace.
  **The read cannot fault.** This collector has been killed once by a
  plain load on memory a dying thread owned (`pthread_kill(id, 0)` on a
  freed `struct pthread`, 3 of 3), so the stack is read with
  `process_vm_readv` against our own pid, which answers `EFAULT` instead
  of signalling — safe by construction rather than by timing.
  A sixth defect fixed on the way: the offsets were measured from the
  mapping the pc happened to be in, and a PIE's executable segment does
  not start at the load base, so nothing `addr2line` could resolve. The
  same anchor reads +0xbe20 from the text segment and +0xace20 from the
  load base. `pc_mapping` now uses the lowest mapping of the same
  pathname, and the harness checks it against its own independent parse
  of `/proc/self/maps`.
  `make thread-census-symbolize` closes the loop: it resolves the
  offsets the census printed and fails when `addr2line` is absent
  rather than skipping. On this runner it reads
  `0x1e69ab -> sleep crystal/system/unix/pthread.cr:111`; on the aarch64
  job it resolves the callers of the task that host has outside
  Crystal's list, whose frames are **different from `SYSMON`'s** — so
  whatever it is, it is not a second monitor.

- **And the thread aarch64 had been reporting for a month is gcry's own
  STW watchdog.** Symbolizing its callers on `test (aarch64 native)`
  resolved `0x1da884 -> watch_loop src/gcry/stw_watchdog.cr:223`, beside
  `SYSMON`'s `sleep` at a different offset. `stw_watchdog.cr` says it in
  its own first lines — "a raw `Gcry::OS.pthread_create` thread, not a
  `Crystal::Thread`" — so it is outside Crystal's list by construction,
  exactly like the parallel-mark helpers, and was counted as an
  unscanned mutator for the same reason. The arch asymmetry is in the
  workflow, not the collector: the aarch64 job sets
  `GCRY_STW_WATCHDOG_MS` as step-level env for its whole step, so every
  binary there has a watchdog, while x86_64 sets it on eight individual
  steps and none of the census ones.
  The watchdog is named `gcry-watch` now and the matcher takes any
  `gcry-` prefix, so the next raw thread gcry adds is covered by naming
  it rather than by editing the census. The test probe was renamed
  `census-probe`: a stand-in for a mutator must not wear the prefix that
  means "mine". Two arms run under `GCRY_STW_WATCHDOG_MS=10000` and
  require the credit to be exactly one with the knob and zero without.
  **What this retires**: the `thread_census_gaps` figure quoted for that
  runner — one thread outside Crystal's list on every collection of
  every binary, 40 of 40 runs — was measuring gcry's watchdog, not the
  birth window it was read as. `thread_census_unexplained` now reads 0
  there.
  And the verdict line was contradicting the one below it: it compared
  `staged` against the **raw** gap, so it printed "at least one is
  unrecorded" directly above "1 is gcry's own, leaving 0 unexplained".
  A gap made entirely of gcry's raw threads needs no staging record to
  be accounted for, so both `thread_census_staged_covered` and the
  wording run against the unexplained gap now — "every one of them is
  gcry's own, so none is unrecorded", and with a real unlisted mutator
  beside the watchdog, "1 of them is not gcry's and it has staged 0,
  fewer — at least one is unrecorded".

- **The `Thread` use-after-free sampler was counting the wrong
  denominator.** Over the 299 sampler jobs of 2026-08-25 → 2026-09-20 —
  2 990 harness runs — it reported 0 crashes, 0 dying-`Thread` reports
  and **11 965 "precondition" sightings**, which reads as overwhelming
  evidence that the birth root holds. The audit prints *two*
  preconditions under one label and only one of them is the window this
  defect needs: `the wait caught it` is the safe path, `the wait GAVE UP
  — the world stopped with it unpublished` is the defect's. Split, it is
  **11 960 caught and 5 gave up** — so the measurement is 0 deaths in 5
  windows, not 0 in 11 965, and the summary line was printing the sum.
  All five are 2026-08-25 to 2026-09-07 with none since, so the sampler
  as configured can no longer observe this defect at all.
  `make thread-uaf-sample` counts and reports the two apart, says so
  when a batch built no window ("a silent batch is an absence of the
  window and not an absence of the defect"), and keeps a run's logs for
  a death **or** a give-up rather than for any precondition. The
  sampler itself is not rotted: pointed at `bin/thread_storm`, where a
  dying `Thread` is routine, one run reports 17 with their details.
  And a report turned out to be a **trigger, not a verdict** — the
  second miscount and the worse one. The audit fires on any watched
  block the mark did not reach, so on a workload where threads *exit* it
  fires constantly: six `thread_churn_uaf --child` runs give **5 712
  dying-`Thread` reports with 0 holders** — none on Crystal's list, none
  linked from a live list node, none in a suspended thread's registers,
  none offered by the stack scan. A `Thread` object dying after its
  thread exits is the collector working. The counter sums reports and
  `of which N with a holder` apart now, and keeps a run's logs for a
  holder or a give-up plus one death-only exemplar, at most four in all.
  With that in place the sampler gained the churn arm, which also builds
  the give-up window it was not added for: **16 give-ups in 3 runs**
  against 5 in 2 990. Its headline is "0 of 2 856 deaths, none with a
  holder, across 16 windows" instead of "0 of 0".

- **The x86_64 CI job had doubled in twelve days and was walking into
  its cap again.** Measured over the 199 jobs of the last 200 runs:
  15.1–16.1 min on 2026-09-08 against **32.0–33.1 min on 2026-09-20**,
  p90 31.6, cap 45 — about +1.4 min a day, which reaches the cap in
  another nine. Diffed step by step, the growth is **purely additive**:
  31 steps that did not exist then, worth 17.1 min, and **not one
  existing step any slower**. That is the shape that walks into a cap
  unnoticed, because every addition is cheap on its own and the sum is
  invisible from any one pull request — and this repo has already lost
  green runs to this exact cap ("29m44s passing, then 30m05s killed on
  the last step with 17 s of work left").
  The four heaviest **sampling** gates — `thread-churn-uaf`,
  `find-block-race`, `stw-epoch` + `stw-ack-window`, `chunk-list-drift`
  — moved to a new `sampling gates (x86_64)` job. A real category, not
  an arbitrary cut: each drives a rare window many times, so its cost is
  the sample size rather than the assertion. `test (x86_64)` goes 33.0 →
  ~20.7 min and the new job is ~13.5, for the same runner minutes.
  Measured over nine green runs on 2026-09-22, two days after the split:
  **p50 22.2 min, max 22.8, against the 45-minute cap** — the estimate
  holds and the job has 49% of its budget left.
  Raising the cap was the other option and is the wrong one: it buys
  days, and the property the cap exists for — a hang failing in minutes
  instead of at GitHub's 6 h ceiling — weakens every time it moves.
  Moving it surfaced a latent bug in one of the moved gates, on the
  first run: `chunk_list_drift`'s reporter read `buckets[-2]` to print
  the last bucket's slope, and the **pre-fix arm is expected to crash**
  — that crash is its evidence. When it went down after the *first*
  bucket the reporter died with `Index out of bounds` and took a
  working gate red with it. The empty case was already handled and the
  one-bucket case was not. Guarded, and it is the only `[-2]` of that
  shape in `bench/`. Not reproducible here — the pre-fix child survives
  every rounds setting tried on this host, up to 6 000 — so the fix is
  a bounds check on the exact expression the CI stack trace named,
  with the passing path re-verified.

- **`make auto-layouts`: `GCRY_DISABLE_AUTO_LAYOUTS` was an orphan.**
  `src/` reads it and `ivar-layout-roots` already runs under
  `GCRY_AUTO_LAYOUTS=1`, which looks like coverage and is not: those
  arms also call `register_layout` on their probes, so the disable
  leaves them registered either way, and a survival assertion would not
  discriminate — the conservative body scan reaches the same words. The
  orphan-knob census found it in no spec, recipe or CI step. Three child
  arms, counters not objects: builtins **51** and a type this file
  declares unregistered; `GCRY_AUTO_LAYOUTS=1` **159** and that type
  registered; both knobs put both back. Dropping the disable reddens it
  (159, still registered). x86_64, aarch64, Darwin.

- **`make scrub-fibers`: `GCRY_DISABLE_SCRUB_FIBERS` was an orphan.**
  `src/` reads it and `samples/sound_profile.cr` already asserts the
  flag — default off, `GCRY_SCRUB_FIBERS=1` overrides `GCRY_SOUND` —
  which looks like coverage and is not: disable agrees with the default,
  so the sample never asks whether it still turns the opt-in back off,
  and the spec sets the property without reading either env var. The
  orphan-knob census found it in no spec, recipe or CI step. Three child
  arms, counters not objects: default **false / 0**; `GCRY_SCRUB_FIBERS=1`
  **true / 1**; both knobs put both back. Dropping the disable reddens it
  (true, runs=1). x86_64, aarch64, Darwin.

- **`make scheduler-roots` constructs its red direction per run.** The
  gate already asserted pin *deltas* derived from `instance_vars`, on
  all three CI platforms, and its ability to fail lived only in a
  ROADMAP sentence ("stub → 7 of 16 named"). `GCRY_DISABLE_EC_PINS=1`
  skips the derived walk and leaves Thread-level slots running. Shipped
  delta **53** against 45 expected; with the knob **6–8** against 45,
  Isolated **2** against 15. Parked fibers still live **16/16** either
  way — a survival assertion would have stayed green. Census
  **99 / 34 / 65 → 99 / 35 / 64.** x86_64, aarch64, Darwin.

- **`make ivar-layout-roots` constructs its red direction per run.** The
  gate already ran on all three CI platforms and asserted that a
  module-typed / Proc ivar is covered — by a precise offset, or by
  falling back to a conservative body scan. Its ability to fail lived
  only in a ROADMAP sentence ("`has_inner_pointers?` dropped").
  `GCRY_LAYOUT_DROP_UNCLASSIFIED=1` skips that fallback and keeps the
  precise is_ptr offsets, so `@payload` / `@job` at byte 16 is simply
  never scanned. Shipped module/proc: `precise?=false`, leaf live;
  with the knob: `precise?=true scan=[8]`, leaf swept. `--control`
  still emits `[8, 16]` and survives either way. Census
  **99 / 35 / 64 → 99 / 36 / 63.** x86_64, aarch64, Darwin.

- **The gate-arm census missed `BoundedChild.run`, which is how this
  repo forks.** The detector looked for `Process.run`. Harnesses fork
  through `BoundedChild.run` (a `Process.new` with a deadline) and
  through `Process.new` directly, so twenty-one gates that already
  construct a red arm every run were counted "by hand, once" —
  `stack-bounds-growth`, `explicit-collect-barrier`, `stw-epoch`,
  `thread-staging`, `darwin-static-root-init` among them. Type-check
  targets stay by-hand: they compile those files and never run them.
  `thread-startup-cost` moved with the `--child` heuristic and is a
  probe. Census **99 / 36 / 63 → 99 / 57 / 42.** Nothing in a recipe,
  a harness, or CI was added. The leftover 42 is mostly property
  tests, fuzz, soak, and type-check.

- **`make mark-clear-index` constructs its red direction per run.** The
  gate already ran on x86_64 CI and asserted that the shipped clear
  leaves no indexed chunk holding a mark, with `--control` restoring
  the list walk in-process. The census excludes `--control` on purpose
  (a control has to pass), so the ability to fail lived only in a
  ROADMAP sentence. The parent now forks `--child` under
  `GCRY_MARK_CLEAR_LIST=1` and `GCRY_SWEEP_MUTATOR_LATCH=0` — the same
  pair `thread-churn-uaf --control` already used. Shipped: residue 0
  of 240. Broken: **6/6** children with residue (one child: residue=4,
  offlist=56 at collection 34). Dropping the knobs reddens it (6/6
  clean). Census **99 / 57 / 42 → 99 / 58 / 41.** x86_64.

- **`make segv-region-report` constructs its red direction per run.** The
  gate already ran on x86_64 CI and asserted that a fault outside the
  span names its mapping — range, permissions, size, distance below the
  top, pathname — with a wild address reported as such rather than
  attributed to the nearest region. Its ability to fail lived only in a
  hand edit of `report_faulting_region` ("drop the report line and all
  three fail"). `GCRY_DISABLE_REGION_REPORT=1` skips that line, so the
  same three faults print "never a gcry allocation" and nothing about
  the mapping, which is the 2026-09-19 churn sighting. The parent forks
  those children under the knob and requires each *not* to name the
  mapping. Dropping the knob reddens the gate. Census
  **99 / 58 / 41 → 99 / 59 / 40.** Linux.

- **`make holders-find` constructs its red direction per run.** The
  gate already ran on x86_64 CI and asserted that a planted word in a
  live marked object's ivar is found, and that a masked address is
  not invented. Its ability to fail lived only in a hand edit of
  `count_heap_holders`. `GCRY_DISABLE_HOLDERS_FIND=1` skips that walk,
  so the three planted holders come back empty — which is what a
  search that has gone silent looks like, and why a contradictory
  "holders — none" on 2026-09-12 could not be told from a clean heap.
  `--disabled` requires each planted target at 0. Dropping the knob
  reddens the gate. Census **99 / 59 / 40 → 99 / 60 / 39.** x86_64.

- **`make parallel-mark-process` constructs its red direction per run.**
  The gate already ran on x86_64 CI and asserted that four configured
  workers actually steal — `parallel_mark_stolen` rises, which is what
  separates "workers were set" from "workers marked". Its ability to
  fail lived only in a hand edit of that counter. `GCRY_DISABLE_PARALLEL_MARK=1`
  pins workers at 1 even if the harness assigns 4, so stolen stays 0 —
  configured, not marking. `--disabled` requires that. Dropping the
  knob reddens the gate. Census **99 / 60 / 39 → 99 / 61 / 38.** x86_64.

- **`make pool-refill-cost` constructs its red direction per run.** The
  gate already ran on x86_64 CI and asserted that refill indexing stays
  at one walk per active class slot per collection (2.0 on this
  workload). Its ability to fail lived only in a hand edit of that
  floor. `GCRY_DISABLE_POOL_INDEX=1` treats the available-chunk index as
  invalid on every take, so each refill walks the class again — 12.25
  rebuilds per collection, the O(chunks) shape the note described.
  `--disabled` requires that. Dropping the skip reddens the gate (2.0,
  FAIL). Census **99 / 61 / 38 → 99 / 62 / 37.** x86_64.

- **`make stw-lag-pause` constructs its red direction per run.** The
  gate already ran on x86_64 CI and asserted that the default path
  skips on shallow fibers (`--dirty-kb=16`, 34 skips). Its ability
  to fail the *disable* lived only in a hand edit of
  `fiber_stack_scan_top`. `GCRY_STACK_LOW_WATER=0` turns the skip
  off, so every config records 0 skips and lag 0 goes from 14.47 ms
  to **329 ms (14.63×)** — the skip's own number. `--disabled`
  requires that. Dropping the assignment reddens the gate (exit 64).
  Census **99 / 62 / 37 → 99 / 63 / 36.** x86_64.

- **`make nursery-headers` constructs its red direction per run.** The
  CI step already ran on x86_64 and asserted HTTP::Headers keys
  survived a minor — on the headerless compile default, where
  `Heap#nursery_enabled=` is a no-op, so `minor_collect` returned
  immediately and the names were string literals on the stack. Both
  arms would have stayed green through a broken Hash walk. The green
  arm now requires `-Dgcry_block_headers`, a live nursery, a KIND_HASH
  layout that walks keys, and a nursery-allocated name that has left
  the stack. `--disabled` installs the pre-fix shape (noscan @entries,
  no key/value walk) and requires that name to vanish. Dropping the
  flag: exit 64. Dropping the zeroed walk: exit 64. Census
  **99 / 63 / 36 → 99 / 64 / 35.** x86_64.

- **`make fork-test` constructs its red direction per run.** The x86_64
  CI step called `after_fork_child_reinit` itself, ignored the child's
  exit status, and only checked that malloc was non-null — it would
  have stayed green with atfork uninstalled. `GCRY_DISABLE_ATFORK` was
  documented and unused. Green now requires `-Dwithout_mt`, the
  pthread_atfork handler, and a child that mallocs+collects without a
  manual reinit. `--disabled` requires the handler off and
  `note_fork_child` + malloc to `_exit(69)` without allocating —
  `raise` re-entered malloc and overflowed the stack. Dropping the
  knob: exit 64. Dropping the `_exit`: malloc succeeds, FAIL. Census
  **99 / 64 / 35 → 99 / 65 / 34.** Linux + Darwin.

- **`make nursery-bitmap-marks` constructs its red direction per run.**
  The recipe built headerless, where `Heap#nursery_enabled=` and
  `bitmap_marks=` are no-ops, so `minor_collect` returned immediately
  and the child survived as an uncollected object — both arms would
  have stayed green through the pre-fix global `@bitmap_marks` clear.
  Green now requires `-Dgcry_block_headers` and a per-chunk clear on
  three representations. `--disabled` is `GCRY_NURSERY_MARKS_GLOBAL=1`:
  bitmap arms must lose a child reachable only through a marked
  nursery parent; the header-marks arm is the control and must keep
  it. Dropping the flag: exit 64. Dropping the knob: exit 64. Census
  **99 / 65 / 34 → 99 / 66 / 33.** x86_64.

- **`make nursery-tlab-smoke` constructs its red direction per run.**
  The x86_64 CI step built headerless, where `Heap#nursery_enabled=`
  is a no-op and `tlab_enabled=` is refused (bitmap allocator forced),
  so `minor_collect` returned immediately — twenty rooted objects
  surviving a no-op. Green now requires `-Dgcry_block_headers` and
  `GCRY_BITMAP_ALLOC=0` (TLAB cannot be enabled once bitmap chunks
  are mapped). `--disabled` is `GCRY_TLAB_MINOR_FREE_OLD=1`: the
  pre-fix old FREE-claim, so an old FREE node on the stack becomes
  USED-unmarked. A major does not clear NURSERY; the plant survives
  a minor first. Dropping the flag or the allocator knob: exit 64.
  Dropping the assignment: still_free=true, FAIL. Census
  **99 / 66 / 33 → 100 / 67 / 33.** x86_64.

- **`make stw-mt-property-test-short` constructs its red direction per
  run.** The x86_64 TLAB and TLAB+nursery CI steps, and Darwin's
  `make stw-mt-property-test-short`, built headerless, where
  `Heap#nursery_enabled=` is a no-op and `tlab_enabled=` is refused
  (bitmap allocator forced), so `minor_collect` returned immediately
  and `--tlab` allocated through the global freelist — both arms
  would have stayed green through a TLAB STW regression. Green now
  requires `-Dgcry_block_headers` and `GCRY_BITMAP_ALLOC=0`, TLAB
  actually on, and TLAB hits. `--disabled` is the headerless binary:
  `--tlab --nursery` must not enable. Dropping the flag or the
  allocator knob: exit 64. Pointing `--disabled` at the green
  config: TLAB on, FAIL. Census
  **100 / 67 / 33 → 100 / 69 / 31.** x86_64 + Darwin.

## [0.26.2] - 2026-09-19

### Fixed

- **Darwin lost a thread's registers past 64 threads, and Windows lost
  the whole collection.** The STW capture table was a fixed 64 slots
  because its claim mask was an `Atomic(UInt64)`, which cannot address a
  65th, and `slot_for` returned −1 past it. On Darwin that thread was
  then scanned with **no registers** — `thread_get_state` is their only
  copy — so a reference held only in the 65th thread's registers was not
  a root. On Windows the stop was *refused* at the 64th thread, so a
  process with 65 threads could never collect. Both now use one shared
  growable table (`Gcry::StwSlots`): a single `LibC.malloc` block
  published by a single pointer store, grown at collection entry before
  the first suspend and never inside the stopped world, never freeing its
  predecessor so a reader walking it during a grow cannot fault. Each
  stop loop hands the claimed slot index down, so the linear scan runs
  once per thread instead of twice. Gated by `make stw-capture-coverage`
  with `GCRY_STW_FIXED_SLOTS=1` as the red arm, and covered by
  `spec/stw_slots_spec.cr` on every platform — including a
  reader-during-grow example that faults 3 of 3 if the growth frees its
  predecessor.
  Two tests pinned the bound this removes and had to move with it:
  `spec/platform_windows_spec.cr` asserted that 65 threads make
  `stop_world` raise — with the table growing it succeeds, so the
  assertion failed *with the world stopped* and then joined 65 suspended
  threads, hanging every Windows job for its full 20-minute budget — and
  `process_spec/regression/9_windows_suspension_capacity_spec.cr`
  asserted the same for both `GC` entry points. The success path is now
  asserted directly (65 threads stop, resume and collect with
  `stw_capture_no_slot` unchanged), and the failure path keeps its
  original coverage through `GCRY_STW_TEST_FAIL_SUSPEND=1`, which
  refuses a stop as though `SuspendThread` had failed.
  Both platforms' capture state is declared `uninitialized` and defaulted
  in a method, which `make once-guard` now enforces: a class variable
  with a non-literal initializer is set up behind `Crystal.once`, whose
  mutex cannot be waited on from `GC.init` (Darwin died at startup) or
  inside the stopped world (`@@stw_handles`, read from
  `resume_suspended_threads`, wedged every Windows job for its full
  20-minute budget, three runs running).
  The table is a value type (`Gcry::StwSlots::Table`) so that a spec can
  own one: the first version was module-level state, and reconfiguring it
  from `spec/stw_slots_spec.cr` — invisible on Linux, which keeps its own
  table — left the Windows collector recording 4 of each thread's 80
  register words and wedged that job's whole spec suite.
  The property that no serial test can show — a reader inside the old
  block when a grow replaces it — is gated separately by
  `make stw-slots-grow-race`: four readers flat out across 12 doublings
  survive 3/3, and `GCRY_STW_SLOTS_FREE_OLD=1` kills them 3/3. It was
  first written as a spec example, where it held the two-vCPU Windows
  runner for that job's entire 20-minute budget; lightened enough to fit
  there it stopped discriminating (5/5 green with the predecessor freed),
  so it moved to a gate with a deadline instead.
  Two earlier attempts were reverted after crashing the Darwin job, and
  the cause was neither the table nor the layout: the module declared its
  class variables **with initializers**, which Crystal sets up lazily
  behind `Crystal.once`, and Darwin boots the table from `GC.init` before
  that machinery exists — so every `-Dgc_none` binary died at startup.
  `linux_stw.cr` documents that rule for the same reason.
  **Linux is unchanged on purpose**: its suspend handler carries no
  `SA_ONSTACK`, so the `ucontext` its registers come from sits on the
  interrupted thread's own stack and the unclamped full-stack scan walks
  it — a missing slot there costs precision, not roots.

- **`GCRY_DISABLE_SP_CLAMP=1` wedged the collector and dropped register
  roots.** Its documented effect is "full pthread range on other
  threads"; it also skipped `install_stw_sp_capture`, which on Linux is
  what installs the `SIG_SUSPEND` handler a stop collects its
  acknowledgements through — so setting it meant a stop waiting forever
  (60 s of no progress in `make greg-roots`) — and it disabled **register
  roots**, because `with_thread_gregs` was gated on the same flag. That
  is the v0.19.0 missed-root shape, reachable from a knob advertised as a
  precision trade. The capture install is unconditional now and the
  register path gates on the table being booted, so the knob does only
  what its row says. `samples/stw_sp_clamp` also passed with `hits=0` —
  a state where the clamp did nothing — and now requires `hits > 0` on
  Linux, with the knob wired as its red arm.

### Changed

- **The race gates name what they faulted on.**
  `bench/chunk_search_race.cr` is a library build on purpose, so nothing
  installed gcry's SIGSEGV report in it, and a deterministic fault on the
  Darwin runner produced one line — `Process terminated because of an
  invalid memory access` — with no address, no backtrace, and no way to
  tell which of its nine arms died, because each prints its own `ok`
  before exiting. It installs the report now, the recipe sets
  `GCRY_SEGV_REPORT=1`, and the parent names the failing arm and
  separates a non-zero exit from a timeout. `dormant-flush-race`,
  `large-cache-race` and `find-block-race` get the variable too: all are
  gates whose failure mode is a fault.
- **`make windows-typecheck` covers the harnesses a spec builds.** Its
  file list mirrored `ci/windows.ps1` and missed
  `bench/chunk_search_race.cr`, which `spec/cached_bitmap_pool_race_spec.cr`
  compiles — so a `Gcry::SegvReport.install` call in that harness broke
  all six Windows jobs, three days after the identical mistake with
  `poison_holders.cr` broke two. A harness a spec builds is a harness
  every platform compiles.
- **`make windows-typecheck` also covers the specs only Windows runs.**
  A spec body inside `{% if flag?(:win32) %}` is compiled by no local
  check, so the only place a mistake in it appears is a Windows job —
  which is where two of them appeared this cycle. `spec/platform_windows_spec.cr`,
  the three spec files with win32 branches and
  `process_spec/regression/9_windows_suspension_capacity_spec.cr` now
  cross-compile for both Windows targets, in ten seconds.

## [0.26.1] - 2026-09-17

### Added

- **`stw_capture_no_slot` on `/gc-stats`**: claims on the STW SP/register
  table that found it full. All three platforms bound that table at 64
  because the claim mask is an `Atomic(UInt64)`, and past it Linux and
  Darwin suspend the thread and scan it with no SP clamp and no
  registers — so a reference live only in the 65th thread's registers is
  not a root. (Corrected 2026-09-17: only on **Darwin**. Linux reads its
  registers from a signal `ucontext` that sits on the interrupted
  thread's own stack, which the unclamped scan walks in full, so the loss
  there is precision.) Nothing counted that before. Measured on Linux: exactly
  zero every collect at 9 and 33 threads, +70 per collect at 101.
  Reporting only; the gate asserting it zero belongs with the fix that
  lifts the bound. Windows refuses any stop it cannot record, so the
  counter is a structural zero there.

- **`stw_threads_suspended` / `stw_threads_resumed` on `Heap`**, Darwin
  only: threads a stop suspended and resumed, counted on `KERN_SUCCESS`
  on both sides, so their equality is the resume's contract. Not on
  `/gc-stats` — that tuple is at Crystal's 300-field ceiling and a
  counter has to earn its place there; these two are a gate contract and
  `bench/darwin_stw_resume.cr` reads them off the heap.

- **`make windows-typecheck`**: cross-compiles `samples/hello.cr` and
  `bench/tls_roots.cr` — what `ci/windows.ps1` actually builds — for both
  Windows targets in 8 s. `make darwin-typecheck` has caught
  platform-only compile breaks for the other platform since 2026-08-22;
  Windows had no equivalent, so a five-line bench change that reached a
  `{% skip_file unless flag?(:unix) %}` module cost two red jobs twenty
  minutes into the matrix.

- **`make thread-startup-cost`: what starting the Nth thread costs, and
  whether a collection makes it worse.** A probe, not a gate — it
  asserts only that its own arms ran. It exists because
  `stack_bounds_growth` asked for 100 live threads and the macOS runner
  never got all 100 running inside 120 s, twice, while Linux does it in
  **2.8 ms**. Three arms over n = 8/32/64/100, each (arm, n) pair its own
  bounded child so a hang at large n does not lose the small-n data.
  Linux baseline: per-thread cost *falls* with n on every arm (×0.16 to
  ×0.22), so nothing quadratic; a collection during the storm costs about
  30× per thread, and cost per collection rises 2.6 → 7 ms as live
  threads go 8 → 100 — the O(n) per stop any collector owes, with
  Darwin's constant the open question. The probe needed a third arm to
  mean anything: `auto=on` and `auto=off` both report `collections=0`,
  because 100 `Thread.new` calls never reach the threshold, so the knob
  separating them does nothing and the two rows are one measurement
  twice; only the arm that forces collections bears on the prediction.
  Runs `continue-on-error` on Darwin, where the evidence is the log and
  not the step conclusion. **It found a defect on its first Darwin run**,
  and not the one it was looking for: startup there is not slow (100
  threads in 2.3 ms with collections off), but a collection during the
  storm hangs at exactly 64 threads — `MAX_STW_SP_SLOTS` in
  `darwin_stw.cr`. `stop_world_threads` suspends every thread but records
  the Mach port only while the table has room, and resume walks only the
  table, so every thread past the 64th is suspended and never resumed.
  Not fixed here; see `ROADMAP.md` and
  `bench/log/linux/2026-09-17-darwin-64-thread-cliff/FINDINGS.md`.

- **`make stack-bounds-growth`: the gate `ROADMAP.md` said already
  existed.** The root scan cannot call `pthread_getattr_np` with the
  world stopped — that is the 2026-08-10 six-hour hang — so bounds are
  snapshotted before the stop and read from a table inside it, and that
  table was a fixed 64 slots. Past it threads were visited with nowhere
  to record them and their OS stacks went unscanned. The board claimed
  this was "gated in `process_spec` … broken on purpose with
  `GCRY_STACK_BOUNDS_NOGROW=1`"; the knob was in no spec, no recipe and
  no CI step, so the gate described did not exist. Three arms on Linux,
  aarch64 and Darwin: 100 threads held live must give
  `stack_bounds_read == stack_bounds_visited` with zero capacity misses;
  `--control` stays inside the initial 64 so that equality is
  attributable to growth rather than to two counters agreeing trivially;
  `--nogrow` freezes the table and requires the loss to show in **both**
  counters — measured `visited=204 read=128` with 76 misses — because a
  frozen table that also stopped counting reads as full coverage of a
  smaller process, which is exactly what the pre-fix counters did (82
  threads reading `visited=64 read=64`). `docs/HARDENING.md` now says
  which counting each of those two measurements belongs to. Still not
  claimed, unchanged from the fix: whether a thread past the 64th ever
  held the only reference to something. **Linux and aarch64 only:** the
  first Darwin run of this gate took that job down — 18m37s, cancelled at
  its 20-minute cap — so it is not enabled there. The harness held its
  100 threads on a 200 us poll and now uses 25 ms, which is the leading
  suspect. Each arm is a **bounded child** of the harness now
  (`BoundedChild`, the module written after a hung arm took an aarch64 job
  down for 13 minutes), so a hang costs `BENCH_CHILD_TIMEOUT_S` and is
  reported instead of cancelling the job; at a 1 s budget the parent
  exits 1, which is the bound's own positive control. The bound is in the
  harness rather than in CI because the first attempt used `timeout 180`
  and macOS has no `timeout(1)`: the step died with exit 127, ran in 0
  seconds, and `continue-on-error` reported it as **success** — a
  continue-on-error step's conclusion is not evidence, only its log is.
  **Linux only, by construction**: `darwin_stack.cr` and
  `windows_stack.cr` query the thread descriptor at lookup time instead
  of snapshotting, so there is no table to grow and
  `stack_bounds_visited` / `read` / `capacity_misses` are zeros by
  design — the harness now skips those platforms with that reason rather
  than failing. The first version of this entry said the arms were not
  Linux-only, read off all three platforms *declaring* the same methods;
  they declare them returning zero, which is the `each_thread_greg` stub
  shape v0.19.0 was about. A Darwin run reported `visited=0 read=0` and
  the harness's own precondition caught it.
  `bench/log/linux/2026-09-16-stack-bounds-gate/FINDINGS.md`

- **`make dead-stack-root`: the v0.20.0 dying-fiber stack root finally has
  a gate.** `Thread#dead_fiber_stack` parks a terminating fiber's stack on
  the thread, which may still be running on it while the owning `Fiber` is
  already off `Fiber.unsafe_each`; rooting it is credited with taking the
  nested-spawn repro from 11/24 crashes to 0/24. Nothing gated it: the
  disable `GCRY_DEAD_STACK_ROOTS=0` appeared in no spec, recipe or CI
  step, `dead_stacks_walked` was printed by `bench/nested_spawn_uaf.cr`
  and asserted nowhere, and that target is "not a gate" and absent from
  CI — so the fix could have regressed to a no-op in silence. Four arms,
  three requiring the victim to **die**, on Linux, aarch64 and Darwin.
  Building it produced two corrections. The harness first allocated the
  victim inside the dying fiber, leaving plaintext copies in that fiber's
  own frames, and its **control arm caught** the hold arm being
  unattributable; the victim is now allocated on the main fiber and only
  `addr ^ KEY` crosses over. And `GCRY_DEAD_STACK_NOROOT=1` alone is not
  the twin control it was documented as — the walk takes
  `offer = @dead_stack_roots`, so it walks *and* offers; the twin is that
  knob plus `GCRY_DEAD_STACK_ROOTS=0`, `docs/HARDENING.md` is corrected,
  and the harness refuses the one-flag form rather than measuring it.
  `bench/log/linux/2026-09-16-dead-stack-gate/FINDINGS.md`

- **`bench/soak.cr --workers=N`, and the parallelism a run actually
  booted.** Default **1** — the baseline every earlier arm ran, so a
  comparison against a recorded run stays a comparison — with
  `soak_workers` as a `workflow_dispatch` input like `fiber_churn` and
  `collect_hz`. `--fiber-churn` and `--collect-hz` raise the rate a bad
  slot is *seen*; this is the first lever on the rate one can be
  *created*. Priced at 90 s with churn 512: four workers hold occupancy
  where the cadence knob diluted it (slots per collection 69.2 → 68.2,
  non-empty collections 90.9% → 97.6%) and produce the first `stw_waits`
  this workload has recorded (0 → 1, max 89.6 µs), costing 21% of
  allocations and 13% RSS. Workers do not replace churn: at
  `--workers=4 --fiber-churn=0` only 1 collection of 59 sees a non-empty
  queue. The `config:` telemetry line now carries `workers_requested`,
  `ec_parallelism` and `os_threads`, with `ec_parallelism` read from the
  context rather than from the flag — the 2026-09-10 arm is what a flag
  nothing honoured looks like six weeks later. No fault was reproduced;
  two 90 s arms are not a rate measurement.

### Changed

- **The holders search (`GCRY_POISON_HOLDERS=1`) now compiles on
  Windows.** `poison_holders.cr` opened with
  `{% skip_file unless flag?(:unix) %}`, which turned out to be a
  conservative gate rather than a dependency: `Platform.thread_sp` and
  `snapshotted_stack_bounds` exist on all three platforms and
  `last_stop_sp` was already Linux-guarded. That mattered because
  Windows is the only platform where `make tls-roots`'s control arm has
  actually come out INCONCLUSIVE — the case the search exists to
  explain — so the instrument was missing exactly where it was needed.
  `ci/windows.ps1` also runs `bench/holders_find.cr` now, so the walk is
  exercised there on a path whose answer is known rather than first
  executing inside a failing gate.

- **`bench/gate_arm_census.py` counts a third shape of red arm.** A recipe
  that re-runs its harness under a knob or flag restoring the pre-fix
  behaviour, with the harness judging that arm, is as much a per-run red
  arm as a `!` prefix or a forked child — `--control` excluded, because a
  control has to pass. The narrow criteria counted `make dead-stack-root`
  as "by hand" while three of its four arms required a death, which is how
  the gap was found. Same tree now reads 30 per run / 55 by hand of 85
  against the 20/64 first reported; the definition moved, not the tree,
  and the earlier record is corrected in place.

- **`make greg-roots` and `make static-bss-roots` now construct their own
  red arm.** Both gates' ability to fail existed only as a sentence in
  `ROADMAP.md` ("broken on purpose and observed red"). The knobs that
  restore the pre-fix behaviour were already in the collector and used by
  nothing: eleven root-disabling `GCRY_*` knobs are read by `src/` and
  appear in no spec, no `bench/`, no recipe and no CI step —
  `knob-doc-check` enforces that a knob is *documented*, nothing enforces
  that it is *used*. Running each against every fast root gate bought two
  arms for no collector code: `! GCRY_DISABLE_GREG_ROOTS=1` (targeted; it
  reddens `greg-roots` and nothing else, and that gate covers the
  v0.19.0 defect shape on two platforms) and
  `! GCRY_DISABLE_STATIC_ROOTS=1`. Under the first the victim still
  **survives** — the conservative stack scan reaches it — and what goes
  red is `register candidates … 0`, the fourth independent case of a
  counter discriminating where survival does not. Also recorded: two
  knobs unsuitable as arms (`GCRY_DISABLE_SP_CLAMP` hangs two gates,
  `GCRY_DISABLE_STATIC_ROOTS` kills five of seven outright) and seven
  that no gate notices, because no harness builds the condition they
  break. `ROADMAP.md`'s claim that `GCRY_STACK_BOUNDS_NOGROW` is gated in
  `process_spec` is retracted — it is not in `spec/`.
  `bench/log/linux/2026-09-16-orphan-break-knobs/FINDINGS.md`

- **`bench/gate_arm_census.py`: which gates can still come out red.**
  Every gate asserts something; what rots is its ability to fail, and
  this repo has three instances — `make page-release-corruption` and
  `make live-graph-audit` testing nothing for releases, the soak's "EC4"
  arm running one worker for six weeks, and the `--resize` arm added the
  same day passing with its window shut. The census reports **20 of 84**
  harness-driven gates constructing their red direction per run (recipe
  `!`/`grep -q`, or a harness that forks a child under a breaking knob
  and judges it) against **64** that had it established once by hand,
  plus the **19** places `ROADMAP.md` claims a hand break that nothing
  re-checks. Three were sampled by breaking the collector for real —
  `each_thread_greg` stubbed, `Layout.register`'s `has_inner_pointers?`
  fallback dropped, the `ec.@schedulers` pin loop removed — and all
  three went red, so the finding is about re-verification, not hollow
  gates. What the breaks showed is worth more than the count: **a
  survival assertion does not discriminate and a counter does**, because
  in all three the object survived the break on conservative scanning
  alone and only a counter noticed.
  `bench/log/linux/2026-09-16-gate-arm-audit/FINDINGS.md`

- **`make scheduler-roots` now audits the one EC state where the
  context's scheduler list and reality differ.**
  `Fiber::ExecutionContext::Parallel#resize` replaces `@schedulers`
  rather than mutating it, and on a shrink the overflow schedulers are
  dropped from it and told to shut down cooperatively — stdlib: they
  "won't stop until their current fiber tries to switch". The collector's
  pin block walks the new array, so for the length of that window a
  `Scheduler` is being run by a live thread with none of its named pins.
  The new `--resize` arm holds the window open with one non-yielding
  fiber per worker, shrinks 4 → 1, and gates on the quantity of named
  coverage lost: **24 pins, exactly `3 × (1 object + 7 ivars)`**, derived
  from `instance_vars` on both the harness and the collector side. Red at
  0 with the pin loop removed, and it refuses to pass if no removed
  scheduler still has a live reader. Nothing is swept in that window —
  and the positive control shows that is not because anything names it:
  with `thread.@scheduler`'s pin deleted the removed schedulers still
  survive, on the `Thread` body scan and the worker's own stack, which is
  the conservative coverage the pin block exists because it does not
  trust. Latent rather than live: nothing in this tree shrinks a context.
  `bench/log/linux/2026-09-16-ec-shrink-window/FINDINGS.md`

### Fixed

- **`make tls-roots`'s control arm no longer fails the job for a stale
  stack word.** That arm allocates a block, holds it nowhere and requires
  it to die; on Windows it survived, and the holders search — which now
  returns its count — named why: 8 words across 5 stacks, roots and heap
  clean, five of them in *live* frames of the running fiber, which
  `wipe_stack` cannot overwrite. Keeping a pointer out of memory is a
  codegen outcome no source-level test can compel, the same fact
  `bench/greg_roots.cr` records about its own end-to-end arm. The arm now
  reports that and exits 0 when a holder is found, and still fails when
  none is — which would mean something the search cannot see keeps the
  block alive. The arms that gate the behaviour are unchanged.
- **`spec/invariant_spec.cr` no longer waits for Crystal's thread list.**
  `check_live_objects` skips when `concurrent_mutators?` — a count of the
  *process*'s threads — is true, and two examples assert the walk ran.
  Waiting for the count to fall was wrong: `Thread#join` returning does
  not mean Crystal has unlinked the thread, and the aarch64 runner still
  listed three of them 5 s later, so the wait turned a flake into a
  deterministic failure. A heap those examples own now says
  `invariant_sole_mutator`, and the checker takes it at its word; the
  two-instant race the skip exists for is still caught by the confirm
  loop. Measured with five threads on the list: the walk runs +0 times
  without the predicate and +2 with it.
- **`make collect-scrub-cost` no longer fails when its cost figure is not
  the initial thread's.** glibc parses `/proc/self/maps` for
  `pthread_getattr_np` only on the initial thread and answers a pool
  thread from its own mmap, and Crystal 1.21 can move the main fiber to a
  pool thread — so the runner measured **1.0 µs at 8 070 mappings**,
  against 1 779 µs here, and the harness failed its own precondition. It
  now attributes that instead of failing, and the structural assertion
  (the collector never asks libc) is unaffected.

- **An explicit `GC.collect` usually did nothing under thread load, and
  said nothing.** `Heap#collect` opened with `return if @collecting`, a
  flag set for a whole cycle, so a request made while *any* thread was
  collecting returned immediately. Measured on 20 hardware threads,
  asking continuously for one wall second: 226 of 1 969 calls landed a
  collection at 8 threads, 58 of 571 342 at 32, and **6 of 85 682** at
  70 — about 1 in 14 000, since a cycle there takes ~145 ms. The guard
  now fires only when the calling thread is inside its *own* cycle, and
  a peer's cycle is waited for in `run_collection`, which already takes
  `@post_stw_mutex` at entry. So `GC.collect` now means what a caller
  reads it to mean: when it returns, a collection has completed. The
  allocation path (`maybe_collect`) and the incremental slice
  (`collect_a_little`) are untouched. Gated by
  `make explicit-collect-barrier`, with `GCRY_COLLECT_SKIP_WHEN_BUSY=1`
  restoring the old guard as the red arm.

- **Darwin: every thread past the 64th was suspended and never resumed.**
  `stop_world_threads` suspends every thread with a Mach port
  unconditionally, but recorded that port only while a slot was free in a
  64-entry table, and the resume walked the table — so a process with
  more than `MAX_STW_SP_SLOTS` threads came back from a collection with
  the rest frozen forever, and the collection reported success. The
  resume now walks Crystal's thread list and resumes on the same
  predicate the stop suspends on, so the two cover the same set with no
  bound between them. Found from the other end: `make
  thread-startup-cost` measured 7.6 ms for 8 threads, 32.3 ms for 32 and
  **120 s TIMEOUT** for 64 and 100, against 31.6/65.1/41.3/85.7 ms on
  Linux — a cliff on the constant, not the O(n²) curve first suspected.
  Gated by `make darwin-stw-resume`: `stw_threads_suspended ==
  stw_threads_resumed`, both counted on `KERN_SUCCESS` only, plus every
  worker still making progress after the restart, with
  `GCRY_STW_BOUNDED_RESUME=1` restoring the pre-fix table walk as the red
  arm. Measured on the runner: 142 suspends and 142 resumes with nothing
  stalled on the fix, 142 against **128** with **7 of 70 workers frozen**
  on the pre-fix walk — a difference of 14, which is 2 collections ×
  (71 − 64) threads. The probe's two timing cells that had been TIMEOUT
  at 120 s now finish, and us/thread *falls* with n as it does on Linux.

- **The aarch64 spec flake family is root-caused: one extra live thread
  turns the empty-chunk release off.**
  `release_empty_chunks_this_collect?` returns false under
  `sweep_multi_mutator?` unless `parallel_empty_chunk_dormant` or
  `parallel_empty_chunk_munmap` is set, and
  `munmap_empty_chunks_this_collect?` is gated the same way.
  `sweep_multi_mutator?` counts Crystal's thread list, so a thread left
  running by another example switches the whole release path off — which
  is why five examples across three files failed together ~3 in 30 runs
  on aarch64, passed 80 of 80 locally, and also showed up under kcov: all
  three are "how long another example's thread is still alive". The
  widened state dump added hours earlier is what identified it, ruling
  out empties never seen free (`fully_free=1048576`), live objects
  (`live_objects=0`), warm preemption (`warm_retain=0`), budget
  (`retain=67108864`), munmap (`unmapped=0`) and `madvise` alignment
  (`page=4096 compiled_page=4096`). Reproduced with one extra thread:
  `dormant=8 → 0` and `unmapped=393216 → 0`, restored exactly by the
  knobs. Fixed at **eight sites** across six files — every spec that
  enables `release_empty_chunks`, not just the five that failed — and it
  changes nothing they measure, since the knobs are only read on the
  multi-mutator branch.
  `bench/log/linux/2026-09-17-empty-chunk-release-flake/FINDINGS.md`

- **The soak ran one worker thread, so the cross-thread corruption it
  exists to catch could not be created.** `bench/soak.cr` hunts the
  2026-08-10 SEGV in `quick_dequeue?` on a partly overwritten run-queue
  slot. Crystal's default execution context is `Parallel` but starts at
  capacity 1 (`init_default_context` calls `Parallel.default(1)`) and
  grows only when the program calls `Parallel#resize`; the harness never
  did, and neither `CRYSTAL_WORKERS` nor `EC_PARALLELISM` moves it — the
  first only feeds `default_workers_count`, the second is this repo's own
  name for the argument `bench/kemal/src/server.cr` passes to `resize`.
  Measured: capacity 1 and 2 OS threads on a plain `-Dgc_none` build and
  on `-Dpreview_mt -Dexecution_context` with `EC_PARALLELISM=4` — the
  configuration recorded as the "EC4 + fiber churn" soak arm on
  2026-09-10, which was therefore single-worker. That record is corrected
  in place. Kemal's EC4 numbers and `bench/soft_soak_ec4.sh` are
  unaffected: `server.cr` does call `resize`.
  `bench/log/linux/2026-09-16-soak-worker-count/FINDINGS.md`

## [0.26.0] - 2026-09-15

Minor release: **the headerless small-object layout is the compile default.**
Small blocks are carved back-to-back with no 16-byte header in front of each
object; size and kind come from the chunk, marks and occupancy from its
bitmaps. Measured on the paired Kemal `/json` run that decided the 0.24.0
bitmap default: **112.6%** [106.6, 118.6] of Boehm at **1.07×** its peak RSS,
against the header layout's 105.3% at 1.30× on the same tree.

The rest is root coverage. A pointer held only in the main thread's
thread-local storage was **collected** — on Linux first, then on Darwin and
Windows, which each needed a different answer because the live block is a
loader allocation, a libc `malloc` and a TEB copy respectively. A chunk could
be released while it still held a live block. A Darwin crash on a poisoned
pointer read as a null dereference, because the register reader that names the
poison was Linux-only. And three gates had rotted into testing nothing, which
is part of why those defects outlived releases.

**Upgrading:** the headerless small-object layout is now the compile default.
A plain `crystal build -Dgc_none` gets it; nothing changes in how gcry is
required or built. `-Dgcry_block_headers` restores the 16-byte per-object
header layout that shipped through 0.25.0, and is required for
`GCRY_BITMAP_ALLOC=0` (the freelist), `GCRY_NURSERY`, and a
`GCRY_CHUNK_BYTES` above 51.2 MiB — none of which exist on a headerless heap.
`-Dgcry_headerless` is accepted as a no-op; passing both flags is a compile
error. Each of those knobs now warns on stderr when the layout ignores it,
naming the flag that brings it back — silence would have been the whole
defect, since `GCRY_BITMAP_ALLOC=0` was the documented escape for a workload
that cares about RSS. If that is why you set it: headerless is the
*lower*-RSS layout of the three (0.85× the header layout's peak, and the
freelist's was 1.87× Boehm on the 2026-09-06 run), so the escape you wanted
is now the default and the flag would take you the wrong way.

### Added

- **`make kernels-ir`: both architectures' vector kernels checked from one
  host.** The plan carried "aarch64 IR gate — CI only, no local arm64 host"
  as an open item, and that was a misreading: `--cross-compile --emit
  llvm-ir` runs the whole pipeline for a target and stops before linking, so
  the check needs the target's *compiler*, never its CPU. One gate, ~19 s,
  asserts aarch64 `"+neon"`, `"+sve"`, `llvm.ctpop.v2i64`, `<2 x i64>`,
  `whilelo` and `cnt z`, and x86_64 `vpandn`, `vpshufb`,
  `llvm.ctpop.v4i64`, `llvm.ctpop.v8i64`, `<4 x i64>` and `<8 x i64>` — the
  vector types and the hand-written asm the tiers are made of. Each arch also
  asserts the other's fingerprints are **absent**, because a grep for a string
  a file never contains reads exactly like a grep for one it should contain
  and does not; that half caught its own first draft, where `<2 x i64>` was
  asserted as aarch64-only and turned out to be SSE2's type as well. The CI
  `test` job runs both arches through it and the aarch64 cross job keeps only
  its object-emit smoke, so the assertions live in one place instead of two.

- **`make bitmap-marks-freelist`: the mark representation nothing was
  running.** On `-Dgcry_block_headers` there are three, not two — marks in the
  block header, marks in the chunk's bitmap with the pool allocator, and marks
  in the chunk's bitmap while the **freelist** allocator keeps handing out
  header-carrying blocks. The third is documented, shipped as `GCRY_BITMAP=1`,
  and had no coverage: the headerless default forces both bitmaps on,
  `GCRY_BITMAP_ALLOC=1` covers marks-plus-pool, and the one CI line that set
  `GCRY_BITMAP=1` set it on a binary built headerless, which ignores the knob.
  The knob also does not mean the same thing on both sides of `-Dgc_none`: the
  process GC defaults the pool allocator **on**, so reaching the freelist arm
  there needs `GCRY_BITMAP_ALLOC=0` as well — measured, and now in the env
  reference, because the first run of this gate was silently the arm CI
  already had. The gate runs unit specs (299), process specs (32), the
  property test at 50 000 iterations, the MT property test on 2 and 4 workers,
  the STW property test with TLAB and nursery, and pattern fuzz, in ~36 s.
  `spec/bitmap_marks_spec.cr`'s live-set A/B is three-way now and names the
  arm that drifts; observed red by taking the block ordinal off
  `chunk + ChunkHeader::SIZE` instead of `data_start`, which reports
  `marks-only: live_objects 0, header 200`. Run at full length by hand as well
  — property 100 000, MT 2/4/8, pattern fuzz 200 phases, thread storm, the
  stress and json_churn samples, `GCRY_DEBUG_INVARIANTS=1` — **all green, no
  defect found**, which is the result and not a disclaimer: the configuration
  was untested, and it is now tested and sound.

- **A chunk a refused release kept is named in the crash report.** The flush
  that now refuses to release an occupied chunk puts it back on the live list,
  which makes it an ordinary chunk again — so when it is released later and a
  stale pointer faults on it, every line of the report describes that ordinary
  release and nothing says the chunk had been through the window the refusal
  exists to close. A sixteen-slot ledger (`note_kept_release` /
  `kept_release_at`, four stores on a path that already walks the chunk)
  records base, length, collection and occupancy at the refusal, and the
  report reads it in both branches where a fault can land — in-span with no
  live block, and out of span, since releasing a chunk is what moves an
  address out of the span. The real window has never opened on a developer
  host (0 chunks considered in 120 collections with more than one mutator
  alive), so the ledger and its line get a positive control instead of a
  promise: `GCRY_REFUSE_EMPTY_RELEASE=<n>` refuses the first n empty-chunk
  releases whatever the occupancy says — a budget, not a flag, because a chunk
  refused forever is never released and the line under test is the one a
  *later* release prints — and `make kept-release-report` faults into such a
  chunk and requires the report to name both. The control is kept out of the
  numbers a sighting is read from: forced refusals land in
  `release_refused_forced`, never in `release_refused_occupied`, because that
  field means a mutator took a block and the one-shot `refusing to release
  chunk` line fires on the first refusal counted there — a control that spent
  either would report the window as hit and then silence the real one. The
  report tells the two apart the same way: 0 blocks says the refusal was
  forced, non-zero says a mutator took one through the index entry the chunk
  still had. `make thread-churn-uaf` grows a `reported` arm that allocates
  exactly as the shipped collector does and carries only the report, which is
  the arm the 2026-09-14 CI sighting had no way to answer from.

- **An 8-hour soak on the overnight tree, recorded.** PASS: 28 743 collections,
  28.6 M allocations, 287 459 fibers, **0 queue faults**, and an RSS envelope
  that is flat — 7 956 kB from hour 2 through hour 7 without moving, 7 800 kB
  after the drain, against 7 024 kB at start. The pause does not drift with
  uptime either (p50 1.80 ms in hour 0, 1.76 ms in hour 6; p99 2.73-2.95 ms
  throughout). Telemetry is kept beside the findings.
  `bench/log/linux/2026-09-13-soak-8h/FINDINGS.md`

- **`make fiber-lag-cost`: the parked-fiber lag is free on untouched stacks and
  costs the whole window on faulted ones.** Under multi-mutator STW every parked
  fiber is scanned from 256 KiB below its saved `stack_top`, and the roadmap
  proposes scanning a fully parked fiber from its own SP instead. Measured with
  256 fibers on a Parallel context: on stacks never faulted below the parked
  frames the pagemap low-water probe removes the **entire** window (67 858 KiB
  of a 67 072 KiB nominal window per collection), so the proposal would save
  nothing there; with each fiber touching 512 KiB of stack first and then parking
  shallow, the probe removes 2 470 KiB and **64 602 KiB per collection is read —
  246.6 KiB per parked fiber**. That second arm is the "pooled stacks lose the
  skip over time" case with no pool and no uptime: one deep call, then park.
  `low_water_misses` and `low_water_unprobed` are new and are what made it
  conclusive; the findings record two readings retracted on the way, including a
  counter that is reset every collection and was read as a cumulative one.
  `bench/log/linux/2026-09-13-fiber-lag-cost/FINDINGS.md`

- **`make index-lock-wedge`: the wedge that needs something this tree does not
  do.** The roadmap has carried "a mutator frozen while holding `@index_lock`
  would wedge the sweep" as a shape with no reproducer. `index_insert` and
  `index_remove` now count their sections and whether the world was stopped:
  **1 155 sections alone, 586 with a second mutator holding the lock, 0 inside
  the stop**, because the sweep's placement is `sweep_after_world?` and the
  collector's index surgery runs with mutators running. What a holder costs is a
  bounded stall rather than a deadlock — a 30 s hold makes the harness kill its
  child, a 1.5 s hold finishes, which is what "waiting on an owner that is still
  running" looks like. And if the precondition ever appears, the watchdog now
  names it: it could say `phase=sweep` and nothing about which lock, and those
  two sections leave a breadcrumb carrying the lock and the chunk. The gate
  fails if a section runs inside the stop without the watchdog naming it.
  `bench/log/linux/2026-09-13-index-lock-wedge/FINDINGS.md`

- **`make pool-refill-cost`, and a retired note.** `tasks/todo.md` carried
  "`bitmap_take_pool_chunk` walks every chunk of the class per refill:
  O(chunks)" since the bitmap allocator landed. Measured: the walk builds a
  sorted index of candidate addresses once per *capacity version*, each sweep
  bumps that version, and the count is **2.0 rebuilds per collection — one per
  active class slot — identical whether the class holds 29 chunks or 598**. The
  cost per allocation does grow linearly with the chunk count (0.0142 to 0.292
  chunk visits per allocation across a 20.6x growth), which is the arithmetic of
  a constant rebuild rate rather than a regression: one visit per chunk is
  **0.391% of what the sweep walks in the same collection**, since the sweep
  visits every block of every chunk. The gate fails if rebuilds per collection
  exceed one per active slot, which is the only way this becomes the per-refill
  walk the note described.
  `bench/log/linux/2026-09-13-pool-refill-cost/FINDINGS.md`

- **`make counter-loss`, and the decision it settles.** The process heap's
  counters use plain `set(get + 1)` unless `GCRY_HEAP_COUNTERS_ATOMIC=1`, and
  the roadmap has carried "3 runs of 40 read `live_objects` one below the walk"
  since v0.20.0 as an open trade. Both halves are now measured. The cost of the
  atomic path is **not resolvable**: 0.9836 [0.9573, 1.0098] on one thread over
  40 M allocations and 1.0091 [0.9877, 1.0304] on four over 20 M, both CIs
  spanning 1.0 (`bench/micro/alloc_ns.cr`, alternating pinned arms; a Kemal
  `/json` A/B is ±10% on this host and cannot see the question at all). The loss
  does not reproduce: `GCRY_INVARIANT_COUNTER_LOSS=1` states the invariant even
  of a heap that may lose updates — the measurement the checker's scope
  correction retired — and finds **zero losses in 4.6 million forced
  comparisons** across three shapes. So the plain counter stays the default, the
  atomic path stays an escape, and the measurement is a gate with three arms:
  atomic and plain must both agree with a walk of the heap, and an increment
  dropped on purpose through `debug_drift_live_objects` must be caught, because
  two zeros with no positive control is a gate that cannot fail.
  `bench/log/linux/2026-09-13-heap-counters/FINDINGS.md`

- **The crash report names the frame that faulted.** A signal-safe walk from
  the faulting `ucontext`: the PC as `exe+offset` against the load bias
  captured at `GC.init`, `sp`/`fp`/`cr2`, the frame-record chain, and — since
  builds without `--release` omit the frame pointer — the words above `sp`
  that land in this binary's text, with the `addr2line` command assembled.
  Crystal's `CallStack` cannot be used here: it allocates its DWARF tables and
  needs `Fiber.current`, and on this heap it produced
  `Failed to raise an exception: END_OF_STACK` while its allocation *became*
  the block the report was about. First run, it named a three-week-old fault:
  the writer was the collector, in its own execution-context root pin.

- **A live object could be reclaimed under thread churn, open since
  2026-08-23 — fixed.** In the post-STW section the sweep asks
  `multi_mutator_threads?` about the world six times between the stop and the
  end of the sweep: `sweep_after_world?` inside the stop, where the decision it
  drives is taken, and `relink_chunks_after_world?` plus
  `munmap_empty_chunks_this_collect?` again during the sweep — of a number that
  a program creating threads in that section changes by design. So one
  collection acted on two answers. Fixed on both axes: the count is latched in
  the stopped world for the whole collection, and the relink decision is read
  once per sweep instead of at each of its three sites. **Measured on `make
  thread-churn-uaf`, both layouts: guarded 7 of 24 and poisoned 17 of 24 with
  `GCRY_SWEEP_MUTATOR_LATCH=0`, 0 of 24 on every arm with it.** That harness is
  now a regression gate rather than a reproducer, with a control arm per layout
  that must still fault. The `@chunks`/`@chunk_index` divergence reported
  yesterday is reduced by the same change (5 of 14 runs to 1 of 14) but not
  eliminated, and with the crash at zero it cannot be the crash's mechanism —
  its path is narrowed rather than closed: sampling the off-list count after
  every step of the post-STW section puts the growth at the sweep and nowhere
  else, which leaves the prepend race between the walk and `map_chunk`.
  Splicing that prefix in at the publish was written and withdrawn for the
  second time — the shipped residual does not move and the pre-fix shape gets
  worse, because the walk rewrites `next` in place.
  **The other end of it is now closed too, and it decomposes the defect.**
  `clear_all_marks` walked the `@chunks` list while the marker reaches chunks
  through `chunk_containing` — the index — so a chunk the index knows about and
  the list does not kept its marks: its blocks read marked forever,
  `mark_impl` returned early on them, and nothing followed their edges. The
  clear now walks the index, the measured superset. Over 12 attempts of the
  churn reproducer: shipped **0**, the mutator-count trigger alone **2**, the
  list-based clear alone **0**, both **7** — so the trigger produces the
  off-list chunks and the clear is what makes them fatal, and either alone is
  nearly harmless. `GCRY_MARK_CLEAR_LIST=1` restores the old walk and
  `GCRY_MARK_CLEAR_AUDIT=1` reports mark residue; the gate's control arm sets
  both knobs. What remains of the divergence is a leaked chunk one run in
  fourteen, which is an RSS question rather than a soundness one — and
  `chunk_index_only_bytes` now gives its retained cost (2.7-3.3 MB over a few
  hundred collections in the pre-fix shape). `make mark-clear-index` gates the
  clear: the shipped walk leaves no indexed chunk holding a mark across 20
  runs, and its control — which needs both halves of the pre-fix shape, and
  runs in child processes because that shape crashes as readily as it leaves
  residue — finds residue in 11 of 14.
  `bench/log/linux/2026-09-12-writer-frames/FINDINGS.md`

- **What the remaining chunk-list divergence costs, and what the latch fix
  actually prevented.** A chunk stranded off `@chunks` is never swept and can
  never rejoin the list, so its bytes are retained for the life of the process
  — but the strand needs a prepend, a prepend happens in `map_chunk`, and so
  the leak rides *mappings* rather than uptime: a heap that has reached its
  working size stops losing chunks. Measured against `chunks_mapped` (new,
  cumulative, one increment beside the `mmap`) the shipped tree strands **0 of
  12.1 million mappings** — 699 171 in the first pass and 11 389 909 more in two
  overnight children of 200 000 collections each, both ending at the heap size
  they started with, so a 95% bound of 2.6 per ten million, under 0.04 bytes per
  chunk mapped — and the sighting behind the open item does not survive as a rate
  either: 60 further runs of the identical command strand nothing, one event in
  74 runs. Restoring the pre-fix mutator-count reads strands **80-181 per 1000
  mappings** and ends with **97-99.3% of the heap in chunks no sweep will
  visit** (1 GiB where the shipped tree sits at 15 MB), so `latch_sweep_mutator_count`
  closed a near-total heap leak needing nothing rarer than allocation plus
  threads, not only the rare use-after-free it was landed for. The rebuild is
  therefore left alone and the instrument ships instead: `make
  chunk-list-drift`, three arms in ~35 s, capped at 5 stranded per 1000
  mappings. `chunk_index_only_now` and `chunk_index_only_now_bytes` report the
  divergence as a snapshot rather than a sum, which is what distinguishes one
  chunk stuck forever from a fresh one lost every collection.
  The same measurement corrected `make mark-clear-index`, which went red on CI
  the same day on its control arm: that arm churned threads and nothing else, so
  it asked a one-in-a-thousand-mappings question of a thirty-mapping sample and
  had been passing on luck (6 of 6 locally, 0 of 6 on the two-core runner). It
  now drives mappings with a live set that grows and drops, and its born threads
  allocate — a thread that only starts and stops is gone before the after-world
  sweep walks the list, so nothing prepends into that walk. After: 6 of 6
  children with residue and 18-91 stranded chunks each.
  `bench/log/linux/2026-09-13-chunk-list-drift/FINDINGS.md`

- **`GCRY_CHUNK_LIST_AUDIT=1`, and it found the root cause of the
  live-object release open since 2026-08-23.** `@chunk_index` and the
  `@chunks` list are maintained separately, and `chunk_containing` reads the
  index while every walk reads the list — `clear_all_marks`, the sweep, the
  holders search. The audit excludes the pending-unmap chain, since a dropped
  chunk is off the list and still indexed by design: the residual under thread
  churn is 1 chunk indexed but not listed in about 6 of 14 runs, none the other
  way, and none at all on a quiescent program. An off-list
  chunk never has its marks cleared, so its blocks read permanently marked,
  and `mark_impl` returns early on a marked block — so the object is never
  pushed onto the mark stack and its out-edges are never followed. That is how
  an execution context's `@schedulers` buffer was swept while the array
  holding it stayed retained, and the poisoned element is what the collector
  then dereferenced. The audit is O(index × list) with both in the tens and
  reports once with the first offending chunk.
  `bench/log/linux/2026-09-12-writer-frames/FINDINGS.md`

- **A control for the holders search** (`make holders-find`). Every
  use-after-free investigation on this heap turns on *"holders — none. Nothing
  in the root set, in a live block or on a fiber stack points into it"*, and
  that search had no test. Three block shapes, one constructed holder each,
  plus a masked block whose address exists nowhere a walk can see: the three
  are found and the control reports zero. `PoisonHolders.heap_holders_count`
  is the heap-only count it needs — the full search sums roots, blocks and
  stacks, and a caller's own locals make every target look held.

- The poisoned-pin diagnostic resolves the address to its block before
  describing or searching it. It arrives as the poison word plus the ivar
  offset the pin site added (8 bytes for `sched.@name`), so the first version
  asked about `[base+8, base+24)` and answered "nothing points at it" about a
  range the buffer's owner does not point into. It also prints `allocated` and
  the mark bit separately rather than calling `live?` liveness: that predicate
  answers occupancy.

- The execution-context pin sites carry a compile-time site tag, so a refused
  slot address names the expression it came from rather than a line nine sites
  share. It named the structure this defect has never named: `sched.@name`,
  from `ec.@schedulers.each`, with `sched` itself read as poison — so the
  freed 16-byte block is the `@schedulers` array's two-slot buffer, freed
  while the context and the array that owns it are both live. `/gc-stats`
  reports it as `ec_root_bad_slot_site`.

- **"SIGSEGV at 0x0" was a poison word, not a null.** `cr2` agreed with
  `si_addr`, but the register held `0xdead7fb15cbe0848` — tagged poison, whose
  top `0xDEAD` bits make the access non-canonical, which Linux reports as a
  fault at address 0. So every such report on the churn reproducer was a
  poison dereference. `mark_ref_slot` now refuses a slot address that is zero,
  non-canonical or poison-tagged, counts it (`ec_root_poisoned_slots`,
  `ec_root_null_slots`) and names the pin site and the freed block instead of
  faulting on it: a collector must not dereference an address it did not
  validate, and there is no object at a poisoned one to mark. What puts poison
  there — a live EC-family object being freed — is open, and the counter is
  how often it happens.
  `bench/log/linux/2026-09-12-writer-frames/FINDINGS.md`

- `GCRY_RELEASE_HOLDERS=1` (research): run the holders search at every large
  release rather than at a fault, printing only when something points into the
  block being released. The fault-time search answers about a release that
  happened 109 collections earlier on the open live-large-object item, which
  is why "holders: none" there never settled anything. Asked at the decision:
  explicit roots 0, one word in a 32-byte `type_id 0` block that nothing
  points at, and every stack word below `@collect_entry_sp` — the collection's
  own frames, not a live mutator frame. The block was garbage and the release
  was correct. `Platform.last_stop_sp` retains the stop's SP table for the
  post-STW section so that verdict can be taken there.
  `bench/log/linux/2026-09-12-release-holders/FINDINGS.md`

- `GCRY_SWEEP_OCC_AUDIT=1` (research): per dead word of the after-world
  sweep, ask every cursor set whether it is mid-allocation inside a block that
  pass just called dead — occupied, live, unmarked and about to be handed to a
  caller. It checks the whole-word `occ[i] = mark[i]` publish, which reads like
  a race against the allocator's lock-free atomic OR and is not one; the store
  comment said only that a *per-bit* clear would be worse, and now states the
  argument that actually holds. Measured 0 over 283 259 words published with
  mutators live, and 0 over the 183 360 per run of the churn reproducer while
  its use-after-free still fired, which is how the open live-large-object
  release lost this hypothesis. An atomic publish plus a mark-before-occupancy
  reordering was written, measured and reverted for fixing nothing.
  `bench/sweep_occ_race.cr`,
  `bench/log/linux/2026-09-12-sweep-occ-publish/FINDINGS.md`

- The unmap-guard release record answers **how many blocks the chunk still had
  allocated** when it was released, printed by `GCRY_SEGV_REPORT=1` as
  `Blocks still allocated at release: N`. Read from the occupancy bitmap
  before the `mprotect`, for the same reason the first user word is: afterwards
  the pages are `PROT_NONE`. It splits a released-chunk fault in two — an
  accounting bug in the release decision, or a stale pointer into a block that
  really was free — and on the open live-large-object release it reads **0**,
  which is what retired the missing-root reading of that defect.

### Changed

- **The parked-fiber lag scan was priced and the fix declined.** `ROADMAP.md`
  has carried "the EC4 pause is the parked-fiber lag scan" with a proposal to
  scan a fully parked fiber from its own saved SP. Its ceiling is a lag of ~0,
  and `bench/lag_width_ab.sh` measures that at Kemal EC4: 0.970 ms [0.302,
  1.638] off a ~6.4 ms pause p50, and no throughput change (0.989 [0.775,
  1.202]). The predicate the sound version needs - an SP for every thread, so
  that "no thread was found on this stack" means "no thread is on it" - is
  available in **0** of 34 989 scans, because SYSMON is signal-exempt and the
  EC Monitor therefore never records one. New counters `fiber_lag_sp_known` /
  `fiber_lag_sp_unknown` report it. Research only; no shipped behaviour
  changes.

- **The perf baseline now gates, and what unblocked it was arithmetic rather
  than more samples.** `PERF_GATE_BASELINE=1` has been "next" on the
  benchmark-alerts item for a year, behind *record more green runs first*. The
  tolerance rule was `max(half the observed range, 1.5 x IQR, floor)`, and both
  of those terms scale with the spread — so the gate sat about 2.3 standard
  deviations from the mean at any sample size (simulated: 2.28 sd at n=23, 2.51
  at 100, 3.04 at 500, 3.24 at 1000), which is a 2.7% false-red rate per run and
  would have needed ~1200 runs to reach 3.3 sd against a 30-day artifact
  retention. The tolerance is now stated in standard deviations (`TARGET_SD =
  3.3`, floored per metric), which puts the three gated metrics at 3.34-3.57 sd:
  **0.10% combined per run, one false red per ~1000 runs**, leave-one-out green
  on 24 of 24 recording runs, and each gate **tighter than the fixed floor it
  was meant to tighten** — 86.06% against 65%, 1.196x against 1.25x, 0.98 ms
  against 2.5 ms. `bench/perf_gate_margin.py` reports the margin and the
  false-alarm rate so the next flip decision is measured too. What the gate
  cannot see is a regression under ~14 pp of `/json` throughput on this runner
  class; that needs confirmation across runs, not a narrower band.
  Sensitivity comes from a second observation rather than a tighter band: two
  runs in a row on the wrong side of 2 sd is 0.05% per pair — lower than the
  single-run gate's own rate — and catches ~9 pp. `perf_compare.py --prev` does
  that check, `bench/fetch_prev_perf_summary.sh` feeds it the previous green
  master run's summary out of the artifact this job already uploads (CI keeps no
  state between runs, but it keeps artifacts), and every failure path there
  degrades to "no previous run" rather than reddening the job. Checked against
  the 24 recording runs: 1 single excursion past 2 sd in 72 metric-runs and no
  consecutive pairs at all. The `perf-smoke-report` artifact also stopped
  carrying the whole checked-in `bench/log` tree — ~200 MB a copy, of which every
  consumer reads one file; it is now this run's own JSON under `bench/log/_run/`.
  `bench/log/linux/2026-09-13-perf-gate-flip/FINDINGS.md`

- **The perf baseline is recorded on the layout that ships.**
  `bench/baseline/perf_smoke.json` was taken on the header layout hours before
  the headerless flip, so `perf_compare.py` had been printing `STALE:` and
  refusing to gate on every run since — the control working, and the re-record
  it asked for is here: 23 green master runs on `ubuntu-latest`, from the
  artifacts the perf job already uploads. Not the ten the note planned, because
  ten under-sampled the runner: the first ten read the `/json` throughput spread
  as 96.6-105.2 and the thirteen after them ranged 93.9-108.4, which would have
  left the gate 0.94 pp from a false alarm on a run that had already happened.
  `pct_json` 99.7 ±9.9, `rss_x` 0.947 ±0.1115, `pause_p50_ms` 0.6399 ±0.2, no
  metric self-firing on any of the 23 (the previous file's `rss_x` fired on 1 of
  10) and leave-one-out green 23 of 23. Gating on it is still off, now for an
  arithmetic reason rather than a judgement call: the three gates sit 2.16-2.50
  sd out, 3.2% per run combined — one false red every ~31 runs.

- **`perf_compare.py` no longer denies the baseline it just used.** `baseline:
  none recorded yet` was the fall-through of the staleness chain, so it printed
  under every non-stale comparison; every baseline that had shipped was stale,
  so no green path had ever reached the line. The first fresh baseline printed
  its own provenance and then reported none existed. `make perf-baseline` gained
  the fixture for the converse, red against the pre-fix report.

- **The headerless layout is the compile default.** Small blocks are carved
  back-to-back with no 16-byte `BlockHeader` in front of each object; size and
  kind come from the chunk, marks and occupancy from its bitmaps, and large
  objects keep their header inside the chunk's metadata region. The
  representation shipped opt-in (`-Dgcry_headerless`) in 0.22.0 and has run
  its own unit, process, ASan, Darwin, aarch64 and Windows CI arms since;
  what changes here is the polarity of the flag. Measured on the five-arm
  paired Kemal `/json` run that decided the 0.24.0 bitmap default
  (`bench/log/linux/2026-09-06-bitmap-default-ab/`, 20 rotated rounds,
  identical-binary null control, Ryzen AI 9 465): headerless **112.6%**
  [106.6, 118.6] of Boehm at **1.07×** its peak RSS, 1.1 minor faults per
  1 000 requests, 69.0 CPU ms per 10 k requests, p99 2.21 ms — against the
  header layout's 105.3% [99.2, 111.3] at 1.30×, 2.7 faults, 74.6 ms and
  2.36 ms on the same binary tree. Peak RSS 31.2 against 37.5 MB (−17%),
  post-GC the same, both flat. Darwin, same protocol
  (`bench/log/macos/2026-09-06-bitmap-default-ab/`, Apple M2 Pro): 101.9%
  [100.9, 103.0] at **1.50×** peak footprint and **0.99×** post-GC resident
  against the header layout's 101.8% at 1.97× and 1.20×. The per-object
  saving is the header itself: 1 M live 16-byte objects, chain walked after
  the collection, 34.9 → 19.3 MB (**−44.5%**; 32 B −31.2%, 64 B −19.2%,
  128 B −10.8%, `bench/log/linux/2026-09-03-phase7-headerless-rss/`). The
  5-hour soak passed on the layout (+3.2 MB against a 4 MB bound, 0
  errors). What the layout gives up, unchanged from its opt-in days: the
  bitmap allocator is forced on (no freelist), the nursery is off and
  `GCRY_NURSERY` ignored (it was already off by default because it is
  unsound), `GCRY_CHUNK_BYTES` is exact to 51.2 MiB rather than 86.3, and
  the SegvReport cannot name the free path for a swept block. CI: the plain
  spec, process-spec, sample and gate runs on every platform now build
  headerless; the header layout keeps arms on both allocators (Linux,
  aarch64, Darwin, Windows x86_64 and ARM64 `headers` / `freelist`
  variants, ASan), and the env-knob smoke exercises the nursery, freelist
  and TLAB knobs on the layout that reads them, and the gates whose control
  arm pins a header-layout knob — `heap-counters` (plain counters),
  `poison-freed` (freelist arms), `darwin-bitmap-page-release` (`--headers`)
  and the sound-profile smoke (`GCRY_NURSERY`) — build that arm with
  `-Dgcry_block_headers`, so the knob is read rather than silently ignored.
  `bench/baseline/perf_smoke.json` was taken on the header layout hours before
  this flip; the re-record it asked for happened before the release rather than
  after it, on 48 green headerless master runs — see the perf-baseline entry
  above. Its provenance note now carries the standing rule instead of a
  pending obligation: re-record on the next layout or allocator flip.

### Fixed

- **A Darwin crash on a poisoned pointer read as a null dereference, and
  now does not.** The report looks for gcry's freed-block poison in the
  faulting GP registers. Linux reads them from glibc
  `ucontext_t.uc_mcontext.gregs`. Darwin STW uses `thread_get_state`, and
  a SIGSEGV hands a `ucontext_t` whose `uc_mcontext` is a pointer to a
  `__darwin_mcontext64` that prefixes those GP words with the exception
  state — so the Linux offsets do not apply. Until now the reader was
  Linux-only and `si_addr == 0` was the whole diagnosis. Offsets from
  XNU; writer frames follow. `make segv-report` on Darwin CI.

- **A pointer held only in a main-thread `@[ThreadLocal]` was collected
  on Darwin and Windows, and now is not.** Linux closed this on
  2026-09-12 by adding the live TLS block to the static roots, sized
  from `PT_TLS`. The other two platforms had the same hole in different
  costumes. Darwin: the dyld walk skips TLS sections because they are
  the *template*, `_tlv_bootstrap` allocates the live block with libc
  `malloc` into memory that is in no `__DATA` section, and the main
  thread's stack scan does not cover it — sized from `__thread_data` +
  `__thread_bss`, clipped with `mach_vm_region`. Windows: `.tls` is the
  template and the live block is per thread through the TEB; the PE
  walk now skips the template (so the red arm can lose it on the main
  thread, which uses the template in place) and the live range is sized
  from the TLS directory, clipped with `VirtualQuery`. `make tls-roots`
  is the gate; the Darwin job and the Windows default variant run it.

- **`make page-release-corruption` had stopped testing anything, and now
  refuses to build that way.** Both free-page release walks are
  freelist-shaped and stand down on bitmap-allocated chunks, so the gate's
  three arms pin `GCRY_BITMAP_ALLOC=0` to get the freelist back. Since the
  headerless layout became the compile default that knob is ignored — there is
  no freelist to return to — and every arm reached nothing: `unlinked 0` on
  the HOLED arm in **4 of 4** runs, the mostly-empty arm at 0-11.8 MB against
  its 16 MiB engagement floor. The harness's own engagement checks caught it
  (they exist because a walk that never ran looks exactly like a walk that
  found nothing wrong), but a gate that cannot run on the layout it is built
  for should say so at the build: it is compiled `-Dgcry_block_headers` now
  and `{% raise %}`s otherwise. On that layout it engages as its history
  describes — 11 674-12 904 page runs unlinked, 60.3-68.7 MB released by the
  mostly-empty walk — and is clean, **0 of 24 per arm across six runs**.

- **`make live-graph-audit` had rotted the same way, and a check now covers
  the class.** Same cause — its arms pin `GCRY_BITMAP_ALLOC=0` for the same
  walks — and the same symptom, `walk 0 B` on both walking arms while the
  workload churned normally. Built `-Dgcry_block_headers` it engages (HOLED
  109.8 MB, mostly-empty 87.2 MB through the walk) and passes **0 of 6 per
  arm**: every edge and every node survived. `make layout-knob-check` now
  fails the build when a gate pins a knob the compile default ignores
  (`GCRY_BITMAP_ALLOC=0`, `GCRY_NURSERY`, `GCRY_TLAB` — read out of
  `gc_override.cr`'s warning block rather than hard-coded) without building
  the layout that honours it. Two rules, both observed red: the harness that
  pins it in its own arms, and the recipe line that sets it before running a
  binary built the wrong way, which is how `make heap-counters` and `make
  poison-freed` could regress — each keeps a headerless binary beside the
  header one.

- **The open "unresolved corruption under concurrent stress" is closed by
  re-measurement.** Its two symptoms were the `mt-property-test`
  `reported=98 walked=233` counter gap and the page-release HOLED arm faulting
  1-3 of 4. On the current tree the MT property test is **0 failures at 500
  iterations on 2, 4 and 8 workers**, and the page-release faults belonged to
  the withdrawn `occ`-built live-mask experiment — the walks stand down on
  bitmap chunks and that arm no longer exists. The step the item asked for
  last (does the class lock serialise the streaming sweep's `occ` word against
  every path into `bitmap_alloc_locked`) was answered on 2026-09-12 with
  `GCRY_SWEEP_OCC_AUDIT=1`: 0 dead words with a cursor mid-allocation over
  71 325 published words.

- **A crash-report line longer than its own buffer smashed the stack instead
  of being truncated.** `RawOut.append` stops at `LIMIT` (480 B) and is handed
  a bare pointer, so it cannot see where the caller's array ends: a buffer
  below `LIMIT` is not a short line, it is a write into the frame around it.
  The report's new kept-release line is **377 bytes and its buffer was 256**,
  and the 121 bytes past the end took out `occ` first — the line then said
  "a mutator took one" two clauses after printing "0 block(s) allocated" — and
  the return address next, so the report exited at 0x0 **inside itself with
  the description of the fault it had been called for still unflushed**. One
  ledger line printed; everything the reader needed did not. Thirty-two other
  buffers were under `LIMIT` at that moment, two of them already able to run
  past their end: `collect_scan.cr`'s index/list disagreement line is 417
  bytes with every number at full width against a 352-byte buffer, and 349 on
  an ordinary mapped chunk — three bytes of margin. All thirty-three are now
  `UInt8[RawOut::LIMIT]`, and `make raw-buf-check` fails the build on a buffer
  smaller than the writer that fills it, including for the two hand-rolled
  writers that predate `RawOut` (`EcQueueAudit` 300/320, `StwWatchdog`
  250/256, both already sound). The gate that found this passed while it was
  happening, because it only asked for the line: it now also fails on a report
  that faults inside itself, on a kept-release line with no fault description
  after it, and on a block count that contradicts the knob that produced it.

- **A chunk could be released with a live block in it, and now the flush
  refuses.** One of the overnight CI runs faulted in `make thread-churn-uaf`'s
  guarded arm, and the report — readable for the first time, because the release
  ledger had just been hoisted above the heap-span test — said `in a chunk gcry
  RELEASED [...] empty size-class chunk release, at collection 206 [...]
  **Blocks still allocated at release: 1**`, with `Collections since: 0`. That
  count is a popcount of the occupancy bitmap at release, so it is a live block
  inside memory the collector gave back rather than a stale pointer into
  legitimately freed memory. The window: the sweep unlinks an empty chunk from
  `@chunks` inside the stop and queues it, its index entry survives until the
  post-STW flush removes it, the allocator resolves pooled chunk addresses
  through that index, and a chunk whose blocks are all free is a legal
  allocation target — so a mutator can take a block out of a chunk already
  queued for unmapping. The flush now re-reads occupancy immediately before
  releasing and keeps an occupied chunk mapped, putting it back on the live
  list; `release_flush_chunks` and `release_refused_occupied` make the state
  legible, and `GCRY_EMPTY_FLUSH_DELAY_MS` / `GCRY_RELEASE_OCCUPIED=1` are the
  research knobs that widen the window and restore the old behaviour. It does
  not reproduce on an 8-core host and the counters say why — with several
  mutators alive the sweep queues nothing at all (0 chunks considered in 120
  collections; 37 in 30 single-threaded ones), so the window needs both the
  single-mutator sweep path and a mutator running at flush time.
  `bench/log/linux/2026-09-14-occupied-release/FINDINGS.md`

- **The crash report excluded the one mechanism it was built to name.**
  `GCRY_UNMAP_GUARD=1` keeps a released chunk mapped as `PROT_NONE` and records
  base, size, release path, collection, first user word and blocks still
  allocated at release — and the report asked that ledger only for addresses
  *inside* the heap span. `heap_span_hi` is the top of the live chunks, so
  releasing a chunk is precisely what moves its address out of the span, and the
  guard then reserves that address so nothing can map over it: a fault there is
  expected to be out of span. Those faults ended on "never a gcry allocation, so
  a swept object is not the explanation", which excludes the mechanism by name.
  Seen overnight on 2026-09-13 under load: `make thread-churn-uaf`'s guarded arm
  faulted 1 of 24 on two consecutive runs, 3.8 MB above the span end, and the
  report said that sentence both times. Both branches now ask one helper.
  `make released-range-report` covers the half a harness can build — a fault
  into a guarded release must be named — and the findings record why the
  out-of-span half cannot be built synthetically, which is three facts about the
  allocator rather than a missing test.
  `bench/log/linux/2026-09-13-released-range-report/FINDINGS.md`

- **The crash report was dying inside itself, and had 4 720 bytes to work in.**
  `make poison-holders` went red on the x86_64 CI runner three times in two days,
  always printing the holders header and then nothing, which read as a search
  that found nothing — and a re-run of the same commit was green each time. It
  was the alternate signal stack: Crystal's is 8 192 bytes and 3 472 are already
  spent when the handler is entered, leaving 4 720 for a report that walks the
  explicit root set, every live block and every fiber stack, each frame carrying
  a line buffer, and then asks the same three questions of the holder it found.
  Two structural reasons nothing said so: SIGSEGV is blocked inside its own
  handler, so a synchronous fault there is a silent kill rather than a second
  delivery, and nothing recorded which section the search was in. gcry now
  installs its own **256 KiB** alternate stack, sets `SA_NODEFER` so the handler
  can be re-entered, and stamps the section — so a fault inside the report now
  prints `while searching the heap walk` instead of vanishing.
  `GCRY_POISON_HOLDERS_FAULT=1|2|3` breaks it on purpose at each section and is
  now a `make poison-holders` arm: with the fix each names itself, and a tree
  missing any of the three parts dies at `rc=139` naming nothing.
  `GCRY_SEGV_REPORT_STACK=1` prints the margin that turned "it dies when you add
  a call frame" — recorded here twice, in August and September — into a number.
  Also: a class variable whose initializer *references a constant* gets a
  lazy-init guard, and writing one from `GC.init` faults before the runtime can
  print anything; the new stage byte is initialised with a literal for that
  reason, and every knob read from `GC.init` wants the same care.
  `bench/log/linux/2026-09-13-report-stack/FINDINGS.md`

- **A pointer held only in the main thread's thread-local storage was
  collected.** `dl_iterate_phdr` gives the executable's writable `PT_LOAD`
  segments, which is every class variable, but a `@[ThreadLocal]` is in none
  of them: `PT_TLS` is only the template and the live block is allocated per
  thread. glibc puts a *spawned* thread's block at the top of that thread's
  own stack mapping — inside the bounds `pthread_getattr_np` reports and above
  the suspend SP — so the ordinary stack scan has always covered every thread
  gcry or a Crystal program spawns, which is why this went unseen. The main
  thread's block is allocated with the shared libraries, nowhere near its
  stack, and nothing scanned it. It is now a root range, resolved at `GC.init`
  on the main thread and sized from the executable's own `PT_TLS` `p_memsz` —
  128 bytes on the harness, against the 824 KiB containing mapping a first
  version took. `GCRY_TLS_ROOTS=0` restores the old behaviour as the red arm
  of `make tls-roots`. Linux only; Darwin and Windows are unmeasured and named
  on `ROADMAP.md`. This is the third branch of what `GCRY_POISON_HOLDERS=1`
  reports on a use-after-free and the only one that had not been tested; it is
  **not** the open live-large-object release, whose rate it does not move.
  `bench/log/linux/2026-09-12-tls-not-a-root/FINDINGS.md`

- **`make static-bss-roots` was green for a reason it does not test.** Its
  victim block was filled with `0xC7`, so its first `Int32` reads negative —
  and `type_id_plausible?` refuses a *static* root whose first word is not a
  dense positive integer. The BSS root the gate exists to prove was therefore
  rejected by the root filter on every run, and the block survived on an
  ungated conservative copy instead: a callee-saved register holding the
  address across `wipe_stack`. Adding one more static root range was enough to
  change the register pressure and turn the gate red, which is how this was
  found. The block now carries a real instance id in its first word and `FILL`
  from the fifth byte on, so the accepted root is the BSS slot; the `--cap`
  arm still goes red.

- `ci/windows.ps1` gives each `crystal spec` invocation its own
  `CRYSTAL_CACHE_DIR`. Two invocations per job shared
  `<cache>/crystal-run-spec.tmp.exe`, and on the ARM64 runner the compiler's
  delete of it raced a lingering handle — failing two of four master runs on
  2026-09-10 *after* the specs reported `0 failures`, and reporting as a
  Crystal compiler bug.

- The mutation gate covers the headerless layout: writing the header that no
  longer exists, and freeing a block without clearing its occupancy bit.
  12/12 killed; before this no mutant touched the layout that is now the
  compile default.

- The perf-smoke baseline is re-recorded on the bitmap allocator default
  (`bench/baseline/perf_smoke.json`, ten green master runs). The previous one
  was taken on the freelist default before 0.24.0, so it read every current
  run as an RSS regression — 5 of 10 replayed runs fail `--gate` against it,
  none for a real regression. `pct_json` now gates 23.8 pp above the fixed
  floor; `rss_x` is documented as report-only until it has more samples.

- The conservative root scan is asserted to visit every pointer-aligned word
  of a range (`spec/scan_completeness_spec.cr`). Stepping its cursor two
  words at a time passed all 291 pre-existing examples, and a root the scan
  skips is an object freed while live. The mutation gate's mutant 09 is that
  perturbation; four of its ten mutants had also stopped matching the source
  and were silently unmeasured (`bench/mutations/README.md`). 10/10 killed.

- **An unanswered suspend signal is re-sent, and a per-thread stop epoch is
  what makes that safe.** `stop_world` spun `until thread.@suspended.get`
  forever when a mutator never acknowledged: six of forty runs of the aarch64
  native job ended at the 20-minute job timeout there, and a job timeout
  reports as *cancelled* rather than failed, so none of them read as a defect
  until the watchdog named `phase=suspend`. Re-sending is the repair
  `start_world` already makes for resume, and it had been refused twice
  because `SIG_SUSPEND` is blocked for the whole handler and inside
  `sigsuspend` — a redundant one stays pending and lands *after* the thread
  resumes, suspending it again with nobody left to wake it.
  `Gcry::Platform`'s stop epoch closes that: 0 when no stop is in progress,
  the stop's id while one is, stamped per thread in the `pthread_t`-keyed
  slot table, so the handler serves each stop once and declines every
  duplicate. The wait then resends every `GCRY_STW_RESEND_SPINS` (20 M spins,
  ~a tenth of the stall report) up to `GCRY_STW_RESEND_LIMIT` (16), and past
  the limit asks `pthread_kill(id, 0)`: on `ESRCH` — the handle names no live
  thread, so nothing can mutate the heap through it — the stop prints
  `SUSPEND ABANDONED` and proceeds instead of spinning out the job. Any other
  answer keeps waiting, because skipping a live thread would stop a world
  that is still running. `make stw-epoch` has six arms, three red on purpose:
  no resend hangs on a dropped signal, `GCRY_STW_EPOCH=0` hangs on the
  duplicate, and a thread that ignores every signal while its handle is live
  hangs either way — the honest limit, since this repairs a lost delivery and
  not a thread that cannot run its handler. `SUSPEND STALLED` now carries
  resends unanswered, handler entries and declines split stale/redundant,
  which is what tells those two apart in the next sighting.
  `bench/log/linux/2026-09-12-stw-stop-epoch/FINDINGS.md`

- **Two threads could share one slot of the suspend-time SP and register
  table**, so one thread's stack was scanned from another's stack pointer and
  its registers were the other's registers — a missed root in the one table
  the conservative scan trusts to be per-thread. Two causes, both latent since
  the table existed, both found by the epoch turning a shared slot into a
  hang: the claim's `Atomic#compare_and_set` result was never checked (it
  returns `{old, success}`, a tuple, which is always truthy, so every thread
  signalled in one stop claimed the same bit), and `clear_thread_sps` cleared
  the claimed mask, the SPs and the register rows but left the `pthread_t`s —
  and because a claim publishes its bit before writing its id, a peer could
  match a slot another thread had just taken, on its own handle from the
  previous stop. Observed as three threads in `rt_sigsuspend` and one spinning
  on a first collection, and as `find_block_race --child alloc` hanging under
  `GCRY_INDEX_AUDIT=1`; 0 of 3 after the fix, all four `find-block-race`
  workloads green with both control arms still crashing. Whether either
  explains an open CI sighting is not claimed.

- **The suspend handler allocated a `Thread` — from inside a signal handler,
  with the world stopping — and acknowledged into it.** Crystal's
  `Thread#start` pushes itself onto `Thread.threads` *before* it sets that
  thread's TLS, so `stop_world` can signal a thread that has no
  `Thread.current` yet; Crystal's accessor creates one on a miss, allocating
  a `Fiber` and a `Thread` and pushing it onto the very list the collector
  holds the mutex for. The handler then set `@suspended` on that **second**
  object rather than the one on the list, so the collector spun forever for a
  thread that had already suspended itself — `phase=suspend`, one thread
  unacknowledged, `pthread_kill(id, 0)` reporting the handle live, handler
  entries incremented. The acknowledgement now lives in the `pthread_t`-keyed
  slot table, which the collector reserves for every thread before it signals
  anyone, so the handler touches nothing Crystal owns; reserving up front also
  keeps the CAS claim off the handler and lets the wait spin on an array index
  instead of a 64-slot scan. `Thread#@suspended` remains the fallback for a
  table that was full *and* a thread that already has a `Thread`; a delivery
  that can use neither declines to suspend rather than freezing with no way to
  say so, counted in `stw_suspend_ack_unavailable`. `make stw-ack-window`
  drives it deterministically with a raw pthread, which has no TLS by
  construction: shipped `acked=true listed_delta=0`, the restored pre-table
  path `acked=false listed_delta=1` — that `1` is the `Thread` the handler
  allocated. `stw_suspend_no_tls` counts real deliveries that land in the
  window and is on `/gc-stats`; it is 0 on this box over 1 800 thread births,
  which is reported rather than read as safety. Whether this explains any
  aarch64 timeout is not claimed.

- **A birth root was never released for a short-lived thread.** It ended only
  when `stop_world`'s pre-suspend walk found its thread on Crystal's list,
  and a thread that publishes *and exits* between two collections is never on
  that list when the walk runs. Once 64 of those had accumulated the table
  was full and every further birth took the overflow path, which roots and
  can never release: over 3 203 short-lived threads, `outstanding` **3 197**
  and `overflows` 3 133, each pinning a `Thread`, its `@func` closure and its
  main `Fiber` for the life of the process. The root now spans the thread's
  life — armed at `pthread_create`, released a collection after its death is
  observed through the `pthread_detach` / `pthread_join` hooks, or at once
  when glibc hands its handle to a new thread, which is proof the previous
  owner is gone. The hooks mark before their real libc call, so a mark cannot
  land on a slot a later birth has reused. The table is sized for live
  threads (64 → 256) rather than unpublished ones. `make thread-birth-root`
  gains a `--churn` arm: 960 short-lived threads leave `outstanding` 4 and
  `overflows` 0, against 961 and 705 with the old policy restored via
  `GCRY_THREAD_BIRTH_DEATHS=0`.
  `bench/log/linux/2026-09-12-thread-life-root/FINDINGS.md`

- **The staged-thread table's occupancy could drift and never recover.** It
  was a `Bool` array beside a plain `Int32` counter maintained with `+= 1` /
  `-= 1` from creating threads and the collector. Lost updates drifted the
  counter upward, and `wait_for_staged_threads` loops `while staged_count >
  0` — so a counter stuck above zero over a table with nothing in it made
  every stop spend its whole spin budget and report a timeout. Occupancy is
  now an atomic bitmask and the count is derived from it; a lost bit is a
  stale entry the next drain clears, where a lost counter update was
  permanent.

- **A reproducer for the thread *death* window**,
  `GCRY_THREAD_UNSTAGE_ON_DEATH=1`, off by default. `Thread#start` removes a
  thread from Crystal's list before its last instructions, so a dying thread
  is neither suspended nor scanned while still dereferencing itself. The
  window has been masked by the staged wait's 2 000-spin timeout, which sits
  exactly between a thread detaching and the world stopping around it;
  dropping a dead thread's staging record removes the mask and crashes 7 of
  40 runs of 960 short-lived threads, against 0 of 40 before and 0 of 40 for
  a pure delay in the same place. `GCRY_POISON_HOLDERS=1` names a
  use-after-free on a 16-byte block with no holder anywhere; rooting every
  `Thread` for its whole life does not fix it, so the victim is not the
  `Thread`. The defect stays open — it now has a reproducer that fires in
  seconds.

- **A reproducer for the live-large-object release**, `make
  thread-churn-uaf`. The defect has been open since 2026-08-23 — a
  large-object chunk released by the large-object path and written into
  afterwards, with no heap object holding it — and it had *lost* its
  reproducer: found under `wrk` against a real application at about one run
  in eight, then silent, with the roadmap noting that until it reproduces at
  a resolvable rate no arm means anything. It needs no application: eight
  short-lived threads per round, one collection per round, about a second per
  attempt, and it fires on **both** object layouts with nothing set — 14 of
  942 headerless, 16 of 924 on block headers. `GCRY_UNMAP_GUARD=1` names the
  chunk (212 992 bytes, large-object release, the write 48 bytes in every
  time) and `GCRY_TRACE_LARGE=1` ties it to its allocation (mapped at
  collection 94, released at 96, written 109 collections later). Three arms
  per layout reporting a rate rather than gating, with the highest-rate arm
  asserted non-zero so the reproducer cannot be lost silently a second time.
  The ordering was initially unclear — a failing run usually raises something
  first, and Crystal's backtrace printer then allocates hundreds of
  kilobytes — and is now settled: on the arm without poison the fault report
  is the **first** line of the child's stderr, so the released chunk is the
  primary event and not the printer's buffer.
  `bench/log/linux/2026-09-12-thread-churn-large-uaf/FINDINGS.md`

- **The live-large-object release is localised to the post-STW sweep, and
  this item's own hypothesis is retired.** With the reproducer above the knob
  matrix becomes a bisect: 36 attempts per configuration, baseline 25 of 36,
  and `GCRY_SOUND=1` — every conservatism gcry has — changes **nothing**
  (25/36). Neither does removing the pagemap low-water skip, the SP clamp or
  the parked-fiber lag. So it is **not** a missed stack or register root; the
  standing reading since 2026-08-23, inferred from a mark audit reporting 0
  edges, never followed (0 edges is exactly what a stack-rooted buffer looks
  like). Two configurations take it to zero: `GCRY_BITMAP_ALLOC=0` (0/36) and
  `GCRY_DISABLE_LAZY_SWEEP=1` (0/36). Both point at `sweep_after_world?`,
  which restarts the world and then rebuilds `@chunks` and unmaps empty
  chunks on the assumption that it is the sole mutator. Both release paths do
  it — the large-object release and the empty size-class chunk release — and
  the fault report is the **first** line of a failing run's stderr, so it is
  the primary event rather than the backtrace printer's buffer.
  `GCRY_DISABLE_LAZY_SWEEP=1` is a one-variable mitigation for anyone hitting
  this; whether it should become the default waits on measuring the pause
  cost of dropping it. Three fixes were attempted and withdrawn with their
  numbers recorded so they are not re-spent.

## [0.25.0] - 2026-09-09

Minor release: **gcry runs on Windows.** Native x86_64 (MSVC) and ARM64
(GNU/MinGW) process GC, `require "gcry"` + `-Dgc_none` as on Linux and macOS,
with six native CI jobs covering the bitmap, freelist and headerless
allocators. The rest is the bitmap allocator's handoff races closed to
the last one, a Windows stack-scrub defect the new CI found on its own
first day, and the ARM kernel backends measured on real hardware.

### Added

- **Native Windows process GC — x86_64 and ARM64** (#38, stakach). The
  backend is `VirtualAlloc`/`VirtualFree` for chunks (decommit + recommit for
  page release, whole reservations only), writable PE sections of the main
  image for static roots, `SuspendThread` + `GetThreadContext` for the
  stopped world with integer and SIMD registers captured as roots, SRW locks
  and FLS for the collector's mutexes and cursor TLS, and
  `CREATE_SUSPENDED` thread creation so a new thread is rooted before it can
  run. Stopped-world diagnostics write through `WriteFile` on the stderr
  handle, never the CRT lock a suspended mutator may hold; root scans and
  the dead-stack scrub walk `VirtualQuery` regions and leave `PAGE_GUARD`
  intact. A failed suspend or capture resumes every thread already stopped
  and raises without allocating until the collector's locks are released — a
  process-level regression with 65 workers found and closed a re-entrancy
  hang in that path. Limits, documented in `docs/WINDOWS.md`: 64 peer
  threads per collection; no fork, Unix signal diagnostics, soft-dirty or
  mprotect barrier; research stack maps ignored; per-thread native TLS is
  not a root (same policy as Linux/macOS); no Windows throughput numbers
  yet. CI: `windows-latest` (MSVC) and `windows-11-arm` (Crystal's
  unsupported ARM64 GNU archive, pinned by SHA-256, MSYS2 CLANGARM64
  linker) × default/freelist/headerless, unit + process specs + optimised
  samples.

### Changed

- The SVE backend runs `range_any?` on the vectorised NEON body: the
  predicated SVE loop measured 21.9 GB/s against 45.3 on a Neoverse-N2
  (`bench/log/linux/2026-09-08-neon-sve-ab`). The same session, the first
  native ARM reading, confirms the vectorised NEON backend over #36's
  assembly for the reductions (2.1× and 1.7×, sweep at parity, popcount 13%
  behind) and SVE2 at parity with SVE.
- README and PERF.md carry the 0.24.x bitmap-default numbers: Kemal `/json`
  105% of Boehm at 1.30× peak RSS on Linux, 102% at 1.97× on macOS. The
  heuristics section and pause table are re-cut on the same default
  (`bench/log/linux/2026-09-08-heuristics-ab`): `GCRY_SOUND=1` is free on
  one mutator thread (117% vs 110.5% of Boehm, identical RSS and pause) and
  halves throughput under EC4 through an 8× pause. That EC4 pause is
  attributed (`…/2026-09-08-ec4-root-phase`): 98% is the parked-fiber lag
  scan, ~8 MB of stack words per collection at 100 connections, growing
  with stack-pool reuse — now a concrete roadmap item.

### Fixed

- **Bitmap-pool handoff races** (#39, stakach). A cached pool probe read a
  chunk header after the index lookup released its lock, so a concurrent
  trim could unmap it in between; and every path that handed a chunk to the
  allocation cursor — cached pop, overflow fallback, dormant revival, fresh
  `map_chunk` — did so before setting the `CURSOR` flag, leaving a window
  in which the in-STW sweep (which ignores the mutator's class lock) could
  reclaim the chunk as empty. Probes now hold the chunk-list lock through
  the header read, and ownership is claimed wherever a chunk is obtained,
  before the protecting lock is released: revive sets cursor before
  clearing dormant, fresh chunks are mapped with `CURSOR` set. Four new
  `make chunk-search-race` arms are red against 0.24.1 (three `SIGSEGV` at
  header+0x14, one "sweep reclaimed a chunk during revival") and green here.
- Windows stack scrubbing walks `VirtualQuery` regions down to the wipe
  floor (#40). Windows reports the committed stack as several regions with
  identical state and protection, so a single query's `baseAddress` could
  sit a few KiB — or zero bytes — below SP, and `clear_stack` /
  `collect_scrub` wiped that much instead of the requested budget. Found by
  the new Windows CI as `spec/stack_scrub_spec.cr` counting no scrub.
- The stack-scrub re-entrancy guard is thread-local; as a process-global
  flag it made one thread's scrub silently skip while any other thread was
  mid-scrub.

Upgrading: no API change. `GCRY_SIMD` accepts `sve`. Windows: build with
`crystal build -Dgc_none app.cr` from a PowerShell with Crystal's MSVC
toolchain; see `docs/WINDOWS.md`.

## [0.24.1] - 2026-09-08

Patch release. **The bitmap allocator that 0.24.0 made the default could
crash a multi-threaded process** (#37, same family as #29): the search that
rebuilds a size class's pool index walked the chunk list without the
chunk-list lock, so a concurrent large-cache trim or the post-collect
empty-chunk flush could `munmap` the chunk it was standing on — `SIGSEGV`
at a page-aligned address inside the heap span, in no live chunk. The
reporter's program crashes 0.24.0 in 2–3 minutes at 32 threads and ran
clean for 2 × 20 minutes on this tree. Fixed by #36 (stakach), which also
found that the whole-header flag setters could restore a removed list link.

With it come #36's kernel backends, kept where they measured at least at
parity and returned to the compiler where they did not
(`bench/log/linux/2026-09-07-kernel-backend-ab`). No default-configuration
collection behaves differently from 0.24.0; `GCRY_BITMAP_ALLOC=0` remains
the freelist escape.

Upgrading: no API change. `GCRY_SIMD` accepts `sve`.

### Fixed

- **Allocation searches raced with large-cache trimming and the post-collect
  empty-chunk flush** (#37, #36): a search could dereference an unmapped
  chunk, and whole-header flag updates (`set_dormant`, `set_cursor`, …)
  copied the header back and could restore a removed `next` link. Searches
  now hold `@chunk_list_lock` (bypassed only by the stopped-world owner, as
  `chunk_containing` already does), deferred small-chunk release waits for
  those readers, and flag/link updates address individual fields with atomic
  RMW. `make chunk-search-race` (3 scheduled searches + a stopped-world lock
  check) and `spec/chunk_field_race_spec.cr` (7 examples) are red against
  0.24.0 and green here.
- The bitmap allocation pool grows its address index outside the chunk-list
  spinlock instead of calling `mmap` while holding it.

### Changed

- Select an allocation-free abstract kernel backend once per heap instead of
  passing a numeric SIMD tier through every bitmap operation (#36). Kernel
  bodies now live under `src/gcry/kernels/`. The AVX2 sweep is hand-written
  assembly (VPSHUFB nibble popcount in vector registers); every other x86
  kernel stays on LLVM's vectorised loops, which beat the single-accumulator
  assembly on Zen 5 by 21–52% in L2
  (`bench/log/linux/2026-09-07-kernel-backend-ab`). AArch64 gains an SVE
  backend (predicated, vector-length-agnostic assembly) selected from Linux
  `AT_HWCAP`; NEON remains the compiler-vectorised baseline. `GCRY_SIMD`
  accepts `sve`.

## [0.24.0] - 2026-09-06

Minor release, and the one that changes what the default build allocates
with.

**The bitmap allocator is the process default.** What 0.23.0 shipped behind
`GCRY_BITMAP_ALLOC=1` — `occ` bitmaps, the streaming `occ &= mark` sweep,
per-thread cursor sets, the adaptive threshold and the warm-chunk budget —
is now what `-Dgc_none` runs. The decision is a five-arm paired Kemal
`/json` run with an identical-binary null control, on Linux and then on
Darwin. Linux: the freelist default was **74.9%** of Boehm at 1.87× its
peak RSS with 1 671 minor faults per 1 000 requests; the bitmap allocator on
the same header layout is **105.3%** [99.2, 111.3] at 1.30× with 2.7 faults
and 15% less CPU per request. Darwin: **101.8%** [100.5, 103.1] against the
freelist's 85.5%, 0.8 faults against 344 — at 1.97× Boehm's peak footprint
against 1.78×, because both arms sit at the 16 MiB Darwin threshold floor
and the warm budget is the difference. `GCRY_BITMAP_ALLOC=0` is the escape
and keeps its own process-spec arm in CI on every platform; library heaps
(`Gcry::Heap.new`) stay on the freelist unless `=1`. An explicit
`GC.collect` now releases the warm chunks, so post-collect RSS is the live
footprint again.

**One more root the `--release` build needs.** 0.23.0 resolved interior
pointers; this release also scans misaligned candidate words
(`scan_unaligned_candidates`, on for the process heap): a byte-wise loop
over a `Bytes` buffer reduces to a raw pointer that is word-aligned one time
in eight, and the alignment filter dropped the only root — SIGSEGV 3 of 3
with a 1 MiB buffer under churn. +4.3% of root work. Both gates
(`make interior-only-buffer`, `make unaligned-only-buffer`) run in CI with
their red arms.

Also here: the six fixes the PR #34 review carried over — five under the
allocator that is now the default, one in the initial thread's stack
bounds, each with a spec that is red without it; #35 (cursor-set metadata
exhaustion reported as OOM rather than a null dereference, stakach) is one
of the five — and `GCRY_INCREMENTAL=1` documented as unsound with more than
one mutator thread.

Upgrading: no API change. One knob removed (`GCRY_UNALIGNED_CANDIDATES=1`,
now the default) and one added in its place (`GCRY_ALIGNED_CANDIDATES=1`);
`GCRY_BITMAP_ALLOC=1` is now what the process heap does on its own, and `=0`
is the escape. If a workload's RSS matters more than its throughput, `=0` is
where to start; under the default, `GCRY_THRESHOLD_FACTOR` is the lever.

### Changed

- **The bitmap allocator is the process default.** `GCRY_BITMAP_ALLOC=0`
  restores the freelist; library heaps (`Gcry::Heap.new` outside
  `-Dgc_none`) keep the freelist unless `=1`, so the unit suite covers both
  by construction. Decided by a five-arm paired Kemal `/json` run with an
  identical-binary null control at 97.5% [93.0, 102.0]
  (`bench/log/linux/2026-09-06-bitmap-default-ab/`): the freelist default
  was **74.9%** of Boehm at **1.87×** its peak RSS with **1 671** minor faults
  per 1 000 requests and 29% more CPU per request; the bitmap allocator on
  the same header layout is **105.3%** [99.2, 111.3] at 1.30× with 2.7 faults
  and 15% *less* CPU — 141.9% [132.1, 151.6] of the old default at 0.69× its
  peak, with p99 6.4 → 2.4 ms. The remaining RSS above Boehm is the
  warm-chunk budget, a policy knob; headerless with the same policy sits at
  1.07×. On acikturkiye (`/api/v1/`, 8 paired trials) the same default is
  **90.8%** of Boehm at 1.55× against the freelist's 80.7% at 1.47×. Cutting
  `GCRY_THRESHOLD_FACTOR` to 50 puts Kemal on the product bar (105.1% at
  0.95×) but halves the fat app's threshold too and costs it 12 pp, so the
  factor stays at 100
  (`bench/log/linux/2026-09-06-threshold-factor-ab/`). With it come the
  defaults that ride on it: the adaptive threshold
  (live × `GCRY_THRESHOLD_FACTOR`, 8–64 MiB), warm retention up to that
  threshold, per-thread cursor sets, and the chunk radix. Every Makefile gate
  passes under it (`bench/live_graph_audit.cr` pins the freelist, since both
  walks it audits are freelist paths); CI keeps a `GCRY_BITMAP_ALLOC=0`
  process-spec arm on Linux, aarch64 and Darwin. The same five arms on a
  Darwin host (Apple M2 Pro, 16 KiB pages, null at 100.9% [99.1, 102.6];
  `bench/log/macos/2026-09-06-bitmap-default-ab/`): the default is
  **101.8%** [100.5, 103.1] of Boehm against the freelist's 85.5%
  [84.6, 86.4], 0.8 faults per 1 000 requests against 344, 10% less CPU per
  request than Boehm, p99 3.0 against 5.2 ms — at **1.97×** Boehm's peak
  footprint against the freelist's 1.78× (post-GC resident 1.20× against
  1.07×). There the RSS order is the reverse of Linux: both arms sit at the
  16 MiB Darwin threshold floor, and the warm-chunk budget is the whole
  difference. Every Darwin CI gate passes under either allocator.
- **An explicit `GC.collect` releases the warm chunks.** The warm-chunk
  budget keeps emptied chunks mapped for the *next* allocation-driven
  cycle; an explicit collect (and the emergency retry before
  `OutOfMemoryError`) is a request for memory back, so it sweeps with the
  budget and the unmap grace off. Post-collect RSS is the live footprint
  again — Kemal `/json` after `/gc-collect` 15.2 MB against Boehm's 12.9
  here, where the resident warm chunks had read 1.61× on the CI runner —
  and automatic cycles are untouched. `warm_released_collects` on
  `/gc-stats`.
- **`GCRY_INCREMENTAL=1` is documented as unsound under more than one
  mutator thread.** The PR #34 review's allocation stress
  (`bench/incremental_mt_stress.cr`: cross-thread free, realloc, tagged
  blocks, a fiber forcing collections) dies in seconds with the knob on
  under `-Dpreview_mt -Dexecution_context` and four workers — SIGSEGV at
  `0x0`/`0x18` or a held block reissued — 3 of 3 on 0.23.0 with either
  allocator, and runs clean on EC1, with one worker, or without the knob.
  Off by default already; the knob table now says why, next to
  `GCRY_NURSERY`. The fix is the write barrier on the roadmap.

### Fixed

- **A live `Bytes` buffer was freed under a `--release` loop that held it
  only by a misaligned pointer.** The twin of the interior-pointer defect
  0.23.0 fixed: a byte-wise loop over a buffer is reduced to a raw pointer
  induction variable that is word-aligned one time in eight, and the cheap
  alignment filter on root candidates rejected it before `find_block` ran —
  SIGSEGV 3 of 3 with a 1 MiB `Bytes` and allocation churn
  (`GCRY_SEGV_REPORT=1`: "inside the heap span but in no live chunk").
  bdwgc resolves the same word through `GC_base`. `scan_unaligned_candidates`
  is now **on** for the process heap; `GCRY_ALIGNED_CANDIDATES=1` is the
  measurement escape and `GCRY_UNALIGNED_CANDIDATES=1` is gone. Cost at the
  collector: +4.3% of root work (SOUND-DEFAULTS, ~2 µs on a 400 µs pause);
  Kemal `/json` pause p50 0.386 / 0.390 ms and RSS 0.95–0.99× Boehm on either
  side, throughput inside this box's noise. `make unaligned-only-buffer`
  (CI) runs both arms.

Six items the PR #34 review carried over — five under the bitmap allocator,
which this release makes the default, one in the initial thread's stack
bounds; each ships with a spec that is red without it.

- **A shared cursor slot's in-flight root could be erased by a peer.** Past
  the 64th thread (or after a `pthread_key_create` failure) threads share the
  fallback cursor set, and `clear_bitmap_alloc_in_flight` stored null into
  the slot unconditionally after the class lock was released — over a peer's
  sentinel or freshly published address, the peer's only root until its
  frame holds the block. Compare-and-clear on the locked path
  (`spec/cursor_in_flight_clear_spec.cr`).
- **A cycle that began marking mid-allocation left the hit path's block
  white.** `fast_alloc` read `@incremental_marking` once, before the
  sentinel; a thread frozen after that completed its allocation unmarked,
  and the incremental cycle's finishing slice rescans dirty pages, not
  stacks. The flag is re-read after the occupancy store, as the locked path
  does; hit path cost unchanged (54–58 ns either side)
  (`spec/fast_alloc_allocate_black_spec.cr`).
- **Bitmap allocation now reports cursor-metadata exhaustion as OOM** (#35,
  stakach). If the C allocator could not create even the shared cursor set,
  the locked bitmap path dereferenced the null set (SIGSEGV at `0xb8` under
  the class lock) before its existing retry and OOM handling. It now returns
  allocation failure while holding the class lock, then retries collection
  and raises after releasing that lock. A fault-injection spec also covers
  recovery and the per-thread-set fallback (`spec/cursor_failure_spec.cr`).
- **A fork child kept a `@cursor_lock` a dead thread held, and the dead
  threads' sets.** The lock is rebuilt with the others, and every set the
  survivor does not own is marked exiting so the next stop-the-world frees
  its slot (`spec/cursor_sets_after_fork_spec.cr`).
- **`adapt_after_sweep` ran after `unlock_post_stw`**, so a peer collection
  could overwrite the live-bytes it reads before it ran; it now runs inside
  the section (`spec/adapt_after_sweep_ordering_spec.cr`).
- **The initial thread's cached stack low never followed `RLIMIT_STACK`.**
  glibc derives it from the soft limit; a program that raised the limit
  after its first collection and grew its main stack below the cached low
  had other threads' collections scan `[stale low, high)`. The soft limit is
  read at each snapshot and a change re-derives the bounds
  (`stack_bounds_main_refreshed` on `/gc-stats`). A child forked from a
  non-initial thread also drops the dead main thread's `pthread_t` as the
  cache key, which a new thread could otherwise have been handed.

Two harness findings from the release's own CI runs, both the same Crystal
1.21 behaviour seen from two sides:

- **A unit spec assumed the main fiber runs on the initial thread; since
  Crystal 1.21 it need not.** The execution context's monitor hands a
  scheduler whose thread it catches inside `open(2)` to a pool thread, and
  the main fiber carries on there — one move per ~1 000–3 000 `File.open`
  calls, measured — while `Thread.current.name` still reads `DEFAULT-0`.
  `spec/stack_bounds_snapshot_spec.cr`'s `RLIMIT_STACK` arm then measured a
  pool thread's mmap (low `0x7fbb38e49000`, 275 GiB below the top of user
  space, unmoved by the halving; CI 34051069821, 1 of 3 runs). The example
  now records the initial thread at load (`SpecInitialThread`) and is
  pending, saying why, when it is not on it. Nothing in the collector
  changed: `GC.init` records the initial thread by pthread id, and threads
  do not move.
- **The bench RSS reader moved the thread it was measuring.** The same
  monitor move, from inside `BenchRss.read_kb?`'s `File.open` of
  `/proc/self/status`: under the bitmap allocator the pool thread the main
  fiber lands on takes its own cursor set — a chunk per size class in use —
  and `heap_size` reads about 2× from then on (+92–111% on a 5.7 MB heap,
  measured by forcing the move; the retired set's chunks stay in the warm
  pool). The v0.24.0 tag run's rss-leak gate failed exactly so (CI
  34051071982: heap 3.3 → 6.3 MB between cycles 10 and 15, "late-half grew
  92.35%"), on a host whose reader opens nothing 0 of 40. The reader uses
  `open(2)`/`read(2)` directly now, outside `Fiber.syscall`. The shape
  itself is documented under `GCRY_BITMAP_ALLOC` in HARDENING: one-time,
  inside the warm budget, not a leak.

## [0.23.0] - 2026-09-06

Minor release. Two things happened since 0.22.0, and one of them changes
what the default build does.

**The collector now resolves interior pointers on the default build.** Under
`--release`, LLVM strength-reduces `live[i % n]` in a hot loop to a register
holding `buffer + k*8`; the base pointer is dead, and a base-only conservative
mark found no root at the buffer and freed it under the loop — a 40-line
program faulted 3 of 3 on 0.22.0, the debug build never did. That is the
shape of the live-object reclaims seen in production, and it is the one class
of root bdwgc has always honoured that gcry did not. `allow_interior_pointers`
is on for the process heap now (measured −0.1% throughput on Kemal `/json`;
RSS inside noise on this box), `GCRY_DISABLE_INTERIOR=1` is the escape, and
`make interior-only-buffer` keeps both arms honest in CI. If you run 0.22.x in
production, upgrade for this line alone.

**Under the bitmap allocator, every thread allocates through its own cursor
set** (PR #34, stakach): lock-free small-object allocation per thread, a
collection threshold and warm-chunk budget that follow the live set, a
lock-free `realloc`/`free` chunk lookup through the radix, one cycle of grace
before an emptied chunk is unmapped, and the initial thread's stack bounds
taken once. Headerless 48-byte `malloc` 31–32 ns on one thread and 29 ns
aggregate across four (Boehm 131 / 135 in the same harness); Kemal `/json`
page faults 1 256 → ≈5 per 1 000 requests. All of it is gated on
`GCRY_BITMAP_ALLOC=1`, which stays **off by default**; the header build gets
no policy change. The review of that PR also found three defects in the
default (header) allocator that 0.22.0 shipped — un-zeroed memory handed out
as clean under a peer refill, dormant-chunk revival that neither zeroed nor
accounted once, and sweep counters that were plain get/set while mutators
ran — each closed with a spec that is red on 0.22.0.

Upgrading: no API change. One knob removed (`GCRY_INTERIOR=1`, now the
default) and one added in its place (`GCRY_DISABLE_INTERIOR=1`);
`GCRY_THRESHOLD_FACTOR` now applies under a fixed `GCRY_THRESHOLD` as the
docs said it did. Everything else new is behind `GCRY_BITMAP_ALLOC=1`.

### Changed

- **Less collector on the Kemal main thread at the same RSS.** A main-thread
  profile put gcry at 9.5% of the time under wrk; five changes take most of
  the avoidable part. `realloc` and `free` resolve the pointer they own
  through the chunk radix with no index lock (`Heap#chunk_for_owned`; the
  table is now on by default under the bitmap allocator, `GCRY_CHUNK_RADIX=0`
  turns it off) and a growing `realloc` takes its fresh block from the
  thread's cursor. A held cursor moves to the next word of its chunk without
  the class lock (`cursor_word_advances`; 96% of locked refills were that
  step), with a `fast_miss_*` census of why an allocation leaves the hit
  path. A fully free chunk past the warm budget gets one cycle of grace
  before it is unmapped (`ChunkHeader::Flags::IDLE`,
  `empty_chunk_grace_kept`), which ends the map/unmap churn that cost ~8% in
  two rounds of twenty. The hit path reads one thread-local word and calls
  no hook. The initial thread's stack bounds are taken once instead of
  parsing `/proc/self/maps` at every stop (`stack_bounds_main_cached`).
  Kemal `/json` CPU per 10 k requests 209 → ≈ 195 ms on the paired runs;
  48-byte `malloc` 34.8 → 31 ns; peak RSS unchanged.
  `bench/log/linux/2026-09-06-stage2-throughput/FINDINGS.md`.
- **Every thread allocates small blocks lock-free through its own cursor
  set.** Under the bitmap allocator each thread owns a `Gcry::CursorSet` —
  one cursor per (class, kind), reached through a thread-local cache — and
  `malloc`/`malloc_atomic` take `Heap#fast_alloc`: table-driven size fit, a
  pop from the thread's own free mask, an atomic `occ` OR into the word its
  cursor is consuming, per-set byte and object counters credited to the heap
  on the locked path and at every stop-the-world, and unrolled clears for
  16–64-byte blocks. A chunk under a cursor carries `ChunkHeader::Flags::CURSOR`
  and no other cursor takes it; the class lock is taken only to refill. A
  stop-the-world retires every idle set (its chunks return to the pool) and
  pins the chunks of a set frozen mid-allocation, which the after-world sweep
  then leaves alone until the next stop-the-world zeroes their marks. Sets
  are reclaimed at thread exit through a pthread key destructor, and a
  process past 64 threads shares a fallback set under the class lock.
  `GCRY_ALLOC_FAST_PATH=0` pins the locked path. This replaced a
  process-wide "single mutator" flag that skipped the locks while one thread
  existed and exempted the runtime's SYSMON thread — which allocates its main
  `Fiber` at start-up, so two threads popped one freelist head
  (`process_spec/regression/7_sysmon_alloc_race_spec.cr`). As shipped,
  headerless 48-byte `malloc` is 31–32 ns on one thread and 29 ns aggregate
  across four (Boehm in the same harness, collection on: 131 / 135;
  `bench/log/linux/2026-09-06-stage2-throughput/FINDINGS.md`). The 21.6 /
  8.8 ns and the "111.8% of Boehm at 0.97× RSS" figures in the earlier logs
  (`2026-09-04-alloc-fast-path`, `2026-09-05-cursor-sets`) belong to the
  withdrawn single-mutator prototype and are superseded, not reproduced.
- **Emptied bitmap chunks are kept warm up to a budget that follows the
  live set instead of being released.** Under the bitmap allocator an
  emptied chunk is reusable in place, and releasing it made every 8 KiB
  block the next cycle handed out arrive on a fresh page — 1 256 minor
  faults per 1 000 Kemal requests against Boehm's 2, on less CPU per
  request than Boehm. `GCRY_EMPTY_CHUNK_WARM_RETAIN` now defaults to the
  collection threshold and then tracks live × `GCRY_THRESHOLD_FACTOR` after
  every major, capped by the threshold, so a fixed 128 MiB threshold does
  not hold 128 MiB of emptied chunks once the live set has dropped; `0`
  restores release-everything.
- **The process heap sizes its collection threshold from the live set, the
  way Boehm's `GC_free_space_divisor` does.** Under the bitmap allocator,
  after each major (the incremental cycle's completion included) the next
  threshold is the live bytes the sweep measured, times
  `GCRY_THRESHOLD_FACTOR` percent (10–1000, default 100), clamped to
  8–64 MiB (Darwin floor 16 MiB). A 10 MB live set therefore collects every
  10 MB and keeps 10 MB of emptied chunks, instead of the fixed 32 MiB each.
  `GCRY_THRESHOLD` still pins a fixed threshold, a Parallel execution
  context keeps its fixed 64 MiB, and the header allocator keeps its fixed
  defaults. `GCRY_TIGHT_GROW`'s collect-before-grow floor is pinned at the
  8 MiB it was calibrated at. Numbers in
  `bench/log/linux/2026-09-04-alloc-fast-path/FINDINGS.md`.

- **A live `Array` buffer was freed under a `--release` loop that held only
  an interior pointer into it.** `live[i % n]` in a hot loop is
  strength-reduced by LLVM to a register holding `buffer + k*8`; the base is
  dead and the `Array` object's spill slot is dropped once nothing reads it,
  so base-only ambient marking found no pointer *at* the buffer and released
  the chunk under the loop — SIGSEGV 3 of 3 on a 40-line program (400 000
  `Node`s + allocation churn), `GCRY_SEGV_REPORT=1` naming "a chunk gcry
  RELEASED … large-object release, at collection 1"; the debug build, which
  keeps the base live, never faulted. bdwgc as Crystal links it has always
  resolved interiors, so every Crystal release before gcry ran this shape
  safely. `allow_interior_pointers` is now **on** for the process heap
  (measured −0.1% on Kemal `/json`, docs/SOUND-DEFAULTS.md);
  `GCRY_DISABLE_INTERIOR=1` is the measurement escape and `GCRY_INTERIOR=1`
  is gone. `make interior-only-buffer` (CI) runs both arms: the default must
  keep its objects intact, the base-only arm must fault.
- **The header allocator handed out un-zeroed memory as clean, and counted a
  dormant chunk's capacity twice.** Both are master defects the PR #34 audit
  found on the default (header) path: a block claimed from the class freelist
  outside the class lock could be cleared *after* a peer refilled the class,
  so the caller's zeroing raced the refill (`spec/header_clear_race_spec.cr`);
  and reviving a DORMANT header chunk rebuilt its headers without zeroing the
  payloads — page release skips the metadata page and Darwin's reusable pages
  keep their contents — while adding its capacity to `free_bytes` a second
  time (`spec/header_dormant_spec.cr`). Both specs are red on 0.22.0, and the
  dormant one is reachable on the macOS default, which retains 512 KiB of
  dormant chunks (Linux retains none unless `GCRY_EMPTY_CHUNK_RETAIN` is set).
- **The sweep's counter updates were plain get/set while mutators ran.** The
  after-world sweep gated its atomic path on `@collecting`, which is already
  false by then, so `live_objects_sub` / `free_bytes_add` raced every
  allocating thread (`spec/sweep_counters_spec.cr`, red on 0.22.0). Gated on
  `@world_stopped` now; the default build pays a CAS per reclaimed block
  (+5.6% on the per-block lazy sweep).
- **`GCRY_THRESHOLD_FACTOR` was ignored under a fixed `GCRY_THRESHOLD`.** The
  factor was parsed inside the adaptive-threshold branch, so with a fixed
  threshold the warm-retention budget followed live × 100% whatever the knob
  said, against what HARDENING.md and the entry above promise. Parsed once,
  before the threshold decision.
- **`make heap-counters` could not see the loss it exists to show.** The
  counter was read around `Thread.new` / `join`, and each thread's own
  bootstrap allocates *inside* the thread, so +5..9 of bootstrap covered the
  0–5 increments the plain path now loses per round (`lazy_set` narrowed the
  race ~100× on 2026-09-05) — the control reported `lost 0` while losing,
  3 of 5 runs locally, and the retry loop added to it only widened the odds.
  The read now sits between a ready barrier and a done barrier: the atomic
  arm counts exactly 1 200 000 of 1 200 000, the plain arm loses 10–29 on the
  first round every run, and losses accumulate across rounds instead of
  being asked of one.
- **`make asan` failed on any box without `clang-19`.** `ci/asan_check.py`
  now takes `clang-19` when present (CI), else `clang` on PATH; `CLANG=…`
  still overrides.

### Added

- **Every benchmark harness refuses to build against the wrong gcry.** The
  Kemal and acikturkiye benches take gcry as a `path: ../..` shard, and
  `shards install` materialises that as an *absolute* symlink to whichever
  checkout ran it. A copied `lib/`, a scratch tree seeded from the main
  checkout, or an install that kept an existing `lib/` then compiles the main
  checkout's collector and attributes the number to the branch the harness
  thinks it is measuring. It has cost two published tables — the
  `acikturkiye/lib/gcry` run ROADMAP records, and PR #33's Kemal table, which
  PR #34's log retracts for exactly this. `bench/assert_gcry_lib.sh` resolves
  the link after every `shards install` and fails hard, both paths printed,
  unless it is the tree the harness runs from; every harness that builds a
  bench binary calls it, and the line it prints on success names the commit
  (`gcry lib: … (93bc3bb +dirty)`) so a log says what it measured.

## [0.22.0] - 2026-09-05

Minor release, and the reason it is minor rather than patch: the collector
gained a second representation. Per-chunk `occ`/`mark` bitmaps with a
streaming `occ &= mark` sweep and pool-cursor allocation
(`GCRY_BITMAP_ALLOC=1`), an opt-in header-less small-object layout
(`-Dgcry_headerless`) that drops the 16-byte block header, SIMD bitmap kernels
with CPU-tier dispatch, an O(1) address→chunk radix, and a sharded parallel
marker. **Every one of them is off by default**; the default path is the header
layout and the freelist, as before.

The line that matters in production is not any of those. It is that
**`/proc/self/maps` is no longer how a Linux build finds its own globals.**
The static roots come from the executable's ELF program headers now, read once
at `GC.init`. The parser they replace failed three ways, each of which is a
collection in which no class variable is a root: it identified `.data` by
pathname — so a program that `mmap`ed its own data files had them scanned after
`munmap` (#29), and a redeploy that renamed the running image to `… (deleted)`
dropped the root set to **zero bytes**; it found the BSS by adjacency to that
line, so losing one lost both; and it read a file that is not a snapshot. A
program header can do none of these. Darwin derives the same set from its
writable `__DATA*` sections rather than a three-name allow-list.

Nine correctness defects were found and closed after the representation
landed, by an adversarial audit of the merge, of the static-root rewrite, and
of the audit's own fixes — including a live object reclaimed by a minor under
`GCRY_BITMAP=1`, a `GCRY_CHUNK_BYTES` that had become silently inert, a
cursor-pinned chunk that held 20 MB at `live_objects == 0`, and three
default-path throughput regressions. Each is listed below with the measurement
that found it and the gate that keeps it closed; every fix ships with a red arm
that fails without it.

Upgrading: no API change, no knob change, no default behaviour change beyond
the static-root source and a 32-byte chunk header (which is what makes
`GC.malloc` 16-byte aligned for the first time — it never was). `GCRY_NURSERY`
is now documented as unsound rather than merely off.

### Fixed

- **`GC.init`'s eager static-root resolve crashed every `-Dgc_none` binary on
  macOS, and the mechanism is now named.** The resolve was Linux-only because
  enabling it on Darwin took `crystal spec -Dgc_none process_spec` to an
  invalid memory access on the macOS runner (CI 33900305015) with no Darwin
  host to attribute it on. It is `once`-guarded lazy class-variable
  initialisation: `GC.init` runs before `Crystal.main` reaches `init_runtime`,
  and `__crystal_once` there reads `Fiber.current` -> `Thread.new` ->
  `Fiber.new` -> `Fiber.@@fibers.push` on a class variable `Fiber.init` has
  not created yet. Null receiver, `EXC_BAD_ACCESS` at `0x18`, before `main`;
  three lines of user code reproduce it. Two declarations in
  `platform/darwin_roots.cr` were responsible — `@@ranges : RootRange* =
  Pointer(RootRange).null` (a call) and `@@cached_generation = UInt32::MAX` (a
  constant path) — while the simple-literal ones beside them were fine, which
  is why `linux_roots.cr`, written with `uninitialized` and literals
  throughout, never hit it. Neither guard was doing anything: the compiler had
  already folded both values into the globals' own initialisers (`ptr null`,
  `i32 -1`), so the guarded store wrote what was already there. Fixed at the
  declarations; the resolve is eager on both platforms now, which takes
  `LibC.realloc` and dyld's image walk out of the first stopped world.
  `make darwin-static-root-init` walks the emitted LLVM call graph and fails if
  `__crystal_once` is reachable from `ensure_static_root_cache` along any path
  that can return; its red arm `-Dgcry_static_root_once` restores the
  `@@cached_generation` initialiser — the accessor that was the resolve's
  first instruction — and must reintroduce the edge *and* SEGV.
  `GCRY_STATIC_ROOT_LAZY=1` is the effect arm.
  `bench/log/macos/2026-09-04-static-root-init-once/`

- **Darwin's static roots were a name allow-list; they are derived now — and
  the obvious parity rule was wrong.** Linux takes every writable `PT_LOAD` of
  the executable minus `PT_GNU_RELRO`, so a linker that renames or adds a
  section stays covered. Darwin accepted `__data` / `__bss` / `__common` and
  refused `__const` by name. The proposed fix — every `__DATA*` section whose
  `initprot` carries `VM_PROT_WRITE`, minus TLS — does not work:
  `__DATA_CONST` declares `initprot=0x3` and dyld mprotects it **read-only**
  after applying fixups, which its `SG_READ_ONLY` segment flag marks and
  `mach_vm_region` confirms as `r--`. That rule would have word-scanned 19456
  bytes of pointer-dense literal pool the mutator cannot write. The rule that
  matches Linux is writable **minus `SG_READ_ONLY`** minus TLS, and that is
  what ships. Measured: identical byte-for-byte to the allow-list on a default
  link (2081682 B, matching `static_root_bytes`), and +19456 B under
  `-Wl,-no_data_const`, where `__const` and `__got` move into a plainly
  writable `__DATA`. No refused section held a heap-owned word in either link,
  so this is insurance against a linker change rather than a bug fix — and the
  `--control` arm, which drops `__common` through `GCRY_STATIC_BSS_CAP=1`,
  finds 38 heap-owned words there and does not survive its own collections,
  which is what stops that "nothing lost" from being a statement about the
  detector. There is no `__bss` in this linker's output at all; zerofill is
  `__common`, so the allow-list's `__bss` entry never matched anything. The
  range table is a fixed `StaticArray` of Linux's bound now, which makes
  `static_root_overflow` and `static_root_bss_lost` real counters instead of
  hardcoded `0` and removes a `realloc` and a `raise` from a path that runs
  inside `GC.init`. `make darwin-static-root-sections`.
  `bench/log/macos/2026-09-04-darwin-static-root-sections/`

- **`GCRY_STATIC_BSS_CAP=1` was a no-op stub on Darwin.** The knob is
  documented as refusing an oversize writable range so a root class can be
  dropped on purpose, and the Linux gate for it (`bench/static_bss_roots.cr`)
  reads `/proc/self/maps` and cannot run here — so the argument had no Darwin
  arm. It refuses a `__DATA*` section of 1 MiB or more now.

- **The Darwin free-page walk's bitmap stand-down had a backwards reason.** It
  was written on Linux and never run on Darwin, the only platform its arm
  exists on. The comment said the mask is built from `BlockHeader.free?`, that
  the flag is stale on a bitmap chunk, and that the walk would therefore
  release a page holding a live object. The staleness is real and the
  direction is not: `set_used` clears FREE when a block is handed out and
  `bitmap_free_block` clears only `occ`/`mark`, so `BlockHeader.free?` is
  false for *every* block on such a chunk and the mask can only fail to
  release. Measured with the stand-down removed
  (`GCRY_PAGE_RELEASE_BITMAP_WALK=1`): 208 KiB released — the tail slack below
  the last whole block — with `page_release_live_blocks=0`, 5 of 5, and still 0
  with the `occ` re-read also off; the header arm of the same gate releases
  2.88 MiB, so the walk does work here. The `next` is kept as a cost decision
  and says so. What keeps the representation sound is the *other* stand-down,
  in `unlink_free_only_page_runs`, which declines because there is no freelist
  to unlink and the pool cursor can hand out a block inside a run being
  released. No checksum can decide this on Darwin: `release_physical_pages`
  issues `MADV_FREE`, and both `MADV_FREE` and `MADV_FREE_REUSABLE` measured
  on this host return 0 on a still-referenced range and leave every word
  intact through 2 GiB of pressure, so a mis-released page is latent and the
  gate reads the counter. `make darwin-bitmap-page-release`.
  `bench/log/macos/2026-09-04-bitmap-page-release-standdown/`

- **`GCRY_BITMAP_ALLOC=1 crystal spec -Dgc_none process_spec` had never been
  run, on either platform, and was red.** `Flags::SWEPT` records which path
  gave a block back, and it is written only by `push_size_class_free` — the
  header freelist reclaim. Under `bitmap_alloc` the sweep is
  `sweep_small_bitmap`, which reclaims by `occ &= mark` and writes no block
  header, because removing that per-block write is the point of the
  representation. The spec asserted `swept == freed` and read `swept=0 of
  freed=19899`, which looks like a collector defect and is a representation
  with nowhere to keep the bit. Its guard was a compile-time
  `flag?(:gcry_headerless)` test; it is a runtime `heap.bitmap_alloc?` test
  now, which covers both — headerless forces `bitmap_alloc` on — and asserts
  the flag's absence where it cannot exist rather than skipping the example.
  The same reading made `Gcry::SegvReport` report **every** swept block as
  "freed by an explicit free, not by the sweep" on those heaps; it says the
  path cannot be recorded under that allocator now, on the same grounds the
  reissue case already used — a verdict that is wrong is worse than none.

- **The Darwin CI job never built either representation PR #33 shipped.**
  `GCRY_BITMAP_ALLOC=1` and `-Dgcry_headerless` arms were added to the Linux
  job when they landed and not to `test (darwin native)`, and the two are not
  interchangeable: pages are 16 KiB here against 4 KiB there, and every bitmap
  ordinal and free-page mask derives from that. Unit, process and sample arms
  for both are in the job now, along with the three new Darwin gates, each
  verified on an Apple M2 Pro host first.

- **A minor collection reclaimed a live object under `GCRY_BITMAP=1`.** The
  mark *read* side gates per chunk — `bitmap_chunk?` excludes nursery chunks,
  because the nursery keeps the header representation — so a nursery block's
  mark lives in the header generation. Both *clear* sites gated on the global
  `@bitmap_marks` instead: `clear_nursery_marks` zeroed a nursery chunk's
  bitmap, which nothing ever writes, and `clear_block_mark` skipped the header
  clear. Nothing therefore cleared a nursery block's mark, a marked block is
  never scanned, and anything reachable only through it was swept **while
  live**. Reproduced in one minor: parent rooted, major, child allocated and
  stored into the parent as its sole reference — the child was freed, its
  address handed to a second owner, and its canary destroyed. Both sites use
  the read side's own predicate now. `make nursery-bitmap-marks`, whose
  bitmap arms are red without the fix. Off the process default path (the
  nursery is off there, and forced off under `-Dgcry_headerless`); on the
  library default path, where `Gcry::Heap.new` enables it.

- **`GCRY_CHUNK_BYTES` was silently dead.** `MAX_RECIPROCAL_CHUNK_BYTES`
  became a `begin ... end` constant in the previous commit, which Crystal
  compiles to a `once`-guarded runtime initialiser — and its only reader is
  `apply_env_config`, which runs inside `GC.init`, before `Crystal.main`
  reaches `init_runtime`. There it read its zero-initialised storage, so
  `chunk_bytes <= 0` rejected every legal value: `GCRY_CHUNK_BYTES=262144`
  gave `small_chunk_bytes=131072`. It is a class method now, and the knob
  works in both layouts. The same hazard is already documented for
  `Platform.host_page_size` and for `ENV` in this exact context.

- **`Heap#free` used the heap-wide flag where the representation is
  per-chunk.** A block freed out of a *nursery* chunk took the bitmap arm,
  which cleared bits in a bitmap nothing reads and never linked the block onto
  `@nursery_freelists`, so it was lost for the life of the chunk while
  `free_bytes_add` still counted it as available. Measured: 2 000 blocks
  freed and reallocated grew the heap by a whole chunk while reporting
  208 896 bytes free. Dispatches on `bitmap_alloc_chunk?` now, like every
  other consumer.

- **A cursor-pinned empty chunk was never released.** `sweep_small_bitmap`
  forces `any_live` for a chunk an allocation cursor points at — correct, and
  the fix for an earlier SIGSEGV — but the claim that its emptiness is
  "noticed next cycle, once the cursor has moved on" was false: the cursor
  advances only when a chunk runs *out* of free blocks, which an empty one
  never does. So the pin was permanent, and a pinned chunk is also excluded
  from the free-page release. Measured with every class touched and no
  survivors: **80 chunks, 20 971 520 mapped bytes and RSS stuck at its
  13.5 MB peak at `live_objects == 0`**, where the header arm returned to
  6.3 MB. The after-world sweep already holds the class lock, so it retires
  the cursor there instead; the in-STW arm still pins, because taking that
  lock is the 0.21.1 hang. Now 0 chunks, 0 bytes, RSS 8.0 MB.
  `sweep_cursor_retired` on `/gc-stats` is the twin `sweep_cursor_pinned`
  needed to be readable.

- **Two more holes in the small in-flight root.** `clear_bitmap_alloc_in_flight`
  stored an unconditional null into a slot shared by every thread allocating
  that (class, kind), and ran after the size-class lock was released — so one
  thread's clear could erase another's live publication, re-opening the exact
  window the slot exists to close. It is a compare-and-clear now. And
  `collect_a_little` — the incremental slice, the third place a bitmap chunk
  is swept — contributed no roots at all, so neither the small nor the large
  in-flight block was offered there. Both are marked now. The fork child also
  resets the slots, since the thread that owed the clear does not survive.

- **Three default-path throughput regressions from the merge.** Each was a
  chunk lookup added to compute a value the header already held, which
  differs only under `-Dgcry_headerless`; `chunk_containing` takes
  `@index_lock` and binary-searches the sorted index with the world running.
  `GC.realloc` did two lookups where one was needed (**+36%**, measured
  against 287404d with 40 000 ballast chunks); `GC.free` did three (**+13%**);
  and `scan_object` resolved the chunk *before* the ATOMIC early-out that used
  to precede it, which every `String` pays (**+19%** of `phase_mark` on an
  atomic-heavy live set). `owns_user_pointer_in?` takes a resolved chunk, both
  callers resolve once, and the header's ATOMIC test is back in front of the
  lookup — sound in both layouts, since `BlockHeader.atomic?` is a literal
  `false` under headerless. Re-measured after: `realloc` 15.1 ns against a
  14.4 ns baseline, `free` 40.7 ns against 45.4 — free is now faster than it
  was before the merge.

- **Static roots: a failed resolution latched forever.** `@@resolved` was set
  before the walk, so a process whose `dl_iterate_phdr` found no writable
  segment warned once and then ran for its whole life with an empty root set,
  sweeping everything held only by a class variable, while
  `static_root_bss_lost` sat at 1 and could no longer tell one lost collection
  from all of them. It latches on success only, so `scan_static_roots` retries
  per collection and the counter means what `/gc-stats` says. Not reached in
  any of eight link configurations (PIE, non-PIE, static, static-pie, norelro,
  release, MT), so this is a failure-mode fix, not an observed bug.

- **`Platform.ensure_static_root_cache` is public on both platforms.** It was
  private on the Darwin half and compiled only because the `GC.init` call site
  carried a `flag?(:linux)` guard — the same asymmetry that broke the macOS
  build on 2026-08-22 via `bss_size_cap=`. The eager resolve stays Linux-only:
  moving Darwin's lazy dyld walk into `GC.init` took `process_spec` on the
  macOS runner to an invalid memory access while Linux stayed green, and there
  is no Darwin host here to attribute it on, so that side keeps the behaviour
  it shipped with.
  Also: the Darwin free-page walk visits every kept size-class chunk rather
  than only flagged ones, so it needed the bitmap stand-down the HOLED/SPARSE
  classification already applies — its live mask is built from block headers,
  which are stale on a bitmap chunk.

- **`GCRY_POISON_FREED` on a bitmap heap now marks the freelist unclean
  itself.** `sweep_words_poisoning` was the first poison site that did not,
  and was safe only because `bitmap_alloc_locked` happens to store `false` on
  every allocation — a store its own comment marks as temporary. The pairing
  is stated where it is relied on.

- **The default-on collector scrub asked libc where the stack was, twice per
  collection.** `GCRY_COLLECT_SCRUB` runs at `run_collection`'s entry and
  exit, and `clear_stack_body` opened with `pthread_getattr_np(pthread_self)`
  — which glibc answers for the **initial** thread by parsing
  `/proc/self/maps`, the cost `platform/linux_stack.cr` already snapshots its
  way around to keep out of the pause. A Crystal program collects on the main
  pthread, so every collection paid two parses whose cost grows with the
  mapping count, and both landed *outside* the pause window where no
  `pause_p50`/`pause_p99` could show them. Measured: 15.7 µs a call at 48
  maps lines, **2.5 ms** at 4 000 parked fibers (8 047 lines), **24.7 ms** at
  20 000 (40 047) — two per collection, on exactly the fiber-heavy server the
  default is for. `Fiber#@stack` already holds the bounds (for a thread's main
  fiber they are the real pthread bounds, filled in once at thread start), so
  the collector reads two words: 0.005 µs, flat in the mapping count. The
  allocation-path wipe still asks libc — it must not touch Fiber/Thread APIs.
  `clear_stack_libc_bounds` counts any fallback and is on `/gc-stats`; gated
  by `make collect-scrub-cost` with `GCRY_SCRUB_LIBC_BOUNDS=1` as the red arm.

- **A parallel-mark cycle could end while a worker still held a batch, and
  live objects were reclaimed.** The master stops on
  `busy == 0 && stack empty`, which is stable only if a worker cannot hold
  work while counted idle — and the batch left the shared stack under
  `@mark_lock` while `@mark_workers_busy.add(1)` happened *after* the unlock.
  In that gap the master reads zero, sees the stack it just emptied, breaks,
  and its `ensure` waits on a counter already at zero; the worker then scans
  up to `MARK_POP_BATCH` objects and flushes their children onto a stack
  nothing will drain, so everything reachable only through them is unmarked
  at sweep time. The counter is incremented inside the critical section that
  removes the entries, and both halves of the condition are read from one.
  `make parallel-mark-termination`: the red arm
  (`GCRY_MARK_BUSY_UNLOCKED=1`) loses a live object on the **first**
  collection — 64 chains × 400 nodes, node 397 reading node 340's tag — and
  the fixed arm runs 60 collections and 2.19 M stolen objects clean.
  Introduced by the sharded marker in this cycle; reachable only with
  `GCRY_PARALLEL_MARK >= 2`.

- **`bitmap_alloc_locked` had the window `alloc_large` just closed.** The
  `occ` bit is set before the caller has the pointer, and in between the only
  reference this thread holds is the *header* address, which `mark_impl`'s
  `base_only` policy rejects. A mutator frozen there leaves a block that is
  occupied, unmarked and referenced by nothing the scan accepts, so
  `occ &= mark` clears the bit under a caller about to be handed the block and
  `~occ` hands the same memory out again. Fixed the way the large path is
  (`@large_alloc_in_flight`): a per-pool-slot `@pool_in_flight` published
  before the `occ` store, rooted from both root phases, cleared once the
  caller's frame holds the pointer. Needs `GCRY_BITMAP_ALLOC=1` and more than
  one mutator thread; the default path never reaches it.

- **`GCRY_POISON_FREED=1` leaked the whole heap under the bitmap allocator.**
  Poisoning is a payload write and the streaming sweep touches no payload, so
  an armed knob stood that arm down and let the header walk run — and that
  walk reclaims through a freelist without ever clearing `occ`, which under
  this allocator is the only thing the allocator reads. Every reclaimed block
  stayed occupied for the life of the process: measured 21.8 → 77.3 MB over
  four churn rounds holding 1 in 500, against a plateau at 18.8 MB. The
  pattern is written inside the arm now (`sweep_words_poisoning`, same
  arithmetic as the kernel, whole-word stores kept), so `occ` stays
  authoritative and the diagnostic actually fires — 2.4 M blocks poisoned
  where it previously reported 0 on bitmap chunks. `make poison-freed` gained
  a reclaim-plateau arm and now runs under `GCRY_BITMAP_ALLOC=1` too.

- **`MAX_RECIPROCAL_CHUNK_BYTES` was wrong for `-Dgcry_headerless`.** The
  64 MiB ceiling was derived with `block_bytes = 16 + payload`; headerless
  makes `BlockHeader::SIZE` 0, which moves the tightest class to 28 672 and
  the bound to **51.2 MiB** — under the ceiling, so a headerless build with
  `GCRY_CHUNK_BYTES` in (51.2, 64] MiB resolved the wrong block for some
  offsets in that class: wrong `occ` bit, wrong mark bit, wrong user pointer,
  silently. Verified at `d = 28672`, offset 53 702 655 → ordinal 1873 where
  1872 is correct. The bound is computed from the build's own class table now
  (86.35 MiB header, 51.2 MiB headerless). The old spec missed it because the
  failure is **not monotone** — 67 108 863 agrees again — so its four samples
  per class could not see it; it checks each class's analytic first-failure
  point against the ceiling, plus every offset of a default-sized chunk.

- **The finalizer index's out-of-memory fallback was neither safe nor
  correct.** `index_grow` frees the table and sets `@index_cap = 0` so
  `notice_reclaim` scans instead, but `index_add` carried on to probe a null
  table (`mask` = `UInt64::MAX`), and the growth was retried on the next
  registration — so a later success produced a *partial* index that
  `notice_reclaim` then trusted, leaving everything registered before the
  failure reading unregistered and its disappearing links uncleared on
  `free`/`realloc` (a dangling `WeakRef`). The give-up is sticky now, and
  `spec/finalizer_index_spec.cr` pins both halves through
  `debug_finalizer_index_give_up`.

- **`GCRY_TLAB=1` could re-enable TLAB after the bitmap allocator disabled
  it.** `bitmap_alloc=` clears `@tlab_enabled` because two allocators must not
  hand out the same blocks, but the env wiring applies `GCRY_TLAB` after the
  heap exists. The allocation paths guard on `!@bitmap_alloc`; what does not
  is `sweep_after_world?`, which returns false while TLAB is on and so moved a
  bitmap heap onto the in-STW sweep, and `mark_impl`'s `claim_free_tlab_block`,
  which became reachable for `occ=0` blocks whose `next_free` words are stale
  payload. The setter refuses under `@bitmap_alloc`.

- **Linux static roots come from the ELF program headers, not from
  `/proc/self/maps`.** The roots are the executable's writable `PT_LOAD`s —
  `.data` and `.bss` together, `p_memsz` covering the zero-fill — minus the
  `PT_GNU_RELRO` window the loader makes read-only before `main`, read once
  at `GC.init` through `dl_iterate_phdr` (the object whose segments hold
  gcry's own statics, not "the first one visited") and never refreshed,
  because they never change. This is what Darwin already did with the Mach-O
  `__DATA` sections, and what Boehm does.
  It replaces a maps parser whose every failure was a collection with no
  class variable rooted. It named `.data` by pathname: first "not a `.so`",
  which admitted any file the program `mmap`ed and scanned it after
  `munmap` — a `MAP_PRIVATE` file grown past EOF is SIGBUS (#29); then
  "equals `/proc/self/exe`" (#31), which lost the executable the moment a
  redeploy renamed its maps lines to `… (deleted)` — root set **0 bytes**,
  `bench/static_roots_redeploy.cr` dies of it on that tree in three
  collections. It found the BSS by adjacency to that line, so losing `.data`
  lost the BSS. And the file is not a snapshot: a mapping changing between
  two `read`s can drop a line. A program header can do none of these.
  Ranges checked against `readelf -l` (RELRO segment dropped, `.data`+`.bss`
  exact to the byte); PIE, non-PIE and static-pie; `-Dpreview_mt`; release.
  Gated by `make static-roots-redeploy` beside `static-bss-roots`, whose
  `GCRY_STATIC_BSS_CAP=1` red arm now refuses the segment instead of the
  mapping. The cache is a `StaticArray`, so a collection no longer calls
  `realloc` to find its roots (Linux; the Darwin cache is still a `realloc`ed
  `RootRange*`, resolved eagerly at `GC.init` now rather than inside the first
  stopped world).

- **`/gc-stats` reports the static-root counters.** `static_scanned_last` /
  `min` / `max` / `drops`, `static_root_bytes`, `static_root_bss_lost`,
  `static_root_overflow`. A fifth acikturkiye sighting on 2026-09-04
  (287404d) faulted in `Radix::Tree#find` on a node reached only through
  Kemal's `@@only_routes_tree` — a class variable, held by nothing but the
  BSS — which is the "globals were not roots this collection" shape and not
  the stack-rooted per-request shape of the four before it. On 287404d the
  BSS was a root only if the maps parse kept `.data`'s line; the mechanism
  that dropped it there is not established, and the counters above plus the
  journal's `gcry:` lines are what would establish it.

### Changed

- **`clear_stack_libc_bounds` counts lookups *attempted*, not lookups that
  succeeded.** The counter backs a structural claim — "the collector never
  asks libc" — and a lookup that fails still pays the `/proc/self/maps` parse
  while leaving a success-gated counter at zero.

- **The reciprocal-ceiling spec finds the first bad offset by scanning**
  instead of recomputing `2^40 / e`, which is the same expression the bound
  itself uses: an error in the derivation appeared identically on both sides
  and the assertion still passed. Independently confirmed by brute force —
  true cliffs at 90 547 743 (header) and 53 702 655 (headerless) against
  bounds of 90 539 495 and 53 687 091, so the bound is conservative by
  8 248 and 15 564 bytes.

- **`GCRY_NURSERY`'s knob row says it is unsound**, not merely off. The
  soundness axis was documented in `SOUND-DEFAULTS.md` but not where anyone
  reads before setting it: a checksummed-graph churn SIGSEGVs 3 of 3 runs at
  `GCRY_NURSERY=262144` on a **default** build, and it does so identically at
  287404d, so it is neither new nor bitmap-related.

### Added

- **CI builds the representations it ships.** Neither was exercised when they
  landed: `GCRY_BITMAP_ALLOC` had unit coverage only under the Boehm library
  heap, and every line of `spec/headerless_switches_spec.cr` sits inside
  `{% if flag?(:gcry_headerless) %}`, so it was compiled out of the whole
  matrix. Added `GCRY_BITMAP_ALLOC=1` unit specs, `-Dgcry_headerless` unit and
  process specs plus a `-Dgc_none` sample, a knob smoke covering
  `GCRY_BITMAP`, `GCRY_BITMAP_ALLOC`, `GCRY_CHUNK_RADIX`, `GCRY_SIMD`,
  `GCRY_PREFETCH`, `GCRY_COLLECT_SCRUB`, `GCRY_PARALLEL_MARK` and the
  TLAB×bitmap pair, and the kernel equivalence fuzz **under `--release`** —
  without it LLVM does not vectorise and the AVX2/AVX-512 clones being
  compared are scalar code carrying feature flags, so the gate passed without
  executing the loops that ship. `make kernels-broken` is the positive
  control and refuses to run on a scalar-only host.
  The headerless process-spec arm found a stale assertion on its first run:
  `SWEPT` is a header flag and there is no header, so the spec asserted the
  layout's own property instead of reporting `swept=0 of freed=19899` as a
  collector defect.

### Corrected

- **0.21.2's field claim is refuted.** Its notes said of the chunk-index insert
  defect that "the fixed defect produces exactly that shape (a null reference
  read out of a live structure) … so 0.21.2 is the build production should be
  on", and labelled the field half an inference rather than a measurement. On
  2026-08-29 a second application — invidious, reported by fixju, on **0.21.3**
  — faulted at the same frame and the same address as the first sighting:
  `0x0` in `String#empty?` (`string.cr:3015`), reached from a route whose first
  acts are `env.params.url[…]` and `env.params.query[…]?`. Three sightings, two
  applications, and the fix that was supposed to explain them is in the build
  that crashed. A fourth the next day — acikturkiye, `0x4`, with the full
  thirty-frame chain — settles what the address means: `value_ptr + 4` with
  `value_ptr == 0`, so the Hash **slot** read zero rather than holding a swept
  String's old address. Both Hash scan paths mark `@entries` whenever the Hash
  object is scanned at all, so a dead entries buffer means the Hash object was
  never marked — and the only thing holding it is the stack of the fiber
  serving the request. The frame is open, and the leading hypothesis is now a
  fiber stack root miss rather than the Hash layout machinery it has always
  been blamed on.
  `bench/log/linux/2026-08-30-zeroed-hash-slot/FINDINGS.md`

## [0.21.3] - 2026-08-29

Patch release. The line that matters in production: **a process that runs out of
address space now reports it and stops, instead of spinning at 100% CPU
forever.** That recovery path had never once worked — `map_chunk` raised while
its caller held a non-reentrant allocator spinlock, and Crystal's `raise`
allocates, so the raising thread deadlocked against itself; the emergency
collection sitting in the same place could only ever do the same. 5 of 5
children hung before, 3 of 3 clean `OutOfMemoryError` after, gated
deterministically by `make oom-no-hang` and verified red against the pre-fix
tree.

The rest is 0.21.2's defect pattern audited to exhaustion — every structure the
stopped world reads unlocked, crossed against every writer a suspend signal can
freeze — which found three siblings of the chunk-index defect and closed them.
Those three are reachable only where the sweep runs inside the pause
(`GCRY_PAGE_DONTNEED=1`, `GCRY_TLAB=1`, `GCRY_DISABLE_LAZY_SWEEP=1`); a default
build is not exposed to any of them, and the small-chunk guard from the second
ships unconditionally regardless. No default-configuration collection behaves
differently from 0.21.2.

### Fixed

- **The pattern behind 0.21.2's fix, audited to exhaustion — three siblings
  found and closed.** Every structure the stopped world reads unlocked was
  crossed against every writer a suspend signal can freeze mid-protocol:
  (1) the in-STW sweep's empty-chunk drop acquired `@index_lock` — a lock a
  frozen mutator can hold — the last such site in the tree; the
  `index_remove` is deferred to the post-STW flush beside the munmap it
  serves. (2) A mutator frozen inside `refill_size_class` leaves mmap-zeroed
  headers the sweep read as dead-USED and reclaimed — blocks that never
  lived, double-owned once the mutator resumed, and a chunk classified fully
  dead under a live writer; the small path now has the size==0 tripwire the
  large path has had since 2026-08-24 (`sweep_small_uninitialised` on
  `/gc-stats`). (3) The in-STW sweep appended to `@large_freelists` without
  `@alloc_lock`, orphaning bucket entries against a frozen mid-cache/mid-take
  mutator; insertions are queued and flushed under the lock after
  `start_world`. Plus one hardening: the `@chunks` head publish is a release
  store, so its safety no longer rests on unfenced source order.
  `GCRY_PAGE_DONTNEED=1` — the config that reaches all three — went from
  2/100 + 1/40 checksum corruptions to **0/90**, and
  `make page-release-corruption` is green end to end for the first time.
  `bench/log/linux/2026-08-27-stw-write-protocols/FINDINGS.md`

- **Running out of memory hung the process instead of reporting it — three
  layers, all on the default path.** (1) `map_chunk` raised `OutOfMemoryError`
  when `mmap` refused, and every caller holds a non-reentrant `SpinLock` across
  that call (`alloc_large` under `@alloc_lock`, `refill_size_class` under the
  size-class freelist lock) while Crystal's `raise` *allocates*: it fills in
  `exception.callstack ||= CallStack.new`, which is an `Array`, which re-enters
  `allocate` and spins on the lock the raising thread already holds. (2) The
  emergency collection sat in the same place, excluded only for TLAB although
  the TLAB-off refill holds a freelist lock just the same — the after-world
  sweep takes that lock and `flush_pending_large_release` opens with
  `with_alloc_lock`, so that recovery path had never once worked. (3) With both
  moved out, the retry recursed: a collection allocates
  (`ensure_static_root_cache` parses `/proc/self/maps`), and the raise recursed
  on its own for 174 frames before the stack overflowed. Now `map_chunk`
  returns null and the refusal travels as a null user pointer to the allocation
  entry points, which hold no lock and own both the one emergency collection
  (`retry_after_emergency_collect?`, non-reentrant behind its own atomic) and
  the raise; a raise nested inside a raise uses a boot-built error whose
  callstack is already set, so it allocates nothing. Measured under `ulimit -v`:
  **5 of 5 children spinning at 100% CPU with no output → 3 of 3 clean
  `OutOfMemoryError`**, both size paths. New deterministic gate
  `make oom-no-hang`, in CI, verified red against the pre-fix tree. New counter
  `emergency_collects` on `/gc-stats`.
  `bench/log/linux/2026-08-29-oom-hangs-not-raises/FINDINGS.md`

- **The unmap guard's ledger claimed a slot with two unsynchronised reads, and
  the `IndexError` it raised was the `dormant_flush_race` silent hang.**
  `guard_release` tested `@guard_count` against the capacity and then read it
  again to index with, from `GC.free` → `trim_large_cache` on whatever thread
  frees and under no lock: two racing frees write slot `UNMAP_GUARD_SLOTS`.
  `Thread.new` stores a worker's exception until `join` and prints nothing, so
  the death was silent — and the gate's own completion count then never
  arrived, leaving the collector stopping the world forever with no output and
  nothing for `GCRY_STW_WATCHDOG_MS` to report (it is *right* to be quiet:
  every stop completes). The slot is now claimed with one atomic
  read-modify-write, the ring arm's cursor likewise, `@guard_overflows` is
  atomic, and the length column is written last and zeroed at arm time so a
  concurrent SEGV report skips a record another thread is still filling rather
  than naming a half-written region. Two pinned cores, six children at a time:
  **20 hangs of 66 → 0 of 48**, and the arm's failures are named exceptions
  instead of killed children. Research knobs only
  (`GCRY_UNMAP_GUARD`, `GCRY_RELEASE_LEDGER`); no default path change.
  `bench/log/linux/2026-08-29-silent-hang-named/FINDINGS.md`

## [0.21.2] - 2026-08-27

Patch release. Closes the `0x18` / null-field crash family at its root — a
publish-order defect in the chunk-index insert. Production sighting on 0.21.1
the same day: `0x4` in `String#empty?` via Kemal's `unescape_url_param`, the
second at that frame; the fixed defect produces exactly that shape (a null
reference read out of a live structure) in multi-threaded builds, so 0.21.2
is the build production should be on.

### Fixed

- **A chunk-index insert could hide the boot chunk from an entire collection.**
  `index_insert_locked` shifted the array and wrote the new slot before
  publishing `@chunk_index_count`, and `chunk_containing` reads the index
  unlocked inside a stop — so a mutator suspended by `stop_world` between the
  shift and the increment left the collector a sorted array whose *last* entry
  did not exist. The topmost address is always the boot chunk, so the mark
  lost `Thread::LinkedList` (its only reference is the `@@threads` BSS slot,
  and `find_block` failed on it), the sweep reclaimed the live list, and the
  allocator re-issued its block — the `0x18` crash at `Thread.lock`, the
  `pthread_mutex_unlock: EINVAL` at thread exit, and the "walk follows a
  payload pointer" faults were one lost mark wearing three coats. The insert
  now duplicates the top entry, publishes the count with a release store, and
  then shifts: every state a suspended thread can expose is sorted with at
  most one adjacent duplicate. Measured on the arm that reproduced it at
  8–44 of 100 children: **0 of 100** with the fix.
  `bench/log/linux/2026-08-27-thread-list-tripwire/FINDINGS.md`
  A 30-minute local `wrk` soak did not reproduce the field crash on either
  binary — its rate is below what half an hour resolves — so the field claim
  stays an inference; the bench-family claim is measured.

### Added

- `GCRY_THREAD_LIST_TRIPWIRE=1` grew into the instrument family that found the
  above: a watch on the `Thread::LinkedList` object (`ThreadListWatch`), block
  set_free/set_used hooks with a backtrace at the corrupting hand-out,
  phase-boundary header probes, a mark-offer reject reporter, and a
  per-operation chunk-index verifier. All armed by the one knob, all free when
  it is off.

## [0.21.1] - 2026-08-26

Patch release. Fixes a stop-the-world hang introduced in 0.21.0.

### Fixed

- **The collector could spin forever on a lock a suspended mutator held.**
  `sweep` ended with `@chunks = kept` under `@chunk_list_lock` unconditionally.
  STW suspends by signal, not at safepoints, so a mutator can be frozen inside
  `map_chunk` or `unlink_chunk` still holding it. Reached only where the sweep
  runs in-STW — `GCRY_PAGE_DONTNEED=1`, `GCRY_TLAB=1`,
  `GCRY_DISABLE_LAZY_SWEEP=1`; a default build sweeps after the world restarts
  and never hits it (0 of 40). The lock is taken on the `after_world` path
  only. Interleaved, 40 children each: 9 hangs on 0.21.0, 0 with the fix;
  0.21.0 totals 21 in 160. `GCRY_STW_WATCHDOG_MS` names it as
  `STALLED in phase=sweep`.
  `bench/log/linux/2026-08-26-stw-sweep-hang/FINDINGS.md`

## [0.21.0] - 2026-08-26

Correctness release. Closes the acikturkiye live-string UAF (layout collision
on Hash/union buffers), chunk-list and large-cache races, the Thread birth
use-after-free, and several root-coverage holes (BSS cap, 64-thread stack
bounds, birth/staging overflow).

### Fixed

- **Precise layout chosen by a mutator word.** `scan_object` treated a block's
  first Int32 as a type id. A raw buffer of union values (`Array(JSON::Any)`, a
  Hash entry table) starts with exactly that kind of small integer, so a 64-byte
  Hash body was scanned to the wrong map and lost its pointers. Hash-kind bodies
  are now word-scanned beside the entry walk; the shape is validated first; a
  miss falls back to the conservative scan (demotion included). Acikturkiye
  `wrk -t4 -c64`: **193 of 216** collections missed edges before, **0 of 216**
  after. `bench/log/linux/2026-08-24-acikturkiye-live-string-uaf/FINDINGS.md`.

- **Chunk list, heap bounds, and large-cache trim races.** `@chunks` was mutated
  under two locks; `unlink_chunk` could unmap a still-linked chunk;
  `update_heap_bounds_after_unmap` overwrote bounds a concurrent `map_chunk` had
  published; `trim_large_cache` unmapped while `alloc_large` issued the same
  chunk; the lazy sweep did the bounds walk unlocked too. List mutations share
  `@chunk_list_lock`; bounds are read off the chunk index under one lock; trim
  detaches under `@alloc_lock` and unmaps after. `large_cache_race`: **18 of 340**
  SIGSEGVs → **0**; `GCRY_TRIM_UNLOCKED=1` **5 of 5** → **0** serialised.
  `bench/log/linux/2026-08-25-aarch64-large-cache-locked-arm/FINDINGS.md`,
  `bench/log/linux/2026-08-23-acik-crash/FINDINGS.md`.

- **`find_block` last-chunk cache and `start_world` index window.** The cache
  loaded `@last_chunk_idx` twice and could index `[-1]` (libc's malloc header —
  the `0x91` CI crash). The index is read once and verified to contain the
  address. Separately, `start_world` resumed threads before clearing
  `@world_stopped`, so mutators took the unlocked index path; the flag is
  cleared first. `make find-block-race`, `make stw-index-race`.

- **Thread birth use-after-free.** A `Thread` is now rooted from
  `GC.pthread_create` until it publishes on Crystal's list. Overflow of the
  64-slot table used to drop the root (the UAF reopened past the 64th birth
  since the last collection); it now roots anyway and leaks, which is the
  deliberate trade. A full staging table drained nothing and dropped the
  *newest* birth; it now drains published entries and evicts the oldest.
  `make thread-birth-root`, `make thread-staging`.

- **Global roots and stack coverage.** BSS larger than 1 MiB was refused as a
  root range, so every class var and constant slot was dropped; the cap is gone
  and oversized ranges are scanned in chunks. The pthread stack-bounds snapshot
  stopped at 64 threads and reported full coverage; the table grows, and the
  visit is counted before the capacity check. `make static-bss-roots`.

- **Heap counters lost updates.** `live_objects` / `total_bytes` /
  `bytes_since_gc` now go atomic in `GC.pthread_create`, *before* the call.
  `GCRY_HEAP_COUNTERS_ATOMIC=0/1`.
  `bench/log/linux/2026-08-20-heap-counter-cost/FINDINGS.md`.

- **Darwin compile.** `LibC::MAP_ANONYMOUS` is no longer redefined when Crystal
  already has it (x86_64 macOS). `bss_size_cap=` lives on both platforms.
  `make darwin-typecheck`.

- **Crash reporter and dying-audit false readings.** Out-of-span faults no
  longer exclude a swept object; reissued-block flags are not a free-path
  verdict; the address-space audit no longer reports its own frames as a scan
  hole; the dying audit records watched types below the 384-byte band.

### Added

- **`GCRY_UNMAP_GUARD=1`** — released chunks stay identified (`mprotect` instead
  of `munmap`) so a SIGSEGV can name the chunk, path, and offset.
- **Thread-death audit.** `GCRY_THREAD_BLOCK_AUDIT=1` names a dying `Thread` in
  the collection that frees it; `GCRY_DYING_TYPE_ID` / `make thread-block-audit`
  prove the walk; `make thread-uaf-sample` buys CI samples. The report says
  whether the object is still on Crystal's list.
- **Race gates.** `make large-cache-race`, `make find-block-race`.
- **Knob reference.** `docs/HARDENING.md` covers the 33 knobs added since
  v0.20.0; `make knob-doc-check` fails CI if a `GCRY_*` has no row.
- **STW stall diagnostics.** The suspend wait names the thread it is waiting for
  and asks libc whether that `pthread_t` still exists (`ESRCH` vs live).

### Changed

- **`GCRY_PAGE_DONTNEED=1` is unsound** (post-STW `MADV_DONTNEED` can zero a live
  object; 4 of 28 attempts on `make page-release-corruption`). Documented as
  such, warns at boot; `GCRY_DISABLE_PAGE_RELEASE=1` / `GCRY_DISABLE_MADVISE=1`
  now actually skip Darwin's walk. Defect still open.
- **Free-page release is opt-in on macOS too** (was the one platform where it
  shipped on). `MADV_FREE_REUSABLE` zero-fills a reclaimed page, so the same
  window is reachable there — read from the code, since the gate has no Darwin
  runner, which is why the default was the wrong place to leave it. Costs macOS
  RSS; `GCRY_PAGE_DONTNEED=1` turns it back on.
- **Dying-type audit** skips the old heap on minor collections (was reporting
  every live `Thread` as dying).
- **CI hang legibility.** aarch64 gates are bounded (`timeout 300`,
  `GCRY_STW_WATCHDOG_MS`); `ec_queue_audit` waits give up after 30 s. Crash
  diagnostics ride all three `stw_mt_property_test` arms, including TLAB and
  Darwin.
- **Pre-commit format** checks `git ls-files -- '*.cr'` instead of walking
  vendored `lib/`.

## [0.20.0] - 2026-08-18

### Added

- **`GCRY_ADDRESS_SPACE_AUDIT=1` — at the moment a block dies, search the whole
  address space for its address and name the region that holds it.** The
  use-after-free hunt had reached a contradiction it could not settle from
  inside the collector: the dying `Deque(Fiber::Stack)` buffer was in no used
  heap block, in no suspended thread's registers, in no explicit root, and the
  crash report found it on a stack immediately afterwards. So the audit stops
  asking gcry and asks the kernel — it walks every readable mapping in
  `/proc/self/maps`, searches it word-aligned, and classifies each hit as a gcry
  block, a live fiber stack (inside or below the scan window), a pooled stack, a
  thread stack, or an unowned one. That is what found the window this release
  fixes. Off by default and expensive: it reads the resident address space
  inside the pause, once per collection.
  Two corrections in it are the reason its numbers can be read at all: the first
  version reported 47 hits that were **its own frames** (it runs on the
  collecting fiber's stack and carries the target as an argument — it now
  compares against the window the scan actually used), and it took a **SIGBUS**
  on a mapping `/proc/self/maps` calls readable, killing the collection it was
  measuring; reads now go through `pread` on `/proc/self/mem`, where a bad page
  costs one page.
  `bench/log/linux/2026-08-17-address-space-audit/FINDINGS.md`

- **Research arms for unowned fiber stacks**, kept rather than deleted because
  the next question about this defect will want the same ones and rebuilding
  them from a log is how a measurement gets quietly redefined:
  `GCRY_DEAD_STACK_NOROOT`, `GCRY_POOLED_STACK_ROOTS`,
  `GCRY_POOLED_STACK_NOROOT`, `GCRY_MAPS_INFLIGHT_ROOTS`,
  `GCRY_MAPS_INFLIGHT_NOROOT`, and `GCRY_UNOWNED_COVERAGE_AUDIT=1`, which walks
  `/proc/self/maps` beside the shipped fix and counts stack-shaped mappings
  nothing accounts for (549 accounted for against 4 not, per run). Every arm
  counts the stacks it walked and the words it offered, so a null result cannot
  be an arm that never ran — and each rooting arm has a twin that walks the same
  memory and offers nothing, which is what separated this fix from the birth
  grace's zero.

- **`GCRY_STAGED_WAIT=1` — the collector waits for a thread that has not
  published itself yet.** gcry records every thread from the moment
  `pthread_create` returns; this is the first change that *acts* on that record.
  Before stopping anything — and before `Thread.lock`, because a starting thread
  publishes by taking that very mutex, so waiting under it would deadlock by
  construction — the collector spins briefly while a staged thread has not
  appeared in Crystal's list. Measured at 16 workers, 160 collections a run:
  crashes **6/60 → 0/60** (Fisher p ≈ 0.03), census gaps **3/30 → 0/30**, with
  about 1.4% of collections waiting at all. A timeout drops the staged entries,
  so a thread that dies before publishing cannot buy a permanent spin.
  The first implementation could not have worked and looked like it did — entries
  were released only by `stop_world`'s later walk, so 68 of 68 waits timed out
  while the gap closed on the delay alone; the loop now drains published entries
  itself, ~140 waits since with zero timeouts. **On by default**
  (`GCRY_STAGED_WAIT=0` opts out) — the uncautious choice, made because the
  local repro is dead (`nested_spawn_uaf` 0/23, `ec_queue_audit` 0/25) and CI is
  the only observer left: a knob nobody sets is never observed, and the open
  question is whether this also closes the `Fiber` family, which has never been
  shown to share the window. Evidence for harm is nil.
  `bench/log/linux/2026-08-17-thread-birth-window/FINDINGS.md`

- **gcry now records a thread as soon as `pthread_create` hands back its
  handle.** Crystal publishes a thread onto `Thread.threads` only from inside
  its own `start`, and until then `stop_world` neither suspends nor scans it —
  a window the census measures at roughly one collection in a thousand. The new
  staging table (`src/gcry/platform/thread_staging.cr`) is filled from the
  creating side and emptied when the thread turns up in Crystal's list, and it
  **accounts for every gap the census has reported** (`staged >= gap`). It
  records only: what the collector suspends and scans is unchanged, because two
  earlier attempts that did change it broke thread startup — holding Crystal's
  thread-list lock across creation (3/10 crashes, window not closed) and a
  trampoline staging `pthread_self()` before user code (8/10 crashes, window
  covered exactly). The creating-side placement is 0/20 against 0/20 without it.
  Counters on `/gc-stats`; gated in `process_spec` with both halves broken on
  purpose. `bench/log/linux/2026-08-17-thread-birth-window/FINDINGS.md`

- **`GCRY_THREAD_CENSUS=1` — is every thread inside the stopped world?** gcry
  learns about threads from Crystal's list: `stop_world` suspends what
  `Thread.unsafe_each` yields and the stack scans walk the same set, so a thread
  that exists at the OS level but has not yet pushed itself onto
  `Thread.threads` is neither stopped nor scanned. The census counts the list
  against `/proc/self/status:Threads` at every `stop_world` and **has caught the
  difference** — the OS reporting 10 threads against Crystal's 9, during worker
  startup. About one collection in a thousand on a churn workload, one thread,
  scaling with thread creation (0/6 runs at 4 workers, 2/6 at 16). Off by
  default: it reads `/proc` inside the pause. The reader returns `nil` rather
  than 0 when `/proc` cannot answer, and `thread_census_unanswered` counts those,
  so "no gaps" can never be the result of never having looked. Linux only;
  Darwin answers `nil` by design. Gated in `process_spec`, broken on purpose and
  observed red. `bench/log/linux/2026-08-17-thread-birth-window/FINDINGS.md`

- **The pthread stack-bounds snapshot is countable, and a fault in it names the
  thread.** `snapshot_pthread_stack_bounds` asks libc for each thread's stack
  range before the suspend signals go out; a thread it visits but gets no bounds
  for silently loses the pthread-mapping half of its root coverage — the same
  shape as the register stubs v0.19.0 closed. `stack_bounds_visited` /
  `stack_bounds_read` on `/gc-stats` make that a number, gated in `process_spec`
  on Linux (Darwin queries the descriptor at lookup time and reports zeros by
  design) and broken on purpose at `visited=96, read=0`. And
  `stack_bounds_in_flight` holds the `pthread_t` being queried, non-zero only
  during the call, which the SIGSEGV report prints before anything about the
  faulting address. Prompted by aarch64 CI crashes inside `pthread_getattr_np`
  on 2026-08-16 — **three** by the end of the day, across two different gates,
  each of the first two leaving a libc frame and one hex number. The third
  arrived on the first run after these landed and answered: the fault is
  `0x418` into the thread descriptor the `pthread_t` points at, on the *next
  page* from the id itself, with 22 threads visited and 21 read. A **fourth**
  on 2026-08-17 repeated those numbers exactly — same `0x418`, same `22/21` —
  so it is one query at a reproducible point, not a race with a random victim.
  The snapshot now also remembers every id it has **successfully** read bounds
  for, and the report says whether the faulting thread is among them: a repeat
  means it stopped being queryable between two snapshots, a first-timer means
  it never was. That is the bit that decides between the two readings left
  after Crystal's own ordering rules out the cheap ones — the handle is
  published before the thread joins the list, the main thread's is set before
  its push, removal precedes `system_close`, and `push` / `delete` /
  `Thread.lock` all take the same mutex. The id table is bounded and says so
  (`stack_bounds_seen_full?`), so "first time" is never reported when the real
  answer is "we stopped recording". Gated in `process_spec` against a live
  thread id, broken on purpose in both directions.
  `bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md`

- **`GCRY_MARK_AUDIT=1` — is the mark complete?** After `mark_loop` and before
  `sweep`, with the world stopped, walk every marked block and report any base
  pointer into a **used but unmarked** block: the sweep is about to free
  something a live object points at. Names the parent's address, `type_id` and
  offset, and the child. `mark_audit_edges` / `mark_audit_misses` on
  `/gc-stats`, so a run that ends without a crash still says whether the mark
  held. Off by default — O(live heap) inside the pause; it reports, it does not
  fix. Gated by `make mark-audit`, whose `hold` arm plants an edge the mark
  provably does not follow — a pointer in a block's `scan_cap` slack under
  `GCRY_SCAN_CAPS=1` — and requires the audit to name it (199 missed of 1579),
  against 0 missed of 1977 on the same workload without it and 0 edges walked
  with the knob off. The first version of that gate did not set `GCRY_SCAN_CAPS`
  and passed vacuously: with the caps off the scan reads the slack too and the
  planted edge is not missed at all.

- **`GCRY_BIRTH_GRACE=1` — research only, and it found the window.** Roots every
  block `allocate` returns for the duration of the next collection, then drops
  it: the one window in which a block is live in a register or a stack slot and
  nowhere else. It runs **after** the mark, so it reports each newborn block the
  mark did not reach — address, size, first word, collection — before saving it.
  On the fiber-creation use-after-free: **20/48 crashes → 0/48**, back-to-back,
  with 2 774 blocks rooted and **0 ring overflows**, so the null arm cannot be a
  silent cap. And 157 of the reported saves across six runs are one thing: a
  192-byte block whose first word is 168, i.e. a **`Fiber`** — which read as a
  fiber under construction and was not; see the third correction below, which
  retires that reading. Not a fix and never a default: it
  keeps every allocation alive for a whole collection. Counters on `/gc-stats`.
  It also reports **where the value is not**: not on any fiber stack above the
  collector's entry SP, not in any suspended thread's captured GP registers, and
  `mark_root_candidate` accepts the address when handed it — so this is a
  scan-coverage gap and not a root filter. Two corrections came with it: the
  locator's first version found **its own parameter** on the stack (87 of 87
  hits, all at one offset inside the collector's call chain; excluding frames
  below the new `Heap#collect_entry_sp` removed every one), and the repro itself
  went quiet late in the session — the committed binary crashing 10/24 dropped to
  0/8 minutes later with no code change, so the rate is host-state dependent and
  a quiet arm proves nothing.
  **And a third correction, which retires this entry's own first claim.** The
  grace now follows its saves into the next collection: **0, 0 and 1** of them
  were live there, against 80–106 garbage. So ~99% of what it saves is ordinary
  short-lived garbage and the saved `Fiber`s are *finished* fibers, not fibers
  under construction — "a `Fiber` mid-`initialize` is reachable from no root we
  scan" is **not supported**. The arm's effect (20/48 → 0/48, back-to-back,
  twice) stands; its mechanism does not, and the remaining reading is that
  delaying a block's return to the freelist moves a use-after-free that depends
  on reuse timing.
  `bench/log/linux/2026-08-16-birth-grace/FINDINGS.md`

- **`BlockHeader::Flags::SWEPT`** — set alongside `FREE` by the sweep's freelist
  link, left clear by an explicit `Heap#free`, and read back by the SIGSEGV
  report. "The collector decided it was garbage" and "the program asked for it
  to be freed" are different defects with different owners, and the poison alone
  could not tell them apart. One OR per free.
  **It needed a second fix, and the first CI catch is what found it.** The flag
  was set only in `push_size_class_free`; four freelist **rebuild** sites in
  `collect_sweep.cr` — which re-link blocks that are *already* free after a
  chunk is emptied or page-released — reconstructed the header with a bare
  `FREE` and **erased** it. A block the sweep had genuinely reclaimed then read
  as an explicit free, and a CI catch was written up as "a second free path
  exists" on exactly that basis. It was retracted: measured on a chunk-emptying
  workload, the flag survives **278 of 278** with the fix and **0 of 278**
  without, and `Heap#free` / `realloc(size: 0)` fire zero times in a
  fiber-spawning workload, so there was never a plausible caller. Both
  directions — the discrimination and the rebuild preservation — are now gated
  in `process_spec`, broken on purpose and observed red at `Expected: 278`.
  A flag is only as good as every site that rewrites the word it lives in.

- **The fiber-creation use-after-free is now bounded from the other side.** The
  block is freed **by the sweep** (`flags 0x81`), **no marked object points at
  it** at sweep time (zero missed edges in 15 runs, 6 of them crashing), and the
  live deque points at it at fault time — so the deque acquired the pointer
  *after* the collection that freed the block, and at that collection it was
  live only in a register or a stack slot. Nothing moves the rate: `GCRY_SOUND`,
  `GCRY_INTERIOR`, `GCRY_AUTO_LAYOUTS`, an explicit root on the pool, the deque
  or the buffer, or never releasing a root on `realloc`'s new block. The hunt
  moves off heap edges and onto ambient roots of the allocating thread. Also:
  the repro is **20× cheaper** — `ROUNDS=20 FIBERS=64` gives 4/12 crashes at ~2 s
  a run. `bench/log/linux/2026-08-16-uaf-mark-complete/FINDINGS.md`

- **`GCRY_POISON_HOLDERS=1` — a use-after-free now names what still points at
  the block, not only which block it read.** `GCRY_POISON_TAG` got as far as
  naming the freed block; the open fiber-creation UAF stopped exactly there, at
  "a `Deque(Fiber::Stack)` buffer abandoned at a resize, freed correctly, and
  something still reads it". On a fault the reporter now searches the three
  places gcry can walk — the explicit root set, every live block in the heap,
  and every fiber stack — and names each holder: the holding block's address,
  size, `type_id`, flags, mark state and the offset the pointer sits at, or for
  a stack the slot address, the fiber's `stack_top` and whether that slot is
  inside the window the collector actually scans. Implies the tag and the crash
  report it extends, since a search with no block address to look for would be a
  knob that silently does nothing. Costs nothing until something faults.
  Gated by `make poison-holders`: a planted heap holder must be named **by
  address**, a stack-only holder must be found on the stack, and a block nobody
  holds must report **0** — the arm that fails if the walk matches the freed
  block on itself or walks FREE blocks. `--control` shows the search adds lines
  and removes none. Both directions broken on purpose and observed red. Linux
  only, alongside `make segv-report` and `make poison-freed`, because
  `SegvReport`'s register scan for the poison is Linux-only and on Darwin the
  search would have no address to look for.
  The search runs a **second pass against the holder itself**, and each reported
  holder's first payload words are dumped, so an object's state is readable and
  not only its address.
  **What it found, and it is the live pool.** Across 7 crashes the chain is the
  same every time, matched by address against the pools the harness prints
  before anything goes wrong: the freed block's only holder is the execution
  context's own `Deque(Fiber::Stack)` (`type_id` 210, `@buffer` at +16), and
  *its* only holder is the context's own `Fiber::StackPool` (`type_id` 199).
  Not an orphan and not the default context's. `0 of 0` explicit roots at both
  levels; every stack holder on a *running* fiber above `stack_top`, i.e. inside
  the scanned window; neither block `ATOMIC`. And the payload dump retires the
  "abandoned buffer" reading: `@capacity` matches the freed block's entry count
  exactly (1536 B ↔ 64, 3072 B ↔ 128) with `@size` below it, so the deque is not
  caught between `Deque#resize_to_capacity`'s `@capacity` and `@buffer` stores —
  it holds the buffer it believes is current, and gcry freed that.
  **Correction.** The first version of this reporter printed `UNMARKED` for a
  zero mark generation and this changelog read it as "no collection ever marked
  the holder". That was wrong: `sweep` clears every survivor's mark, so between
  collections every live object reads zero — measured against an object held in
  a local across three collections. The verdict is out; raw flags stay, with
  `ATOMIC` named because that bit does mean the payload is never scanned.
  `bench/log/linux/2026-08-16-uaf-holders/FINDINGS.md`

- **`ec_root_pins` — the Parallel EC pin block is now readable from outside the
  collector.** `scan_thread_roots` names the execution context's queues, event
  loop, stack pool and schedulers, and the whole block sits behind a macro gate
  on `Thread.@execution_context`. A gate that compiles a root scan out looks
  exactly like one that ran and found nothing — the shape of both v0.19.0
  defects. The counter is on `/gc-stats`; `bench/scheduler_roots.cr` and
  `make scheduler-roots` gate on it, measured as a delta across a collection
  taken before the context exists so ambient Thread-level pins cannot carry the
  arm. Both directions broken on purpose and observed red: stubbing `pin_ec_root`
  drops the delta to 7 against 16 named, and removing the per-collect reset moves
  the control arm off zero. Runs on Linux x86_64, Linux aarch64 and Darwin.
  Note what the gate is *not*: with the pins stubbed the parked fibers still
  survived 16/16, because the conservative scan reaches them anyway — the delta
  discriminates, the survival does not.

- Two candidate explanations for the 2026-08-10 soak SEGV are **eliminated**, and
  neither is a fix: (1) the macro gate is **open** on the configuration the soak
  builds — measured on Crystal 1.21.0, open by default and under
  `-Dexecution_context`, closed only under `-Dpreview_mt`, where the pre-EC
  scheduler means there is nothing to pin — so the pins do run there; (2) the
  precise-offset path drops module-typed ivars (neither Reference, Pointer,
  Value-with-ivars nor StaticArray, so they are omitted without forcing the
  conservative fallback — `@event_loop : Crystal::EventLoop` was named here as
  the instance and is **not** one, see the correction below), but that path only
  installs under `GCRY_AUTO_LAYOUTS=1`, which the soak does not set — the default
  `register_scan_caps` installs a cap and no offsets, so the scan stays
  conservative and covers the slot. The second is now **verified as a defect** in
  its own right and fixed — see below — though not as an explanation for the
  SEGV, and not on the ivar it was recorded against.

- **The soak, the STW × TLAB property test and the invariant checker now run on
  Darwin — and the soak's RSS gate stopped passing by measuring nothing.** Three
  bench harnesses each carried a `/proc/self/status` reader with a
  `rescue 0_u64`. On Darwin that is not a fallback: the file does not exist,
  every sample reads 0, and the soak's RSS ceiling compares 0 against a start of
  0 and passes. `bench/bench_rss.cr` replaces all three — `task_info(MACH_TASK_BASIC_INFO)`
  on Darwin, `/proc` on Linux, and **nil rather than 0** when the platform cannot
  answer, so `soak` and `rss_leak` refuse to run instead of gating on zeros
  (`pattern_fuzz` only reports RSS, so it tolerates it). The Darwin read carries
  two consistency checks — `resident != 0` and `resident_max >= resident` — so a
  wrong struct offset surfaces as "cannot answer" rather than as a plausible
  wrong number. Type-checked by cross-compiling for `aarch64-apple-darwin`; not
  yet run on a Darwin host. The macOS job gained `stw-mt-property-test-short`,
  `soak-smoke` (as `continue-on-error` until a Darwin RSS ceiling is *measured*
  rather than guessed), `ec-queue-audit` and `perf-baseline`.

- **`bench/perf_compare.py` — perf against a recorded baseline, not just against
  a floor.** `perf_smoke.sh` gates on thr ≥65% of Boehm, RSS ≤1.25×, p50 ≤2.5 ms,
  and quiet tip holds ~85% @ ~0.8× @ ~0.6 ms, so **85% → 70% clears every gate in
  the suite**. The comparator reads the same `summary.json` and compares the four
  ratio metrics against `bench/baseline/perf_smoke.json`; it runs at the end of
  `perf_smoke.sh`, report-only unless `PERF_GATE_BASELINE=1`. One rule holds it
  up: a baseline gates only if it carries a **tolerance derived from measured
  spread** — `--record` needs ≥3 runs and otherwise writes no tolerance, so the
  file reports rather than gating against a noise floor nobody measured. Runs
  now stamp the runner class into the summary, and a comparison across classes
  says so. `make perf-baseline` gates the comparator on fixtures — a regression
  in each metric's direction, an improvement, a within-noise run, both gate
  modes, a tolerance-less baseline, and the unrecorded file the repo ships —
  which needs neither wrk nor a quiet host. **No baseline is recorded yet**, and
  the perf job's own comment records ~68–88% thr across runs there, so the honest
  next step is N green runs on that runner class before any number is committed.

- **The soak can now keep its run queues occupied, and CI runs three arms at
  once.** The queue audit below can only catch a slot that is corrupt *while* a
  collection sees it, and the baseline workload gave it almost nothing: measured,
  **1 collection in 24** had a non-empty queue when the world stopped (10 Hz
  spawn against ~1 collection/s, each fiber returning immediately).
  `--fiber-churn=N` spawns N fibers per 1 ms burst that yield four times each —
  four because a fiber that returns immediately is drained in microseconds and
  the ring is empty again before any collection sees it. At **512**: 23 of 24
  collections non-empty, 2486 slots, max 508 per collect. Default **0**, the
  baseline every earlier soak ran on and the one the open 2026-08-10 SEGV is
  measured against. Churn holds thousands of fiber stacks (**+44.7 MB** over
  25 s), so a churn run whose `--rss-limit-kb` is still the baseline +4 MB is
  **refused** rather than failed on a bound nobody chose. The CI soak is now a
  `fail-fast: false` matrix of three concurrent arms — one 5 h arm a week cannot
  chase a crash that took 1h24m to arrive, and an arm that dies must not cancel
  the two that might have died differently — with `fiber_churn` and
  `soak_rss_limit_kb` as `workflow_dispatch` inputs and per-arm telemetry
  artifacts. No fault reproduced yet; what changed is the rate at which a run
  could catch one. `bench/log/linux/2026-08-15-soak-churn-arms/FINDINGS.md`

- **Three readings of the 2026-08-10 soak SEGV closed by audit.** gcry writes
  outside its own chunks in exactly two places and **neither was active in that
  run**: the parked-fiber scrub — the one with a measured-zero margin — was
  already default-off in that build (`93776f4` is an ancestor of `d36effe`), and
  the soak's disappearing links point into a fiber loop that never returns. No
  chunk was released either (`release_empty_chunks_this_collect?` is false under
  multi-mutator unless a Parallel reclaim knob is set; both default off), which
  rules out "a valid pointer into an unmapped chunk"; and the soak calls no
  `GC.free`, which rules out an explicit free of a live block. What survives is a
  block freed by the **sweep** while still referenced. The two root defects fixed
  in this release are not it either — the soak sets no `GCRY_AUTO_LAYOUTS`, so
  its `Fiber` / `GlobalQueue` / `Runnables` are scanned word by word.
  `bench/log/linux/2026-08-15-segv-write-path-audit/FINDINGS.md`

- **`GCRY_SEGV_REPORT=1` — the crash says what gcry knows about the address.**
  `Invalid memory access at 0x7f1700000149` is everything the 2026-08-10 soak
  left behind, and at that moment the collector could have said whether the
  address was in its heap span, which chunk and size class, whether the block
  read used or free, and what sat at its start. On SIGSEGV/SIGBUS it now prints
  that and hands the signal back to Crystal's handler — adding lines, removing
  none. Two things it had to be taught by being wrong first: **installing at
  `GC.init` accomplishes nothing** (Crystal installs its own handler afterwards
  with `sigaction(..., nil)`, discarding it — the first version printed nothing
  at all, so it now arms from the first collection), and **the poison is
  invisible to `si_addr`** (`0xdeadf2ee…` is non-canonical on x86_64, so a
  dereference raises #GP and the kernel reports address 0 — the report asks the
  faulting context's *registers* instead, reusing the ucontext offsets the
  collector already scans suspended threads with). `make segv-report` forks a
  child per fault shape — poison, FREE block, USED block, an address gcry never
  mapped — and requires each to be named for what it is; `--control` requires no
  gcry line at all. Default off: it installs a signal handler, which a collector
  should not do to a process that did not ask. On for the CI soak.
  `bench/log/linux/2026-08-15-segv-report/FINDINGS.md`

- **`GCRY_POISON_FREED=1` — a freed payload becomes `0xdeadf2eedeadf2ee`.** The
  2026-08-10 soak died on `0x7f1700000149`, and three sessions have argued about
  what that value was — a partially overwritten pointer, a reissued object's
  first two `Int32`s, a valid pointer into an unmapped chunk. The argument is
  unresolvable because the value is *plausible*. Poison is not: it is not a
  pointer, not zero, not anyone's data, and non-canonical on x86_64, so
  dereferencing it faults at an address that reads as a sentence. Every small
  used→free transition funnels through `push_size_class_free` (`GC.free`, the
  sweep's `reclaim_small`, and the warm-retain path), so one hook covers them;
  large blocks are poisoned at their own site, and `poisoned_blocks` on
  `/gc-stats` counts both. Sound because the freelist link lives in the header,
  not the payload. **The half that could have broken the collector is the one
  the gate is built around:** gcry skips `malloc`'s clearing memset when a size
  class's freelist is known clean, so poisoning without clearing that flag would
  hand poison to a caller expecting zeros — `make poison-freed` frees and
  re-allocates 64 blocks per class and checks every word, and deleting the line
  that clears the flag turns it red (10560 of 10560 words came back poisoned).
  Measured cost, soak pause p50 at n=5: **2.72 → 3.81 ms median, about +40%** —
  visible, unlike the queue audit's, which is why the default is off and the soak
  job is where it is turned on.
  `bench/log/linux/2026-08-15-poison-freed/FINDINGS.md`

- **`make darwin-page-query` — the experiment the Darwin low-water skip is
  blocked on.** macOS takes none of the 8.06 → 3.60 ms EC4 pause the parked-fiber
  low-water skip bought on Linux, because the skip rests on a primitive Darwin
  does not have. `mincore` cannot supply it on either platform — it answers
  *resident*, so a page written and later evicted reads absent and skipping it
  loses a pointer. The candidate is `mach_vm_page_query`, and whether its
  `PRESENT` / `PAGED_OUT` bits actually cover the written-then-evicted case has
  been the open blocker. `bench/darwin_page_query.cr` carries the candidate
  predicate — the exact logic a `darwin_pagemap.cr` would use — and five arms:
  untouched pages must read skippable, written ones must not, **every skippable
  page must read back zero** (the claim `spec/stack_low_water_spec.cr` pins on
  Linux, checked exhaustively here), an `MADV_FREE_REUSABLE` page must read zero
  whatever its bits say, and a page that leaves residency with its contents
  intact must not read skippable. Runs in the macOS job; type-checked by
  cross-compiling for `aarch64-apple-darwin`, **not yet run on a Darwin host**.
  The eviction arm is expected to be INCONCLUSIVE on a runner that will not
  compress — it exits 0 and says exactly that, because a probe that cannot
  produce the case must not report that it passed.

- **The queue audit also checks the structures, not only the slots in them.** A
  slot walk cannot report a reissued *container*: if the `Runnables` block is
  freed and reused, its head, tail and ring are read out of whatever the block
  became, and the walk finds garbage everywhere rather than a slot that stopped
  being a Fiber — which is the standing reading of the 2026-08-10 SEGV.
  `audit_ec_structs` checks every ivar whose declared type is a concrete
  Reference class for a **live object of that type** (heap + allocated + exact
  type_id), derived from `instance_vars`; abstract and module-typed ivars are
  skipped rather than guessed at. Two lessons are in the code: a referent
  *outside* the heap is not a fault (every context's `@name` is a String literal
  in the program image, which the first run reported as corrupt on every
  collection), and a container that fails identity is **not then walked** — the
  first run buried the real line under 255 garbage slot faults. Gated by a fifth
  arm in `make ec-queue-audit` that plants a live object of the wrong type in a
  scheduler's `@runnables` and requires the report to name it; silent across a
  15 s soak at `--fiber-churn=128`.

- **`GCRY_EC_QUEUE_AUDIT=1` — name the corrupt run-queue slot at the next
  collection instead of at the crash.** The 2026-08-10 soak died in
  `Parallel::Scheduler#quick_dequeue?` on `0x7f1700000149`, 1h24m in; the dequeue
  is where the damage surfaces, and the write that caused it is an unknown time
  earlier. The audit walks both structures that dequeue reads — each scheduler's
  `Runnables` ring between head and tail, and the context's `GlobalQueue` list —
  inside the stopped world, where they are quiescent, and requires every slot to
  be a **live Fiber** (in the heap, in an allocated block, `Fiber`'s type_id at
  offset 0). The first collection that sees otherwise prints the structure, index
  and value; `ec_queue_audit_ring_slots` / `ec_queue_audit_list_slots` /
  `ec_queue_audit_faults` / `ec_queue_audit_last_fault` are on `/gc-stats`, faults
  cumulative on purpose. Off by default (bounded, but inside the pause); on for
  the CI soak, whose telemetry now carries `queue_slots` and `queue_faults` per
  hour. Gated by `make ec-queue-audit` with two planted values that fail different
  halves of the test — one outside the heap, one a live object of the wrong type —
  and the gate asserts the report names *the planted value*: with the type check
  removed the second poison is accepted and the walk trips one hop later on
  garbage, which a fault count alone could not tell from a catch. Measured cost on
  the soak: none (p50 2.51–2.65 ms with, 2.66–2.81 ms without, n=3), because that
  workload's queues hold 0–1 slots per collection — thin exposure, not thin
  coverage. Also settled: the **default** execution context is
  `Fiber::ExecutionContext::Parallel` on Crystal 1.21.0 with or without
  `-Dexecution_context` / `-Dpreview_mt`, so plain `spawn` is covered by this and
  by the pin block. `bench/log/linux/2026-08-15-ec-queue-audit/FINDINGS.md`

- **`GCRY_POISON_TAG=1` — the poison carries the address of the block whose free
  wrote it.** `GCRY_POISON_FREED` proves a crash is a use-after-free and stops
  there, because one constant makes every freed block read alike. The tagged form
  puts `0xDEAD` in bits 63:48 and the freed block's address in the low 48 — still
  non-canonical, so it faults identically and the `si_addr == 0` register scan
  still finds it, and 48 bits is the whole of an x86_64 user address. The SIGSEGV
  report then describes that block against the heap's own tables, the same way it
  describes a faulting address: `the free that wrote it was of the block at
  0x…, still FREE, size 768, flags 0x1`. Opt-in, and it implies
  `GCRY_POISON_FREED`. It found what it was written for on its first run — see
  the entry below.

- **`bench/nested_spawn_uaf.cr` — a use-after-free in fiber creation, in seconds
  instead of 1h24m.** `make ec-queue-audit` went red three times on 2026-08-15
  (aarch64, Darwin, x86_64) and looked like a flaky gate. It was not: every crash
  cut off *before* that harness plants anything, and with `GCRY_POISON_FREED=1`
  it said what it was — `the poison is in the faulting context … a
  use-after-free, not a wild pointer`, in `Fiber#initialize` → `makecontext`.
  Stripped to the churn that provokes it — a fiber that spawns a fiber and
  yields, collections underneath — it is **16 crashes in 25 runs under gcry and
  0 in 25 under Boehm**, same file, so the collector is the subject and not
  Crystal's execution context. It does not need parallelism either: one worker
  reproduces it 7 times in 12. Not wired into CI, because it fails most runs on
  purpose; `make nested-spawn-uaf`, and it becomes the regression test when the
  defect is fixed. **`GCRY_POISON_TAG=1` then named the block**: across 40
  crashes the freed block is 384, 768, 1536 or 3072 bytes — `Fiber::Stack` is 24
  bytes, so those are 16, 32, 64 and 128 entries, the capacity-doubling sequence
  of a `Deque(Fiber::Stack)` — always `still FREE`, never reissued. It is
  `Fiber::StackPool`'s deque buffer. The trigger is the deque's **resize**, and
  that is measured rather than inferred: pre-grow the pool so it never resizes
  during the run and the crash goes to **0 in 20**, the only condition all day
  that removed it rather than halving it. Two things it is *not* — gcry never
  frees the buffer the deque is using (0 dead in 4 800 checks), and the window is
  not inside `Heap#realloc` (suppressing collection across its copy as well
  changes nothing). What the crash reads is a buffer the deque **abandoned** at a
  resize: freed correctly, still read. Boehm survives the same read because a
  conservative collector that sees the stale pointer keeps the block alive and
  its contents valid; gcry frees and poisons it, so the read is fatal. Whether
  the retained pointer is Crystal's or gcry's is the open half.
  `bench/log/linux/2026-08-15-nested-spawn-uaf/FINDINGS.md`

### Changed

- **CI pins Crystal instead of asking for `latest`.** On 2026-08-17 GitHub's
  releases-list endpoint for `crystal-lang/crystal` began returning an empty
  array — `releases/latest` and the tags stayed correct — so
  `crystal-lang/install-crystal`, which resolves `latest` off that list, asked
  for version `null` and took **ten of the twelve jobs** down with it, twice an
  hour apart. Every `latest` in the workflows is pinned to 1.21.0; the pinned
  job was green on the same tree throughout, which is what identified it. The
  matrix's `latest` arm became the same job as the pinned one and was dropped —
  worth bringing back when the endpoint recovers, since it is the only thing
  that reports a compiler release breaking the collector.

- **`make scheduler-roots` now runs with the crash diagnostics on**, for the
  reason the STW × TLAB test did: it has caught the open use-after-free twice —
  aarch64 on 2026-08-16 and x86_64 on 2026-08-17, both SIGSEGV inside
  `pthread_getattr_np` under `stop_world` — and both times could report nothing
  but one hex number, because the knobs were not set there.
- **The STW × TLAB property test now runs with the crash diagnostics on.** It
  caught the open use-after-free on 2026-08-17 — SIGSEGV inside
  `pthread_getattr_np` under `stop_world`, on **x86_64**, in a harness that uses
  plain `Thread.new` — and could say nothing about it, because
  `GCRY_POISON_HOLDERS` and `GCRY_THREAD_CENSUS` were not set on that step. That
  sighting also settled something: the crash is **not aarch64-specific**, and
  not specific to execution-context workers. Every earlier sighting being on
  aarch64 was sampling.

- **`make ec-queue-audit` and the 5 h soak arm now run `GCRY_POISON_HOLDERS=1`
  instead of `GCRY_POISON_FREED=1`.** Same memset, strictly more information: the
  tag puts the freed block's address in the poison, and the crash report then
  names the block, its size, whether the **sweep** or an explicit free released
  it (`Flags::SWEPT`), and what still points at it. Prompted by CI on
  2026-08-16 — `ec-queue-audit` caught the open fiber-creation use-after-free on
  aarch64 and the report could only answer "the poison is untagged, so it names
  no block". The local repro has gone quiet, so CI is currently the only place
  the defect is observed and a sighting is not something to waste.
  `GCRY_SEGV_REPORT` stays set explicitly on the soak so turning the poison off
  does not silently take the crash report with it.

- **`--collect-hz=N` — the soak's collect cadence is a knob, and it was the
  cheaper half of the catch rate.** The queue audit only reports a slot that is
  corrupt while a collection looks at it, so chances = collections × occupancy.
  `--fiber-churn` bought the occupancy factor; the other sat hardcoded at
  `sleep(1.seconds)`, and `GCRY_THRESHOLD` does not move it (118/119/119
  collections over 120 s at 32 MiB / 8 MiB / 2 MiB) because these collections are
  the harness's timer and not the allocator's. Priced on two 5 h CI dispatches, three
  arms each and identical but for the cadence: **×14.6 the collections, ×2.56 the
  slot walks**, because occupancy falls from 24.2% to 3.4% — 20× more collections
  leaves 20× less time for fibers to pile into a queue, so the two factors are
  not independent. The 120 s local arms had projected ×16 with occupancy flat,
  which is the lesson: measure a cadence knob at the duration it runs at. Pause
  and RSS do improve (2.04 → 1.84 ms p50, 30.4 → 10.8 MB max); the workload cost
  at 5 h is −13% to −40%. Default 1, the cadence every earlier soak ran; 0 is
  refused rather than divided by.
  `bench/log/linux/2026-08-15-soak-collect-cadence/FINDINGS.md`

- **`Gcry::Clock.monotonic_ns` — one clock reader, and no deprecated `Time` call
  left in the tree.** `Time.monotonic` is deprecated on the Crystal versions this
  shard supports, and every job printed the warning from `trace.cr`. The trace
  emitter could not simply move to `Time.instant`: `Time::Instant` is opaque by
  design and yields only a `Time::Span` between two readings, while `ts_ns` is an
  absolute stamp written into a stack buffer from inside the stopped world. The
  collector had already solved that — a bare `clock_gettime(CLOCK_MONOTONIC)` —
  and so had `MonitorGate` and `StwWatchdog`, each with its own copy of the same
  three lines. All four now call one, for the reason `RawOut` exists. The bench
  harnesses, which only ever wanted deltas, use `Time.instant` as intended.

- **The set of execution-context types is derived too — an `Isolated` context had
  no explicit pin at all.** The pin list stopped being seven names earlier in this
  cycle; the dispatch *into* it was still one: `if ec.is_a?(Parallel)`. There are
  two context types on Crystal 1.21.0. Measured, with an `Isolated` context up:
  **3 pins**, all of them the ambient per-thread slots any thread contributes, so
  its `@main_fiber`, `@thread`, `@wait_list` and the user's `@func` closure were
  left to the conservative body scan the pin block exists because it does not
  trust. Now dispatched over `Fiber::ExecutionContext.includers` plus their
  subclasses, most-derived first (so a `Concurrent` is pinned with its own
  `instance_vars`, not `Parallel`'s): **18 pins against 15 expected** for its own
  slots. `make scheduler-roots` gained an Isolated arm that derives its
  expectation the same way, and the queue audit asks the type whether it has
  queues rather than naming Parallel — `Isolated` has none, and is skipped for
  that reason. Note where this meets the layout fix below: `Isolated#func` and
  `#spawn_context` are two of the 19 ivars that walk dropped, so under
  `GCRY_AUTO_LAYOUTS=1` that closure was reachable by neither route.
  `bench/log/linux/2026-08-15-isolated-context-unpinned/FINDINGS.md`

- **The Parallel EC pin list is derived from the types, not written beside them.**
  `scan_thread_roots` pinned seven names; the structures carry **ten** pointer
  ivars on the context and **seven** on the scheduler, so `@mutex`, `@condition`,
  `@rng`, `@next`, `@previous`, `@name`, `@thread` and the scheduler's own
  `@global_queue` / `@event_loop` were left to the conservative body scan the pin
  block exists because it does not trust (Kemal EC4 SEGV @ …0008). `pin_ec_ivars`
  now walks `instance_vars` at compile time — a list drifts, `instance_vars`
  cannot — giving **45 named slots per collection** for a 4-worker context
  against the old 16. Anything not plainly a `Reference` gets **every word** of
  its slot marked rather than a guessed one: `sizeof(Fiber::ExecutionContext | Nil)`
  is 16 on Crystal 1.21.0 (a module union carries a type_id word), so pinning
  "the pointer word" would have pinned the type_id and looked covered. Two knock-on
  changes: `ec_root_pins` counts the *slot* rather than the mark, so a nil ivar
  and an ivar nobody visited stop being indistinguishable; and a new
  `ec_root_unpinned_ivars` on `/gc-stats` counts the one shape with no sound
  answer — pointer-bearing and narrower than a pointer — which
  `make scheduler-roots` asserts is zero. That gate computes its expectation from
  the same `instance_vars`, so an upstream addition moves both sides together.
  Both arms broken on purpose and observed red. It does **not** explain the
  2026-08-10 soak SEGV: the soak sets no `GCRY_AUTO_LAYOUTS`, so those ivars were
  reached conservatively there anyway — what changed is that they no longer
  depend on it. `bench/log/linux/2026-08-15-ec-pin-completeness/FINDINGS.md`

### Fixed

- **A fiber's stack was scanned by nothing while the fiber was ending, and a
  use-after-free lived in that window.** Crystal cannot release a terminating
  fiber's stack until the thread swaps off it, so `Thread#dying_fiber` parks the
  stack on the thread. While it sits there the owning `Fiber` is already gone
  from the fiber list — so no fiber scan reaches it — and the thread may still
  be **executing on it**, which gcry's other-thread scan cannot see either
  because that scan works from *pthread* stack bounds a fiber stack is nowhere
  near. Anything reachable only from those frames was unrooted, and a collection
  landing in the window freed it. `bench/nested_spawn_uaf.cr` at
  `ROUNDS=20 FIBERS=64` with poison on: **10/24 crashes against 0/24** with the
  new root, interleaved, and re-measured from scratch after the code was
  rewritten. It is not retention — same `heap_size`, same 160 collections, and
  fewer live objects than control — and it is not the walk: a twin arm that
  reads the identical memory and offers nothing to the mark stays at 12/24. On
  by default; `GCRY_DEAD_STACK_ROOTS=0` opts out. Gated in `process_spec` in
  both directions.
  **Two neighbouring windows were measured and are not the defect**, which is
  worth recording because the first version of this fix was built on one of
  them: a stack sitting in the `Fiber::StackPool` deque (rooting them is *worse*
  than control, 20/24), and a stack checked out of the pool but not yet attached
  to a published `Fiber` — a `Fiber::StackPool#checkout` hook covering exactly
  that moved 13/24 to 8/24, which is nothing, and was deleted rather than
  shipped on a maybe.
  `bench/log/linux/2026-08-17-dead-fiber-stack-roots/FINDINGS.md`

- **The live-object invariant was stated of heaps that do not maintain it, and
  flaked for it.** `spec/invariant_spec.cr` failed 6 runs in 25, on three
  different examples. Two causes, one of which is a real defect the check was
  right about: `note_alloc_bytes` uses plain `set(get + 1)` unless
  `heap_counters_atomic` is set, so a second allocating thread makes the counter
  lose increments **permanently** — the process heap drifts with no thread in
  the program but main and the monitor. The checker now states the invariant
  only where the counter can be kept (`Heap#counters_may_lose_updates?`), and
  establishes quiescence from the heap's own counter — sample, walk, sample
  again, re-check a mismatch `CONFIRM_ATTEMPTS` times — rather than from a
  thread count that called "main plus monitor" quiescent. It also no longer
  re-enters itself: the failure message interpolates, interpolation allocates,
  and that landed straight back in `after_malloc`. **0 failures in 100 runs**
  since. The counter itself is on the board; making it atomic costs the
  allocation hot path and needs the throughput numbers beside it.

- **The SIGSEGV report claimed x86_64 reasoning on every architecture, and
  implied a diagnosis Darwin cannot make.** Its `si_addr == 0` branch explained
  the address with "On x86_64 that is also what a *non-canonical* dereference
  looks like" — printed verbatim on arm64. Worse, the check that would settle
  it, looking for the poison in the faulting context's registers, is Linux-only:
  Darwin keeps them in a different `ucontext_t` layout and gcry has no reader.
  So a Darwin crash on a poisoned pointer read as "a null dereference" with no
  hint that gcry simply could not look — observed on Darwin CI 2026-08-17, where
  `make ec-queue-audit` died and the report had nothing, while the same crash on
  Linux names the block, its size, its free path and its holders. The branch is
  now architecture-accurate and says the limitation out loud. The missing
  `__mcontext` reader is on the board.

- **`Heap#realloc(ptr, 0)` freed the caller's block immediately.** Twenty lines
  below it, the grow path spells out why that must not happen: Crystal stores
  the result *after* `realloc` returns, so until that store the caller's ivar
  still holds the old pointer, and freeing it lets a peer Parallel collect reuse
  the block underneath a live owner — the defect that comment was written for,
  reachable through a second door. The size-zero path now leaves the block to
  the sweep, exactly as the grow path does.
  Stated honestly: this path fires **zero** times in a fiber-spawning workload
  and Crystal's stdlib has no caller that reaches it (`GC.free` appears only in
  the zlib and GMP allocator hooks), so it is a trap closed rather than a live
  defect fixed. Found while chasing what a use-after-free report called "an
  explicit free", which turned out to be something else entirely. Gated in
  `process_spec`, broken on purpose and observed red.

- **The page size was asked for on Darwin and assumed on Linux.** Three
  constants read `4096_u64`: the pagemap stride in `linux_softdirty.cr`, the
  `mprotect` alignment in `linux_mprotect.cr`, and a dead one in
  `darwin_stubs.cr` — in the same file whose `host_page_size` documents Apple
  Silicon as 16 KiB. `Platform.host_page_size` on Linux returned that constant
  rather than a reading, and eight call sites in `collect_sweep.cr` plus
  `heap.cr`'s mmap `align_up` trust it. Nothing was unsound: the pagemap stride
  is gated by `soft_dirty_tracks_writes?`, which writes a page and requires the
  bit back, so a wrong stride fails the probe and the backend is never selected —
  but it fails *silently*, and `mprotect` on a misaligned address fails the same
  quiet way. All three now call `sysconf(_SC_PAGESIZE)`. Linux x86_64 and Ubuntu
  arm64 both return 4096, so no supported host changes behaviour; measured
  identical backend selection before and after. Found by sweeping for the
  defect that produced three CI reds today — an assumption sitting where a
  measurement belongs — after the same shape turned up in
  `bench/darwin_page_query.cr`, whose hardcoded 4096 was a *quarter* of the
  runner's real 16384.

- **`make scheduler-roots` measured from a baseline that had not settled, and it
  cut both ways.** The gate went red three times on 2026-08-15 (aarch64 once,
  Darwin twice) on `the pin count moved by 2 with no Parallel EC in the process`,
  which read like a platform difference and was not: reproduced on x86_64 at **1
  run in 25**. Not a thread arriving either — the count jumps with
  `/proc/self/status` `Threads:` flat at 2 — but the runtime still finishing its
  asynchronous boot, since a 50 ms sleep before the first collection makes it
  stable on 10 of 10. Both arms baselined off that first collection, so the same
  line turned `--control` red *and* inflated the hold arm's `delta` by 2,
  discounting the threshold it must clear (the failing Darwin run: `before: 23`,
  delta 49 against 45 expected; settled it was 47). `settled_pins` now collects
  until two readings agree. No threshold changed; `--control` is 0 in 40 runs and
  the gate 8/8. `bench/log/linux/2026-08-15-ec-pin-baseline-settles/FINDINGS.md`

- **The lint gate linted ameba, and four regression specs had never run.** CI's
  Ameba step `cd lib/ameba`'d to build the binary and never came back, so
  `../../bin/ameba` ran with its working directory inside ameba's own checkout:
  it inspected **346 files of ameba**, never loaded gcry's `.ameba.yml`, and
  every green Ameba check on record is that. gcry is 82 files. `make lint` was
  always correct — make runs each recipe line in its own shell — so CI now calls
  it. The config also had `ExcludedPaths`, a key ameba does not read (it reads
  `Excluded`); harmless, since `Globs` already bounded the walk, but a line that
  looked like a rule and was not. The first honest run found **10 issues**, nine
  of them style — and four `Lint/SpecFilename` warnings that were the real find:
  `spec/regression/{1..4}_*.cr` are one regression test per historical GC defect,
  and `crystal spec` never ran any of them, because it collects `*_spec.cr`. They
  ran only inside `spec/all_specs.cr`, the kcov / ASan entrypoint, i.e. in two
  Linux-only jobs. `spec/all_specs.cr` keeps its name and is excluded from the
  rule with the reason written beside it — renaming *it* would make
  `crystal spec` run the whole suite twice.

- **Those four regression specs were testing Boehm.** Making them run showed it:
  each calls `GC.malloc` / `GC.collect`, and gcry only takes over `GC` under
  `-Dgc_none`, which neither `spec/` nor the `all_specs` builds pass. Measured —
  requiring gcry without the flag, three `GC.collect` calls move gcry's
  collection count **0 → 0** and `GC.malloc`'s result is **not in gcry's heap**.
  Moved to `process_spec/regression/`, the tree that does pass the flag:
  **process_spec 13 → 17 examples**, Linux and Darwin both. One then failed, which
  is why moving them was worth it — `live_objects < 100` was calibrated against a
  heap that held nothing; under `-Dgc_none` the whole runtime lives there (~150
  ambient). It now asserts the **delta** the v0.14.0 defect actually produced:
  the count must rise by at least the 10 000 allocated and come back within 500
  of baseline after they are freed and collected.
  `bench/log/linux/2026-08-15-ameba-linted-ameba/FINDINGS.md`

- **`make invariants` passes — and it was never a Darwin problem.** Two failures,
  two causes, neither platform-specific. `count_live_blocks` walked **dormant**
  chunks, whose headers the sweep has advised away: Linux zeroes them
  (`flags == 0` is not FREE), Darwin leaves them stale (also not FREE), so both
  read as live. Measured on Linux — 4 dormant chunks, **6 501 blocks counted
  against `live_objects = 1`**, 6 348 headers all-zero and 153 stale. A dormant
  chunk is empty by construction and the sweep already skips it; the walker was
  the last reader that believed those headers. The second failure
  (`spec/mt_spec.cr:118`) is a **race**: `after_malloc` runs outside the
  allocation lock, so with four threads allocating the walk and the counter are
  different instants — `actual=40 reported=41`, off by the allocation in flight.
  It is skipped above main+monitor threads, and the skip is counted
  (`Invariant.concurrent_skips`) rather than silent. **163 examples, 0 failures**,
  first green run recorded; both halves broken on purpose and observed red
  separately, both pinned by `spec/invariant_spec.cr` under plain `crystal spec`
  so they gate on every platform, and `GCRY_DEBUG_INVARIANTS=1 crystal spec` is
  now a step in the macOS job for the first time.
  `bench/log/linux/2026-08-15-invariants-dormant-walk/FINDINGS.md`

- **A precise layout could skip an ivar and still call itself precise.**
  `Layout.register` sorts every ivar into a scan offset, a noscan offset, or
  `force_scan_cap` (give up on precision for the whole type, scan its body
  conservatively). An ivar that is none of `Reference`, `Pointer`, a pointer-safe
  union, a `Value`-with-ivars or a `StaticArray` reached **none** of the three:
  no offset, and no fallback. The entry installed as precise, `scan_object`
  scanned exactly the offsets it listed, and the word was never read — so
  anything reachable only through that ivar was swept. Measured on both shapes
  that ship: a module-typed ivar and a `Proc` (whose second word is the only
  pointer to the closure's environment), each swept before the fix and live
  after, on both registration routes, with a Reference-typed control that
  survives either way — `bench/ivar_layout_roots.cr`, `make ivar-layout-roots`,
  gated on all three CI platforms. **19 such ivars in 186 stdlib types** for a
  program requiring `json`/`http/server`/`socket`, `Fiber#proc` and
  `Thread#func` among them. Fixed by adding `has_inner_pointers?` to the
  fallback — the same predicate `register_hash` already applies to its key and
  value types, and the one the plain-ivar walk beside it did not. Strictly more
  conservative: 9 of those 186 types move from precise to `scan_cap`, none the
  other way, and the precise/conservative scan mix on the `json_churn` shape is
  unchanged (4012/45 in both directions).
  **Correction:** `@event_loop : Crystal::EventLoop`, recorded above as the
  shipping instance, is not one — on Crystal 1.21.0 `Crystal::EventLoop` is an
  abstract *class*, so it is `< Reference` and its offset was always emitted.
  Every ivar of `Fiber::ExecutionContext::Parallel::Scheduler` classifies. The
  defect was real; that example was wrong, and the 2026-08-10 soak SEGV is
  unaffected either way (the soak sets no `GCRY_AUTO_LAYOUTS`).
  `bench/log/linux/2026-08-15-ivar-layout-drop/FINDINGS.md`

## [0.19.0] - 2026-08-14

Correctness release on **two** platforms. `collect_scan` asks the platform for a
suspended thread's GP registers, because a reference can live only in a register
— and on **Darwin** that call was an empty stub, while on **Linux aarch64** it
returned nothing under a "for now". Both dropped live objects. The second was
found by the gate written for the first, on its first CI run.

### Added

- **The Monitor-inside-STW overlap is excluded as the cause of the 2026-08-10
  soak SEGV** — measured, not assumed. `GCRY_MONITOR_GATE=0` restores the pre-fix
  behaviour and `GCRY_STW_TEST_STALL_MS` holds the world stopped on every
  collection, so the overlap can be manufactured rather than waited for: three
  control arms accumulated **438 overlaps** against the ~1.3 the crashing CI run
  had seen when it died, and none crashed. The narrower race the stall cannot
  amplify — a `munmap` landing while the collector walks thread stacks — needs
  only a number: that phase is **30 µs** of a 2.76 ms pause, one expected hit per
  ~46 h. `MonitorGate` stands on its own terms and its cost is now measured over
  a long run (**one wait of 263 ns in 3411 collections**), but the crash is
  unattributed again. `bench/log/linux/2026-08-13-soak-segv/FINDINGS.md`
- **The soak is dispatchable** (`workflow_dispatch`), with `soak_duration`,
  `monitor_gate` (`on` = tip default, `off` = pre-fix behaviour) and `stall_ms`
  inputs — so a rare cross-thread corruption can be chased without waiting for
  Monday. Inputs reach the step through `env:` rather than the script body, so a
  dispatch cannot inject shell.
- **`bench/soak.cr` records which configuration actually booted** — a `config:`
  line with `monitor_gate` / `stw_test_stall_ms` read from the collector, plus a
  60-second `# gate` heartbeat carrying `monitor_blocks` / `stw_waits`. An A/B
  arm labelled "gate off" that quietly booted with the gate on measures nothing,
  and a crash logged without that line cannot be attributed to either arm
  afterwards. Same rule `bench/sound_profile_ab.sh` already applies to `sound`.

- **`GCRY_SOUND=1` — root-completeness profile.** gcry's process defaults
  include a class of knobs that trade *root-scan completeness* for throughput
  or RSS: base-pointer-only ambient roots, the static-root `type_id` gate, the
  256 KiB STW stack/pthread lags, and parked-fiber scrub. Each can decline to
  mark a pointer that is genuinely live, so throughput measured with them armed
  does not answer "what does a correct gcry cost?". One flag turns the whole
  class off. Applied before the individual knobs, so any explicit `GCRY_*`
  still overrides it. [docs/SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md)
- **`scan_unaligned_candidates` / `GCRY_UNALIGNED_CANDIDATES=1`** (implied by
  `GCRY_SOUND`). The mark path dropped misaligned candidate *values* before
  `find_block` ever ran, so an interior pointer into a byte buffer
  (`str.to_unsafe + 3`) — a root bdwgc resolves via `GC_base` — was never
  followed. Escape back to the cheap filter: `GCRY_ALIGNED_CANDIDATES=1`.
- **`Gcry.sound_roots?` / `Gcry.root_soundness`**, plus the underlying knob
  values on `/gc-stats`. Derived from the live heap fields, so a benchmark can
  *prove* which configuration ran instead of trusting that an env var took.
- **`bench/sound_profile_ab.sh`** (`make bench-sound-profile`): Boehm vs gcry
  tuned vs gcry sound vs gcry sound+conservative, one host, one run. Aborts if
  a config labelled `sound` did not actually boot sound.
- **CI:** `sound-profile-smoke` plus the stress / churn / pattern-fuzz /
  thread-storm / finalizer / STW-MT suite re-run under `GCRY_SOUND=1` and under
  `GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1`. `samples/sound_profile.cr` fails the
  build if a root heuristic is added later and forgotten in
  `apply_sound_profile`.
- **`bench/root_phase_ab.sh`** — per-collection pause composition from the
  `GCRY_TRACE=1` records: ~370 samples per config at 1–7% IQR instead of the
  single `/gc-stats` snapshot, which is what makes per-knob attribution
  possible at all. Takes a config list, drives a foreign server binary (the fat
  app), builds for Parallel EC, and warns rather than reporting a median when
  the samples are multimodal.
- **`bench/sound_profile_ab.sh` no longer trusts wrk's `Requests/sec`.** WSL2
  steps `CLOCK_REALTIME` backwards ~1.6 s every ~32 s and wrk derives its
  duration from that clock, so a 10 s pass catching a step reports ~19% high —
  and since which config it hits is random, it *biased* comparisons rather than
  merely widening them. That is the mechanism behind every "sound ahead of
  tuned" reading. Passes are now timed with `CLOCK_MONOTONIC` against wrk's
  request count, and a stepped pass is redone.
- **`bench/stw_lag_pause.cr` / `make stw-lag-pause` — CI gate for the STW lag
  pause trap.** `GCRY_SOUND=1` is a 19× pause regression at Kemal EC4 and 14.5×
  on a fat app, and CI could not see it: the sound correctness suite passes at
  any pause, and reproducing the regression needed a server, a fat app or an EC4
  build. It does not — `stw_multi_stack_lag = 0` scans every parked fiber
  guard→bottom under any multi-mutator STW, so >2 OS threads and a parked fiber
  population are enough. 32 fibers reproduces 15× in under 6 s. Asserts the
  booted lag state against `GCRY_SOUND` and caps the lag-0 penalty at 30×; both
  host-independent, and the cap is an upper bound so making the root scan cheap
  cannot break it.
- **The collector warns once when `stw_multi_stack_lag` is 0 under
  multi-mutator STW** — the shape where every parked fiber stack is scanned in
  full. Deliberately not a boot warning: `GCRY_SOUND=1` sets lag 0
  unconditionally, but the knob is inert until STW runs with more than two
  mutator threads, and at Kemal EC1 the whole profile is throughput-neutral.

- **`bench/scrub_margin.cr` (`make scrub-margin`) — the parked-fiber scrub has
  zero margin.** The audit could close only half the scrub question: for a
  genuinely parked fiber, `@context.stack_top` is the only record of its SP, so
  there is nothing independent to check the wipe window against. This finds the
  boundary instead. `GCRY_SCRUB_OVERSHOOT=<bytes>` (research only, default 0)
  slides the window up into frames that must be live, and sweeping it in child
  processes supplies the positive control the first audit lacked — without a run
  that corrupts, a clean run at 0 proves nothing.

  Result on x86_64: clean through **56 bytes** of overshoot, corrupt at **60**.
  That is `swapcontext`'s six callee-saved registers plus the return address —
  **the wipe window ends exactly where live data begins.** No defect at the
  shipping window, but no tolerance either: correctness rests entirely on
  `@context.stack_top` being exact, every collection, on every platform, through
  any change to how Crystal spills registers. Further support for the knob being
  opt-in. [docs/SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md) § "Auditing the scrub"
- **`low_water_skips` / `low_water_skipped_bytes` on `/gc-stats`**, reset per
  collection. Whether the skip engages is not inferable from a pause number:
  it needs `multi_mutator_threads?`, which is `Thread` count > 2, and a real
  app can sit on that boundary — the fat app reported 2 threads from one build
  and 3 from another. `bench/stw_lag_pause.cr` reports them per config.

- **`Gcry::MonitorGate` — the EC Monitor no longer runs inside the stopped
  world.** `stop_world` never signal-suspends the Monitor (resume races wedged it
  in `sigsuspend`) and assumed it would cooperate by blocking in `allocate` /
  `lock_read`. Measured, it did not: through a 4 s stop it woke ~100×/s and ran
  `StackPool#collect` — `Crystal::System::Fiber.free_stack`, i.e. munmap of fiber
  stacks — *inside* the stop, while the collector scanned thread stacks. It is
  now handshaken out: the Monitor marks itself busy and backs off if the world is
  stopping, `stop_world` waits for in-flight work to finish. No compiler fork —
  the Monitor's three per-iteration calls are wrapped from the shard with
  `previous_def`. Cost over 3000 collections: **zero** added pause
  (`monitor_gate_stw_waits=0`), worst case one in-flight Monitor call; the wait is
  counted on `/gc-stats`. `GCRY_MONITOR_GATE=0` restores the old behaviour for
  A/B. Gate: `make stw-monitor-gate`, both directions.
  [bench/log/linux/2026-08-11-sysmon-runs-during-stw/FINDINGS.md](bench/log/linux/2026-08-11-sysmon-runs-during-stw/FINDINGS.md)
- **`GCRY_STW_WATCHDOG_MS` — a stop-the-world hang says something now.** When the
  collector wedges under STW every mutator is frozen in `sigsuspend`, so the
  process cannot report anything: no crash, no output, and `/gc-stats` cannot
  answer because its thread is suspended too. Finding the `pthread_getattr_np`
  hang below took inserting markers and rebuilding. Armed, a raw watcher thread
  (not a `Crystal::Thread` — STW must not suspend it) prints the phase that is
  stuck: `gcry: STOP-THE-WORLD STALLED 514 ms in phase=thread-stacks`. Validated
  against that real hang, where it names the exact phase the bug was in, and
  driven from both sides by `make stw-watchdog`: it must fire on a deliberate
  stall (`GCRY_STW_TEST_STALL_MS`, research only) and stay silent on an ordinary
  collection. Default off; the phase breadcrumb it reads is recorded either way.

### Changed

- **The weekly soak asked for 24 h on a runner GitHub cancels at 6 h, so it
  never once passed.** Both scheduled runs that ever reached it prove it:
  2026-08-03 was **cancelled at 6h00m14s**, and 2026-08-10 only reported at all
  because it crashed first (SEGV at 1h24m). A gate that cannot pass is not a
  gate. The CI arm is now **5 h** with `timeout-minutes: 330`; 24 h stays the
  local number (`make soak`, `SOAK_DURATION`). The crashing run also threw its
  own evidence away — `Upload telemetry` had no `if: always()`, so the hours of
  heap / pause / RSS history before the SEGV were discarded. It does now.
  `bench/log/linux/2026-08-13-soak-segv/FINDINGS.md`
- **CI jobs have timeouts, and the STW-heavy steps arm the watchdog.** On
  2026-08-10 both `test` jobs hung in `stw_mt_property_test` — the
  `pthread_getattr_np`-under-suspension bug fixed later that day in `8f2cdad` —
  and, with no `timeout-minutes` anywhere in the workflow, each burned **6h00m**
  in silence before the runner cancelled it. The hang was identifiable only from
  the last line printed (`STW-MT workers=4 iterations=50 seed=10001`) and the
  orphan process the runner killed. `GCRY_STW_WATCHDOG_MS=10000` is now set on
  the six steps that can wedge (the three STW MT property tests, thread storm,
  process parallel mark, the `GCRY_SOUND` correctness suite), so the next one
  prints `STOP-THE-WORLD STALLED <n> ms in phase=<name>` instead. Step-level and
  not job-level on purpose: `bench/stw_watchdog.cr` runs an unarmed child to
  prove the knob gates the print, and a job-wide env would quietly arm it.

- **The low-water skip now applies on the `lag > 0` default path.** It was
  gated on `lag == 0`, so the default faulted in a fixed 256 KiB window per
  parked fiber without asking whether those pages had ever been written — most
  had not. `fiber_stack_scan_top` now starts at
  `max(stack_top − lag, low_water)`: never wider than the lag window, never
  narrower than what the words can hold, since a page with neither the present
  nor the swapped bit has never been faulted. `scan_pthread_stack` already did
  this; the two paths now agree.

  **Kemal EC4 pause 8.06 → 3.60 ms** (−55%), root work 7424 → 3002 µs, post-GC
  RSS flat to 0.2%, `mark` and `sweep` unchanged — 9 paired reps, ~2300
  collections per config, single heap regime, IQR 24%/12%
  (`bench/log/linux/2026-08-09-104417-root-phase/`). Fat app at its ~72 MiB
  regime: **10.7 ms** against the old default's 28.8 ms and `GCRY_SOUND=1`'s
  18.2 ms (`…-105503-root-phase/`, stratified; softer — that session's FINDINGS
  records a thread-count confound).

  `lag = 0` remains the wrong default: the skip makes the *bounded* scan cheap,
  not the complete scan affordable (16.4 ms at EC4). Kemal at EC1 is unaffected
  by construction — `multi_mutator_threads?` is false at 2 threads, so the lag
  branch is unreachable. `GCRY_STACK_LOW_WATER=0` restores the old behaviour.

- **`scrub_fibers_enabled` now defaults to `false`** (Linux and macOS process
  GC; `GCRY_SCRUB_FIBERS=1` opts back in, `GCRY_DISABLE_SCRUB_FIBERS=1` still
  works). The parked-fiber scrub zeroes `[stack_top − 4 KiB, stack_top)` on
  *another* fiber's stack, keyed on `@context.stack_top` — a saved value, i.e.
  an estimate of where that fiber's live frames end. bdwgc's `GC_clear_stack`
  only ever wipes below the *calling* thread's own hardware SP.

  Nothing measured supports the default any more. The fat-app RSS that put it
  on (acikturkiye 3.00× → 2.65×) does not reproduce — acik is bistable between
  a ~44 and a ~72 MiB heap regime, so n=3 said +46% worse and n=9 said −34.9%
  better; stratified it is a wash. Kemal RSS is flat (0.76× → 0.75×).
  Throughput cannot resolve it in either direction: `roots + scrub + stacks` is
  0.146% of wall time at EC1 and the knob moves 9.1% of that, ~0.013%, while
  both published cuts (+1.29%, −1.22%) are ~100× that. `bench/scrub_audit.cr`
  closes the foreign-thread half of the correctness question — the wipe never
  reached a suspended thread's live frames across EC1 and EC4 — and explicitly
  leaves open whether a pointer can live only in the wiped region in a shape
  those runs never exercised.

  A knob with no measurable benefit, no measurable cost, and an open
  correctness question does not keep its default; it is also the only default-on
  heuristic that *writes* into memory the collector does not own, and a wipe one
  frame too high zeroes a live reference slot — an immediate nil deref when the
  fiber resumes, or a dropped root and a use-after-free later.
  [docs/SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md) § "What `scrub_fibers` costs"

  **Measured after the flip** (`bench/log/linux/2026-08-09-061508-root-phase/`,
  Kemal `/json` EC1, 9 paired reps, ~1050 steady-state collections per config):
  turning scrub back on costs **+11.2%** root work and **+5.9%** pause, and
  post-GC RSS is **2.2% higher** with it on — a wash at 9 reps, but not the
  reduction that justified the default. The +11.2% agrees in sign and magnitude
  with the −9.1% recorded for the opposite direction. End to end the flip is
  invisible: Kemal `/json` **81.4%** of Boehm @ **0.77×**, `/` **88.5%** @
  **0.76×** (`…-060252/`), inside this host's quiet-smoke band.

- **The Darwin fat-app headline is re-cut, and `~0.63×` does not reproduce.**
  It is **~98.0%** of Boehm throughput @ **~0.97×** post-GC RSS, n = 9 per arm,
  0 Non-2xx across all 18 trials (`bench/log/macos/2026-08-14-acik-recut/`).
  Same harness and same `base` variant as the 0.63×, so this is a replacement —
  which the 2026-08-10 `run_all.sh` cut never was, because that one collects
  once and is a different post-GC state.

  **gcry is not what moved.** Its post-GC RSS is within **0.6%** of the
  2026-08-04 draws (36,480 → 36,272 KiB) across ten days, two default flips and
  a commit range; Boehm's fell **35%** (57,568 → 37,392 KiB). The old ratio was
  in substantial part a statement about that session's three Boehm draws, and
  Boehm is the noisy arm here too — RSS IQR 16.8% against gcry's 4.5%. The
  v0.17-era ~18× gate stays closed; what changes is that gcry is at **parity**
  with Boehm on this app rather than a third below it. Throughput 89.9% → 98.0%
  is real at this n but not attributable — a commit range, the scrub flip and
  the register fix all sit between the cuts.

  Defaults confirmed **per draw** from `/gc-stats` rather than assumed:
  `fiber_scrub_runs = 0`, `low_water_skips = 0`, `thread_greg_candidates = 23`
  in all nine gcry draws. Two caveats are kept in the FINDINGS rather than
  smoothed over: n = 9 is below this repo's own 12-rep publishing floor, and one
  draw's `Requests/sec` (254.40) is a wrk artefact — it ended with `timeout 100`
  socket errors after 1.81 min instead of 30 s, so its rate divides real
  requests by stalled wall time. The median is insensitive; a mean would have
  been wrong by 8%.
- **Kemal, sound-profile and fat-app cuts re-taken on the tip default.**
  Sessions `bench/log/linux/2026-08-09-*`. The Kemal headline does **not** move
  — three trials cannot resolve a difference against a 6–8% run spread, and the
  re-cut lands inside the band this host has carried since v0.16. The
  sound-profile table is refreshed (tuned **81.8%** / sound **83.0%** / sound +
  conservative bodies **83.6%**, RSS 0.75/0.76/0.74×); it is a *third*
  unresolved throughput reading, not a confirmation of the second.
- **README's `scrub_fibers` +1.29% row is now marked retracted.** The docs
  retracted it in `355febd`; the README kept carrying it, along with the
  "loses on every axis" framing that the same commit retired.
- **`make stw-lag-pause` now carries CI's `--max-ratio=4`** instead of the
  program's loose 30× default. A local gate that passes where CI fails is not a
  gate. Measured this run: `stack_lag0` **1.03×**, `sound` **1.47×**.
- **`bench/stratify_root_phase.py`** — `root_phase_ab.sh` refuses to quote
  medians when a config's IQR exceeds 50% and tells you to stratify by heap
  regime, but shipped no tool to do it, so the fat app's numbers were
  re-derived by hand every session. The harness now prints the exact command.
- **`samples/sound_profile.cr` pins the scrub default.** Nothing did: scrub is
  off under `GCRY_SOUND` too, so flipping the process default back on left the
  default run still reading `tuned` and the sample still green. Verified by
  negative control — flipping the default fails the sample.

### Fixed

- **gcry dropped live objects on Darwin: a suspended thread's registers were
  never scanned.** `collect_scan` asks `Platform.each_thread_greg` for them,
  because a reference can live only in a register — the compiler is free to keep
  an object pointer in a callee-saved register and never spill it, and a
  conservative scan of that thread's stack then sees nothing. On Darwin that
  method was an **empty stub**, sitting next to a `thread_get_state` that
  already read SP and discarded the rest. The mark phase asked for a root source
  the platform did not provide, so those objects were swept.

  Observed on the fat app as a live `String`'s tail overwritten in place —
  `user_profile_picture\0\0\0\0<` where `user_profile_picture_path` should be,
  the same 25 bytes, the same allocation, across four sessions. It needed a
  collection to appear (`GCRY_DISABLE_AUTO=1` is 0/5 against 8/10, p ≈ 0.0003),
  which is what makes it a dropped root rather than a write bug.

  **Scope, because the defect is codegen-dependent:** every reproduction came
  from a **1.22.0-dev** probe compiler (2/5 without execution contexts, 5/6
  with). Under **stock Crystal 1.21.0 it never reproduced** — 0/5 on the
  system-compiler arm and 0/18 across `run_all.sh`, 0/23 combined. Whether a
  pointer lives in a register or is spilled is a codegen choice, which is also
  why Linux x86_64 never saw it. So the hole was real by construction on any
  compiler — the mark phase asked for a root source the platform did not
  provide — but stock-1.21 users have no reproduction, and no evidence of
  safety either.

  The same `thread_get_state` now fills a slot-parallel register table, cleared
  per STW with a validity flag so an unfilled slot cannot read as "no roots".
  **Ungated by `GCRY_DISABLE_SP_CLAMP`:** that knob trades precision for speed,
  whereas skipping the registers drops roots. A/B at `75a9d25`, both arms back
  to back: plain **4/10** corrupt, fixed **0/10** (p ≈ 0.006).

  The control was **re-established on the current probe compiler** before this
  release, because the A/B ran on an older one and a codegen-dependent defect
  does not inherit a base rate across compilers: `75a9d25` plain is **7/10**,
  tip with the fix **0/10**, same host and morning. Those arms differ by a
  commit range as well as by the fix, so the single-commit attribution stays the
  4/10 → 0/10 above; what the re-run establishes is that the workload still
  produces the defect on the current toolchain.

  Now gated, in `process_spec` and in `bench/greg_roots.cr` (`make greg-roots`),
  on a `thread_greg_candidates` counter that also appears on `/gc-stats` — 0 is
  what a platform that never reports registers looks like from the outside, and
  is exactly what the stub produced. The gate is verified red: stubbing the
  method out fails the spec and drops the count to 0, 5/5. The same gate now
  runs on Linux x86_64 and aarch64, where the contract has a different
  implementation (signal ucontext).

  **Still open:** nothing here connects this to the 2026-08-08 production
  SIGSEGV, and that diagnosis remains an unproven bet.
  `bench/log/macos/2026-08-11-080733-acik-ec-isolation/FINDINGS.md`
- **Linux aarch64 had the same gap, and the new gate found it on its first CI
  run.** `linux_stw.cr` set `UCONTEXT_NGREGS = 0` on aarch64 under the comment
  "skip full mcontext register dump on aarch64 for now (SP clamp only)", so
  `copy_ucontext_gregs` returned immediately and `each_thread_greg` yielded
  nothing while `collect_scan` called it — the same dropped-root defect as
  Darwin's stub, by a different route. `make greg-roots` reported 0 candidates
  with a thread suspended. x86_64 (`NGREGS = 23`) was never affected, and
  `process_spec` could not have caught it: that assertion is Darwin-gated.

  Fixed by giving aarch64 its real offsets: `regs[0]` at `uc_mcontext + 8` =
  **184**, **31** words x0…x30 (fp, lr included; no sp or pc — the stack is
  scanned by range and pc is not a heap pointer). The offset is cross-checked
  against a constant already known good rather than trusted on its own: `sp`
  follows `regs[30]`, so `184 + 31*8 = 432`, which is the SP offset the aarch64
  clamp has been running on in production.
- **`bench/stw_lag_pause.cr` did not compile on Darwin.** Line 263 called
  `Platform.pagemap_available?`, which exists only in
  `platform/linux_pagemap.cr`; the same file already guards the identical call
  further down, and this one was missed. So the target had never run on macOS —
  the failure was a build error, not a test result. Guarded, and it now passes
  at the relaxed `--max-ratio-nolw` bound, which supplies a number the
  "low-water skip on Darwin" item wanted: **21.3× pause ratio** is what Darwin
  pays for not having the skip (348 ms against 16 ms), measured on a Darwin host
  rather than inferred from the Linux 8.06 → 3.60 ms delta.
  `bench/log/macos/2026-08-14-release-validation/FINDINGS.md`
- **`scan_object` ignored `allow_interior_pointers` for raw buffers.** The
  conservative fallback marked untyped allocations base-only, so an interior
  pointer stored inside a `Slice` / raw buffer was dropped — and the same line
  was a second, silent consumer of `type_id_plausible?`, so the type_id
  heuristic still steered marking with `type_id_gate` off. Both now follow
  `allow_interior_pointers`, which is what makes `root_soundness=sound` a true
  statement. Pinned by `spec/sound_defaults_spec.cr` in both directions.

Kemal `/json` (WSL2 i3-12100F, median of 7,
`bench/log/linux/2026-08-06-052109-sound-profile/`): tuned **78.3%** @
**0.795×**, sound **81.0%** @ **0.794×**, sound+conservative **84.4%** @
**0.797×**. **RSS is flat across all three and reproduces across two
sessions.** Throughput did not, and four harness biases are why: the clock bug
above; a retry loop that made the 9×30 s methodology impossible; blocked
execution (config order confounded with time, ~2–3%); and a fixed config order
within each round (~2% to whichever ran first). All four are bias, not
variance, so run count never helped. With them out, the apparent gap fell
+2.27% → +2.11% → **+0.82%**.

**The sound profile is throughput-neutral on Kemal `/json` at EC1** — +0.82% at
1.7σ over 9 paired rounds, not distinguishable from zero
(`bench/log/linux/2026-08-06-140037-sound-profile/`). The one knob with a real
signal is `scrub_fibers`, and it argues against its own default: disabling it
gains **1.29%** (8/9 rounds, 3.2σ), matching the per-collection trace, which has
it saving 1.7% of root work. An earlier ~1pp claim was retracted separately: it
was measured before the raw-buffer fix above.

**Pause cost, however, is measured, and it is not small.** Per collection off
the trace records: Kemal EC1 398 µs → 398 µs (+0.1%), but Kemal **EC4** 7.2 ms
→ **141.7 ms** and acik at EC1 with a heap past ~60 MiB 17 ms → **213 ms**. In
all three the entire cost is the two STW lag knobs; the other five
root-completeness heuristics stay within ±6%, and parked-fiber scrub is a net
saving. This withdraws the earlier "STW lag knobs are inert at parallelism 1"
reading — true of Kemal, false of the fat app — and it is why the defaults stay
tuned for now.

- **The 24 h soak's RSS gate failed on warm-up, not on a leak.** It bounded final
  RSS at 10% of the *starting* RSS — a percentage of a ~6 MB base, where gcry's
  chunk granularity is 256 KiB, so three chunks crossed it. Measured over a 4 h
  run: RSS took exactly two values (7104 kB for 1296 samples, 7360 kB for 1583)
  with a single blip, while the heap *shrank* 2244 → 2116 kB and 1.33 M objects
  were finalized. That is a step function, not a ramp, and the total delta does
  not grow with duration — ~960 kB at 4 h against ~752 kB at 10 s. The bound is
  now absolute (`--rss-limit-kb`, default 4096 kB) and the failure message
  reports start/end/max and sample count so a step can be told from a ramp. The
  old `--rss-limit` percentage flag is a hard error rather than reinterpreted, so
  a stale `--rss-limit=30` cannot silently become a 30 kB ceiling. `make
  soak-smoke` now runs the same ceiling as the real gate instead of a looser one.

- **Collector hang: `pthread_getattr_np` was called with the world stopped.**
  `scan_other_thread_stacks` asked for each thread's stack bounds *after* STW had
  frozen those threads. That call locks the *target* thread's descriptor, which a
  suspended thread can be holding, and the collector then waited forever: no
  crash, no output, no diagnostic. It is specifically a query about a frozen
  thread and not libc under STW in general — isolated against a positive control
  in the same binary: non-main threads 9/100, main thread only 0/100,
  `LibC.malloc` 64 KiB under STW 0/100, `fopen` 0/100, and ~1999 finalizer
  `queue_pending` mallocs under STW 0/150 (which is why the finalizer registry
  was left alone). Measured at
  EC parallelism 4 with one fiber holding a worker across the first collection:
  **18 of 150 process starts hung**. Bounds are now snapshotted in `stop_world`
  under `Thread.lock`, before the first suspend signal, and the scan under STW is
  a table lookup (`Platform.snapshotted_stack_bounds`) — same number of
  `pthread_getattr_np` calls per collection, none of them inside the suspension
  window. **0 of 500** after the fix, 12 of 150 again when reverted. Misses in the
  table are counted as `pthread_bounds_misses` on `/gc-stats`, because a miss
  costs the pthread-mapping half of that thread's root coverage. Darwin is
  unaffected: `pthread_get_stackaddr_np` only reads the descriptor. Gate:
  `make stw-startup-hang`.
  [bench/log/linux/2026-08-10-stw-startup-hang/FINDINGS.md](bench/log/linux/2026-08-10-stw-startup-hang/FINDINGS.md)
- **Process / backticks under `-Dgc_none`:** Crystal `prepare_args` omits the
  argv NULL terminator; Boehm size-class padding hid it, gcry exact classes
  surfaced `EFAULT` (`Bad address`). Shard workaround:
  `crystal_process_compat.cr` (`malloc(args.size + 1)`). [#14]

## [0.18.0] - 2026-08-04

Product release on **upstream Crystal ≥ 1.21** — no compiler fork.
Stack-map support ships **dormant** (`GCRY_PRECISE_STACK` default off;
needs experimental Crystal emit to activate — research only).

Soft ≥90%@≤0.85× and hard ≥95%@≤1.0× both **MISS** on the default path
after the 9950X re-open; shard-only thr is **exhausted** (next lever:
compiler stack maps). Hub: `bench/log/linux/2026-08-02-018-FINDINGS.md`.
Parallel RSS stays **opt-in**. Linux Kemal PERF headline still carries
**v0.16.0** (~87% / ~0.80×).

### Highlights
- Finalizer registry fix (fat-app RSS)
- Linux process retain defaults → 0 (escape: `GCRY_EMPTY_CHUNK_RETAIN` /
  `GCRY_LARGE_CACHE`)
- Darwin acik tip ~90% @ ~0.63× (was ~18× at v0.17)
- Darwin Kemal tip ~84% @ ~1.01×
- Opt-in `GCRY_TIGHT_GROW` (not default)

### Documentation

- **`GCRY_TIGHT_GROW` (opt-in):** sticky newest-chunk freelist + sparse
  GC-before-grow closes acik mapped-freelist residual — **~103%** thr @
  **~0.92×** RSS (`…/acik-tight-grow-v2-med3/`); Kemal `/json` **~78%** @
  **0.78×** (`…/2026-08-04-085740/`) — not process default. Synced
  [PERF.md](docs/PERF.md) / [ACIKTURKIYE.md](docs/ACIKTURKIYE.md) / README /
  [HARDENING.md](docs/HARDENING.md). Hub:
  `bench/log/linux/2026-08-04-acik-tight-grow/FINDINGS.md`.
- **Tip fat-app band (Linux):** i3 retain=0 **~96%** thr @ **~1.63×** RSS
  (`…/2026-08-04-acik-i3-retain0-med3/`); 9950X **~90–100%** @ **~1.0–1.6×**.
  Residual = mapped freelist (`…/acik-i3-residual/`). Synced
  [PERF.md](docs/PERF.md) / [ACIKTURKIYE.md](docs/ACIKTURKIYE.md) /
  [STACK_MAPS.md](docs/STACK_MAPS.md) / README / ROADMAP. Kemal **headline
  stays v0.16** (~87% @ 0.80×); tip smokes ~80–85% @ ~0.75–0.79×.
- **0.18 campaign FINDINGS:** Phase 0 EC1 baseline `/json` **87.9%** @
  **0.81×** (`2026-08-02-120500/`); confirm soft **85.4%** @ **0.76×**
  (`152806/`). EC4 reclaim-off **80.5%** @ **5.48×** (`145600/`).
  Hub: `bench/log/linux/2026-08-02-018-FINDINGS.md`.
- **9950X thr hunt (CLOSED MISS):** tip default `/json` ~**80–83%** @
  **0.76×**, pause_p50 ~**0.33 ms** (`072122/` + `072954/`). KEEP
  **90.1%** @ **3.23×** (`080248/`). Warm retain 32/256 MiB reject as
  default. `GCRY_ALLOC_BATCH=4` **SEGV** under `/json` → reject.
  Soft-soak EC4 **40/40**. Summary:
  `bench/log/linux/2026-08-03-9950x-thr-hunt/`.
- **KEEP_CHUNKS ceiling re-measured:** `GCRY_KEEP_CHUNKS=1` → `/json`
  **95.0%** @ **3.07×** RSS on i3 (`121411/`); **90.1%** @ **3.23×** on
  9950X — escape only. Office profil: KEEP absolute ~**+4%** rps
  (`…/2026-08-04-kemal-thr-profil/`).
- **Rejects (not defaults):** `empty_chunk_retain=32 MiB` thr↓ (**81.9%**);
  hot-prefer dormant demotion (no thr win; reverted); Parallel dormant
  **default-on** thr % **68.8%** @ **3.29×** (RSS ok, thr gate miss;
  reverted); warm retain (RSS↑ without ≤0.85× path to ≥90%);
  `GCRY_ALLOC_BATCH=4` (SEGV); Linux HOLED `PAGE_DONTNEED` default;
  `GCRY_MOSTLY_EMPTY` / `MODE=dontneed` default. Prior
  `GCRY_PARALLEL_DORMANT=1` + retain 32 still the **supported RSS opt-in**
  (~75% @ ~4×).

### Fixed

- **Finalizer registry leak:** LibC tables (no `Entry.object` roots), MT
  quiesce, and Boehm-style resurrect-before-sweep so finalize is not UAF.
  Closed fat-app RSS that pinned dead `TCPSocket` / `OpenSSL::Digest`
  graphs (pre-fix tip ~8.5× → post-fix ~1.8× before retain=0).
- **Exclusive stack-map correctness:** `GCRY_PRECISE_STACK=2` no longer skips
  other-thread STW word scans (SYSMON / mid-swap / pthread); mutator spill
  window **4→16 KiB**. `GCRY_PRECISE_FIBERS=1` default **LEAF=8 KiB** (+ FP-fill);
  LEAF=0 + fill-only missed parked stack slots (`stackmap_exclusive_fiber_smoke`
  SEGV). Harness no longer forces LEAF=0. Acik med3 clean: exclusive **~96%**
  @ **~2.1×**, exclusivef **~99%** @ **~1.9×** — research only, not an RSS win
  (`…/2026-08-04-acik-exclusivef-stabilize-med3/`).
- **Nightly fuzz CLI:** `nightly-fuzz.yml` now passes `--seconds=1800 --seed=42`.
  Positional `1800 42` was ignored (`bench/fuzz.cr` only parses flags), so the
  job ran the default **30s** fuzz instead of 30 minutes.
- **CI flake/gates:** `perf-smoke` thr floor **70% → 65%** (GHA flaked at
  68.4% then 68.1% under 70%; host band ~68–88%). `rss_leak` gates
  **heap_size** late-vs-early primarily; RSS is a looser secondary ceil
  (DONTNEED re-fault noise).
- **pattern_fuzz pause ratios:** gate on per-phase `pause_last_ns`
  percentiles (was cumulative heap p50/p99/max — one early major poisoned
  every later pattern vs a lucky baseline on GHA). Short runs drop the
  worst phase before p99/max; baseline floored at 5 ms; Zipfian/Bimodal
  ratio limits raised for GHA (crystal 1.21 CI saw ~25× vs 3×/20× caps).
- **pause_budget minor/major ratio:** soft ceiling **3.0 → 4.5**. Post-STW
  EC1 majors landed ~6 ms p50 on GHA while nursery minors stay ~15–19 ms
  (ratio 3.22 flake).

### Added

- **`GCRY_TIGHT_GROW=1` (opt-in):** sticky newest-chunk freelist + sparse
  GC-before-grow for fat-app mapped-freelist residual. Acik med3 **~103%** @
  **~0.92×**; Kemal thr soft (~78%) — **not** process default. Escape:
  `GCRY_DISABLE_TIGHT_GROW` / `GCRY_DISABLE_TIGHT_GROW_GC`. Hub:
  `…/2026-08-04-acik-tight-grow/`.
- **`GCRY_MOSTLY_EMPTY` (research):** HOLED-less free-page advice on
  high-free-ratio chunks (`SPARSE`). Default MADV_FREE (no freelist rebuild);
  `MODE=dontneed` unlink+DONTNEED. Measured on acik — **not** a process
  default (`…/2026-08-04-acik-mostly-empty/`).
- **Stack maps spike:** [docs/STACK_MAPS.md](docs/STACK_MAPS.md) — GO on
  `llvm.experimental.stackmap` MVP. Runtime: `Gcry::StackMaps` parses ELF
  `.llvm_stackmaps` v3; hybrid walker (STW gregs + FP walk) calls
  `mark_precise_root` when `GCRY_PRECISE_STACK=1` (conservative scan still
  on). Crystal probe `gcry-stackmap-probe`: live locals (alloca preferred),
  auto `-no-pie`. EC root pins gate on `Thread` ivar presence (tip Crystal
  vs 1.21.0 release both build `-Dgc_none`). `GCRY_PRECISE_STACK=2`
  exclusive research knob; `make stackmap-smoke`. Walker: `find_near` +
  hybrid leaf-only; tip builds need `-Dpreview_mt -Dexecution_context`.
- **`GCRY_EMPTY_CHUNK_WARM_RETAIN`:** opt-in bytes of fully-free chunks kept
  mapped (no DONTNEED) before dormant/munmap — research middle path vs
  `KEEP_CHUNKS`. Measured on 9950X; **not** a process default (no
  ≥90%@≤0.85×). Spec: warm retain keeps heap_size / zero unmapped.
- **Secondary bench suite (crystal-metric):** vendored
  [kostya/crystal-metric](https://github.com/kostya/crystal-metric) under
  `bench/crystal_metric/` + `bench/run_crystal_metric_ab.sh` /
  `make bench-crystal-metric`. Same-host Boehm vs gcry wall-time A/B;
  **process-fresh** per bench (`FILTER=gc|core|stress|all`). Shared-process
  suite order inflated `JsonParsePure` (~20× after `JsonGenerate`); alone /
  fresh is ~5×. Not a ship headline — Kemal `/json` + acikturkiye stay
  primary. Documented in [PERF.md](docs/PERF.md).
- **EC4 soft-soak gate:** `bench/soft_soak_ec4.sh` + `make soft-soak-ec4`
  (N=40) / `make soft-soak-ec4-smoke` (N=5). Scrapes soft mark-miss /
  hard SEGV over Parallel TLAB-off Kemal `/json`; CI `perf-smoke` runs the
  smoke. Tip local gate **40/40 soft=0 hard=0** (thr med ~66k). Process-GC
  `make soak-smoke` is now on the PR `test` job.
- **EC1 numeric regression gate:** `bench/perf_smoke.sh` now also fails on
  post-GC RSS × Boehm (`MAX_RSS_X`, default **1.5**) and `/gc-stats`
  `pause_p50` (`MAX_PAUSE_P50_MS`, default **3.0**), after the existing
  same-host `/json` thr % gate. CI `perf-smoke` uses `MIN_PCT=65`
  `MAX_RSS_X=1.25` `MAX_PAUSE_P50_MS=2.5` (GHA thr band ~68–88%; RSS×/pause
  catch pause-campaign regressions).

### Changed

- **Linux process retain defaults → 0:** `empty_chunk_retain` and
  `large_cache_retain` munmap by default (was 16 MiB dormant + adaptive
  large-cache → 32 MiB). With the finalizer fix this closes acik RSS to
  ~**1–1.6×** Boehm. Escape: `GCRY_EMPTY_CHUNK_RETAIN` / `GCRY_LARGE_CACHE`
  (or `GCRY_KEEP_CHUNKS=1`). Darwin retain budgets unchanged.
- **Parallel experimental surface narrowed:** `GCRY_TLAB=1` and
  `GCRY_PARALLEL_RELEASE=1` are **unsupported** product paths (knobs kept
  for research/A/B). Process GC prints a stderr warning when either is set.
  `soft_soak_ec4` refuses both so the gate stays on TLAB-off + lazy.
  Prefer `GCRY_PARALLEL_DORMANT=1` for Parallel RSS. Docs: POLICY,
  HARDENING, PERF, COMPARISON.
- **EC1 post-STW sweep (pause):** sole-mutator path now ends STW before the
  O(heap) sweep (same shape as Parallel lazy). Empty munmap still goes through
  the pending list + flush; `@chunks` rebuild is guarded by
  `@block_other_heap` so SYSMON cannot race `map_chunk`. Fully-dead
  defer_reclaim fuses the dead-count into the discover pass (no second walk).
  Under-load `/json` pause med **~4.1→~0.59 ms**; quiet med-of-3 `/json`
  **84.6%** @ **0.82×** RSS, `pause_p50` **~0.58 ms**. Hub:
  `bench/log/linux/2026-08-02-ec1-018-pause-lazy/`. Parallel munmap+lazy
  remains rejected.
- **Skip post-rebuild `recalc_free_bytes`:** munmap empties subtract FREE
  payload counted in discover; drop the extra full-heap free walk after
  freelist rebuild. Under-load sweep med **~3.47→~2.63 ms (−24%)**; pause
  holds ~0.58 ms. Hub: `bench/log/linux/2026-08-02-ec1-018-pause-recalc/`.

### Performance

- **Fat-app (acikturkiye):** Linux tip ~**90–96%** thr @ ~**1–1.6×** RSS
  (i3 headline **~96%** @ **~1.63×**; 9950X **~90–100%** @ **~1.0–1.6×**).
  Opt-in `GCRY_TIGHT_GROW=1` → ~**103%** @ ~**0.92×**. Darwin tip base
  ~**90%** @ ~**0.63×** (v0.17 was ~**71%** / ~**18×**).
- **Darwin Kemal tip:** `/json` ~**84%** @ ~**1.01×**; `/` ~**91%** @
  ~**0.95×** (`bench/log/macos/2026-08-04-172842/`). Holds vs v0.17.
- **Linux Kemal:** PERF headline still v0.16 (~**87%** / ~**0.80×**). Tip
  quiet band ~**80–85%** @ ~**0.75–0.79×**; 9950X thr hunt closed MISS
  (~80–83% @ 0.76×; KEEP ~90–95% @ ~3× escape only). **pause_p50**
  ~**0.33 ms** on 9950X (~0.6 ms under-load i3 pause cut). Parallel
  opt-in unchanged (~80% @ ~5.5× reclaim-off; `PARALLEL_DORMANT` RSS).

## [0.17.0] - 2026-08-02

Darwin Kemal re-cut (first since v0.13) + Parallel TLAB-off + lazy sweep as a
**supported opt-in** (~79% `/json`). Linux Kemal PERF headline carries
**v0.16.0** (~87% / ~0.80×); EC1 remains the default path.

### Documentation

- **Darwin re-cut:** Kemal `/json` **83.6%** @ **0.93×** RSS (hold vs v0.13
  **83.9%**; confirm **83.2%**); `/` **89.6%** @ **0.97×**. acikturkiye
  `/api/v1/` **70.7%** thr @ **18.4×** RSS (was v0.13 **~78%** / **~16×**;
  confirm soft-Boehm % discarded). Sessions
  `bench/log/macos/2026-08-02-085522/` + confirm `091817/` (`18513e0`). See
  [PERF-macos.md](docs/PERF-macos.md), [ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).
- **EC1 production-readiness re-cut:** acikturkiye `/api/v1/` **~90%** thr @
  **~3.43×** RSS (was v0.15 **~2.54×** RSS; thr hold). `perf_smoke`
  **PASS** `/json` **84%** (`BENCH_RUNS=5`). Quiet Kemal tip smoke **~83%**
  `/json` (host soft; v0.16 PERF headline unchanged).
  Session `bench/log/linux/2026-08-02-ec1-readiness/`.
- **Parallel TLAB-off + lazy sweep → supported opt-in:** Stretch ~80% thr
  campaign closed (accepted hold **~78.8%** `/json`). Documented as a
  measured opt-in path in [docs/PERF.md](docs/PERF.md), COMPARISON,
  HARDENING, README — **not** the process default (EC1 remains the
  headline). `GCRY_TLAB=1` / Parallel munmap stay experimental. FINDINGS
  hub: `bench/log/linux/2026-07-29-parallel-tlab-FINDINGS.md`.

### Fixed

- **RSS leak CI flake:** `bench/rss_leak.cr` now runs dedicated warm-up
  cycles (default **15**) before sampling; late-vs-early gate applies only
  to post-warm-up medians. Previously the first half of a 20-cycle run was
  still ramping (~33% “growth” on GHA). `--warmup=` / `--limit=` knobs;
  CI + `make rss-leak` updated.
- **mprotect barrier `@@mp_hits` Atomic:** SEGV handler increment was a
  plain class `UInt64`; under `--release` the mutator re-read a
  register-cached zero, so `barrier_spec` false-pending'd on Linux/WSL
  even when the dirty card was set. Hits are `Atomic(UInt64)`; spec
  asserts dirty card + hits, and still `pending!` only if the host
  truly never traps the RO write. Soft-dirty remains the preferred
  Linux barrier.
- **CI pause-budget Phase 4:** in-header mark-gen cut major p50 (~23→~7ms
  on GHA) while nursery minors stayed ~15ms (full old→young), so
  `minor ≤ major` red-flaked since `c04f1ff`. Gate on absolute minor p50
  (50ms) + soft ratio 3.0 (`bench/pause_budget.cr`).
- **Darwin `stw_sp_clamp` flake:** EC1 other-thread scan skipped threads
  with nil `current_fiber` and silent-returned when fiber `stack_top` was
  unusable — CI saw `hits=0 fallbacks=0` despite Mach STW. Fall through to
  pthread scan; sample + process_spec park a real `Thread` during collect.

### Performance

- **Parallel lazy (post-STW) sweep:** End STW after mark; reclaim under
  per-size-class freelist locks while mutators run. Active when
  Parallel + TLAB off + empty-reclaim off (`GCRY_DISABLE_LAZY_SWEEP=1`
  escapes). Soft **0/40**. Same-host EC4 `/json` **~78.8%** Boehm @ ~**69k**
  (was ~76.6%; pause p50 ~20→~8.5 ms). Session
  `bench/log/linux/2026-08-01-ec4-lazy-sweep/`. Folded into PERF as
  **supported opt-in** (EC1 headline unchanged).
- **Parallel dormant + lazy sweep (opt-in):** dormant-only empty reclaim no
  longer forces in-STW sweep; already-dormant chunks skip the block walk.
  Soft **0/40**. Quiet EC4 `/json` **~75.1%** @ ~55k with retain=32 MiB, RSS
  **~4.0×** (was opt-in dormant **71.7%** / ~1.7× when lazy was disabled).
  Still below lazy gate **78.8%** — **not** Parallel default. Freelist churn
  revives dormants each cycle (`sweep_dormant_skips` ≈ 0). Session
  `bench/log/linux/2026-08-01-ec4-dormant-lazy/`.
- **Parallel bounded empty-chunk dormant (opt-in):** `GCRY_PARALLEL_DORMANT=1`
  DONTNEEDs empties within `empty_chunk_retain` (unbounded legacy:
  `GCRY_PARALLEL_DORMANT_ALL=1`). Soft **0/40**. Prior quiet (pre-lazy compat)
  **~71.7%** @ ~63k, RSS **~1.7×**. Session
  `bench/log/linux/2026-08-01-ec4-rss-bounded/`.
- **In-header mark generation:** `clear_all_marks` bumps an 8-bit generation
  in `BlockHeader` flags (bits 8–15) instead of walking the heap — kills
  `phase_clear` (~3 ms → ~tens of ns under Parallel reclaim-off). Wrap at 255
  does a full gen clear. Side-bitmap path unchanged. Soft **0/40**. Same-host
  EC4 `/json` **~76.6%** Boehm @ ~**67k** (was ~73.4%; ≥75% campaign bar).
  Pause p50 ~24→~20 ms. Session `bench/log/linux/2026-08-01-ec4-mark-gen/`.
  No `PERF.md` fold-in.
- **Parallel pthread LAG (experimental EC>1):** when suspend SP is on a pool
  fiber, scan only the top **256 KiB** of the OS pthread stack from high
  (was full map — dominated `phase_stacks` after fiber-scan dedupe).
  `GCRY_STW_PTHREAD_LAG` overrides; `0` = full. Soft **0/40**. Same-host EC4
  `/json` **~73.4%** Boehm @ ~**65k** (was ~71.5% @ ~47k); `phase_stacks`
  ~7→~0.4 ms; pause p50 ~34→~24 ms. Session
  `bench/log/linux/2026-08-01-ec4-pthread-lag/`. No `PERF.md` fold-in.
- **Parallel STW stack dedupe (experimental EC>1):** drop dual
  `scan_fiber_stack_full` in `scan_other_thread_stacks` — running fibers are
  already full-scanned by `scan_all_fiber_roots` under multi-mutator STW. Keep
  greg + SP-containing stack + pthread scans. EC4 pause phases cut (roots
  ~12.5→~2.2 ms, stacks ~12.5→~6.5 ms, p50 ~48→~37 ms vs prior sizeclass cut).
  Soft soak **0/40**. Session `bench/log/linux/2026-08-01-ec4-stw-dedupe/`.
  No `PERF.md` fold-in.
- **Parallel parked-fiber LAG default 256 KiB** (was 512; `GCRY_STW_STACK_LAG`
  still overrides; `0` = full guard→bottom). Soft **0/40**; quiet EC4 `/json`
  med ~**58k** ≥ 512 KiB cut ~**51k**. Same-host Boehm re-cut after ship:
  EC4 `/json` **~71.5%** @ ~47k (`2026-08-01-092050`). See FINDINGS.
- **`phase_scrub_ns`:** parked-fiber scrub timed separately on `/gc-stats`
  (excluded from `phase_roots_ns`) for Parallel A/B.

## [0.16.0] - 2026-08-01

EC1 thr recovery after Parallel-era STW / scrub / counter fallout. Supported
path remains EC parallelism **1**, `GCRY_TLAB` **off** (Parallel+TLAB stays
experimental — FINDINGS only, not folded into PERF).

### Performance

- **Linux Kemal** (same-host median-of-3, `wrk -c 100 -d 30`, scrub on): `/json`
  **~87%** of Boehm @ **~0.80×** post-GC RSS; `/` **~82%** @ **~0.79×**. Session
  `bench/log/linux/2026-08-01-093130/` (`cb4d7f2`; idle `/` from `slash-recut/`).
  Fair Boehm ~40k baseline. See [docs/PERF.md](docs/PERF.md) (Linux).
- **EC1 thr levers (Boehm ~40k fair):** restore v0.15 parked-fiber scrub on EC1
  (**4 KiB blind** clear; Parallel keeps 512 B + `clear_range_safe`). Tip with
  512 B + safe retained ~4× more `live_objects` than bebedae. EC1 alloc/free
  counters use plain get/set (`heap_counters_atomic` only when
  `EC_PARALLELISM>1`) — avoid LOCK XADD/CAS on the hot path.
- **EC1 sweep pause:** STW `live_objects` / `free_bytes` updates no longer
  CAS-loop per dead object. Empty dormant/munmap freelist cleanup batches
  into one `rebuild_size_class_freelist` per size class. Dormant post-STW
  flush early-outs when `dormant_chunk_bytes == 0`.
- **EC>1 thr gap (experimental):** auto-collect **trylock-or-skip** on
  `@post_stw` (no waiter pile-up; wait_total ~11s/20s → ~0). Default major
  threshold **64 MiB** when `EC_PARALLELISM>1` (`GCRY_THRESHOLD` still wins;
  EC1 stays 32 MiB). Same-host re-cut: gcry EC4 `/json` **~68%** of Boehm EC4
  @ **~53k** abs (was ~52% @ ~36k). Long soak **100/100** soft=0 hard=0
  (`2026-07-31-ec4-soak-100-post-thr`). No `PERF.md` fold-in. See FINDINGS.
- **Parallel empty-chunk reclaim opt-in:** default stays off under EC>1 (thr).
  `GCRY_PARALLEL_DORMANT=1` DONTNEEDs empties (was unbounded; see 0.17.0
  for retain-capped semantics). `GCRY_PARALLEL_RELEASE=1` adds munmap excess
  (hung in A/B). EC1 dormant+munmap unchanged. See FINDINGS RSS A/B.
- **EC>1 alloc-path A/B:** `GCRY_TLAB=1` @ EC4 still ~½ of TLAB-off thr (soft 0
  — keep opt-in). `@alloc_lock` as `pthread_mutex` deadlocks under STW
  (collections=0) — rejected; stay on `Crystal::SpinLock`. Fold
  `note_alloc_bytes` into the freelist lock (one acquire per small alloc /
  TLAB hit). Session `2026-07-31-ec4-alloc-thr-ab`. No `PERF.md` fold-in.
  See FINDINGS.
- **Atomic alloc counters:** `bytes_since_gc` / `live_objects` / `free_bytes` /
  etc. are `Atomic` so TLAB hits need no `@alloc_lock` for accounting. EC4
  TLAB-off thr unchanged (~51k); TLAB-on still ~52% of off. Session
  `2026-07-31-ec4-atomic-counters`. No `PERF.md` fold-in. See FINDINGS.
- **Per-size-class freelist SpinLocks:** TLAB-off small alloc/free lock only
  that size class (not global `@alloc_lock`). Large + TLAB table/refill keep
  `@alloc_lock` (per-class refill hurt TLAB-on via `@index_lock`×`find_block`).
  Quiet EC4 `/json` ~**55k** (was ~51k). Session
  `2026-07-31-ec4-sizeclass-locks`. No `PERF.md` fold-in. See FINDINGS.

### Fixed

- **EC1 STW stack scan thr regression (Parallel fallout):** process-STW full
  fiber/pthread scans added for EC>1 mid-swap were also applied on EC1
  (main+SYSMON). Every Thread root fiber is named `"main"`, so SYSMON hit a
  full pthread map scan (`phase_stacks` ~0.02→~3ms; Kemal `/json` ~86%→~80%
  Boehm). Restore cheap SP/`stack_top` other-thread scans when
  `!multi_mutator_threads?`; keep aggressive Parallel path. Limit
  foreign-SP scrub skip to Parallel only. Sessions `2026-07-31-164302`
  (regress), `2026-07-31-173530` (fix); final cut above.
- **Parallel `@suppress_collect` race:** plain `Int` `+=`/`-=` under concurrent
  `realloc` lost decrements so suppress stuck high (≈4607) and auto-collect
  never ran (`collections=0`, thr collapsed). Use `Atomic(Int32)`. Exposed when
  alloc counters left `@alloc_lock` (shorter critical section). See FINDINGS.
- **`chunk_containing` lock during post-STW:** skipped `@index_lock` whenever
  `@collecting` (not only `@world_stopped`). Flush keeps `@collecting` after
  `start_world`, so Parallel mutators `index_insert` while peers realloc
  unlocked → false `owns_user_pointer?` (`pointer is not a gcry allocation` on
  String::Builder). Lock skip only under true STW. Soft errors **0/60** after
  empty-chunk gate (was 2–3/60). See FINDINGS.
- **Parallel empty-chunk release off:** under multi-mutator STW, skip empty-chunk
  munmap even when `release_empty_chunks` is on (EC1 unchanged). Residual
  mark-miss × post-STW munmap surfaced as Kemal `/json` soft
  `pointer is not a gcry allocation` (22/40 → **3/40** with the gate; hard
  deaths 0/40). `GCRY_STW_STACK_LAG` env for LAG A/B (default 512 KiB). See
  FINDINGS mark-miss triage.
- **EC1 `stw_sp_clamp` counters:** idle/`stack_top` other-thread scan now
  increments `sp_clamp_fallbacks` (missed after cheap-scan restore; aarch64 /
  Darwin CI `samples/stw_sp_clamp` saw hits=0 fallbacks=0).
- **`pattern_fuzz` Stride CI floor:** raise Stride p99/max vs-baseline limit
  20→**80×** after EC1 4 KiB parked-fiber scrub (quiet ~11×; GHA crystal-latest
  hit ~45–57×).

- **No live TLAB steal:** `steal_from_other_tlabs` could null another thread's freelist head while that thread was in lock-free `tlab_alloc_small` (TOCTOU dual-alloc). Removed cross-TLAB steal; idle freelists return via STW `flush_all_tlabs`. `@tlab_steals` stays 0 (metric reserved for a future CAS steal).
- **FREE-claim × minor:** stack/thread FREE-claim cleared `FREE` before the minor/old filter, so an old freelist node became USED-unmarked and scrub dropped it. Skip claim entirely for old nodes during minor (minor never munmaps old chunks); nursery nodes still claim+mark.
- **Parallel worker STW stack scan:** `scan_other_thread_stacks` used `max(stack_top, sp)` for running fibers; stale `stack_top` above hardware SP skipped live frames, so Parallel+TLAB in-flight mallocs were swept (pin saw FREE). Prefer suspend SP (+ x86_64 red zone), mark saved GP registers from the suspend `ucontext`, and with TLAB scan the full fiber stack (SP/greg alone still flaked under Parallel>2). CI: `stw_mt_property_test --tlab --nursery` mixes minors.
- **TLAB FREE-claim chain mark:** stack/thread FREE-claim only marked the current freelist `user`; TLAB batch tails reachable via `next_free` stayed unmarked FREE, so empty-chunk release munmapped them and `tlab_alloc_small` SEGVd in `BlockHeader.free?` (Kemal `GCRY_TLAB=1` @ EC1). Claim now marks the `next_free` chain (keep FREE on tails); abandon TLAB heads that fail `find_block`.
- **Parallel mutator heap-index races (partial):** under `EC_PARALLELISM>1`, `chunk_containing` / last-chunk cache raced `index_insert` (false `owns_user_pointer?` / corruption). Added `@index_lock`; `with_alloc_lock` always locks (was a no-op when TLAB off); `ensure_tlabs` boots under `@alloc_lock`. Process-STW other-thread fiber stacks always full-scan. Kemal `EC>1` HTTP still fails — see FINDINGS.
- **TLAB per-slot freelist locks:** Parallel dual-alloc on lock-free TLAB heads (`ec_alloc_stress` double-free / `not a gcry allocation`). Per-slot `Crystal::SpinLock` (StaticArray — no GC malloc under `@alloc_lock` at boot). STW `flush_all_tlabs` must not take slot locks (suspended mutator may hold them). Refill always re-claims under the slot lock. Kemal `EC>1` still open.
- **STW running-fiber scan:** `scan_all_fiber_roots` skipped `fiber.running?`, relying on `thread.@current_fiber`; under Parallel that TLS can be briefly nil so stacks were missed. Under process STW, scan running fiber stacks too; if `current_fiber` is nil, fall back to pthread stack bounds + greg.
- **STW × ExecutionContext deadlock (`GCRY_STRESS`):** signal-suspending `SYSMON` deadlocks (fiber `yield` wait, or lost `SIG_RESUME` leaving `sigsuspend` forever). Fix: skip SIGPWR for the Monitor; cooperative STW via `@world_stopped` barriers in `allocate` / `lock_read`; busy-wait `@suspended` for other threads (no `yield_current`); hold `Thread.lock` for stop→start; harden resume handshake; **forbid process collect on `SYSMON`** so the Monitor cannot STW-suspend the mutator.
- **TLAB@EC1 measured:** correctness OK (Kemal 20/20 default + thr=32KiB; STW MT `--tlab`). `/json` thr ~71–77% of TLAB-off on same host — keep **opt-in** (`GCRY_TLAB=1`), not an EC1 default. Hit-path `find_block` dominates; stripping it SEGVs. See FINDINGS.
- **EC>1 thr vs Boehm (measured):** Kemal EC4 TLAB-off `/json` **~23%** of Boehm EC4 and **~0.52×** gcry EC1 (session `2026-07-31-100844-ec-parallel-thr`). Correctness quieter; Parallel still anti-scales — experimental.
- **Multi-mutator STW stack LAG:** full `guard→bottom` on every parked fiber dominated EC4 `phase_roots` (~100ms+/collect). Prefer suspend SP−red_zone when present; otherwise scan from `stack_top − 512KiB` (not full guard). Same-host A/B `/json` median-of-5: LAG **~30k** vs stw_full **~16k** (~1.9×); EC4 soak 30×8s **0/30**. Quiet re-cut vs Boehm: EC4 `/json` **~37%** Boehm EC4 and **~0.87×** gcry EC1 (was ~23% / ~0.52×). `GCRY_TLAB=1` @ EC4: soak 3/20, thr not above good TLAB-off — keep opt-in. See FINDINGS.
- **EC4 post-STW queue:** SpinLock wait on `@post_stw` burned ~8–11s/20s of worker time under Parallel HTTP. Switch to embedded `pthread_mutex`; auto-collect **coalesce** when a peer already cleared the debt; pause stats exclude queue wait. EC4 `/json` ~**40k** med (d=20) + soak **20/20** (was ~22k + crash outliers). Quiet `d=30` re-cut vs Boehm: EC4 `/json` **~52%** Boehm EC4 and **~1.17×** gcry EC1 (was ~23% / ~0.52× pre-LAG). Long soak **96/100** (4× SEGV/MARK_MISS). See FINDINGS.
- **Post-STW flush keeps `@collecting` + `@suppress_collect`:** clearing `@collecting` before flush allowed stress/auto re-entry while still holding `@post_stw_lock` (non-recursive SpinLock). Hold collecting through flush.
- **realloc suppress-collect + Boehm-like thread stacks:** growing `realloc` sets `@suppress_collect` around the fresh allocate so a mark miss cannot free-then-reuse the pinned buffer mid-copy (String::Builder `/json` double-free). `scan_other_thread_stacks` always scans `current_fiber`'s stack (no `name=="main"` early-out — every Thread main fiber is named `"main"`); also scans the pthread stack when suspend SP lies there. Register `String::Builder` layout (`@buffer` noscan).
- **type_id_gate stacks off by default:** process GC gated *all* ambient roots; stack words pointing at Channel/Deque buffers (no Crystal type_id) were dropped, so `Log::AsyncDispatcher#write_logs` SEGVd under frequent collect (`GCRY_THRESHOLD=32KiB` killed even EC1 at boot). Gate now applies to static roots only; `GCRY_TYPE_ID_GATE=1` restores stack gating. Kemal `EC>1` still has residual flakes.
- **Post-STW flush × Parallel collect race:** `@collecting` cleared before `flush_pending_empty_chunks`, so another EC worker could `stop_world` mid-munmap while a peer swept (`realloc(): invalid pointer` via `!is_heap_ptr` → `LibC.realloc`). Serialize next collect behind `@post_stw_lock` held through post-STW flush; refuse LibC.realloc for addresses still in the historic heap span.
- **Parallel pthread stack always scanned:** when SP sat on a pool fiber, `scan_other_thread_stacks` skipped the OS thread stack, so scheduler/main frames left on the pthread mapping were unmarked (Kemal EC4 ~1–2/40 SEGV). Always scan pthread bounds (SP−red_zone clamp when SP is there; full mapping otherwise).
- **STW scan stack that holds SP:** `Scheduler#swapcontext` sets `current_fiber` before saving the previous SP. Mid-swap STW then scanned the next fiber / stale `stack_top` and missed live frames on the previous stack (SEGV @ `0x4`). Also scan `[SP−red_zone, bottom)` of whichever fiber stack contains the suspend SP.
- **Process-STW full fiber stack scan:** under `@world_stopped`, scan every fiber from guard→bottom (ignore parked `stack_top`). Parallel EC4 still flaked with SP/current_fiber heuristics alone.
- **Skip fiber scrub when SP still on stack:** parked-fiber scrub used `stack_top` while Parallel mid-swap left the OS thread SP on that stack — wiping live frames before mark.
- **Historic heap span for realloc/free:** `@heap_min/@heap_max` tighten after munmap, so a dangling gcry pointer fell outside the live span and `GC.realloc`/`free` called LibC (`realloc(): invalid pointer`). Keep a monotonic `@heap_span_*` for the LibC-fallback guard.
- **Mutator stack scan from hardware SP:** `scan_mutator` used `pointerof(local)` (mid-frame), skipping the leaf/red-zone window on the collecting worker under Parallel.
- **Freelist unlink cycle guard:** `unlink_freelist_range` could spin forever on a corrupted `next_free` cycle (Parallel EC4 long-GDB hang: DEFAULT-1 in sweep while peers stuck in STW). Bound the walk and break self-loops; install the partial freelist instead of hanging the stopped world. Skip precise Hash entry walk when `@entries` is not a live heap pointer.
- **Revert Hash `@entries` grey-scan:** marking `@entries` via `mark_candidate` false-retained capacity-slot garbage (layout_spec) and collapsed Kemal `/json` thr (~36% of Boehm). `@entries`/`@indices` stay noscan; Entry walk remains authoritative.
- **`-Dwithout_mt` compile:** Parallel EC root pins (`Thread.@execution_context` / `Fiber::ExecutionContext`) are gated with the same Crystal flag condition so `fork_reinit` and Darwin/aarch64 sample builds compile.
- **STW fiber full-scan only with multi-mutator:** process-STW always full-scanning every parked fiber (Parallel mid-swap hardening) crushed CI Kemal `/json` thr (~78%→~48% Boehm). Restore `stack_top` clamp when only main+Monitor threads exist; multi-mutator now uses SP / `stack_top−512KiB` LAG (see above) instead of blanket `guard→bottom`.
- **CI pause-budget floor:** major p99 floor 100→200 ms, major max floor 250→350 ms (GHA flakes `100.72`, `163.6` / `270`). Stress `hello_env` / sample steps wrapped in `timeout` so a hang fails fast instead of a 6h cancel.

## [0.15.0] - 2026-07-29

Correctness release: process-STW × TLAB freelist UAF class fixed and CI-gated;
process-STW MT property harness; acikturkiye Linux re-cut measured; shard RSS
dead-end defaults documented. Supported path remains EC parallelism **1**,
`GCRY_TLAB` **off** (Parallel+TLAB stays experimental).

### Performance

- **Linux Kemal** (same-host median-of-3, `wrk -c 100 -d 30`, scrub on): `/json` **~86%** of Boehm @ **~0.77×** post-GC RSS; `/` **~86%** @ **~0.76×**. Session `bench/log/linux/2026-07-29-151144/` (`bebedae`). Collector defaults unchanged vs 0.14 — thr within host noise of the v0.14 ~89% cut. See [docs/PERF.md](docs/PERF.md) (Linux).
- **acikturkiye Linux re-cut (measured):** `/api/v1/` **~90%** of Boehm thr @ **~2.54×** post-GC RSS (median-of-3, `wrk -c 100 -d 30`, scrub on). Session `bench/log/linux/2026-07-29-112202/` (`9decd01`). Replaces the v0.14.0 ~93% / ~2.65× *estimate*. See [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **Shard RSS A/B (defaults unchanged):** same-host cuts rejected as defaults — Linux HOLED `GCRY_PAGE_DONTNEED`, process-default curated `HTTP::Headers::Key` Hash layout, collect-time mutator `clear_stack`, Linux 1 MiB large-cache floor. Keep fiber scrub, Linux **4 MiB** large-cache, HOLED **opt-in**; Headers layout stays app-side / `GCRY_AUTO_LAYOUTS`. See [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md) “Don’t bother”.

### Fixed

- **Explicit-root list × process STW race:** `add_root`/`delete_root` could run concurrently with `stop_world`, freezing a mutator mid-list splice so `@roots.each` walked a freed/`next`-corrupt `RootNode` (SEGV at `run_collection` during `stw_mt_property_test`). Serialize mutations with `@roots_lock` acquired before STW; collector may mutate without the lock while `@world_stopped`.
- **Parked-fiber scrub on thinly mapped stacks:** Cap wipe to the same 512 B fiber path as `clear_stack` and zero only readable pages via `Roots.clear_range_safe` (defense in depth; Crystal fiber stacks grow on demand).
- **TLAB + Parallel under process STW:** mid-`tlab_alloc_small` STW could leave FREE freelist nodes only reachable from mutator stacks; mark ignored FREE, then empty-chunk release munmapped them (and `unlink_freelist_range` could coerce USED→FREE). Fix: claim FREE stack/thread roots when TLAB+STW (**clear FREE but keep `next_free`** so scrub can walk the chain — `set_used` was severing freelists → OOM), freelist scrub after flush/mark (TLAB-only), flush only FREE nodes, TLAB epoch + detach-before-claim (no dual-alloc after flush), no nested `collect` under `@alloc_lock` (deadlock), unlock-and-collect retry on refill miss, steal stranded TLAB freelists, skip nil `Thread#current_fiber` under Parallel. CI gates `stw_mt_property_test --tlab --workers=2,4`.

### Added

- **Process-GC STW MT property harness:** `bench/stw_mt_property_test.cr` (`-Dgc_none`) runs Parallel allocator workers while the default EC pins roots (ACK handshake) and `GC.collect`s under real STW. Closes the gap left by library-heap `mt_property_test` (`stop_the_world=false`). CI gates `--workers=2,4` and `--tlab --workers=2,4`. (`make stw-mt-property-test`)

### Changed

- **Docs / knobs:** Linux HOLED page release documented as **opt-in** (post-STW; not “STW-heavy”). Large-cache defaults clarified (Linux process **4 MiB**, Darwin **1 MiB**). Darwin `GCRY_DISABLE_PAGE_RELEASE=1` / `GCRY_DISABLE_MADVISE=1` explicitly clear `madvise_free_pages`.

## [0.14.0] - 2026-07-29

Trust and tooling release: industry-style test suite, debug observability, and a
measured Linux Kemal re-cut. Collector throughput unchanged; Kemal post-GC RSS
now measured (not estimated).

### Performance

- **Linux Kemal** (same-host median-of-3, `wrk -c 100 -d 30`, scrub on): `/json` **~89%** of Boehm @ **~0.79×** post-GC RSS; `/` **~89%** @ **~0.78×**. Session `bench/log/linux/2026-07-29-035426/`. See [docs/PERF.md](docs/PERF.md) (Linux). Fat-app (acikturkiye) not re-cut — still ~93% thr / ~2.65× RSS *est.* ([ACIKTURKIYE.md](docs/ACIKTURKIYE.md)).

### Added

- **Debug invariant checker (`GCRY_DEBUG_INVARIANTS=1`):** validates heap invariants at runtime -- `live_objects` counter accuracy, freelist cycle/consistency checks, chunk index integrity, and block overlap detection. Hooks into `malloc`, `free`, and `collect`. Diagnostics use `write(2)` / no managed-heap alloc (not a claim that GC is async-signal-safe). `-Dgcry_invariant_abort` for core dumps. Exposed `Heap#each_chunk`, `#freelist_for`, `#nursery_freelist_for` for the checker. CI runs invariants on every PR. (`spec/invariant_spec.cr`, `make invariants`, CI `Debug invariants` step.)
- **Coverage infrastructure:** `spec/all_specs.cr` entrypoint for kcov (DWARF-based line/branch coverage). `ci/coverage.sh` wrapper runs kcov + `crystal tool unreachable` + `crystal tool macro_code_coverage`. `make coverage` / `coverage-kcov` / `coverage-unreachable` / `coverage-macro` targets. CI `coverage` job builds the spec binary, installs kcov from Debian, and uploads the report. (`ci/coverage.sh`, `Makefile`, `.github/workflows/ci.yml`)
- **Memory safety CI:** `make asan` builds and runs specs with AddressSanitizer (`-Dasan`). `make valgrind-samples` runs samples under Valgrind memcheck (`--leak-check=full`). CI `asan` and `valgrind` jobs on every PR. (`Makefile`, `.github/workflows/ci.yml`)
- **Deterministic replay fuzzing:** `bench/fuzz.cr` rewritten with `--seed=`, `--seconds=`, `--log=`, and `--replay=` flags. Fuzz logs every operation to a replayable log file (opcode + args). Replay mode reads the log and replays the exact sequence of heap operations. Op 9 (spawn + Channel) excluded from logs as non-deterministic Crystal runtime. CI runs fuzz + replay on every PR. (`make fuzz-replay FUZZ_LOG=path`, CI `Fuzz with log + replay` step.)
- **Property-based testing:** `bench/property_test.cr` -- random alloc/free/collect sequences with deep heap invariant verification: `live_objects` counter accuracy (reported == walked count), `heap_size` == sum of chunk `mapped_bytes`, freelist consistency, and per-node `live?` assertion. 100k iterations in ~8s. (`make property-test`, CI `Property test` step.)
- **Layout property test:** `bench/layout_property_test.cr` -- 5 self-contained sub-tests verifying precise scan offset correctness, conservative fallback, leaf layout (scan_cap=0), noscan offset keep-alive semantics, and scan_cap limiting. Runs 10k iterations in ~2.5s. (`make layout-property-test`, CI `Layout property test` step.)
- **MT property test:** `bench/mt_property_test.cr` -- concurrent allocation via fiber workers (2, 4, 8) with periodic collect; verifies no objects lost under concurrent alloc, `live_objects` counter accuracy after TLAB flush, and parallel mark (workers=2) produces the same live set as serial mark (workers=1). 500 iterations × 3 worker counts in ~2.4s. (`make mt-property-test`, CI `MT property test` step.)
- **24-hour soak test:** `bench/soak.cr` -- sustained load with alloc storm (~1000 obj/s), periodic collect (1 Hz), fiber spawn (10 Hz), finalizer load (100 obj/s), WeakRef via disappearing links (10 Hz). Hourly telemetry: heap size, free bytes, live objects, pause p50/p99, RSS. Post-soak RSS check (< 10% growth) and drain verification. Weekly CI cron (Monday 06:00 UTC). (`make soak`, CI `soak` job.)
- **Alloc pattern fuzzing:** `bench/pattern_fuzz.cr` -- 3 allocation distributions (Zipfian power-law, bimodal small+large, stride array-growth) each checked against baseline uniform-random. Verifies pause p99 < 8-10x baseline and RSS growth < 10%. 200 phases × 5000 objects per phase. (`make pattern-fuzz`, CI `Alloc pattern fuzz` step.)
- **Thread storm test:** `bench/thread_storm.cr` -- 3 phases: thread spawn storm (OS threads doing alloc/free/collect in batches), rapid thread create/destroy (250 short-lived threads), Crystal `Signal.trap` deferred alloc (event-loop mutator path; GC is **not** async-signal-safe — see POLICY.md). 1000+ iterations total, 0 errors. (`make thread-storm`, CI `Thread storm` step.)
- **OOM scenarios:** `bench/oom_test.cr` -- 3 phases: bounded heap (low gc_threshold, 500 iterations, no crash), mmap failure (graceful OutOfMemoryError), finalizer under OOM (no crash under pressure). (`make oom-test`, CI `OOM test` step.)
- **Bug-fix test policy:** `CONTRIBUTING.md` with "bug fix must include test" rule, `.github/PULL_REQUEST_TEMPLATE.md` with reproducing test checkbox, and `spec/regression/` directory with 4 regression tests (live_objects dormant chunk, hash_layout entries_size, scan_cap alloc_size mismatch, signal_stack false root). (`spec/regression/`, CI regression jobs.)
- **API misuse test suite:** `spec/api_misuse_spec.cr` -- tests covering `GC.free(null)`, `GC.realloc(null, 0)`, `GC.malloc(0)`, `GC.malloc_atomic(0)`, `Gcry.add_root(null)`, `Gcry.register_disappearing_link(null, ...)`, `collect` inside finalizer (no deadlock), Crystal `Signal.trap` deferred alloc (Linux; not async-signal-safe), `add_root` with large pointer, alternating malloc/free. (`make spec`, CI `spec` step.)
- **Fork reinit test:** `bench/fork_reinit.cr` -- standalone `LibC.fork` + `after_fork_child_reinit` + alloc in child + parent continues allocating after collect. 3 assertions, all pass. (`make fork-test`, CI `Fork reinit test` step.)
- **Finalizer complex scenarios:** `bench/finalizer_complex.cr` -- 7 phases: finalizer chain, finalizer calling `GC.collect`, finalizer adding root (resurrection), finalizer + disappearing links interaction, finalizer under heavy allocation pressure (500 objects), finalizer creating 1000 objects, and many disappearing links (200). 8/8 assertions pass. (`make finalizer-complex`, CI `Finalizer complex scenarios` step.)
- **Perf regression alerting:** `bench/perf_smoke.sh` rewritten with variance protocol -- 5 wrk runs per path, min/max discarded, median reported, noise ratio computed (IQR/median). same-host variance protocol (N wrk runs, min/max discard, median, noise ratio); gate is gcry /json % of Boehm only. Absolute RPS is not compared across hosts. Per-run JSON under `bench/log/` uploaded as CI artifact. (`bench/perf_smoke.sh`, CI `perf smoke` job.)
- **Microbenchmark suite:** `bench/micro/run_all.cr` -- 6-phase suite measuring alloc latency (10 size classes, p50/p99/max), free latency, collect latency (5000 obj, p50/p99/max), TLAB refill cost, STW suspend/resume latency, and GC lock overhead. Runs in < 10s. (`make microbench`, CI `Microbenchmark suite` step.)
- **Pause time budget:** `bench/pause_budget.cr` -- major p99/max budgets scaled to live set, incremental `collect_a_little` slice budget (STW-aware), minor vs major pause ratio. (`make pause-budget`, CI `Pause budget` step.)
- **RSS leak detection:** `bench/rss_leak.cr` -- cyclic alloc/free/collect; gate is intra-run RSS growth only (late-half vs early-half <10%). RSS/heap ratio is informational. Writes gitignored `bench/trend.json`. (`make rss-leak`, CI `RSS leak detection` step.)
- **Darwin platform parity tests (Phase 6.1):** `spec/platform_darwin_spec.cr` asserts soft-dirty/mprotect stubs return unsupported, `pthread_get_stackaddr_np` stack bounds contain the current SP, and host-page-aligned `MADV_FREE_REUSABLE` reclaim works. `process_spec` Darwin section exercises Mach `thread_suspend`/`resume` STW round-trip + SP clamp under `-Dgc_none`. Windows process-GC gap documented in `docs/INTEGRATION.md` (crystal#15173 HeapAlloc stub ≠ gcry port).
- **Compiler GC contract (Phase 6.3):** `bench/compiler_gc_contract.cr` mirrors Crystal `spec/std/gc_spec.cr` (stats/prof_stats/enable) plus malloc/realloc/collect, disable/enable, and runtime `@crystal_type_id` vs `crystal_instance_type_id`. CI also runs `crystal tool hierarchy` / `unreachable` on gcry sources. (`make compiler-gc-contract`)
- **Kemal E2E (Phase 6.4):** `bench/kemal_e2e.sh` hits every endpoint (`/`, `/json`, `/gc-collect`, `/gc-stats`, `/metrics`) before and after concurrent wrk load. CI runs 60s; full 10-min DoD via `KEMAL_E2E_DURATION=600 make kemal-e2e`.
- **GC trace log (Phase 7.1):** `GCRY_TRACE=1` emits NDJSON events (`alloc`/`free` sampled, `collect_start`/`collect_end`, `finalizer`, `barrier_arm`) via `Gcry::Trace`. Reentrancy guard avoids malloc recursion. (`make trace-smoke`, `spec/trace_dump_spec.cr`)
- **Heap dump (Phase 7.2):** `Gcry.dump_heap(io)` / `dump_heap_addresses` / `heap_dump_gone`/`new` for live-object NDJSON and leak diffs. Dump count matches `live_objects`.
- **Mutation harness (Phase 7.3):** `bench/mutations/run.sh` — 10 hand-crafted sed mutants; kill suite scores **10/10**. Feasibility notes in `docs/MUTATION.md`.

### Fixed

- **`Gcry::Trace` under `-Dgc_none`:** do not `require "json"` or write via abstract `IO` — both pulled JSON/OpenSSL into the GC bootstrap and broke process builds. Trace now emits NDJSON with a stack buffer + `LibC.write` to a raw fd.
- **Darwin `release_physical_pages` spec:** do not assert immediate zero-fill after `MADV_FREE_REUSABLE` (kernel may keep contents until reclaim). Assert aligned success + still-mapped only.
- **Nursery HTTP::Headers regression:** moved from `process_spec` to standalone `bench/nursery_headers.cr` — Spec + process GC + nursery was flaky on CI (SEGV during Spec reporting).
- **Process parallel mark:** moved from `process_spec` to `bench/parallel_mark_process.cr` for the same Spec+process-GC flake; CI retries `process_spec` up to 3 times.

- **`live_objects` counter drift on dormant chunks:** the counter was not updated when a fully-free chunk was marked DORMANT during sweep, causing the invariant checker to flag a mismatch (actual=6502, reported=1). *Discovered by the new invariant checker. Covered by `spec/regression/1_live_objects_dormant.cr`.*
- **`after_fork_child_reinit` stability:** `LibC.fork` + reinit + alloc in child, parent continues after collect. Covered by `bench/fork_reinit.cr`.

### Changed

- **Signal policy clarity:** GC is **not** async-signal-safe ([POLICY.md](docs/POLICY.md)). Crystal `Signal.trap` is deferred (event loop); tests/docs no longer claim handler-safe `GC.malloc`.

## [0.13.0] - 2026-07-27

### Changed

- **Darwin `empty_chunk_retain` 8 MB → 512 KB:** Aggressive `MADV_FREE_REUSABLE` reclaim on Darwin. Kemal RSS drops from ~160 MiB to ~18 MiB (1.04× Boehm). ACIKTURKIYE RSS unchanged (~700 MiB); conservative live set remains the dominant driver.
- **`scrub_fibers_enabled` = true (Linux + macOS):** Default-on fiber stack scrubbing to reduce false roots from parked fiber stacks. Linux: Kemal RSS 0.99×→0.95×, acikturkiye RSS 3.00×→2.65×. macOS: ACIKTURKIYE RSS steady at ~700 MiB (conservative live set dominant). Opt-out via `GCRY_DISABLE_SCRUB_FIBERS=1`.
- **Darwin `gc_threshold` 32 MB → 16 MB:** More frequent major collections on Darwin; pause halved (47→25 ms p50) on ACIKTURKIYE.
- **Darwin `small_chunk_bytes` 128 KiB → 256 KiB:** The 128 KiB chunk inflated collection count (~290 majors in 30s) and crushed acikturkiye throughput to ~57% Boehm. 256 KiB recovers throughput to ~78% without meaningful Kemal RSS cost (1.06× vs 0.88×). Set in `gc_override.cr` for Darwin only; library default stays 128 KiB. Escape: `GCRY_CHUNK_BYTES=131072`.

### Added

- **Darwin large-freelist `MADV_FREE_REUSABLE`:** `darwin_release_large_freelist_pages` issues `MADV_FREE_REUSABLE` for every cached large-object chunk after major collection on Darwin, dropping physical pages without unmapping. Linux unchanged (mmap-resident for cache budget).

### Performance

- **macOS v0.13.0** (Apple Silicon M2 Pro, median-of-3, `wrk -c 100 -d 30`, `--release`, 256 KiB chunk default):
  - Kemal: `/` **92.6%** of Boehm; `/json` **83.9%**; post-GC RSS **0.93–1.06×**.
  - ACIKTURKIYE `/api/v1/`: **77.9%** of Boehm, post-GC RSS **15.8×** (~600 MiB). 0 crashes across 3 trials.
  - See [docs/PERF-macos.md](docs/PERF-macos.md), [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).

## [0.12.0] - 2026-07-26

### Added

- **`-Dgcry_side_bitmap` (opt-in):** side `MarkBitmap` mmap path kept for experiments. Default is in-header `MARK` again after Linux A/B showed bitmap default at **82%** `/json` @ **~9.2×** RSS vs header **89%** @ **0.99×** (acikturkiye **50%**→**93%**, **5.6×**→**3.0×**) -- `bench/log/bitmap-ab/FINDINGS.txt`.
- **Bitmap shrinking + adaptive headroom (P1.1):** `MarkBitmap#shrink_to_fit!` reduces the side-mark bitmap mmap when the heap range contracts. Adaptive headroom (25% of recent growth history) prevents immediate re-growth. Combined with tighter `update_heap_bounds_after_unmap`, Kemal RSS drops from ~10× to ~5–7× (when `-Dgcry_side_bitmap`).
- **Darwin `MADV_FREE_REUSABLE` (P1.1, macOS):** `release_physical_pages` switched from the expensive 3-syscall `mach_vm_deallocate`+`allocate`+`protect` to a single `madvise(..., 5)`. `empty_chunk_retain` lowered from 64 MiB to **8 MiB** on Darwin (no cost; `MADV_FREE_REUSABLE` is cheaper than the retain budget).
- **Deferred madvise -- STW pause damping (P1.4):** All `madvise` / page-release syscalls defer to post-STW flush functions (`flush_pending_dormant_chunks`, `flush_pending_page_release_chunks`). DORMANT/HOLED flags set during STW; actual syscalls run after threads resume, eliminating kernel VM lock contention that caused 132–150 ms pause tails.
- **Cross-chunk dormant coalescing (P1.4):** `flush_pending_dormant_chunks` merges contiguous dormant chunks into a single `madvise` region (one syscall per run instead of one per chunk).
- **Per-chunk free-page coalescing (P1.4):** `dontneed_free_pages_in_chunk` pre-computes a live-page mask and issues one `madvise` per contiguous free run instead of one per free page (reduces from up to 64 syscalls/chunk to 1–3).
- **Auto-layouts (P2.1):** `Gcry.register_layouts` whole-program walk + `@unsafe_layouts` blacklist (`Cry` / `Crystal::*` / `LibC::*`; metric `layout_unsafe_skips`). **Opt-in** via `GCRY_AUTO_LAYOUTS=1` (Linux Kemal `/json` ~**−7pp** vs builtins-only -- see `bench/log/thr-abis`). Escape when opted in: `GCRY_DISABLE_AUTO_LAYOUTS=1`.
- **Per-source root reject counters:** New `type_id_stack_rejects` / `type_id_static_rejects` / `type_id_thread_rejects` count where false roots come from (fiber/mutator stacks, BSS/data, TLS). Plus `type_id_root_false_negatives` is now exposed in `/gc-stats`, metrics, and Prometheus -- was tracked but never surfaced. Sum invariant: `stack + static + thread == type_id_root_rejects`.
- **Adaptive nursery threshold:** `@nursery_threshold` adjusts dynamically after each minor based on the moving-average survival rate (last 10 minors). Target survival rate is 50%; when survival rises above it the threshold grows by 25% per minor (reducing collection frequency); when survival drops below 25% the threshold shrinks by 25% (collecting sooner to limit survivor pressure). Clamped to [64 KiB, 8 MiB]. Default-on for process GC (`adaptive_nursery=true`); disable via `GCRY_DISABLE_ADAPTIVE_NURSERY=1`.
- **Large-cache LRU eviction + adaptive retain (P3.3):** `cache_large_chunk` inserts at tail (LRU). `trim_large_cache` evicts from head. Adaptive retain: after each major, hit-rate above 50% doubles retain (capped at 64 MiB); hit-rate below 10% halves it (floor 1 MiB). Default: 1 MiB on Darwin (macOS), 8 MiB on Linux.
- **Bitmap headroom reduced 25% → 12.5%:** `note_bitmap_growth` now uses `avg_range >> 3` instead of `>> 2`, shrinking side-mark bitmap reserve -- less RSS waste on stable heaps.

### Fixed

- **Hash layout walk used `entries_capacity` instead of Crystal `entries_size`:** precise `scan_hash_object` iterated `(1 << indices_size_pow2) / 2` slots. After `realloc`, slots past `@size + @deleted_count` are uninitialized; non-zero garbage `@hash` words caused false marks / mutator UAF under acikturkiye (`GCRY_DISABLE_LAYOUT=1` was the only green bisect). Now walks `@size + @deleted_count`, capped by capacity. Also word-scans `@block` (`Proc?`, 16 bytes) instead of treating it as a single pointer.
- **Layout `scan_cap` required `alloc_size` match:** on size mismatch (raw buffer whose leading `Int32` collided with a registered `type_id`), the old path still applied that type's `scan_cap` and returned -- truncating the mark scan and dropping live pointers (acikturkiye SEGV with layouts on; green with `GCRY_DISABLE_LAYOUT=1`). Size mismatch now falls through to full conservative scan.

### Changed

- **In-header MARK is default again:** side mark bitmap moved to `-Dgcry_side_bitmap` after Linux HTTP A/B (`bench/log/bitmap-ab`). Headline cut: Kemal `/json` **88.8%** @ **0.99×** RSS; acikturkiye **92.8%** @ **3.0×** -- [docs/PERF.md](docs/PERF.md), [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **Nursery + incremental default-off for process GC:** Linux no longer enables `nursery` / `incremental_auto` by default. Soft-dirty false-negatives under WSL release HTTP (Kemal) caused Hash key UAF / SEGV (`0x0`/`0x4`/`0x11`). Opt in with `GCRY_NURSERY=1` / `GCRY_INCREMENTAL=1` after measuring. Darwin unchanged (already off). Related fixes kept: `realloc` pins old buffers across collect; explicit roots skip `type_id_gate`; old→young always full-walks (soft-dirty is additive only) with one-level buffer chase.
- **`incremental_auto` defaults (P1.3, Linux/Darwin):** *(superseded -- both off by default; see above.)*
- **`GCRY_AUTO_LAYOUTS` opt-in (P2.1):** briefly default-on; reverted after Linux A/B -- builtins-only `/json` **~85%** Boehm vs auto-on **~78%** (`bench/log/thr-abis`). Set `GCRY_AUTO_LAYOUTS=1` to enable.
- **Bench default build:** `bench/run_all.sh` uses pure `--release` again (PERF.md). `--release --debug --error-trace` cost ~15–18pp thr; use `CRYSTAL_FLAGS` / `DEBUG=1` only for SEGV hunting.
- **Nursery default-on for Linux process GC:** *(superseded -- off by default again; see above.)*
- **Darwin blacklist re-enabled:** Previously default-off on Darwin (freelist-abandonment spiral under all-conservative scanning). Layout-precise scans (P2.1) cut false root hits sharply, making the blacklist safe. Escape via `GCRY_DISABLE_BLACKLIST=1`.
- **Darwin aggressive free-page release:** `flush_pending_page_release_chunks` walks ALL kept size-class chunks (not just HOLED) on Darwin. `MADV_FREE_REUSABLE` is page-table-level (no VM lock churn), so the extra walk is cheap per major.
- **Darwin large cache reduced to 1 MiB (adaptive):** Adaptive LRU policy starts at 1 MiB on Darwin (vs 8 MiB on Linux). mach_vm reclaim already punches holes on free, so a fat cache is wasteful; 1 MiB floor avoids mmap churn for the common case.

### Performance

- **Linux** Kemal (WSL2 x86_64, median of 3, pure `--release`, in-header MARK default, session `bench/log/linux/2026-07-26-173602/`): `/` **90.4%** of Boehm; `/json` **88.8%**; post-GC RSS **0.99×**. acikturkiye `/api/v1/`: **92.8%** of Boehm, post-GC RSS **3.00×**. Side-bitmap A/B (`2026-07-26-171942`): `/json` **82.3%** @ **~9.2×**, acik **50.1%** @ **5.58×**. See [docs/PERF.md](docs/PERF.md), [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **macOS** Kemal (Apple Silicon M2 Pro, median of 3, pure `--release`, in-header MARK default, session `bench/log/macos/2026-07-26-181318/`): `/` **85.4%** of Boehm; `/json` **86.5%**; post-GC RSS **1.34–1.36×**. acikturkiye `/api/v1/`: **76.7%** of Boehm, post-GC RSS **22.3×** (RSS improved 2.6× vs prior session; conservative live set remains the dominant driver). See [docs/PERF-macos.md](docs/PERF-macos.md), [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).
- **STW pause tail eliminated:** deferred madvise removes kernel VM lock from the STW window. Max pause drops from 132–150 ms to well under 50 ms on Kemal `/json` c=100.

## [0.11.0] - 2026-07-25

### Added

- **Side mark bitmap:** mark bits live in a separate mmap (one bit per word-aligned heap address), replacing the in-header `MARK` flag. `clear_all_marks` is now a `UInt64` word-by-word zero over the bitmap (full memory bandwidth) instead of a per-block header write. `marked?`/`set_mark`/`clear_mark` are answered from heap-inlined mirror fields (`@mark_bitmap_base` / `@mark_bitmap_base_addr` / `@mark_bitmap_cap_bits`) so the mark hot path no longer dereferences `Gcry.current_mark_bitmap` plus a `MarkBitmap` method. Bitmap relocation publishes the new base pointer **before** unmapping the old mapping; `Heap#destroy` clears the global first then nulls the mirrored fields so stale readers short out.
- **Chunk coalescing on flush:** `flush_pending_empty_chunks` walks the pending list and merges **fully-contiguous** chunks (next.base == current end) into single `munmap` regions (one syscall + one VMA teardown per run instead of one per chunk). Stricter than the naive `<=` check so chunks with a gap (kernel-placed VMA between) are flushed independently.
- **`empty_chunk_retain` bumped to 64 MiB** in the process GC override -- keeps recently-freed chunks as `MADV_DONTNEED` dormant (kernel drops the physical pages, VMA cache survives for fast reuse). 0 MiB regressed ~70% via mmap/madvise cycling; 32 MiB regressed ~50% (reclaim thrashing); 64 MiB is the sweet spot.

### Changed

- **HDR pause histogram:** `@pause_hdr` is a `StaticArray(UInt64, 64)` with bucket indices chosen by `clz` on the elapsed-ns value (1–3 ns, 4–7 ns, …). Exposed via `Gcry.pause_percentile_hdr_ns(p)` and `Gcry.pause_hdr_snapshot` (per Kemal `/gc-stats`).
- **`type_id` gate instrumentation:** `type_id_root_false_negatives` counter for objects rejected by the ambient-root gate that later proved live by other means; bounds the false-negative rate under workloads that mix static-root scanning with type_id gating.
- **Mark-stack prefetch + chunk batching:** the mark loop walks chunk ranges in size-class order with `__builtin_prefetch` on the next chunk header; cache miss count drops on Kemal `/json`.

### Fixed

- **Flush coalescing under-counted `unmapped_bytes` on Linux.** The old `<=` coalescing predicate (`nxt.base <= run_end`) silently skipped chunks whose ranges overlapped or had a small gap (4 KiB page between two separately-mmap'd size-class chunks is common on Linux x86_64). The result was `unmapped_bytes` ~½× `released_chunk_bytes` on `spec/collect_spec.cr:159` ("munmaps fully free size-class chunks on major"), failing CI on Linux x86_64 + aarch64 native + aarch64 cross-compile. Tightened to `nxt.base == run_end` (only fully-contiguous chunks coalesce) so the release count and the unmapped count always match. Verified in `crystallang/crystal:1.21.0` Docker (Linux x86_64): 94/94 unit specs + 13/13 process specs + 5 samples + format + Ameba all pass.

### Performance

- **macOS** Kemal (Apple Silicon, median of 3, scrub off): `/` **~100%** of Boehm (was **~97%**); `/json` **~94%** of Boehm (was **~90%**); post-GC RSS **~10×** (was ~0.97× -- see notes). Latency p50: `/json` **2.3 ms** (was **18 ms**, **−87%**); `/` **1.7 ms** (was **14 ms**, **−95%**). p99 latency within 2× of Boehm on both paths. See [docs/PERF-macos.md](docs/PERF-macos.md).
- **Note on RSS:** the side mark bitmap itself allocates a separate mmap region covering the live heap (1 bit per word-aligned address). For the Kemal workload this adds ~200 MiB of mapped address space on top of the managed heap -- hence the ~10× post-GC RSS. This is the explicit price paid for moving mark bits off the object headers; further reduction requires the bitmap to follow heap-range tightening (see `ensure_bitmap_covers`) or a shared page-cache strategy. The throughput + latency win more than compensates for the higher mapped set on the HTTP workload.
- **Linux** numbers unchanged (this host is Darwin) -- re-record on Linux before citing a new Linux cut. See [docs/PERF.md](docs/PERF.md).

## [0.10.0] - 2026-07-25

### Added

- **macOS process GC (the headline):** `-Dgc_none` + `require "gcry"` is a **real collector on Darwin** (arm64 + x86_64), Crystal **≥ 1.21** -- not stubs.
  - **STW:** Mach `thread_suspend` / `thread_resume` (signal STW under HTTP was ~hang / ~2 req/s)
  - **SP clamp:** `thread_get_state` + `pthread_get_stackaddr_np` stack bounds
  - **Static roots:** dyld main-image `__DATA` / `__DATA_CONST` (`__data` / `__bss` / `__common`; skip `__const`)
  - **Free-page RSS:** host-page `mach_vm_deallocate` + `allocate(FIXED)` (Apple Silicon **16 KiB**; `MADV_DONTNEED` does not drop Darwin RSS)
  - **Defaults:** page blacklist **off** (opt-in `GCRY_BLACKLIST=1`); `large_cache_retain` **0**
  - CI: `macos-latest` native specs + samples
- **`Gcry.register_set(T)`** -- registers `Hash(T, Nil)` for `Set` backing maps.
- **`GCRY_SCAN_CAPS=1`** -- optional whole-program `instance_sizeof` scan caps (fat-app live set often unchanged).

### Changed

- **Layout builtins:** broader curated coverage -- primitive/`String` arrays, `Set`-backing hashes, `Hash`/`Array` + `JSON::Any`, `IO::Memory` (noscan buffer), more `Deque`s. Still not whole-program `GCRY_AUTO_LAYOUTS`.
- **Layout correctness:** `Pointer(T)` noscan uses `!T.has_inner_pointers?` (safe for `Array(JSON::Any)`). Hash keys/values with inner pointers word-scanned.
- **Mark:** size-class mismatch falls back to `scan_cap` when present; precise entries store `instance_sizeof`.
- **Large objects:** mmap aligned to `Platform.host_page_size`; `LARGE_CACHE_LIMIT` hard-caps freelist retain.
- **Blacklist:** page granularity uses `host_page_size`.
- Docs: Linux vs Darwin PERF / ACIKTURKIYE split; README highlights macOS.

### Performance

- **macOS** Kemal (0.10.0 cut, Apple Silicon, median of 3, scrub off): `/` **~97%** of Boehm; `/json` **~90%**; post-GC RSS **~0.96–0.97×** -- see [docs/PERF-macos.md](docs/PERF-macos.md).
- **macOS** acikturkiye `/api/v1/` (median of 3): thr trial-median **~80%**; post-GC RSS **~11.8×** (dense conservative-live; reclaim works) -- see [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).
- **Linux** Kemal / acikturkiye cut numbers unchanged from **0.9.0** (this host is Darwin; re-record on Linux before citing a new Linux cut) -- [docs/PERF.md](docs/PERF.md), [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

## [0.9.0] - 2026-07-24

### Added

- **Process-GC parallel mark (STW-exempt):** with `GCRY_PARALLEL_MARK=N` / `parallel_mark_workers > 1`, helpers are raw `LibC.pthread_create` threads (not Crystal::Thread), so `stop_world` does not suspend them. They steal grey objects under `@mark_lock` (`parallel_mark_stolen`). Fork child abandons the pool via `reset_mark_workers_after_fork`.
- **Library-heap parallel mark:** with `parallel_mark_workers > 1` and `stop_the_world == false`, helper `Thread`s steal grey objects (`parallel_mark_stolen`).
- **Stack scrubbing (no Crystal patch):** `GCRY_CLEAR_STACK=1` zeros a window below SP (skips x86_64 red zone; default every **16** allocs) without calling Fiber/Thread APIs; `GCRY_SCRUB_FIBERS=1` zeros a capped window below each parked fiber's saved SP before mark (not the full unused stack -- that faults pages in and blows RSS). Metrics: `clear_stack_*` / `fiber_scrub_*` (json_stats + Prometheus). Not stack maps; measure before enabling as default.
- Richer `Gcry::Observability.json_stats` (phase timers, mapped/live bytes, TLAB, parallel-mark, barrier) -- Kemal `/gc-stats` uses it.
- Prometheus: TLAB, parallel-mark, phase, layout, SP clamp, barrier, size-class live / released chunk gauges; `gcry_clear_stack_*` / `gcry_fiber_scrub_*`.
- Median-of-3 helpers: `bench/median_kemal_boehm.sh`, `bench/median_acikturkiye_boehm.sh`.

### Changed

- README / HARDENING / POLICY: `GCRY_PARALLEL_MARK` is real for process GC (pthread steals), not counter-only -- and labeled **experimental / measure first** (Kemal `/json` + acikturkiye `/api/v1/` thr **regressed** vs `N=1` in same-host wrk).
- README / HARDENING: document `GCRY_DISABLE_*` escapes, `GCRY_TLAB`, stack-scrub knobs.
- Dogfood docs: [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md) + [docs/API.md](docs/API.md) point at Observability routes; acikturkiye `make run-demo-gcry` / README GC section.
- Same-host Kemal (0.9.0 cut, median of 3, scrub off): `/` **~89%** of Boehm; `/json` **~92%**; post-GC RSS **~0.97×** -- see [docs/PERF.md](docs/PERF.md).
- Same-host acikturkiye `/api/v1/` (median of 3, scrub off): thr trial-median **~93%**; post-GC RSS **~2.84×** (was ~3.20× at 0.8.0) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

### Fixed

- **`clear_stack` aarch64 SEGV:** wipe used approximate `pointerof(local)` as SP (mid-frame). With no x86_64 red zone that zeroed the leaf frame (`Invalid memory access @ 0x0` on CI `test (aarch64 native)`). Now reads hardware SP (`Roots.hardware_stack_pointer`) plus a leaf margin.

## [0.8.0] - 2026-07-24

### Added

- **Page-dirty write barriers:** soft-dirty is the official nursery/incremental remembered set; `mprotect`+SEGV is the process-GC fallback (`GCRY_MPROTECT_BARRIER=1` to force, `GCRY_DISABLE_MPROTECT=1` to forbid). See `Gcry::Heap#barrier_backend_name`, `barrier_dirty_rescans`.
- **Sounder incremental termination:** `collect_a_little` re-scans dirty pages before sweep when a barrier backend is armed.
- Pause histogram docs in [docs/PERF.md](docs/PERF.md) (`Gcry.pause_stats` p50/p99).
- Specs: `spec/barrier_spec.cr`.
- **TLAB:** `GCRY_TLAB=1` enables thread-local freelist buffers for parallel ExecutionContext alloc (`tlab_refills` / `tlab_steals`). Flush before STW sweep.
- **Parallel mark knob:** `GCRY_PARALLEL_MARK=N` (API + metrics); true multi-thread mark under Crystal STW awaits STW-exempt workers -- today N>1 still marks serially and increments `parallel_mark_runs`.
- STW SP table: CAS bitmask claim (safe under concurrent suspend; `@@stw_claimed` is `uninitialized Atomic` so GC.init does not trip Crystal.once before Fiber exists).
- Specs: `spec/mt_spec.cr`.
- **Page blacklisting:** process GC records type_id-gate false roots and prefers non-blacklisted freelist pages (`blacklist_hits` / `blacklist_skips`; `GCRY_DISABLE_BLACKLIST=1`).
- **`Gcry.register_layouts`:** auto-registers precise layouts for concrete `Reference` subclasses (skips private / nested generics). Opt-in via `GCRY_AUTO_LAYOUTS=1` or an explicit call -- not process-default (unsound offsets on some stdlib types regress HTTP thr).
- Layout table: **4096** entries, **32** offsets, open-addressing `entry_for` (was 512 + linear scan).
- Specs: `spec/blacklist_spec.cr`.
- **Linux aarch64 STW SP clamp:** `sp_from_ucontext` uses glibc `uc_mcontext.sp` offset (432); install on aarch64 as well as x86_64. CI native `ubuntu-24.04-arm` runs specs + `stw_sp_clamp` + `fork_reinit`.
- **Fork reinit:** `pthread_atfork` registered by default; child resets locks / STW / maps cache (`GCRY_DISABLE_ATFORK=1` restores poison). Smoke: `samples/fork_reinit.cr` under `-Dwithout_mt` (ExecutionContext cannot fork).
- **macOS stubs:** `platform/darwin_stubs.cr` so the shard type-checks on Darwin; process GC still raises at init until Mach STW + dyld roots land.
- **Collector split:** `collect.cr` reopened into `collect_stw` / `collect_scan` / `collect_mark` / `collect_sweep` for contributors.
- **Observability:** `Gcry.metrics`, `Gcry.prometheus_text`, `Gcry::Observability.json_stats`; Kemal `/metrics` + richer `/gc-stats`.
- **Ameba** lint in CI (`make lint`); [docs/API.md](docs/API.md); README gcry-vs-Boehm table; [docs/ANNOUNCE.md](docs/ANNOUNCE.md) draft.

### Fixed

- **`register_layouts`:** skip non-concrete type args (`Array(Int)`, `Runnables(256)`, unbound generics) so fat apps (e.g. acikturkiye) compile even when the method is present but unused.

### Performance

- Same-host Kemal (0.8.0 cut, median of 3): `/` **~91%** of Boehm; `/json` **~89%**; post-GC RSS **~0.93×** -- see [docs/PERF.md](docs/PERF.md).
- Same-host acikturkiye `/api/v1/` (median of 3): thr **~95%**; post-GC RSS **~3.2×** (RSS gate still fail; dense conservative-live) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

## [0.7.0] - 2026-07-24

### Fixed

- **Nursery minors:** do not run finalizers / clear WeakRef links for unmarked **old** objects (`minor_only` leaves them unmarked by design). This crashed process GC under Kemal `GCRY_NURSERY` + concurrent `/json`.
- **Base-pointer-only vs `Array#shift`:** ambient roots stay base-only (RSS); **heap** marks allow interiors so shifted `@buffer` keeps the allocation. Process GC under fiber/`GC.collect` no longer frees live `Array` elements (CI `samples/stress` SIGSEGV).

### Changed

- Large-object freelist reuse is **exact mapped-size** only (no oversized VMA for a smaller need).
- `GCRY_LARGE_CACHE` sets free large bytes retained after post-collect trim (default **8 MiB**).
- Heap / Kemal `/gc-stats`: `large_mapped_bytes`, `small_mapped_bytes`, `small_free_bytes`, `large_cache_retain`, `dormant_chunk_bytes`, `dontneed_bytes`, `empty_chunk_retain`.
- Empty size-class chunk `munmap` deferred **outside STW**; occupancy: `fully_free_chunk_bytes` / `size_class_chunk_count` / `released_chunk_bytes`.
- Size-class occupancy: `size_class_live_bytes` + fill histogram (`chunk_fill_lt25`…`ge75`); `GCRY_CHUNK_BYTES` (default **256 KiB**).
- **Soft-dirty nursery (Phase 11):** Linux `/proc` soft-dirty helpers; chunk-scoped pagemap; dirty-fraction fallback (`GCRY_SOFT_DIRTY_MAX`, default **25%**). `GCRY_NURSERY` stays opt-in (off by default).
- **Phase 12 (shard-only RSS):** process GC **empty-chunk release default-on** (`empty_chunk_retain` default **0** → munmap; `GCRY_EMPTY_CHUNK_RETAIN` / dormant DONTNEED; `GCRY_KEEP_CHUNKS=1` escape). Freelist **range-unlink** on release (no full size-class rebuild). Process majors at **32 MiB**. Mark roots **base-pointer-only** by default (`GCRY_INTERIOR=1` restores interiors on ambient roots; heap marks always allow interiors). `GCRY_TYPE_ID_GATE=1` / `GCRY_PAGE_DONTNEED=1` opt-in. Bench: `GET /gc-collect`.
- **Layout-precise scan (false retention):** `Gcry::Layout` type_id → pointer offsets (StaticArray, boot-safe); size-class gate; noscan buffers; `Gcry.register_hash` entry walk. `GCRY_DISABLE_LAYOUT=1`. Does **not** close acikturkiye RSS (still ~2.8×) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **Root-only `type_id` gate (process default-on):** stack/static candidates must have a plausible Crystal `type_id`; heap-scan marks stay ungated (buffers). `GCRY_DISABLE_TYPE_ID_GATE=1`. acikturkiye: ~15 rejects/major, RSS unchanged (~3×) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **STW SP clamp (process default-on, linux x86_64):** capture RSP in SIG_SUSPEND; clamp other-thread stack scans to used SP (`sp_clamp_hits` / `sp_clamp_fallbacks`; `GCRY_DISABLE_SP_CLAMP=1`). acikturkiye RSS unchanged (~3×) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

### Performance

- Same-host Kemal (0.7.0 cut, median of 3): `/` **~92%** of Boehm; `/json` **~90%**; post-GC RSS **~0.93×** -- see [docs/PERF.md](docs/PERF.md). (`GCRY_KEEP_CHUNKS=1` ≈ **95%** thr @ ~**3×** RSS.)
- Same-host acikturkiye `/api/v1/` (Phase 12, median of 3): thr **~96%**; **post-GC RSS ~2.55×** -- empty release ~noop; dense conservative-live -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- Soft-dirty on WSL **6.18.33.2**: HTTP nursery still too dirty -- keep opt-in.

## [0.6.0] - 2026-07-23

### Fixed

- Process GC **static roots:** treat kernel-named VMAs (`[anon:…]`, `[stack]`, …) like anonymous -- do not scan them as file-backed (Linux 6.x CI SIGBUS). Stack scans use hole-aware `safe` probing (glibc guard pages inside pthread bounds).
- Process GC **stop-the-world** for Crystal 1.21+ `ExecutionContext` Monitor (SYSMON) thread: suspend other OS threads and scan their stacks. Missing roots caused live objects to be swept under load (`not a size-class payload: 0` / `END_OF_STACK` / Monitor SIGSEGV).
- **Monitor stack bounds:** `GC.current_thread_stack_bottom` now returns this OS thread's pthread stack high address (was a single global `@stack_bottom`, so SYSMON scans were skipped or wrong). Other-thread main fibers use `pthread_getattr_np`.
- Mutator stack scan spills **all** GP registers (not only `setjmp` callee-saved) before scanning; marks every `Fiber` / `Thread` object.
- Process GC `lock_read` / `lock_write` use a real `Crystal::RWLock` so collect does not race fiber `swapcontext`.
- Allocate-black while `@collecting` (mid-collect allocations survive sweep).
- **Static roots:** scan ELF BSS zero-fill only when anonymous RW is **contiguous with** the previous file-backed RW mapping (class vars like `Exception::CallStack::@@skip`), plus main-executable `rw-p` (and small RELRO). Skip all `.so` data and large RELRO (≥64 KiB) -- fat-binary STW was dominated by those word scans. Large-object `munmap` does not invalidate the maps cache; empty-chunk release still does. Object mark clamps `header.size` to the mapped chunk.
- **Fiber roots:** process GC scans suspended stacks **once** via `scan_all_fiber_roots` (no duplicate `push_gc_roots` in `before_collect`).
- **Safe stack scans:** leading PROT_NONE probe, then bulk-scan when ends are readable; hole-aware fallback; fiber scans clamp past the guard.
- STW phase timers (`last_phase_*_ns`) exposed for Kemal `GET /gc-stats`.
- **Finalizers / WeakRef:** process unreachable entries once after mark via index APIs (O(finalizers), no Crystal `Proc` -- a closure mid-collect re-entered `malloc` and crashed). Size-class sweep is inlined (no `each_block` yield).
- **Sweep:** recycle large objects onto a size-bucket freelist instead of `munmap` during STW. Thousands of per-buffer VMAs made Linux `munmap` dominate pauses on HTTP apps; trim cache outside STW when over 64 MiB.
- `free` / `reclaim_small` use chunk size-class (not possibly corrupted `header.size`); `owns_user_pointer?` requires block alignment.
- **`notice_reclaim`:** skip registry scan on `free`/`realloc` unless the object has `FINALIZER` / `DISAPPEARING` header flags (was O(entries) per Array growth -- ~15%+ CPU on acikturkiye).
- **Chunk index:** keep address-sorted `@chunk_index` updated on map/unmap (no dirty full rebuild on every mmap); `owns_user_pointer?` no longer double-looks up via `is_heap_ptr`.

### Changed

- Size-class ceiling **8→32 KiB** (`10240`…`32768`): medium buffers use chunk freelists instead of per-object mmap.
- Skip `malloc` clear while a size-class freelist (or fresh large mmap) is still MAP_ANONYMOUS-zeroed; `SizeClasses.fit` one-pass class lookup.

### Performance

- Same-host Kemal vs **Boehm**: `/` **~105%**, `/json` **~100%** of Boehm req/s; `GCRY_RELEASE_CHUNKS=1` ~**92%** on both -- see [docs/PERF.md](docs/PERF.md).
- Same-host **acikturkiye** `/api/v1/`: gcry **~101%** of Boehm req/s (154 vs 153); RSS still ~3–4× -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- Path to parity (same doc): early post-STW ~51% → size-class 16/32 KiB → `notice_reclaim` fast-path → chunk index.

## [0.5.0] - 2026-07-23

### Added

- Pause percentiles: `Gcry.pause_stats` now includes `p50_ns` / `p99_ns` (ring of last 64 pauses).
- Meaningful `GC.prof_stats`: `bytes_before_gc`, `bytes_reclaimed_since_gc`, `reclaimed_bytes_before_gc`, `expl_freed_bytes_since_gc`, `obtained_from_os_bytes`.
- `samples/json_churn.cr` -- Hash/JSON mutation dogfood under process GC.
- CI: aarch64 cross-compile of hello/min/alloc on PR+push; `json_churn` + chunk env knobs on x86_64.

### Changed

- Empty-chunk release stays **opt-in** (`GCRY_RELEASE_CHUNKS=1`); `GCRY_KEEP_CHUNKS=1` forces off.
- Finalizer Array buffers / Proc closures pinned during mark (safe opt-in chunk munmap).
- STW hot path: O(n) static-root×heap exclusion (sorted chunk index merge); `find_object` size-class block-bytes cache; mark stack default 256 KiB.
- Empty finalizer registry skips `on_reclaim` work.

### Performance

- Same-host vs **Boehm**: `/` **~92%**, `/json` **~82%** of Boehm req/s -- see [docs/PERF.md](docs/PERF.md).
- Page-map + per-chunk mark bitmap tried during 0.5 prep; **not shipped** (no `/json` win) -- see [DESIGN.md](DESIGN.md) Phase 8.
- `GCRY_RELEASE_CHUNKS=1` still ~**49%** of Boehm `/json` -- remains opt-in.

## [0.4.0] - 2026-07-23

### Added

- Empty size-class chunks can be `munmap`'d after major (`release_empty_chunks`; enable with `GCRY_RELEASE_CHUNKS=1`).
- `GC.stats.unmapped_bytes` / heap `unmapped_bytes` count returned mappings.
- Fork skeleton: `GC.note_fork_child` poison -- post-fork `malloc`/`collect` raise (no auto `pthread_atfork` / heap reinit yet).
- `GCRY_INCREMENTAL=1` opt-in for experimental sliced auto-majors.

### Changed

- Process GC default majors are **full STW** again. Incremental auto without write barriers was unsound under pointer-mutating workloads (Kemal `/json` Hash overflow / double-free).
- `stop_world` / `start_world` documented as v0.4 STW stubs (still no-ops at parallelism 1).
- Docs: POLICY / HARDENING updated for chunk release, fork poison, incremental opt-in.

### Performance

- Kemal wrk vs **v0.3.0** (same host): `/` **−2.7%** req/s, **+0.5%** lat.avg; `/json` **−0.6%** req/s, **−0.4%** lat.avg. Throughput-neutral; prioritizes soundness (STW default).

## [0.3.0] - 2026-07-23

### Added

- Pause instrumentation: `last_pause_ns` / `max_pause_ns` / `total_pause_ns` / `pause_count` on `Gcry::Heap`; `Gcry.pause_stats`.
- Env knobs: `GCRY_DISABLE_INCREMENTAL=1`, `GCRY_INCREMENTAL_WORK` (mark units per slice).
- [docs/PERF.md](docs/PERF.md) -- % of Boehm on Kemal wrk (`/` + `/json`).

### Changed

- Process GC auto-major uses **incremental** `collect_a_little` slices (up to 4 per alloc) instead of full STW; opt out with `GCRY_DISABLE_INCREMENTAL=1`.
- Default incremental work budget raised to 1024.
- `maybe_collect` drains in-progress incremental cycles even when under the major threshold.

### Performance

- Kemal wrk vs **0.2.0** on `/` (same host): **+1.2%** req/s, **−33%** lat.avg.
- Bench app: enriched **`GET /json`** (nested JSON alloc stress); formal `/json` baseline **30112** req/s vs Boehm **41748** (~72%).

## [0.2.0] - 2026-07-23

### Changed

- Process GC performance: nursery **off** by default (opt-in via `GCRY_NURSERY`); major threshold **64 MiB**.
- Cached `/proc/self/maps` static-root ranges; skip bulky `libcrypto` / `libssl` / `libpcre` segments.
- O(log n) chunk index for mark pointer lookup.
- README Kemal+wrk numbers: ~75–80k req/s under gcry (vs ~4k with prior defaults).

## [0.1.0] - 2026-07-23

### Added

- **Kemal HTTP bench** (`bench/kemal`) -- realistic `require "gcry"` + `-Dgc_none` app; `make bench-kemal-wrk` runs `wrk -c 100 -d 30`.
- **Phase 7 productization**
  - [docs/POLICY.md](docs/POLICY.md) -- OOM (emergency collect + `OutOfMemoryError`), fork unsupported, not signal-safe.
  - [docs/COMPARISON.md](docs/COMPARISON.md) -- checklist vs bdwgc.
  - Env knobs: `GCRY_NURSERY`, `GCRY_DISABLE_NURSERY` (plus existing major-threshold knobs).
  - `Makefile` for `spec` / `samples` / `bench` / format.
  - `shard.yml` description + repository metadata.
- **Phase 6 performance**
  - Nursery + `minor_collect` (old→young scan without write barriers; survivors promote).
  - Incremental mark via `collect_a_little` / `GC.collect_a_little` (black alloc during cycle).
  - Specs: `spec/phase6_spec.cr`; bench: `bench/churn.cr`.
  - Process GC nursery threshold default: 512 KiB.
- **Phase 5 hardening**
  - Stress specs (`spec/stress_spec.cr`) and process stress sample (`samples/stress.cr`).
  - CI workflow (`.github/workflows/ci.yml`): `crystal spec` + `-Dgc_none` hello/alloc/stress.
  - Env knobs via `LibC.getenv`: `GCRY_THRESHOLD`, `GCRY_DISABLE_AUTO=1`.
  - [docs/HARDENING.md](docs/HARDENING.md) -- false retention, sanitizers, tuning.
- **Phase 4 process GC** -- `gc_override.cr`, static roots, samples.
- **Phase 3** -- fiber roots, finalizers, disappearing links.
- **Phase 2** -- conservative mark–sweep.
- **Phase 1** -- mmap size-class allocator.

### Changed

- CI: create `bin/` before sample builds; Crystal `1.21.0` + `latest` matrix; format check; `samples/min`, env-knob smoke, `bench/churn`.
- README status → Phase 7 complete; development via `make`.
- Crystal 1.21 docs: default `Fiber::ExecutionContext` (parallelism 1); deprecated `-Dpreview_mt`.

### Fixed

- ExecutionContext (Crystal 1.21+ default): refresh stack bottom from `Fiber.current` on collect; `set_stackbottom` matches `gc/none` (`Thread` form when `!without_mt`).
- Static roots: scan file-backed RW segments only; exclude heap chunks per-mapping (not one bounding box).
- Finalizers: `on_reclaim` no longer allocates Crystal Arrays mid-sweep (nested GC / SIGSEGV under Kemal+wrk).
- Avoid Crystal `ENV` during `GC.init` (Fiber/`once` deadlock); use `LibC.getenv`.
- Suppress auto-collect while finalizers run.
- Bootstrap: no `LibC::MAP_FAILED` / runtime size-class Array on malloc path.
- OOM: one emergency collect + retry before raising on heap `mmap` failure.

### Notes

- Phase 0–7 complete (v0.1 productization).
- Default process auto-collect: 4 MiB major; 512 KiB nursery.
- Concurrent mark / compacting / precise GC need compiler cooperation.
- Optional upstream `-Dgc_gcry` backend remains out of scope (shard override is enough).

[Unreleased]: https://github.com/sdogruyol/gcry/compare/v0.27.0...HEAD
[0.27.0]: https://github.com/sdogruyol/gcry/compare/v0.26.3...v0.27.0
[0.26.3]: https://github.com/sdogruyol/gcry/compare/v0.26.2...v0.26.3
[0.26.2]: https://github.com/sdogruyol/gcry/compare/v0.26.1...v0.26.2
[0.26.1]: https://github.com/sdogruyol/gcry/compare/v0.26.0...v0.26.1
[0.26.0]: https://github.com/sdogruyol/gcry/compare/v0.25.0...v0.26.0
[0.25.0]: https://github.com/sdogruyol/gcry/compare/v0.24.1...v0.25.0
[0.24.1]: https://github.com/sdogruyol/gcry/compare/v0.24.0...v0.24.1
[0.24.0]: https://github.com/sdogruyol/gcry/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/sdogruyol/gcry/compare/v0.22.0...v0.23.0
[0.22.0]: https://github.com/sdogruyol/gcry/compare/v0.21.3...v0.22.0
[0.21.3]: https://github.com/sdogruyol/gcry/compare/v0.21.2...v0.21.3
[0.21.2]: https://github.com/sdogruyol/gcry/compare/v0.21.1...v0.21.2
[0.21.1]: https://github.com/sdogruyol/gcry/compare/v0.21.0...v0.21.1
[0.21.0]: https://github.com/sdogruyol/gcry/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/sdogruyol/gcry/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/sdogruyol/gcry/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/sdogruyol/gcry/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/sdogruyol/gcry/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/sdogruyol/gcry/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/sdogruyol/gcry/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/sdogruyol/gcry/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/sdogruyol/gcry/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/sdogruyol/gcry/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/sdogruyol/gcry/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/sdogruyol/gcry/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/sdogruyol/gcry/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/sdogruyol/gcry/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/sdogruyol/gcry/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/sdogruyol/gcry/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/sdogruyol/gcry/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sdogruyol/gcry/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sdogruyol/gcry/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sdogruyol/gcry/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sdogruyol/gcry/releases/tag/v0.1.0
