# Hardening & knobs

Stress the collector. Tune process GC. Know where false retention comes from.

## Stress

| Suite | Mode |
|-------|------|
| `crystal spec` (+ `spec/stress_spec.cr`) | Library `Gcry::Heap` under Boehm |
| `samples/stress.cr` | Process GC (`-Dgc_none`) |

```sh
crystal spec
crystal build -Dgc_none samples/stress.cr -o bin/stress && ./bin/stress 300
# optional: side mark bitmap (higher RSS on Linux HTTP) — crystal build -Dgc_none -Dgcry_side_bitmap …
```

## Defaults that matter (process GC)

- Marks live in the **BlockHeader** (`MARK` flag). Side `MarkBitmap` mmap is **opt-in** (`-Dgcry_side_bitmap`) — Linux HTTP A/B: ~9× Kemal RSS vs ~1× header marks
- Majors: Linux **32 MiB**, Darwin **16 MiB**; **full STW**; nursery / incremental **off** (opt in `GCRY_NURSERY=1` / `GCRY_INCREMENTAL=1`)
- **Adaptive nursery threshold** when nursery is on (target survival 50%, clamped [64 KiB, 8 MiB]). Disable with `GCRY_DISABLE_ADAPTIVE_NURSERY=1`
- Empty chunks **released** (`GCRY_KEEP_CHUNKS=1` to retain); dormant retain budget: Linux **0**, Darwin **512 KiB** (`GCRY_EMPTY_CHUNK_RETAIN`)
- Base-pointer-only ambient roots; root **type_id** gate **on**; layout scan **on**; **SP clamp** **on**; page **blacklist** **on** (Linux + Darwin; `GCRY_DISABLE_BLACKLIST=1` to opt out)
- Fiber stack scrub **off** (was on through v0.18; `GCRY_SCRUB_FIBERS=1` to opt in)
- Base-ptr roots, the type_id gate, the STW stack/pthread lags, the blacklist —
  and fiber scrub when it is opted in — are **root-completeness heuristics**:
  each can decline to mark a pointer that is genuinely live. (Layout scan is a
  *separate* axis: body-scan precision, not root completeness.) `GCRY_SOUND=1`
  turns the whole class off in one flag — that is the configuration whose
  numbers belong in a correctness claim. See [SOUND-DEFAULTS.md](SOUND-DEFAULTS.md)
- Size-class chunk: library/Linux **128 KiB**; Darwin process **256 KiB** (`GCRY_CHUNK_BYTES` to override)
- Large-object freelist retain: Linux process **0**, Darwin **1 MiB** (`GCRY_LARGE_CACHE`; adaptive grows only from a non-zero floor, up to 32 MiB)
- Free-page physical release: Darwin **on** (`MADV_FREE_REUSABLE`); Linux HOLED **opt-in** (`GCRY_PAGE_DONTNEED=1` — measured thr+RSS regression as default). Escape: `GCRY_DISABLE_PAGE_RELEASE=1` / `GCRY_DISABLE_MADVISE=1`
- Auto-collect suppressed while finalizers run

Pauses: `Gcry.pause_stats`. HTTP: `GET /gc-stats`, `GET /gc-collect`, `GET /metrics` under `-Dgc_none`.

Raising `GCRY_THRESHOLD` cuts major count but grows pause p50 — measure on the real app before changing the default.

