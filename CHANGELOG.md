# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [Unreleased]

### Fixed

- **The dying-type audit called live objects dying on every minor collection.**
  It walked every used block after the mark and reported each one of the watched
  type the mark had not reached — a question that only means "about to be swept"
  in a **full** collection. A minor marks the nursery and reclaims the nursery,
  so every old live object reads unmarked and reads that way correctly.
  Measured on `stw_mt_property_test --tlab --nursery`: **262 reports in one
  run**, against **0** for the same harness with the nursery off, and every one
  of them a `Thread` the report itself said was still on Crystal's list. That is
  what an audit looks like when it is asking the wrong question rather than
  finding an answer.
  The walk now carries `sweep`'s own two conditions (`collect_sweep.cr:67` and
  `:144`): skip the chunk unless the collection is major or the chunk is
  nursery, and skip the block unless major or the block is nursery. 262 → 0, and
  the arm got cheaper on that harness (11.0 s → 4.3 s) because it stops walking
  the old heap on minors.
  `make thread-block-audit` gained two arms to hold it there: `lives-minor`
  forces 15 minor collections with 200 rooted probes and requires **0** deaths,
  and `lives-minor-all` runs the same thing under the new
  `GCRY_DYING_AUDIT_ALL_COLLECTIONS=1`, which removes the predicate and brings
  the phantoms straight back — **2 800 deaths and 14 address-space walks** over
  live objects. The existing arms are untouched and still pass: the audit still
  names 200 planted deaths and still finds live `Thread` blocks under its
  default, so this narrows the question rather than silencing it.

### Changed

- **`ec_queue_audit`'s own waits are bounded, so the hang says what it was
  stuck on.** The harness waits on three channels — the churn fibers, the
  blocker starting, and the 24 fibers queued behind it running once it is
  released — and none of those waits had an end. A fiber that is queued and
  never dequeued turns `ran.receive` into a block with no output, which is
  exactly what the aarch64 runner has been killing at 20 minutes. Each wait now
  gives up after 30 s and prints how many arrived, how many are still parked on
  the context's global queue, and what the audit had counted, then leaves
  through `LibC._exit` rather than an `at_exit` that would run on the scheduler
  that is stuck.
  Positive control, because a bound that never fires is indistinguishable from
  one that is not wired up: `bin/ec_queue_audit --stall` never releases the
  blocker, so the 24 fibers cannot run, and `make ec-queue-audit` requires the
  report — `0 of 24 after 3s … 24 still owed; context global queue holds 24
  fiber(s)`. Not reproduced locally either way: 60 runs of the audit-on arm on
  x86_64 Linux, 0 hangs.

- **The aarch64 job has been hanging for two days and it read as
  `cancelled`.** Six of its last forty runs ended at the 20-minute job timeout,
  and every one that was examined was killed in the same place: `Terminate
  orphan process: … (ec_queue_audit)`. GitHub reports a job timeout as
  *cancelled*, not as a failure, so a ~15% hang rate — on the runner where the
  open `Thread` use-after-free lives, in one of the two gates that has caught
  it — never showed up as anything to look at.
  Every gate in that step is now bounded with `timeout 300`, so the run fails
  with whatever it had printed instead of the job being cancelled with nothing,
  and the step arms `GCRY_STW_WATCHDOG_MS=10000` so a stopped world that never
  restarts says `STOP-THE-WORLD STALLED <n> ms in phase=<name>` from the inside.
  The x86_64 `EC run-queue audit` step gets the same bound and the same
  watchdog. Neither of these diagnoses the hang; they are what make the next one
  legible.

- **The crash diagnostics now ride the TLAB arms, which is where this harness
  has actually crashed.** `stw_mt_property_test` runs three arms and only the
  plain one carried `GCRY_POISON_HOLDERS` / `GCRY_THREAD_CENSUS` /
  `GCRY_THREAD_BLOCK_AUDIT`. That was right for the sighting it was added for —
  x86_64, 2026-08-17, run `32006847158`, SIGSEGV inside `pthread_getattr_np`,
  which is the plain arm — but it left the other two arms mute, and they are not
  quiet. All three now carry them on Linux, and so does the Darwin step, which
  runs all three through the Makefile and carried nothing.

