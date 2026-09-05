# Performance improvement plan for PR #34

Date: 2026-09-05

Revised after author feedback: prioritize Kemal allocation and header retention; gate higher-risk root and policy changes on real-workload evidence.

## Recommendation

Include the performance work in PR #34 on the branch carrying it. Organize each item as a separate reviewable commit with its own trials, preserving the existing review history. After repairing the measurement gaps, prioritize cursor hits above 2 KiB for Kemal, then chunk refill indexing and warm retention for the default header allocator. Include atomic-leaf enqueue skipping as an early, small change, measured on a suitable collector workload.

The priorities differ by workload: Kemal primarily benefits from allocation and page-reuse improvements; large live graphs need a separate tracing benchmark. Split root sub-timers now, but stop there unless a real application proves root-bound. Retain the simple live × factor policy unless a workload demonstrates a failure it cannot address. Do not use a Kemal throughput result to accept or reject every collector change.

This document proposes work; it does not claim any of the proposed optimizations are implemented or measured.

## Review scope and evidence

- Reviewed the current [PR #34](https://github.com/sdogruyol/gcry/pull/34), remote head `b360bcdd387ed91a6e3c6e1b65313a439dd76315`.
- Local branch: `cursor-sets`, HEAD `9c04dd68f4e0d6f6b1435f2645c68759ced17b23`. The local and remote commits have identical tracked trees: `a7d47c139f30b586df20a94b2d438478344f0256`. This review therefore covers the current PR code, including its review fixes, rather than the withdrawn single-mutator implementation.
- Inspected allocation, cursor lifecycle, size classes, marking, root scanning, Linux stack metadata, sweeping and retention, parallel mark workers, configuration, observability, relevant specs, CI, and benchmark runners. Existing untracked `CLAUDE.md` and `simd_plan/` were left untouched; the C prototype's roadmap is background, not evidence of production Crystal performance.
- Recomputed comparisons from the committed trial data using the repository's analysis script. No new load benchmarks, profiles, or correctness suites were run for this documentation review. Numerical results below describe those stored trials, not this workstation.

### What the existing measurements establish

The 20-round paired headerless run contains a Boehm null control and separate upstream, heap-policy, and cursor arms. Its [raw trials](../bench/log/linux/2026-09-04-alloc-fast-path/trials.jsonl) and [analysis](../bench/log/linux/2026-09-04-alloc-fast-path/analysis.txt) report:

| Configuration | Throughput / Boehm, 95% CI | Peak RSS / Boehm | Minor faults / 1,000 requests | CPU ms / 10,000 requests |
|---|---:|---:|---:|---:|
| Upstream v0.22.0, headerless | 89.5%, [86.1, 92.9] | 1.88 | 1,255.6 | 230 |
| Retention + adaptive threshold | 100.9%, [96.8, 105.1] | 0.97 | 5.0 | 204 |
| PR with per-thread cursors | 106.7%, [102.2, 111.2] | 0.97 | 4.8 | 193 |

Re-running the analysis with `policy-hl` as reference gives **+5.8% for cursors over policy alone**, with a ratio CI of **+3.2% to +8.5%**, n=20. That direct comparison supports the cursor work more clearly than comparing two separate intervals against Boehm.

The [header-allocator trials](../bench/log/linux/2026-09-04-alloc-fast-path/trials_header.jsonl) still show about **1,548 faults / 1,000 requests** and **2.48× Boehm peak RSS** for the PR. Re-analysis against the upstream header arm gives +2.8%, CI −6.3% to +11.8%, n=10: the result is inconclusive, establishing neither an improvement nor parity. This remains a substantial opportunity for users who build only with `-Dgc_none`.

The [cursor findings](../bench/log/linux/2026-09-05-cursor-sets/FINDINGS.md) report a quiet 48-byte allocation result of 32.5 ns at one thread and 156.8 ns at four, and a four-thread collection with roughly 2.2 ms in `phase_roots`. Treat these as diagnostic leads: the referenced `ub/alloc_ns.cr` is not a committed, reproducible benchmark in this tree. Earlier tables in that file include withdrawn code and contaminated measurements; they must not become new baselines. The author identifies the 2.2 ms root figure as a four-thread microbenchmark collecting every 8 MiB and reports only about 0.7 ms for the entire Kemal pause. Those workload-specific figures must not be transferred into a Kemal root-optimization priority; the latter is author-provided context, not a new measurement from this review.

The historical Kemal GC duty cycle is only 0.2–0.5% ([benchmark rationale](../bench/micro/gc_phases.cr), [performance notes](PERF.md)). At that duty cycle, even eliminating all measured GC pause work offers only about 0.2–0.5% direct wall-time improvement. Re-measure the fraction for each new workload and include collection work after world restart; allocation stalls, CPU contention, and page faults need their own measurements.

## Prioritized work

Effort estimates are engineering days, including focused regression coverage, excluding long benchmark queues and cross-platform soaks. Benefits are hypotheses except where explicitly identified as existing results. Acceptance targets below are proposed decision thresholds, not forecasts.

| Order | Work | Main beneficiary | Expected benefit and confidence | Effort | Risk |
|---|---|---|---|---:|---|
| 0 | Repair measurements, commit allocation benchmark, split root sub-timers | Every subsequent decision | High confidence: more trustworthy attribution | 2–3 days | Low |
| 1 | Extend cursor hits above 2 KiB, prioritizing 8 KiB | Kemal / buffer churn | Small dispatch change on a known hot allocation; gain needs measurement | 1–2 days | Medium |
| 2 | Index available chunks by size class and kind | Bitmap/headerless, especially growing heaps | Measured scaling problem; also supports frequent 8 KiB refills | 3–5 days | Medium–high |
| 3 | Evaluate coupled retention and threshold policy for header allocator | Default `-Dgc_none` users | Strong page-fault evidence; freelist relinking cost is the experiment | 2–4 days | Medium |
| 4 | Avoid enqueueing known atomic leaves | Atomic-heavy live sets | Small change using the chunk already in hand | 1–2 days | Low–medium |
| Conditional A | Reuse root metadata and deduplicate discovery | A real application proven root-bound | Defer beyond sub-timers until application evidence exists | 3–5 days if justified | High |
| Conditional B | Change the simple heap policy | A workload demonstrating a failure of live × factor | No controller work without a reproducer | 3–5 days if justified | Medium |
| Conditional C | Carry chunk metadata in mark work items | A profile showing repeated resolution is material | Separate from atomic-leaf skipping | 2–3 days if justified | Medium |
| Conditional D | Park idle mark helpers and measure per-worker statistics | Opt-in parallel marking | Busy-spin is confirmed; prioritize when this mode is a target | 3–5 days | High |

### 0. Make the next measurements reproducible

**Code evidence.** [The PR runner](../bench/log/linux/2026-09-04-alloc-fast-path/run_kemal_ab.sh) reads wrk's reported requests/sec; it does not record a monotonic measurement duration, request error census, or effective GC configuration. [Its analyzer](../bench/log/linux/2026-09-04-alloc-fast-path/analyze_ab.py) filters out failed/zero-rate trials and assumes a CPU tick is 10 ms. These are limitations of future reuse, not proof the stored comparisons are wrong. The repository already documents a clock problem and a monotonic approach in [PERF.md](PERF.md) and [sound_profile_ab.sh](../bench/sound_profile_ab.sh).

**Deliverables:**

1. Promote a maintained runner out of the dated log directory. Record commit/tree, binary hash, build flags, resolved shard path, compiler/LLVM, CPU/kernel, effective GC settings, monotonic duration, request count, errors, CPU ticks and `CLK_TCK`, minor faults, peak RSS, and post-GC RSS. Keep failed trials visible and fail a run with errors; never silently improve an arm by excluding its failures.
2. Keep the existing [shard identity check](../bench/assert_gcry_lib.sh) before builds. Build arms sequentially in their own checkouts. Use fresh processes, a defined warm-up, rotated arm order, a same-binary null control, and paired analysis by round. Use the same estimator for an effect and its significance test; the current script reports a ratio CI but a t-statistic on absolute differences.
3. Commit the scratch `ub/alloc_ns.cr` as a maintained benchmark under `bench/`, retaining its original ring and timing setup so the cited result is reproducible. Extend it to cover `malloc` and `malloc_atomic`, 16/48/192/2,048/8,192/32,768-byte classes and large-object boundaries, with 1/2/4/8 threads. Include bounded ring churn, fixed-live-set growth, mixed classes, and cross-thread free. Time batches; the per-allocation clock calls in [micro/run_all.cr](../bench/micro/run_all.cr) are a poor primary instrument for tens-of-nanoseconds changes.
4. Repair [gc_phases.cr](../bench/micro/gc_phases.cr): `--fanout` adds edges only while filling the initial ring. The timed loop allocates zeroed objects and replaces ring entries without restoring edges, so graph density decays. Maintain the selected graph topology during churn, report actual reachable bytes/edges, and add stable-live-graph trace-only and pointer-free controls. Run each survival setting in a fresh process to avoid carrying adaptive policy and heap state between settings. Also document that `--size` currently sets words, despite the ambiguous name.
5. Add optional phase sub-timers and per-thread counters: cursor hits, misses by reason, chunk/bitmap words inspected per refill, lock wait, cursor retirement/pinning and bytes retained, root bytes by source, range/probe counts, pagemap reads, mark pushes, and collection work after STW. Expose safe snapshots in [observability.cr](../src/gcry/observability.cr). `bitmap_alloc_fast` currently counts the locked bitmap path, while `fast_path_objects` counts cursor hits. Fix these names in the measurement commit (for example, explicit locked-allocation and cursor-hit counters), update their consumers, and document the denominator; exposing the existing ambiguous names is insufficient. Do not put shared atomic increments on every allocation just to measure this.

**Completion:** every published result can be recreated from a runner, configuration manifest, and raw per-trial data; the graph benchmark maintains its requested shape; a null comparison bounds the noise. Collect profiles separately from headline timing runs.

### 1. Let frequently allocated medium buffers use cursor hits

**Code evidence.** [`fast_alloc`](../src/gcry/heap.cr), line 830, rejects sizes above `FAST_PATH_MAX = 2048`, although the existing [size classes](../src/gcry/size_classes.cr) extend to 32 KiB and cursor slots already cover them. Consequently, the 8 KiB response-buffer class highlighted by the PR always takes `allocate`, size fitting, the class lock, and global accounting. Its chunk contains relatively few blocks, so refill remains important.

**Design:** prioritize the 8 KiB class already identified in Kemal, recording size/kind distribution and cursor hit opportunities in the baseline. Keep the existing 257-entry table for sizes through 2 KiB; evaluate shift-and-compare dispatch for 2–32 KiB, avoiding an unnecessarily enlarged hot table. The limit is a dispatch-table choice, not missing cursor infrastructure. Inspect emitted code and benchmark tiny allocations to verify the added dispatch has no material cost; do not assume it is free. Measure cursor hits and chunk refills separately, since a faster hit path cannot eliminate frequent refill work. Preserve full zeroing for pointerful reused buffers, atomic-allocation semantics, threshold accounting, diagnostics, monitor-thread cooperation, and sentinel/in-flight publication. Keep large mappings above 32 KiB on their existing path.

**Validation:** compare malloc and malloc_atomic separately, cold and warm buffers, just below/at/above class boundaries, and 1–8 threads. Inspect emitted code for clearing, size fit, TLS access, and atomic operations. Target at least 10% lower 8 KiB warm allocation cost with no material regression in tiny allocations; require application evidence before enabling broadly. Do not weaken occupancy atomics or the STW publication fence to improve a microbenchmark.

### 2. Remove the full-heap search from chunk refill

**Code evidence.** [`bitmap_take_pool_chunk`](../src/gcry/bitmap_alloc.cr), line 645, iterates `each_chunk`, filters class/kind/ownership, scans occupancy words, and chooses the lowest-address eligible chunk. It must finish the entire list even after finding a candidate. `bitmap_revive_dormant` can then walk the list again. The caller holds the size-class lock. Growth through H chunks can therefore accumulate quadratic chunk-list examination, even when allocations use only one class. Mixed-class and retained heaps make the search longer. The author measured four-thread allocation cost rising from 292 ns at 96 MB to 1,125 ns at 960 MB with collections disabled, as recorded in the cursor findings. Preserve that workload when committing `alloc_ns.cr` and reproduce it with the maintained runner. This item follows medium-buffer hits because 8 KiB chunks hold few blocks and refill often; benchmark the two changes independently and together.

**Design:**

- Add available-chunk and dormant-chunk structures per `(size class, atomic kind)`. Track an availability summary or next usable bitmap word so refill does not rediscover capacity in full chunks.
- Distinguish available, cursor-owned, full, dormant, and pending-release states. Publish transitions from sweep, map/revive, cursor retirement, and explicit free. An explicit free into an owned chunk must not make it available to a second cursor. A free into an unowned full chunk must eventually make its capacity discoverable without another heap-wide scan.
- Remove claimed chunks from availability before publishing cursor ownership. On release, remove every queue/index reference before the mapping can disappear. Keep global `@chunks` for whole-heap traversal.
- Preserve locality deliberately. An address-ordered structure can provide O(1) access to its first candidate with O(log H) updates; a FIFO can provide constant-time updates but changes reuse order. Benchmark both if locality matters. Do not replace the current search with an O(H) sorted insertion on every refill and call it constant-time allocation.
- Respect stopped-world lock rules: a collector must not acquire a class lock held by a suspended mutator. Use the existing STW ownership protocol and defer unsafe publication when necessary. Metadata allocation must not re-enter the managed allocator under a heap lock.

**Validation:** run 16/64/256/512 MiB heap sweeps with unrelated classes, 1–8 threads, and automatic collection both enabled and disabled for bounded runs. Measure refill time, inspected chunks/words, lock wait, allocation throughput, faults, and RSS. The acceptance target is a search cost that no longer rises with unrelated heap chunks and at least 15% lower allocation cost on the large-heap refill stress, without a material small-heap regression. Check empty revival, blacklist/tail masks, explicit free, in-flight allocation, thread exit, lazy sweep, and release races.

### 3. Bring page-reuse gains to the header allocator

**Code evidence.** [`apply_env_config`](../src/gcry/gc_override.cr) enables adaptive policy and default warm retention for bitmap heaps. The normal header allocator retains its older fixed threshold and release behavior. [`sweep`](../src/gcry/collect_sweep.cr) already contains a warm-retention path, but header reuse can require freelist work that bitmap chunks avoid.

**Experiment:** run a same-build factorial comparison: current policy, warm retention only, adaptive threshold only as a diagnostic control, and the coupled policy. Start with 8 KiB churn and Kemal, then burst/drop and the larger application. Do not ship the smaller collection threshold alone: the earlier PR review showed why it can multiply collections without reducing page faults.

Measure freelist rebuilding, clear/zeroing costs, total collection CPU, faults, throughput, and both peak and post-GC RSS. Bound the warm budget by live demand and preserve explicit user overrides. Validate fresh-versus-reused zeroing and freelist correctness.

**Acceptance:** at least a 90% reduction in steady 8 KiB churn faults with a bounded resident footprint and a reproducible improvement in CPU/request or throughput. Headerless and bitmap-with-headers remain regression arms. If header freelist rebuilding erases the benefit, retain the current default and document the measured reason.

### 4. Skip enqueueing known atomic leaves using the chunk already in hand

**Code evidence.** [`mark_impl_unlocked`](../src/gcry/collect_mark.cr) resolves the block and chunk, marks it, and enqueues it. `scan_object`, line 455, subsequently returns for atomic blocks; in headerless mode it performs a chunk lookup to discover that fact. Atomic leaves therefore consume queue/prefetch/drain work despite having no outgoing edges. The serial prefetch ring and bitmap/radix infrastructure already exist.

**Small, early change:** after recording the mark and required attribution, check atomicity using the block/chunk already resolved by `mark_impl_unlocked` and avoid enqueueing definite atomic leaves. This requires no wider mark-stack entry and no additional chunk lookup at the push decision. Handle header, headerless-small, large, and nursery representations through the existing atomicity rules. Keep finalizer and weak-reference behavior unchanged; do not infer leaf status from an arbitrary payload/type ID.

**Validation:** atomic-only, mixed-kind, dense-pointer, shuffled, cyclic, and large-object graphs, with serial and parallel marking. Record queue pushes, mark time, bandwidth/cache misses, and mark-stack high-water. A leaf-only graph should enqueue no ordinary atomic leaves while retaining them correctly. Seek at least 10% lower mark time on the intended workload; Kemal is a regression guard here.

### Conditional A. Optimize root discovery only for a proven root-bound application

**Code evidence.** [`scan_all_fiber_roots`](../src/gcry/collect_scan.cr), line 759, calls `fiber_stack_scan_top`; `fiber_stack_sp_scan_low` walks all threads for each fiber. [`Platform.thread_sp`](../src/gcry/platform/linux_stw.cr) itself searches a 64-slot table. Later, `scan_other_thread_stacks` calls `scan_stack_containing_sp`, which walks all fibers again for each suspended SP. Stack bounds also use a linear snapshot lookup. Some covered stack ranges are revisited for mid-swap safety. [`bitmap_settle_cursor_sets`](../src/gcry/bitmap_alloc.cr), line 359, additionally walks all chunks and cursor slots inside `phase_roots`.

**Design:**

1. **Do now, in the measurement commit:** split `phase_roots` into callbacks/explicit roots, cursor settling, fiber discovery, stack metadata/probes, and scanned bytes. Measure them on real applications with full collection duty cycle and CPU/request. **Stop after instrumentation unless a real workload shows root discovery materially limiting throughput or latency.** The 2.2 ms microbenchmark figure alone does not open this gate. Steps 2–5 remain deferred designs, not scheduled implementation.
2. Build a collection-local snapshot of thread IDs, captured SP/register locations, pthread bounds, and fiber stack intervals. Preallocate storage before suspension; if capacity or metadata is unavailable, retain the existing conservative fallback. Resolve SP-to-stack membership once, using sorted intervals or another bounded index, and reuse the result across root passes.
3. Deduplicate overlapping scan intervals only after proving the same words receive all required root policies. `RootSource` influences acceptance and diagnostics, so merging ranges across sources requires more than matching addresses. Retain signal-frame slack, red-zone coverage, registers, current-stack coverage, and mid-swap fallback.
4. If profiling identifies probe overhead, cache readability/low-water results only within the collection for mappings whose stability is established. Keep fallback behavior on probe failure. Do not persist a low-water boundary across collections without proving newly touched pages remain visible.
5. If cursor settling is significant, use a previous-cycle pinned-chunk list and an active-slot bitmap to reduce traversal. Preserve all chunks needed by an in-flight set; narrowing set-wide pinning is a separate protocol change.

**Validation, only after the application gate opens:** retain the real workload as the primary acceptance case, then vary threads and fibers independently (1/4/8 threads; tens through thousands of parked fibers). Compare root bytes and accepted roots, not just pause time. Exercise `GCRY_SOUND=1`, mid-swap, greg roots, signal slack, stack-bounds fallback, raw pthread birth, and scheduler churn. Target at least 20% lower root-phase time on a workload proven root-bound, with unchanged coverage and no new stack faults. This does not imply a 20% HTTP throughput improvement.

### Conditional B. Revisit heap policy only after the simple rule fails

**Code evidence.** [`adapt_after_sweep`](../src/gcry/collect.cr), line 58, scales swept live bytes by a factor and clamps the allocation threshold to 8–64 MiB on Linux, with a 16 MiB Darwin floor. EC parallelism keeps a fixed 64 MiB threshold. Warm retention follows the computed budget, but actual release is separately gated by [`release_empty_chunks_this_collect?`](../src/gcry/collect_scan.cr). Under multiple mutators, shrinking the warm budget alone does not necessarily return memory. Idle or pinned capacity also differs from immediately reusable capacity.

**Gate:** retain the current live × factor rule and live-following warm budget. The author confirms that they now handle the burst/drop failures raised in review. Continue covering those cases as regressions; do not schedule a replacement controller. Open policy work only with a real-workload reproducer showing that the simple rule misses an explicit CPU, latency, or memory requirement.

**Investigation after that gate opens:** measure the failing workload and relevant controls, including steady small/large live sets, expensive roots with a small live set, burst/drop/recovery, many classes, and many threads. Sweep threshold factor and warm budget separately, pinning other policy knobs. Include lazy and incremental completion and fixed-threshold overrides. Track collection count, full collection CPU, allocation stalls, threshold overshoot, peak/post-GC RSS, pinned capacity, faults, and time to shrink.

First test whether existing factors, caps, release settings, or a focused bug fix address the demonstrated failure. Consider a smoothed collection-cost term or per-class reuse controller only if those simpler remedies fail and the measured mechanism calls for it. Any such design must preserve explicit memory bounds and avoid release/refault oscillation. A changed 64 MiB cap or EC4 default needs its own evidence.

**Acceptance:** publish a CPU/latency/RSS tradeoff curve. Adopt a policy only if it improves one without exceeding agreed limits on the others. Preserve fixed overrides and require recovery after a live-set drop. Provisional limit: no more than 5% peak/post-GC RSS increase for a throughput-oriented change, or explicitly justify a different budget before making it a default.

### Conditional C. Carry mark metadata only when a profile justifies it

This is separate from atomic-leaf skipping. Do not change mark-stack representation without a profile showing repeated chunk resolution is material on a stable live graph. If that gate opens, compare `{object, chunk}` or equivalent validated scan metadata against the existing representation, including wider work items, memory traffic, and stack capacity. Test prefetch depth and metadata prefetching on the repaired graph benchmark rather than assuming the C prototype's optimum transfers. Require a repeatable reduction in the targeted mark cost with unchanged reachability and bounded mark-stack memory.

### Conditional D. Improve opt-in parallel marking before redesigning its queues

**Code evidence.** [`mark_worker_loop`](../src/gcry/parallel_mark.cr), line 266, busy-spins on `@mark_epoch` between collections using `Intrinsics.pause`. Batched push/pop buffers already exist. Mark helpers also update shared fields such as `@layout_conservative_scans`, type-ID rejection counters, and `@parallel_mark_stolen`. [Existing task notes](../tasks/todo.md) attribute poor 4+ worker scaling to shared statistics; source inspection confirms the writes, but does not prove they dominate on every machine.

**Design:**

- Park helpers between epochs with a raw OS wait/wake mechanism appropriate to each platform; do not use a GC-allocating Crystal synchronization primitive inside STW. Preserve epoch wakeups, shutdown, fork reset, and the existing busy/queue-empty termination invariant. Use bounded spinning only within an active collection if measured useful.
- Put diagnostic counters in cache-separated worker-local storage and aggregate when workers have quiesced. Keep operational mark/termination state synchronized; diagnostic sharding does not justify weakening it.
- Measure 1/2/4/8 workers and idle CPU before changing work distribution. Consider worker activation based on work size if small graphs lose to startup/coordination. Defer a work-stealing rewrite until a profile demonstrates shared-queue contention after these changes.

**Acceptance:** helper CPU should approach zero between collections; no lost wakeups or premature termination under stress. Require repeatable mark speedup at the chosen worker count and no material increase in application CPU/request. Do not enable more workers by default solely because isolated mark time falls.

## Benchmark and correctness gates

| Workload | Purpose | Required modes |
|---|---|---|
| Kemal `/json` and `/` | CPU/request, throughput, page faults, request latency | Boehm/null; upstream; PR baseline; candidate; header, bitmap-with-headers, headerless |
| Allocation ring and growing heap | Cursor hits, refill scaling, contention | 1/2/4/8 threads; atomic/pointerful; fixed threshold plus actual defaults |
| Fiber/root stress | Root discovery, range scanning, STW latency | EC1/EC4/EC8; parked/migrating fibers; sound profile; fallback paths |
| Stable graphs and sustained graph churn | Tracing and parallel scalability | Multiple live sizes, survival rates, fanouts, atomic fractions, shuffled layouts |
| Burst/drop/recovery and large buffers | RSS, retention, refaults, release/revive | Fixed/adaptive thresholds; incremental/lazy sweep; explicit free; large cache |
| Larger application / acikturkiye | Integration and large-live-set policy | Default settings first; selected candidate knobs second |

Start with Linux x86_64, then verify Linux aarch64 and Darwin on real runners before changing portable defaults. Include 64/65+ allocating-thread and repeated thread-exit cases in cursor lifecycle stress: the fixed cursor-set capacity and shared fallback are existing behavior, not a reason to assume unlimited scaling.

For comparisons, use at least 20 paired rotated rounds as a starting point, a same-binary null arm, and a second independent session for a default change. Report effect sizes and 95% intervals, with each process/run as the unit of replication. If the interval cannot resolve the proposed acceptance threshold, report the result as inconclusive. Keep request p99 separate from GC pause p99; process-cumulative pause histograms and one `last_phase_*` sample cannot describe an arbitrary measurement window.

Each implementation must add a focused regression that exercises its changed invariant, then run the applicable existing gates:

- Allocation/policy: cursor and adaptive-threshold specs, all three process regression specs added by PR #34, `heap-counters`, `stw-mt-property-test`, `dormant-flush-race`, `page-release-corruption`, `thread-birth-root`, fork and OOM tests.
- Root work: `greg-roots`, `scheduler-roots`, `static-bss-roots`, `static-roots-redeploy`, stack-bound/SP specs, and EC4 churn/soak with invariant and poison diagnostics.
- Mark work: graph/layout property tests, atomic and large-object coverage, `mark-audit`, `parallel-mark-process`, `parallel-mark-termination`, finalizer/weak-reference coverage, and fork shutdown/wakeup cases.

Run gates in the affected header/bitmap/headerless configurations; do not assume a Makefile target compiles all variants. Library specs under Boehm are insufficient: run the `-Dgc_none` process suite, including `-Dgcry_headerless`, and verify invariant/debug modes actually exercise the new path. Before enabling a default, run the current [CI workflow](../.github/workflows/ci.yml), relevant sanitizer checks, and sustained EC4 soak. Resolve any failure before interpreting performance.

## Delivery sequence and stop conditions

The user explicitly wants this performance work included in PR #34. Implement on the branch carrying #34, one item per reviewable commit with its own trials; update the existing PR in place. The follow-through is authorized by the user’s instruction to continue; preserve the existing PR history.

1. **Measurement commit:** maintained runners, committed `alloc_ns.cr`, stable graph cases, corrected counter names, root sub-timers, and a fixed baseline at the reviewed PR #34 head. No collector-policy change.
2. **Medium-buffer cursor commit:** prioritize 8 KiB hits, checking size boundaries, zeroing, counters, and tiny-allocation regressions. This is the first collector optimization for Kemal.
3. **Refill commit:** availability indexing with state-transition regressions and before/after heap-scaling evidence. Also measure its interaction with the preceding medium-buffer change.
4. **Header-retention commit:** publish the factorial result, including freelist relinking cost; select a default only if application and memory gates pass. This precedes any root-discovery rewrite.
5. **Atomic-leaf commit:** a small enqueue check using the existing chunk, measured with the repaired graph/atomic workloads. Keep mark-stack metadata changes out of this commit.
6. **Conditional follow-ups:** root-discovery changes require a real application proven root-bound; a controller requires a failure of the simple live × factor policy; wider mark entries require a supporting profile. Worker parking/statistics work remains scoped to opt-in parallel marking. Add further commits only when those prerequisites are met; unproven conditional work does not block completion of the measured improvements.

Preserve #34's review history without rewriting existing commits. Every performance commit should include its mechanism, affected configurations, validation, raw trial location, and a comparison with the preceding implementation. Also retain the reviewed #34 head as a fixed baseline for cumulative results, and update the PR description to describe the final scope and evidence. Stop or revert an experiment when its mechanism does not measurably improve, its end-to-end effect exceeds what the profile can explain, or it fails a correctness/memory gate.

Do not prioritize more SIMD sweep work, a copying nursery, concurrent collection, or relaxed root coverage for this round. Bitmap sweep and mark prefetching already exist; a moving or concurrent collector changes the runtime contract. Also retain explicit realloc rooting: the prior cursor investigation measured its removal as noise and reverted it. None of these is a substitute for fixing demonstrated allocation costs; root-discovery changes remain contingent on real-workload evidence.

## Reproducing the review's statistical checks

From the repository root:

```bash
python3 bench/log/linux/2026-09-04-alloc-fast-path/analyze_ab.py \
  bench/log/linux/2026-09-04-alloc-fast-path/trials.jsonl policy-hl

python3 bench/log/linux/2026-09-04-alloc-fast-path/analyze_ab.py \
  bench/log/linux/2026-09-04-alloc-fast-path/trials_header.jsonl base-v0.22.0-hdr
```

These re-analyze existing samples; they do not reproduce the benchmark executions. New claims must use the improved measurement protocol above.


## Implementation record

The implementation and experiments remain in PR #34 as separate commits.
Local measurement hashes map to the commits appended to the reviewed PR head
in [PERFORMANCE_PR34_PROVENANCE.md](PERFORMANCE_PR34_PROVENANCE.md).

| Work | Outcome | Evidence |
|---|---|---|
| Measurement infrastructure | Monotonic durations, error census, actual CPU tick rate, consistent ratio statistics, dependency/source/binary records, maintained allocation/graph benchmarks, counter names and opt-in root sub-timers | [Runner documentation](../bench/performance/README.md) |
| Medium cursor dispatch | Hits through 32 KiB; 8 KiB atomic EC4 cost −22.5%. Initial HTTP comparison inconclusive | [Medium cursor findings](../bench/log/linux/2026-09-05-medium-cursors/FINDINGS.md) |
| Refill indexing | Final 960 MB growth cost −87.8% [−89.6, −86.0]; 8 KiB atomic EC4 −73.2%; small-allocation guard −3.7%. Includes stopped-world locking, freed-behind-cursor reuse, and release/acquire publication fixes | [Final refill findings](../bench/log/linux/2026-09-06-refill-final/FINDINGS.md) |
| Atomic-leaf enqueue skip | Atomic graph mean pause −34.2% [−34.6, −33.8]; pointerful graph result inconclusive | [Atomic findings](../bench/log/linux/2026-09-06-atomic-leaves/FINDINGS.md) |
| Header-policy factorial | Coupled policy: micro cost −49.9%; HTTP peak RSS −40.2%, request p99 −25.4%, post-GC RSS **+88.6%**; throughput inconclusive. No header default change | [Micro experiment](../bench/log/linux/2026-09-06-header-policy/FINDINGS.md), [application experiment](../bench/log/linux/2026-09-06-kemal-policies/FINDINGS.md) |
| Final headerless application comparison | +5.5% throughput, CI −0.6 to +11.6%, **inconclusive**. 60 error-free trials; measured collector/server hashes match final source | [Final application results](../bench/log/linux/2026-09-06-refill-final/FINDINGS.md#final-application-result) |
| Correctness and portability checks | Unit/process/invariant/sanitizer suites and applicable race/root/fork/OOM gates; explicit harness limitations | [Validation record](../bench/log/linux/2026-09-06-performance-validation/FINDINGS.md) |

Next decisions are evidence-gated: longer application windows on an exclusive
host, a second independent session and burst/drop/recovery tests for header
retention, and resolution of the baseline header stress defect found on native ARM.
[Native diagnosis](../bench/log/linux/2026-09-06-native-arm/FINDINGS.md) records
10/10 baseline header failures and 20/20 passing bitmap trials; native CI covers
both bitmap representations. The existing background soak is
not validation of this code. Root discovery stops at sub-timers; the simple
live × factor controller, root coverage, and mark-stack representation remain
unchanged. Conditional rewrites are deferred, not silently treated as completed.