## Env reference

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes since last major (Linux default **32 MiB**; Darwin process **16 MiB**) |
| `GCRY_DISABLE_AUTO=1` | No auto-collect |
| `GCRY_NURSERY` | Opt-in nursery (bytes; default threshold **512 KiB** when enabled). Process GC default **off** |
| `GCRY_DISABLE_NURSERY=1` | Force nursery off |
| `GCRY_DISABLE_ADAPTIVE_NURSERY=1` | Use fixed nursery threshold (no auto-tuning) |
| `GCRY_SOFT_DIRTY_MAX` | Dirty/total % cap for soft-dirty scan (default **25**) |
| `GCRY_DISABLE_SOFT_DIRTY=1` | No soft-dirty |
| `GCRY_MPROTECT_BARRIER=1` | Force mprotect+SEGV barrier |
| `GCRY_DISABLE_MPROTECT=1` | Forbid mprotect |
| `GCRY_INCREMENTAL=1` | Sliced majors (+ dirty re-scan if barrier armed) |
| `GCRY_DISABLE_INCREMENTAL=1` | Full STW (process default) |
| `GCRY_INCREMENTAL_WORK` | Objects per slice (default **1024**) |
| `GCRY_STRESS=1` | Collect every N allocs (`GCRY_STRESS_EVERY`, default **16**) |
| `GCRY_KEEP_CHUNKS=1` | Retain empty chunks (higher thr / RSS) |
| `GCRY_RELEASE_CHUNKS=1` | Force empty release (already default-on) |
| `GCRY_EMPTY_CHUNK_RETAIN` | Dormant empty-byte budget (process: Linux **0**, Darwin **512 KiB**; library **0**) |
| `GCRY_EMPTY_CHUNK_WARM_RETAIN` | Mapped warm empty-byte budget before dormant/munmap (research; not default) |
| `GCRY_TIGHT_GROW=1` | Sticky newest-chunk freelist + sparse GC-before-grow (fat-app RSS; Kemal thr soft — not default) |
| `GCRY_DISABLE_TIGHT_GROW=1` | Force tight-grow off |
| `GCRY_DISABLE_TIGHT_GROW_GC=1` | Prefer-freelist only (no GC-before-grow) |
| `GCRY_PRECISE_STACK=1` | Load `.llvm_stackmaps` + hybrid precise walker (additive; see [STACK_MAPS.md](STACK_MAPS.md)) |
| `GCRY_PRECISE_STACK=2` | **Research:** exclusive precise stacks (no conservative stack word scan; UAF risk) |
| `GCRY_PARALLEL_DORMANT=1` | Parallel: DONTNEED empties within retain (keeps post-STW lazy sweep) |
| `GCRY_PARALLEL_DORMANT_ALL=1` | Parallel: DONTNEED every empty (legacy; thr↓) |
| `GCRY_PARALLEL_RELEASE=1` | **Unsupported** — Parallel munmap excess (forces in-STW sweep; can hang). stderr warn; prefer `GCRY_PARALLEL_DORMANT=1` |
| `GCRY_SOUND=1` | **Soundness profile** — turns off every heuristic that can decline to mark a live pointer (interiors on, misaligned interiors on, static roots on, type_id gate off, STW lags 0, fiber scrub off, blacklist off) and pins the barrier axis (nursery/incremental off). Applied before the individual knobs, so any explicit `GCRY_*` still wins — and the `soundness` field on `/gc-stats` demotes to `sound-roots-only` / `tuned` when one does. See [SOUND-DEFAULTS.md](SOUND-DEFAULTS.md) |
| `GCRY_INTERIOR=1` | Interior pointers on ambient roots |
| `GCRY_UNALIGNED_CANDIDATES=1` | Follow misaligned candidate values (`str.to_unsafe + 3`); implied by `GCRY_SOUND` |
| `GCRY_ALIGNED_CANDIDATES=1` | Force the cheap alignment filter back on (escape from `GCRY_SOUND`) |
| `GCRY_PAGE_DONTNEED=1` | Sparse free-page release (Linux opt-in; Darwin process default-on) |
| `GCRY_DISABLE_PAGE_RELEASE=1` | Disable free-page reclaim (Darwin default-on; Linux if forced on) |
| `GCRY_LARGE_CACHE` | Large freelist retain (Linux process **0**; Darwin **1 MiB**; adaptive from non-zero) |
| `GCRY_CHUNK_BYTES` | Chunk mmap size (library/Linux default **128 KiB**; Darwin process **256 KiB**) |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | Disable root type_id filter |
| `GCRY_DISABLE_LAYOUT=1` | Disable layout-precise scan |
| `GCRY_SCAN_CAPS=1` | Register `instance_sizeof` scan caps for all References (clips size-class padding; fat-app live set often unchanged) |
| `GCRY_DISABLE_AUTO_LAYOUTS=1` | When auto-layouts opted in: keep builtins only |
| `GCRY_AUTO_LAYOUTS=1` | Opt-in whole-program precise layouts (Linux Kemal `/json` thr cost ~7pp) |
| `GCRY_DISABLE_SP_CLAMP=1` | Full pthread range on other threads |
| `GCRY_STW_STACK_LAG` | Multi-mutator parked-fiber scan depth below `stack_top` (bytes; default **256 KiB**; `0` = full guard→bottom) |
| `GCRY_STW_PTHREAD_LAG` | Multi-mutator pthread scan from stack high when SP is on a fiber (bytes; default **256 KiB**; `0` = full map) |
| `GCRY_STACK_LOW_WATER=0` | Disable the low-water skip (Linux; default **on**). The scan starts at `max(stack_top − lag, low_water)` — a page with neither the present nor the swapped bit in `/proc/self/pagemap` was never faulted, so it is zero and skipping it cannot lose a root. Not a conservatism knob: setting `0` only makes the scan *wider* and slower (Kemal EC4 pause 3.60 → 8.06 ms). Exists for A/B and for a kernel whose pagemap misbehaves; unreadable pagemap already falls back on its own |
| `GCRY_MONITOR_GATE=0` | Let the EC Monitor run inside the stopped world again (default **on**, i.e. shut out). STW never signal-suspends the Monitor — resume races wedged it — and it was measured waking ~100×/s through a 4 s stop and running `StackPool#collect`, which munmaps fiber stacks, while the collector scanned thread stacks. `Gcry::MonitorGate` handshakes it out instead. Measured cost over 3000 collections: zero added pause (`monitor_gate_stw_waits=0`), worst case one in-flight Monitor call. `0` is for A/B and is the old, unsound-by-assumption behaviour |
| `GCRY_STW_WATCHDOG_MS` | Print which phase the collector is stuck in when the world has been stopped longer than this (ms; default **off**). A hang under STW is otherwise silent: every mutator is frozen in `sigsuspend` and `/gc-stats` cannot answer because its thread is suspended too. The watcher is a raw pthread — not a `Crystal::Thread`, so STW does not suspend the one thread whose job is to notice. Costs one sleeping thread while armed; the phase breadcrumb it reads is recorded either way |
| `GCRY_SEGV_REPORT=1` | On SIGSEGV / SIGBUS, print what the heap knows about the faulting address — inside the heap span or not, which block, used or free, the first word of its payload, and whether the freed-block poison is in the faulting context's registers (`0xdeadf2ee…` is non-canonical, so the kernel reports `si_addr` as 0 for it). Then hands the signal back to Crystal's handler, which reports as before. Armed from the **first collection**, not from `GC.init` — Crystal installs its own handler afterwards and discards anything earlier. Default **off**: installing a signal handler is not something a collector should do unasked. `make segv-report` |
| `GCRY_POISON_FREED=1` | Overwrite a freed block's payload with `0xdeadf2eedeadf2ee`. A use-after-free then reads a value that is not a pointer, not zero and not anyone's data, and faults at a non-canonical address instead of at something plausible — the 2026-08-10 soak died on `0x7f1700000149`, which three sessions could not agree about. Sound because the freelist link lives in the block header, not the payload, and because every free path marks the size class's freelist unclean so `malloc`'s clearing fast path still hands out zeros (`make poison-freed` gates both halves). Default **off**: measured **+40%** on the soak's pause p50 (2.72 → 3.81 ms, n=5) |
| `GCRY_POISON_TAG=1` | The poison above, with the freed block's own address in its low 48 bits, so a crash says *which* free wrote what it read instead of only that some free did. Still non-canonical (bits 63:48 are `0xDEAD` and bit 47 of a user-space address is 0), so it faults identically. Implies `GCRY_POISON_FREED` — asking for the tag and not getting poisoned blocks would be a knob that silently does nothing |
| `GCRY_POISON_HOLDERS=1` | And the step after naming the block: naming **what still points at it**. On a fault whose poison names a block, search the explicit root set, every live block in the heap and every fiber stack for that address, and report each holder — the holding block's address, size, `type_id`, flags and mark state with the offset the pointer sits at, or for a stack the slot address, the fiber's `stack_top`, and whether that slot is inside the window the collector actually scans. Finding **nothing** is a result too: the pointer is then in a register, in thread-local storage, or in memory gcry never mapped. Implies the tag and `GCRY_SEGV_REPORT` (the search needs a block address to look for). Costs nothing until something faults. Linux only — the poison is found in the faulting context's registers, and that path is Linux-only. `make poison-holders` |
| `GCRY_MARK_AUDIT=1` | After `mark_loop` and before `sweep`, with the world stopped, walk every marked block and report any base pointer into a **used but unmarked** block — the sweep is about to free something a live object points at. Names the parent's address, `type_id`, size and the offset the pointer sits at, plus the child. Counters `mark_audit_edges` / `mark_audit_misses` on `/gc-stats`, so a quiet run still says whether the mark held. Base pointers only and ATOMIC parents skipped, both to keep false positives from burying a real hit. Default **off**: O(live heap) inside the pause, and it is a debugging instrument, not a safety net — it reports and does not fix. `make mark-audit` |
| `GCRY_BIRTH_GRACE=1` | **Research only.** Root every block `allocate` returns for the duration of the next collection, then drop it. Closes the one window in which a block is live in a register or a stack slot and nowhere else — between being handed out and being stored into an object. Runs **after** the mark, so it reports each newborn block the mark did not reach (address, size, first word, collection) before saving it: that is the point, not the saving. Took the fiber-creation use-after-free from 20/48 to **0/48**, and named what it saves — `Fiber` objects mid-`initialize`. Not a fix and never a default: it keeps every allocation alive for a whole collection, which is a retention policy nobody chose. Counters `birth_grace_rooted` / `birth_grace_saved` / `birth_grace_overflows` on `/gc-stats`; the ring is 1 Mi slots and **counts what it drops**, so a null result cannot be a silent cap |
| `GCRY_EC_QUEUE_AUDIT=1` | Walk the Parallel execution context's run queues at every collection, inside the stopped world where they are quiescent, and require every slot to be a **live Fiber** (in the heap, in an allocated block, `Fiber`'s type_id at offset 0). Prints the structure, index and value of the first slot that is not, and counts it on `/gc-stats` (`ec_queue_audit_faults`, cumulative). Exists because the 2026-08-10 soak SEGV'd in `Parallel::Scheduler#quick_dequeue?` an unknown time after whatever overwrote the slot — this names the collection instead of the crash. Default **off**: bounded (ring capacity per scheduler plus the global list) but inside the pause. Gated by `make ec-queue-audit` |
| `GCRY_STW_TEST_STALL_MS` | **Research only**, default 0. Hold the world stopped inside the thread-stacks phase for this long, so the watchdog above has a run it is expected to fire on (`make stw-watchdog`). Freezes every mutator on purpose — never ship non-zero |
| `GCRY_DISABLE_LAZY_SWEEP` | Force in-STW sweep (default: EC1 and Parallel reclaim-off / TLAB-off sweep after `start_world`) |
| `GCRY_BLACKLIST=1` | Force page blacklist on (already process default) |
| `GCRY_DISABLE_BLACKLIST=1` | No page blacklist |
| `GCRY_DISABLE_STATIC_ROOTS=1` | Skip dyld/ELF static root scan (debug; unsafe) |
| `GCRY_LIVE_ATTR=1` | Research: first-mark root-source counters; pair with `/gc-live-attr` |
| `GCRY_LIVE_ATTR_WATCH_TID` | Research: first-mark counts for one type_id (`first_mark_watch_*`; implies LIVE_ATTR) |
| `GCRY_DISABLE_FIBER_FP_FILL=1` | With `PRECISE_FIBERS`: skip FP-frame conservative fill (pure maps; UAF risk) |
| `GCRY_FIBER_FP_FILL_MISS_ONLY=1` | With `PRECISE_FIBERS`: skip FP-fill on nonempty map hits (research; acik UAF) |
| `GCRY_STACKMAP_MISS_LOG=1` | Research: parked map-miss PC ring on `/gc-stats` (`stack_maps_top_miss_pcs`) |
| `GCRY_STACKMAP_NEAR_DELTA` | Research: ret↔map slack bytes (default **128**; was 32 — too tight for arg pushes) |
| `GCRY_TLAB=1` | **Unsupported** under Parallel — thread-local freelists (research/A/B; stderr warn). Supported path keeps TLAB **off** |
| `GCRY_ALLOC_BATCH=N` | TLAB-off: claim N (1..64) freelist nodes per lock; USED stash (lazy-safe) |
| `GCRY_CLEAR_STACK=1` | Unused-stack wipe on alloc (RSS experiment; every **16**) |
| `GCRY_CLEAR_STACK_BYTES` | Wipe size (default **4096**) |
| `GCRY_CLEAR_STACK_EVERY` | Wipe every N allocs |
| `GCRY_SCRUB_FIBERS=1` | Parked-fiber scrub on (**opt-in** on tip; was the process default) |
| `GCRY_DISABLE_SCRUB_FIBERS=1` | Disable parked-fiber scrub |
| `GCRY_FIBER_SCRUB_BYTES` | Parallel parked-fiber wipe below SP (default **512**; 64..8192) |
| `GCRY_PARALLEL_MARK=N` | **Experimental** mark workers — HTTP thr often **regresses** |
| `GCRY_DISABLE_MADVISE=1` | Skip free-page physical release helpers |
| `GCRY_DISABLE_ATFORK=1` | No atfork; post-fork GC raises |
| `GCRY_DEBUG_INVARIANTS=1` | Runtime heap invariant checks |
| `GCRY_TRACE=1` | NDJSON GC event log (stderr or `GCRY_TRACE_FILE`) |
| `GCRY_TRACE_FILE` | Trace output path |
| `GCRY_TRACE_ALLOC_SAMPLE` | Log 1/N alloc/free lines (default **1000**; `0` = off) |