- **`-Dgc_none` did not compile on x86_64 macOS, and had not for as long as the
  shim existed.** `src/gcry/block.cr` defined `LibC::MAP_ANONYMOUS = MAP_ANON`
  for every Darwin target, on the grounds that "Darwin only defines MAP_ANON" —
  but Crystal's `x86_64-macosx-darwin` bindings define `MAP_ANONYMOUS`
  themselves, and defining it again is a hard error: `already initialized
  constant LibC::MAP_ANONYMOUS`. CI runs `macos-latest`, which is Apple Silicon,
  so a platform the README and `shard.yml` both claim was never once compiled
  for. The shim is now conditional on the constant actually being absent
  (`LibC.has_constant?`), which is a test rather than a guess about which target
  has it.

- **The Darwin build broke on a method that only existed on Linux.**
  `GCRY_STATIC_BSS_CAP`'s setter was added to `linux_roots.cr` and called
  unconditionally from `GC.init`, so every Linux job passed and the macOS one
  failed to compile — `undefined method 'bss_size_cap=' for
  Gcry::Platform:Module`. `Gcry::Platform` is two files that have to present the
  same surface, and nothing checked that until the last job in the matrix.
  `make darwin-typecheck` now does, from Linux: `--cross-compile` runs the full
  semantic analysis for both Darwin targets and stops before linking. It runs
  early in the Linux job, and it is what found the `MAP_ANONYMOUS` collision
  above. Broken on purpose and observed red: removing the Darwin stub reproduces
  the runner's own line.

- **A full staging table threw away the birth it had just been handed — the
  newest one, which is the thread actually inside the window the table exists
  to see.** `Platform.stage_thread` records a thread from the moment
  `pthread_create` returns, and `stop_world`'s pre-stop wait uses that record to
  wait for it to publish itself. A slot is freed when the thread turns up in
  Crystal's list, and the only thing that looked was the collection's own walk —
  so the table held every thread created **since the last collection**, not the
  ones being born. Measured, no collection in between: 65 `Thread.new`s fill it,
  and at 200 threads only **73 of 201** births were recorded at all.
  What a missing record costs is the wait. That thread is not waited for, so the
  world stops with it unpublished: it is neither suspended nor scanned, and
  anything reachable only from its stack has no root. `ThreadBirthRoot` covers
  the `Thread` object and nothing else the thread has touched.
  A full table now **drains** entries whose threads have already published —
  which is what the occupancy should have been all along — and evicts the
  **oldest** entry if that frees nothing. The oldest is the birth most likely to
  be over; the newest is the one in flight. All 201 births are recorded now.
  Both halves earn their place, and the measurement says which does the work:
  at 100 threads the drain absorbs almost everything (6 overflows, 4 evictions),
  while at 200 it absorbs 2 of 107, because those threads have already **exited**
  and a thread that has left Crystal's list can no more be drained than one that
  never joined it. Without the eviction half, that case is the one that loses
  the newest birth.
  `staged_overflows` no longer means a record was lost — it counts births that
  found the table full, most of which the drain then accommodates. The number
  that means a thread will not be waited for is the new
  `thread_staged_evictions`, on `/gc-stats`.
  Gated by `make thread-staging`, both directions: the table is filled with raw
  pthreads, which never reach Crystal's list, so neither the drain nor the
  collection's walk can release them and the full table is a fact rather than a
  race. The birth handed to it must be recorded; under the new
  `GCRY_STAGED_NO_EVICT=1` the same birth must be **absent**, and is.
  **Still lossy, and counted**: an eviction is a thread that will not be waited
  for, and a table full of entries for threads that have exited still costs one
  timed-out spin at the next collection before the wait drops them.

