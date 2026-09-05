# Defect fixes after the stage-2 performance commits

Starting point: `42de285c55a17eb38766a7197dee23ca1ea0abf6`, the latest
`perf-single-mutator` / PR #34 head when this work started. The six stage-2
commits remain intact. These are correctness fixes, not new throughput claims.

## Header dormancy and zeroing

The previously gated medium-buffer stress exposed real header allocator bugs:

- Dormancy retained already-free bytes in the counter, then revival added the
  whole chunk again. Repeating the cycle inflated `free_bytes` past mapped heap
  size. The header discover pass also left newly dead payload uncredited until
  revival. Dormancy now credits only that newly dead payload; revival adds none.
  This matches bitmap dormant-capacity accounting.
- Revival marked the freelist clean after rebuilding headers. The metadata
  page is not released, so its old payload survives; Darwin's reusable-page
  advice need not zero other pages either. Revived header payload is now dirty
  and pointerful allocation clears it before returning it.
- Allocation read the class-wide clean flag after releasing its lock. A peer
  could map a fresh chunk in that interval, making a dirty claimed block appear
  clean. Old-generation and nursery allocation now return the claimed block's
  cleanliness from inside the class lock. TLAB and batch lists cannot use a
  global freelist's cleanliness as evidence and therefore clear pointerful
  payloads. Atomic allocations retain their existing clearing contract.

All five focused header tests fail on the exact pre-fix commit and pass after
the changes. The scheduled peer-refill tests use a spec-only method wrapper,
without sleeps or production hooks. The process stress is enabled normally
again in all three allocator configurations; `HEADER_MEDIUM_STRESS` is no
longer needed. Header policy defaults are unchanged.

## Cursor cache lifetime

The new single-pointer TLS cache checked the heap identity inside its cursor
set. If a worker finished using heap A, a peer destroyed A, and the worker then
allocated from B, that check read A's freed set. This reproduced as a real ASan
`heap-use-after-free` in `cursor_set_cached`; the report is retained.

A literal UInt128 TLS value now carries the heap identity and cursor address.
The identity check precedes any dereference, retaining one TLS accessor while
rejecting a stale cache for another heap. It neither keeps destroyed heaps
alive nor leaks cursor sets. The two-thread regression passes in both layouts
with actual ASan instrumentation after the fix. Concurrent use of a heap while
it is being destroyed is not added to the API contract.

## Correcting the sanitizer gate

The old `crystal build -Dasan ...` only defined a conditional compilation flag.
No collector/compiler code consumed it to enable sanitization, and the produced
binary had neither ASan load checks nor its runtime. Earlier results described
as ASan runs were ordinary spec executions and must not be cited as sanitizer
coverage. Their original transcripts are retained.

`ci/asan_check.py` marks emitted LLVM function definitions `sanitize_address`,
compiles them with Clang 19's ASan pass and runtime, and first requires a control
to fail with an actual `heap-use-after-free` report. It then runs the cursor
metadata lifetime regression in bitmap-with-headers and headerless layouts.
The control and both clean runs pass the gate. The full ordinary spec suite
remains required in the same CI job. `make asan` uses the real gate too.

This is deliberately scoped sanitizer coverage for libc-owned metadata. It
does not poison mmap-managed GC objects or certify conservative stack scans.
An attempted instrumented collection suite crashed without a useful ASan
report; `asan-collection-limitation.txt` records that failed experiment, which
is not counted as a pass. Broad sanitizer support for collector stack capture
and scanning requires separate integration. See [Clang's ASan documentation](https://clang.llvm.org/docs/AddressSanitizer.html).

## Validation

Local Linux x86_64, Crystal 1.21.0:

- Full unit suites: header 271, bitmap-with-headers 271, headerless 252 examples;
  zero failures, one platform-dependent pending example each.
- Process suites: 32 examples in each configuration, zero failures and zero
  pending examples, including the previously excluded header stress.
- Focused cursor/header checks: 11 examples, zero failures.
- Real ASan: the UAF control is detected; the cursor lifetime regression passes
  in both bitmap representations.
- Header page-release and heap-counter gates pass, including their controls.
- Focused headerless invariants: 12 examples, zero failures. Lint passes 127
  files, and all 163 runtime knobs remain documented.
- Native ARM CI repeats the restored header process suite in three fresh
  processes, alongside both bitmap process configurations.

Adjacent transcripts preserve failing controls and passing results. Native ARM
and Darwin validation is performed by the PR's required CI jobs; local success
alone does not establish a native result. The existing header policy experiments
still require independent application/memory confirmation before any default
change. Earlier throughput numbers describe their recorded source commits.

## Native CI exposed a second accounting cause

CI at `3c5831c` passed the real ASan gate but still failed header accounting
on native ARM and Darwin. The dormant and zeroing regressions were valid; they
did not explain all the counter drift. Lazy sweep keeps `collecting` true
after mutators resume, while `free_bytes_add` and `live_objects_sub` used that
flag to select non-atomic updates. They also missed the bitmap allocator's
implied atomic-counter setting. A collector update could overwrite a mutator's
debit, inflating free capacity.

The helpers now use atomic updates whenever the world is running and the heap
requires atomic counters. Only the actual stopped-world phase (or the explicit
single-mutator/unsafe setting) permits plain updates. A two-thread regression
loses 45,247 and 31,336 free-byte updates before the fix and none afterward,
covering both explicit header atomicity and bitmap-implied atomicity. Full local
unit suites now pass 273 / 273 / 253 examples, with one platform pending each.
The local header process suite passes all 32 examples.

The preceding stage-2 CI also failed the dormant-flush gate because none of its
six unsafe stress trials reached the race. The gate now additionally schedules
the exact interleaving: a walk holds a chunk, a peer frees/trims it, then the
walk reads the held metadata. Queued release must keep it mapped; immediate
release must fault at that read, with a verified diagnostic and a deadline.
All six safe stress trials remain required. The stress-control counts are
still reported, but timing alone no longer decides whether the control is
engaged. The local scheduled control faults as required, with safe stress 0/1
and unsafe stress 1/1 failures. Native confirmation follows in PR CI.