OOM / fork / signals: [POLICY.md](POLICY.md). Trace / heap dump: [API.md](API.md), `make trace-smoke`. Mutation scoring: [MUTATION.md](MUTATION.md).

## False retention

Conservative GC keeps any aligned word that **looks** like a heap pointer.

Common sources: stale stack slots, integer bit patterns, broad static scans.

Mitigations already on by default: empty-chunk release, base-ptr roots, type_id gate, layout builtins, SP clamp, blacklist. Fiber scrub is **opt-in** on tip (`GCRY_SCRUB_FIBERS=1`) — it cut false retention, but nothing measured kept its default alive. Linux HOLED page release is opt-in (`GCRY_PAGE_DONTNEED=1`). Opt-in `GCRY_CLEAR_STACK=1` wipes **unused** stack on alloc — not stack maps. Closing dense-live RSS on fat apps needs the compiler.

### Diagnosing via `/gc-stats`

Per-source root reject counters tell you where false roots come from:

| Field | Source | When to act |
|-------|--------|-------------|
| `type_id_stack_rejects` | Fiber/mutator stacks | Stale slot; consider `GCRY_CLEAR_STACK=1` |
| `type_id_static_rejects` | BSS/data segments | Library has wide globals; no good fix at GC level |
| `type_id_thread_rejects` | Thread TLS | Worker stack slack; review thread count |
| `type_id_root_false_negatives` | Rejected roots later proved valid | **UAF risk**: gate is too strict, raise `1_000_000` upper bound |