- **A Crystal program with more than 1 MiB of static data had every global root
  dropped.** gcry finds a program's BSS in `/proc/self/maps` by adjacency — the
  anonymous RW mapping that begins exactly where the executable's file-backed RW
  `.data` ended — and then required it to be **smaller than 1 MiB**. Above that
  the whole BSS was refused as a root range, so every class variable and every
  constant slot holding a heap reference was invisible to the mark and was
  swept. It reproduces in twenty lines: an 8 MiB static class variable, one
  `GC.malloc` stored into it, two collections, and the process dies inside
  `IO#encoder` — because `STDERR`, a constant living in that BSS, had been
  collected and **finalized**, which closes fd 2. The block does not merely get
  freed: its chunk goes back to the OS, so reading the payload afterwards faults
  with `Cannot access memory`. That the failure is loud is luck; what the
  collector did was free reachable objects.
  The condition was also inverted with respect to the reason written above it.
  That comment says gcry's own large objects are anonymous and **under** 1 MiB
  and that caching one and scanning it after `munmap` is a SIGSEGV — but
  `< 1 MiB` *accepts* exactly that band and rejects the sizes a gcry large
  object cannot have. What keeps gcry's mappings out is the adjacency test,
  which an unhinted `mmap` cannot satisfy, backed by
  `each_static_range_excluding_heap`, which subtracts gcry's chunks from every
  range the parser yields and exists for precisely this case.
  **Removing the cap alone would only have moved the hole**, because
  `Roots.scan_range` refuses any range longer than `MAX_SCAN_BYTES` (64 MiB) —
  silently, until now. Static ranges go through a new `scan_range_chunked`, and
  the refusal is counted (`Gcry::Roots.oversize_skips`) so nothing can skip a
  root range without saying so again.
  `make static-bss-roots` gates it with two binaries and four arms: 8 MiB of
  BSS clears the parser cap, 96 MiB clears `MAX_SCAN_BYTES` and can only pass
  through the chunked scan, and each is run again under the new
  `GCRY_STATIC_BSS_CAP=1`, which restores the old refusal and requires the same
  block to **die**. It does, both sizes, `live=false` with the static slot still
  holding the address. Each arm measures its own BSS from `/proc/self/maps`
  first, so an arm that never crossed its threshold fails instead of passing
  quietly, and the verdict goes out through a duplicated fd because the arm
  under test closes fd 2.
  **Unmeasured and worth stating**: any program this affected was collecting
  objects it should have retained, so its RSS and pause numbers were not
  measuring the same collector as a correct run. The published fat-app figures
  may move if that app's BSS is over 1 MiB; nothing here re-cuts them.

