# The allocation fast path, measured against Boehm's

Branch `perf-single-mutator` (PR #34: heap policy), on top of upstream `master` at 9bcd0e6; the allocation path is the stacked `cursor-sets` branch, logged in `../2026-09-05-cursor-sets/`.

## Where the Kemal gap was not

Headerless Kemal `/json` sat at 92% of Boehm with the collector at 0.2–0.5%
of wall time, so the gap is in the mutator. The first guess — that the
allocation fast path's atomics were it — was wrong in an instructive way: a
steady-state microbenchmark (20M allocations, 4096-object ring, collection
on) showed gcry *faster* than Boehm per allocation in every mode, because
Boehm's cost there is its collections on a tiny heap. With collection
disabled Boehm's pure fast path is 15–17 ns for a 48-byte object and 10 ns
for 16 bytes; gcry's was 38–55 ns. That is the number Kemal pays.

## What a 48-byte allocation cost, and why

Under the bitmap allocator, per allocation: the class spinlock (acquire and
release), three atomic adds for `total_bytes`, `bytes_since_gc` and
`live_objects`, a compare-and-swap loop for `free_bytes`, an atomic OR for
the `occ` bit, a `memset` call for the block, and ten-odd branches in
`maybe_collect`. About six lock-prefixed operations at ~20 cycles each on a
path Boehm runs from a thread-local free list with none.

Two findings made a cheaper path possible without touching the multi-thread
case:

- gcry already flips the heap's counters to atomic in its `pthread_create`
  wrapper when a second thread appears — and the runtime's SYSMON thread is
  created at boot, so every program is on the atomic path from its first
  allocation. An exemption for SYSMON was tried and withdrawn: it *does*
  allocate (`Thread#start` builds its main `Fiber` on it), and two threads
  on the unlocked path popped one freelist head — `make scheduler-roots`
  hung under load with that fiber pushed twice onto `Fiber.fibers`, `next`
  pointing at itself. `process_spec/regression/7_sysmon_alloc_race_spec.cr`
  reproduces it in under a second. The regime therefore ends at boot under
  execution contexts, and the numbers below for the fast path are what a
  library heap or a monitor-less program gets; the Kemal numbers were
  re-measured without it (next section).
- The "plain" counter branch used `Atomic#set`, which is an `xchg` — locked
  whether asked or not — which is why an earlier measurement found it "never
  cheaper". `lazy_get`/`lazy_set` are the plain loads and stores.

## The paired run (2026-09-05, after review)

`run_kemal_ab.sh 20 trials.jsonl …` in this directory: every round runs
every arm once with the order rotated a position per round; `analyze_ab.py`
pairs each arm with the Boehm arm of the same round, reports the mean of
the per-round ratios with a 95% CI (t distribution, n = 20), a paired t on
the differences, peak RSS × Boehm, faults per 1 000 requests and CPU
milliseconds per 10 000 requests. A second Boehm arm from the same binary
is the null control. Base is upstream v0.22.0 headerless built in its own
worktree under `bench/assert_gcry_lib.sh`. Load average 1.0 → 2.6 over the
25 minutes; `trials.jsonl` and `analysis.txt` are the record.

| arm | req/s | vs Boehm (paired) | 95% CI | peak RSS × Boehm | faults / 1k req | CPU ms / 10k req |
|---|---|---|---|---|---|---|
| Boehm | 49 038 | 100% | | 1.00 | 2.7 | 224 |
| Boehm, second arm (null control) | 48 349 | 99.0% | [95.1, 103.0] | 1.02 | 2.8 | 227 |
| upstream v0.22.0, headerless | 43 726 | 89.5% (t = −6.25) | [86.1, 92.9] | 1.88 | 1 255.6 | 230 |
| this PR: retention + adaptive threshold, headerless | 49 283 | **100.9%** (t = 0.26) | [96.8, 105.1] | **0.97** | 5.0 | 204 |
| + per-thread cursor sets (stacked PR), headerless | 52 083 | **106.7%** (t = 3.02) | [102.2, 111.2] | 0.97 | 4.8 | 193 |

The heap policy alone takes headerless from 89.5% of Boehm at 1.88× its
peak RSS to parity at 0.97×, on 9% less CPU per request, and the fault
rate from 1 256 per 1 000 requests to 5. That is the page-fault finding at
the top of this file, measured the way the repo's own baselines are. The
review's corrections stand: the earlier "before" row here was spliced from
three batches and two of its cells came from arms that already contained
retention; it is retracted in favour of this table.

Configurations the review measured and this PR now handles: a fixed
`GCRY_THRESHOLD=134217728` no longer holds 128 MiB of emptied chunks after
the live set drops (the warm budget follows live × factor, capped by the
threshold); a Parallel execution context keeps its fixed 64 MiB threshold
but gets the same live-following budget; the header allocator keeps its
fixed defaults rather than the smaller threshold without the relief;
`GCRY_INCREMENTAL=1` recomputes the threshold when its cycle completes;
Darwin's floor is its old 16 MiB; `GCRY_THRESHOLD_FACTOR` is clamped to
10–1000; `GCRY_TIGHT_GROW`'s collect-before-grow floor is 8 MiB. Only the
warm-budget cap has a spec that drives it; the incremental and Darwin
cases are argued, not measured here.