`stack_rejects + static_rejects + thread_rejects == type_id_root_rejects`. Any non-zero `false_negatives` is a production alarm.

### Nursery survival metrics

| Field | Meaning | Tuning |
|-------|---------|--------|
| `nursery_survival_bytes` | Surviving payload from the last minor | High → grow threshold; low → shrink |
| `nursery_alloc_before_minor` | Nursery alloc bytes at the start of the last minor | Compare with survival_bytes for rate |
| `nursery_survival_rate_pct` | Moving-average survival rate (last 10 minors) | Target is 50%; >80% → threshold grows; <25% → shrinks |
| `adaptive_nursery` | Whether adaptive auto-tuning is active | Set via heap property or `GCRY_DISABLE_ADAPTIVE_NURSERY` |

```crystal
before = GC.stats.heap_size
# drop refs…
GC.collect
after = GC.stats.heap_size
```

Watch `unmapped_bytes` / RSS. Large objects (&gt;32 KiB) stay on a freelist through STW; excess trimmed after (`GCRY_LARGE_CACHE`).

## Process GC (HTTP)

ExecutionContext does not call `set_stackbottom` on swap — gcry refreshes from `Fiber.current` at collect. STW suspends other OS threads (Monitor included); without it, HTTP heaps corrupt under load.