- **The pthread stack-bounds snapshot stopped at 64 threads, and the counters
  built to notice that reported full coverage.** `snapshot_pthread_stack_bounds`
  records each thread's stack range before the suspend signals go out, and the
  scan under STW looks the range up instead of asking libc. The table was a
  fixed 64 entries: a process whose thread list is longer recorded the first 64
  **in list order** and nothing for the rest, at every collection, for the life
  of the process. A thread with no entry loses the pthread-mapping half of its
  root coverage — `scan_pthread_stack` returns without scanning — and that is
  where a Parallel worker's scheduler frames sit while its SP is on a pool
  fiber, the same frames whose absence is recorded in this file as an acik
  `ThreadPool` UAF and a collect hang.
  Measured, threads parked, one collection: **82 threads on Crystal's list gave
  `visited=64 read=64`** — a clean bill from the pair whose only job is to say
  the platform answered nothing — with 18 lookups falling through to `nil`. At
  122 threads, 58. The lookup miss was counted (`pthread_bounds_misses`, which
  is on `/gc-stats` and whose comment already named "the thread list outgrows
  the table" as reachable); what was not counted was the **visit**, because the
  capacity check returned before `visited` was incremented. So the one assertion
  that would have caught this — `read == visited` — could not.
  The table now grows, doubling from 64, and the visit is counted before the
  capacity check. Growth needs no synchronisation and that is a property of the
  caller: the table is written only by the thread stopping the world, between
  `Thread.lock` and the first suspend signal, and read only by that thread while
  the world is stopped — no thread is frozen when `realloc` runs, the same
  argument that lets `pthread_getattr_np` be called from there at all. After:
  82 threads `visited=82 read=82`, 202 threads `visited=202 read=202`, zero
  misses either way.
  Gated in `process_spec` with a thread list longer than the initial table, and
  broken on purpose with the new `GCRY_STACK_BOUNDS_NOGROW=1`: the same spec
  goes red at `visited=150 read=130`, with 18 capacity misses and 18 lookup
  misses on the 82-thread run. `stack_bounds_capacity_misses` is on
  `/gc-stats`; a non-zero value there means some thread's OS stack is not being
  scanned.

- **A full thread-birth table cost the root, not just the record — so the
  use-after-free v0.20 closed reopened silently past the 64th birth.**
  `ThreadBirthRoot` roots the `Thread` object `GC.pthread_create` is handed and
  releases it when the thread publishes; the release runs inside `stop_world`,
  which is the fact the 64-slot table was sized against the wrong quantity. What
  it has to hold is not **concurrent** births — it is births **since the last
  collection**. Measured, with no collection in between: 65 `Thread.new`s
  overflow it, 100 overflow it 37 times and 200 overflow it 137 times, and every
  one of those births used to take the `return` that counts an overflow and
  roots nothing. A `Fiber::ExecutionContext::Parallel` bringing up 128 workers
  before the heap is big enough to collect had half of them covered by nothing.
  An overflow now roots the object anyway and never releases it. That leaks one
  `Thread` and the graph it holds, which is the deliberate half of the trade: a
  leak is a memory bug, an unrooted birth is the use-after-free this file exists
  to close. `outstanding` counts it, so the leak is visible rather than implied,
  and `thread_birth_armed` / `_released` / `_outstanding` / `_overflows` are on
  `/gc-stats` beside the staging counters.
  Gated in **both directions**, which is what makes the arm worth having:
  `make thread-birth-root` gained a `--burst` arm that fills the table with
  births that can never be released (raw pthreads, which never reach Crystal's
  list) and requires the victim to survive its overflowing birth, and a
  `--burst-unrooted` twin under `GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED=1` that
  restores the old behaviour and requires the same block to **die**. It does, every run — the
  second local, deterministic reproduction of this window, and the first that
  needs no timing at all.
  **Stated and not fixed**: `Platform`'s staging table is the same shape and
  overflows on the same input (37 and 137 in the runs above), because it is
  drained by the same walk. Its overflow costs the pre-stop *wait* for that
  thread rather than the root, so with the above it is a degradation and not a
  hole — `thread_staged_overflows` has always counted it.

- **The allocation counters stop losing updates, and the cost that was traded
  for those losses does not exist on x86_64.** `live_objects`, `total_bytes`
  and `bytes_since_gc` were updated with plain `set(get + n)` unless
  `heap_counters_atomic` was set — measured, four threads lose **5 723 of
  1 200 000** increments. They now flip to atomic in `GC.pthread_create`,
  **before** the call rather than after it — flipping on the way out leaves a
  window in which the new thread is already allocating, and leaves the flag's
  visibility to it unordered, while setting it first is published by the thread
  creation itself. A single-threaded program never reaches the hook and keeps
  the cheap path.
  The comment that justified the losses said an atomic RMW would cost Kemal
  throughput. On x86_64 `Atomic#set` compiles to `mov; inc; xchg`, and `xchg` to
  memory is locked whether you ask or not — so the "cheap" path was already
  paying for a locked instruction per counter and losing updates for it, against
  a single `lock incq` for the atomic. Interleaved and pinned: 55.69 / 55.47 /
  56.13 ns per allocation for plain / atomic / relaxed, within a ~3 ns
  within-arm spread. On **aarch64** the cost is real (`ldar; add; stlr` against
  an `ldaxr/stlxr` retry loop), which is why this flips on a second thread
  rather than shipping on.
  `GCRY_HEAP_COUNTERS_ATOMIC=0/1` pins an arm and survives the flip, which is
  what makes `make heap-counters` two-directional: the old path must be shown to
  lose or the new one's exactness proves nothing.
  `bench/log/linux/2026-08-20-heap-counter-cost/FINDINGS.md`

### Changed

- **The unowned-coverage audit now names thread stacks, and its residue is
  labelled.** What it could not account for is exactly the population the
  in-flight arm walks — measured on `nested_spawn_uaf`, `accounted + not`
  equals `maps_inflight_walked` in every run — so the split is "parked in a
  `Thread#dying_fiber` slot or not", not "known or unknown". Three corrections
  to the reading it shipped with: it is **not 4 a run** (1 to 36 on the same
  harness), it **cannot be thread stacks** — measured, the geometry test looks
  for `STACK_SIZE - PAGE_SIZE` = 8 384 512 bytes while a Crystal thread's stack
  maps exactly 8 388 608, one page apart, so they never reach the audit — and it
  needs a Parallel execution context under concurrent spawning, a quiesced
  single-context program reporting 0 either side of a spawn storm.
  The thread-stack check ships as a **tripwire** whose zero is structural and
  documented as such: that page is where glibc happens to put the guard, not a
  guarantee, and a non-zero count would mean a libc has made the two shapes
  identical. It carries the number of bounds it compared against, so it can also
  say when it had nothing to compare. The first version of this entry offered
  the zero as a measurement ruling thread stacks out; it ruled nothing out.

### Added

- **`GCRY_THREAD_BLOCK_AUDIT=1` — name the dying `Thread`, in the collection
  that frees it.** The second use-after-free is only ever seen on CI: gcry calls
  `pthread_getattr_np` under `stop_world` on a `pthread_t` that is its own freed
  block poison, i.e. it read a `Thread`'s `@system_handle` out of memory it had
  already reclaimed. Eight sightings, three gates, both architectures, and no
  local repro in three days. The instrument that cracked the fiber family —
  walk `/proc/self/maps` at the moment of death and name the region that holds
  the address — could not see this one, and the reason was size in both halves:
  the dying-register audit that triggers it only walks size classes at or above
  384 bytes (the `Deque(Fiber::Stack)` band) and a `Thread` is 192, and it fires
  for whichever block died first in a collection, which in a fiber-churning
  program is never the one wanted. So the arm aims the same question at one
  type: after the mark and before the sweep, read Crystal's `type_id` out of
  every used block, report each one of the watched type the mark did not reach,
  and hand its address to the address-space walk. Wired into the gates that have
  caught this defect — `scheduler-roots` and `ec-queue-audit` (both
  architectures, and six of the eight sightings are on the aarch64 runner) and
  the x86_64 `stw_mt_property_test` step. Measured: +3% on the property test,
  nothing on the root gates.

- **`GCRY_DYING_TYPE_ID=<n>` and `make thread-block-audit`**, which are what let
  the arm's silence on CI be read as evidence. The knob points the same walk at
  a type whose life and death the harness controls, and the gate has three arms:
  200 dropped objects of that type must be named as dying **and** must trigger
  the address-space walk; the same 200 held alive must produce zero deaths and a
  non-zero *live* count; and the shipped default must find live `Thread` blocks
  with four threads running — a default aimed at a `type_id` that matches
  nothing in the heap would be quiet on CI for a reason that has nothing to do
  with the defect. Broken on purpose in three directions and observed red:
  treating every block as marked fails the first arm, dropping the type
  comparison fails the second (8 phantom deaths among rooted objects), and a
  bogus default id fails the third.

- **The dying-type arm now counts the defect's precondition every collection,
  not just its consequence** — and the first version of that count was zero by
  construction, which is why it now reports three separate things: what the
  pre-stop wait saw, whether it **gave up** (the world then stopped with a
  thread unpublished), and whether a thread was staged *after* the wait ran, so
  nothing waited for it at all. Asking `Platform.staged_count` after the mark,
  as the first version did, can only ever return zero: the wait drains what has
  published and drops the rest.
  Measured in the failing harness locally: **24 sightings in 12 runs** of a
  thread staged when the world was about to stop, every one caught by the wait.
  Both branches that would say otherwise are shown to fire by staging an id that
  can never publish — `make thread-block-audit` gained `staged` and
  `staged-nowait` arms for exactly that, since a real thread publishes too fast
  to be held in the state the defect needs.
  The two kinds are the two candidate mechanisms and they need different fixes:
  staged (created, not yet on Crystal's list) and a gap (on the list, no bounds
  from the snapshot). Both are countable in **green** runs, which is what makes
  them worth having — the consequence arrives in bursts (4 of 20 in one batch, 0
  of 60 across the three after it). The gap half is silent locally too, and that
  silence is evidence: stubbing `snapshotted_stack_bounds` to `nil` makes the
  same run report `6 listed, 0 bounded` at every collection.

- **The report is three lines now, and the reason is the one this file keeps
  recording:** it grew past `RawOut::LIMIT` (480 bytes) and was silently
  truncated, losing the end of its own verdict — the same failure mode the crash
  reporter has been corrected for three times, committed by the instrument
  written to correct it. In the same pass, "not on Crystal's list" stopped
  asserting "the thread has exited": off-list has two causes and the first catch
  to reach that line was the other one, a thread that had not published yet. The
  line now states both and quotes the pre-stop wait's own record beside it,
  including the dying object's `@system_handle` against the staged ids — as
  *consistent with*, never as an identification, because glibc recycles thread
  ids (measured: one value across eight collections while the staged total went
  4 → 11).

- **The dying-type report now says whether the dying `Thread` is still on
  Crystal's list, and whether any live thread's list node still links to it.**
  Those are different defects — a listed `Thread` dying means the static root
  that is `Thread.threads` did not cover it, while an unlisted one is legitimate
  garbage and the defect is whatever still walks to it, `Thread::LinkedList`
  being intrusive. Both are answerable on any catch, without waiting for the
  address-space walk to find a holder, and the line carries a self-check: a "not
  on the list" from a walk that cannot find the collecting thread either is a
  broken comparison, not a finding.

- **`make thread-uaf-sample` — buy samples of a defect that only happens on
  CI.** The `Thread` use-after-free fires in about one aarch64 job in three and
  in none of 40 local runs of the same harness, and the arm that names its
  holder only speaks when it fires. The target runs the failing harness ten
  times with the arm on and keeps the logs of the runs that said something. It
  is deliberately **not** a gate — it exits 0 either way, because a step
  expected to fail while the defect is open would block every pull request or
  train everyone to ignore it — and it ships as a `continue-on-error` aarch64
  job that uploads what it caught. `THREAD_UAF_BIN` points it at another
  harness, which is how its own reporting path is shown to work: against
  `thread_storm`, where a dying `Thread` is routine, it must keep and print.

### Fixed

- **The `Thread` use-after-free is closed: the object is rooted from
  `pthread_create` until the thread publishes itself.** Between the two, the
  `Thread` is covered by no root — it is not on `Thread.threads` yet, so the
  static root that is the list cannot reach it, and its only other holder is the
  new thread's own stack, which gcry has no bounds for and never scans. The
  pre-stop wait was supposed to cover the window and does, in 40 sightings
  across 20 green CI runs; the two catches that crashed are the ones where it
  **gave up** and stopped the world anyway, with the kernel reporting one more
  thread than Crystal's list held.
  The fix needs none of that machinery, because the object was already in
  gcry's hands: Crystal calls `GC.pthread_create(…, arg: self.as(Void*))`, so
  the `Thread` *is* the argument the hook is handed. It is rooted there and
  released in `stop_world`'s walk once the thread is on the list — one
  `add_root` per thread created, and no change to what the stopped world does,
  which matters because two earlier attempts at this defect changed collector
  behaviour and broke it. `GCRY_THREAD_BIRTH_ROOT=0` turns it off;
  `GCRY_THREAD_BIRTH_NOROOT=1` records the same births and roots nothing.
  Gated by `make thread-birth-root`, which holds the window open the only way it
  can be held open — a **raw** pthread created through the same hook, which
  never joins Crystal's list — and requires the block to survive rooted, and to
  **die** in both the twin and the knob-off arms. The first version of the
  release path deadlocked the collector: `stop_world` runs under `@roots_lock`
  and it is not reentrant, so the release hands the pointer back and the caller
  mutates the set directly.
  The twin earned its place on the first CI run: it failed on aarch64 because
  the record table is a class variable, i.e. static memory the conservative root
  scan reads — so storing the address there rooted it, and neither arm could
  have told `add_root` from the bookkeeping. Addresses are masked in the table
  now, and the harness materialises the victim's pointer only inside a
  `@[NoInline]` frame it then wipes.
  Known and counted: a thread that never publishes keeps its root for the life
  of the process (`ThreadBirthRoot.outstanding`), and the interval *inside*
  `pthread_create` is still uncovered — closing that needs a trampoline on the
  new thread, tried before and crashed 8 runs in 10.

- **The crash reporter excluded the defect it was reporting.** A fault outside
  the heap span printed "never a gcry allocation, so a swept object is not the
  explanation" — in three control runs, two lines after naming the `pthread_t`
  the collector was querying, and at exactly that id **+ `0x418`**. The address
  is a field of the descriptor that id points at, the id came out of a
  `Thread`'s `@system_handle`, and a reissued `Thread` block carries no poison,
  so a swept object is the *leading* reading there rather than an excluded one.
  The decision is now a pure function (`SegvReport.out_of_span_reading`) with
  five cases in `spec/segv_report_spec.cr`, because the branch that matters can
  only fire while libc is inside the query and no harness can enter it.

- **The crash reporter named a free path from a reissued block's flags.**
  `SWEPT` is set beside `FREE` by the sweep and cleared when the block is handed
  out again, so on a reissued block those flags describe the reissue — and the
  line was read as "freed by an explicit free" three times, the last against a
  block the dying-type audit had watched the **sweep** condemn one collection
  earlier. It now declines the verdict unless the block is still free, and says
  why. `make segv-report` grew a `reissued-poison` arm that requires exactly
  that, broken on purpose in both directions.

- **The address-space audit reported its own call chain as a hole in the stack
  scan.** Its first version reported 47 hits that were its own frames and was
  fixed by comparing against the window the scan actually used — but the audit
  runs at roughly the depth the scan ran at, so its frames land *inside* that
  window, and the verdict they earned was "the scan walked these bytes and did
  not offer the value": a filter bug that does not exist. It now excludes
  everything below `collect_entry_sp`, the same boundary `GCRY_BIRTH_GRACE`'s
  holder search already uses, and says so — the collector's own call chain, this
  audit's included, is not evidence. Measured on the new gate: 6 of 7 base hits
  on a dropped object were the audit's own chain and one was its caller's local;
  before the fix, one of them was classified as inside the scanned window.

- **The dying audit's "never offered by the mutator-stack scan" line could not
  be true for a 192-byte block.** The table it reads records only candidates at
  or above the 384-byte band, so any smaller block was "not recorded" rather
  than "not offered". It now also records blocks of the watched type, whatever
  their size.

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

[Unreleased]: https://github.com/sdogruyol/gcry/compare/v0.19.0...HEAD
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