Static roots: main executable RW (+ adjacent BSS); skip `.so` data and large RELRO. Fiber stacks scanned once per collect.

Parallel contexts: STW covers Crystal threads. **Supported opt-in:**
`EC_PARALLELISM>1`, **`GCRY_TLAB` off**, lazy sweep on (default) — thr
~**80%** `/json` @ ~5.5× RSS; `GCRY_PARALLEL_DORMANT=1` for RSS ~**75%**
@ ~4× — [PERF.md](PERF.md). Correctness gate: `make soft-soak-ec4`
(soft+hard **0/40**); CI runs `make soft-soak-ec4-smoke` (N=5).
`GCRY_TLAB=1` and `GCRY_PARALLEL_RELEASE` are **unsupported** (knobs
kept for research; process GC prints a stderr warning). Soft-soak refuses
both. `GCRY_PARALLEL_MARK` is research — [POLICY.md](POLICY.md).

## CI

Format, specs, `-Dgc_none` samples, env smoke, `bench/churn`, `soak-smoke`,
and EC4 soft-soak smoke on Linux x86_64 (Crystal 1.21 + latest). aarch64
native and `macos-latest` for STW/fork samples. `perf-smoke` gates Kemal
`/json` same-host thr % (`MIN_PCT=70`), post-GC RSS × (`MAX_RSS_X=1.25`),
and `pause_p50` (`MAX_PAUSE_P50_MS=2.5`) via `bench/perf_smoke.sh`.
See `.github/workflows/ci.yml`.
