# acikturkiye / HTTP process-GC findings (2026-07-23)

Field notes from dogfooding gcry as process GC on **acikturkiye** (Kemal + PostgreSQL, `/api/v1`). Continue from branch `fix-stw`.

## How to measure

- Prefer **`--release`** for wrk A/B (debug/`--error-trace` makes mutator look ~5–10× worse than GC).
- WSL: Postgres lives on the **Windows host**. Use `ACIKTURKIYE_ENV=demo` (loads `.env.demo` → `DATABASE_URL` with the host IP).
- Build example: `export ACIKTURKIYE_ENV=demo && crystal build -Dgc_none --release src/acikturkiye.cr -o acikturkiye-gcry`
- Expose `GET /gc-stats` (see [bench/kemal/src/server.cr](../bench/kemal/src/server.cr)) or dump `Gcry.pause_stats` + `Heap#last_phase_*_ns` + `finalizer_entry_count` / `finalizer_link_count`.
- Toy Kemal `make bench-kemal-wrk` understates fat-binary / many-fiber / large-buffer costs.
- Mobile API needs `X-API-KEY` / `X-API-SECRET` from `.env.demo`.

## Release A/B (same host, wrk `-c 100 -d 30` `/api/v1`)

Earlier machine (field notes):

| GC | req/s | notes |
|----|------:|-------|
| Boehm `--release` | **~222** | baseline |
| gcry `-Dgc_none --release` | **~113** | **~51% of Boehm**; ~80 timeouts |
| gcry debug (earlier) | ~10–23 | not comparable |

gcry release `/gc-stats` snapshot after wrk (earlier host):

- `pause_p50_ns` ≈ **12ms**, `pause_total_ns` ≈ **0.2s / 30s** → STW is no longer the throughput bottleneck.
- `phase_mark_ns` ≈ 8ms (largest phase); `phase_sweep_ns` ≈ 1.7ms.
- `heap_size` ≈ **445 MiB**, `large_free_bytes` ≈ 18 MiB, `unmapped_bytes` = 0.
- `finalizer_entries` ≈ 7.5k, `weak_links` ≈ 9.

### Same-host baseline (WSL, 2026-07-23, before 16 KiB size-class)

Load: `wrk -c 100 -d 30`, fresh process, `--release`. acikturkiye: `ACIKTURKIYE_ENV=demo`, path `/api/v1/`.

**Toy Kemal** (`bench/kemal`):

| GC | path | req/s | % Boehm | RSS | notes |
|----|------|------:|--------:|----:|-------|
| Boehm | `/` | 105199 | 100% | 17 MiB | |
| gcry | `/` | 84535 | **80%** | 98 MiB | heap ≈ 101 MiB; `large_free` 0 |
| Boehm | `/json` | 40561 | 100% | 17 MiB | |
| gcry | `/json` | 36461 | **90%** | 92 MiB | heap ≈ 95 MiB; pause p50 ≈ 15ms |

**acikturkiye** `/api/v1/`:

| GC | req/s | % Boehm | RSS | timeouts | notes |
|----|------:|--------:|----:|---------:|-------|
| Boehm | 153 | 100% | 33 MiB | 529 | |
| gcry | 83 | **54%** | 166 MiB | 486 | heap ≈ 278 MiB; `large_free` ≈ 16 MiB; pause p50 ≈ 14ms; mark ≈ 14ms |

RSS / `heap_size` gap confirms retention + large-object VMAs; pause totals still small vs wall.

## Bugs fixed on this branch (why pauses were multi-second)

1. **STW / Monitor roots** — Crystal 1.21 SYSMON thread; wrong stack bottom; register spill; RWLock; allocate-black.
2. **BSS / static roots** — class vars past file-backed `.data`; then adjacency-only BSS (blanket anon&lt;1MiB cached large-object VMAs → SIGSEGV after munmap).
3. **Safe stack scan** — PROT_NONE guard; later cheap leading-probe + bulk / clamp + `safe: false`.
4. **Duplicate fiber stack scan** — `push_gc_roots` + `scan_all_fiber_roots` (removed duplicate).
5. **Static root volume** — skip `.so` data; skip large RELRO.
6. **Sweep munmap storm** — each &gt;8KiB object is its own VMA; munmap during STW dominated `phase_sweep` (~8s). **Fix:** large-object freelist + trim outside STW.
7. **Finalizer/WeakRef** — per-reclaim registry scan was O(reclaimed × entries); now one post-mark index pass. **Do not** pass a Crystal `Proc` into collect (malloc mid-STW → crash); use index APIs only.

## Remaining gap (historical; throughput now ≈ Boehm)

Earlier ~2× req/s gap was **not** explained by pause totals (~1% of wall). Drivers that remain for RSS / locality (throughput already caught up after `notice_reclaim` + size-class work):

- Conservative retention → larger `heap_size` / worse locality vs Boehm
- Large-object cache RSS trade-off
- App/DB interaction under load (timeouts on both GCs)

### After size-class ceiling 16 KiB (WSL, same day)

Medium payloads (8–16 KiB) now use size-class chunks instead of one mmap/VMA per object.

**Toy Kemal** (host-noisy; compare same-day Boehm above):

| GC | path | req/s | % Boehm | RSS | notes |
|----|------|------:|--------:|----:|-------|
| gcry | `/` | 107533 | ~102% | 98 MiB | idle path; treat as noise vs 80% baseline |
| gcry | `/json` | 40802 | **~101%** | 93 MiB | was ~90%; `large_free` still 0 |

**acikturkiye** `/api/v1/` (prefer this for “did GC get better?”):

| GC | req/s | % Boehm | RSS | timeouts | notes |
|----|------:|--------:|----:|---------:|-------|
| gcry | 104 | **~68%** | 173 MiB | 380 | was ~54% / 83 req/s; `large_free` **16→3 MiB**; heap ≈ 289 MiB; pause p50 ≈ 22ms |

Takeaway: ceiling bump cut large-object cache / VMA pressure and lifted real-app throughput; still ~1.5× behind Boehm. RSS did not regress badly.

### After size-class ceiling 32 KiB (WSL, same day)

Classes `20480…32768` added; `LARGE_THRESHOLD = 32768`.

**Toy Kemal:**

| GC | path | req/s | % Boehm | RSS | notes |
|----|------|------:|--------:|----:|-------|
| gcry | `/` | 103512 | ~98% | 98 MiB | noise |
| gcry | `/json` | 37813 | **~93%** | 92 MiB | slightly below 16 KiB run |

**acikturkiye** `/api/v1/`:

| GC | req/s | % Boehm | RSS | timeouts | notes |
|----|------:|--------:|----:|---------:|-------|
| gcry | 136 | **~89%** | 156 MiB | 557 | was ~68% / 104 req/s at 16 KiB; heap ≈ 258 MiB; `large_free` ≈ 21 MiB; pause p50 ≈ 20ms |

Takeaway: 32 KiB ceiling is a clear win on the real app (~68%→~89% of Boehm). Remaining gap is mostly mutator/allocator + retention, not VMA storm.

### Mutator path: skip clear on zeroed freelist (WSL, same day)

`malloc` used to `memset` every pointerful alloc. MAP_ANONYMOUS chunks and fresh large mmaps are already zero — skip clear until `free` / sweep reclaim dirties that size-class freelist (or a large-cache hit). Also `SizeClasses.fit` (one pass + coarse start) replaces round+index.

**Toy Kemal:**

| GC | path | req/s | % Boehm | notes |
|----|------|------:|--------:|-------|
| gcry | `/` | 100433 | ~95% | noise vs prior |
| gcry | `/json` | 38409 | **~95%** | flat vs 32 KiB run |

**acikturkiye** `/api/v1/`:

| GC | req/s | % Boehm | RSS | timeouts | notes |
|----|------:|--------:|----:|---------:|-------|
| gcry | 135 | **~88%** | 152 MiB | 623 | flat vs 32 KiB (~136 / ~89%); heap ≈ 233 MiB; `large_free` ≈ 17 MiB |

Takeaway: correct optimization, **no steady-state wrk win** — after the first major, reclaim dirties freelists so almost every `malloc` still clears. Remaining ~10–12% is elsewhere (allocator bookkeeping, locality/retention, DB/timeouts).

### perf: `notice_reclaim` on every free/realloc (WSL, same day)

`perf record -F 99 --call-graph dwarf` under wrk on `/api/v1/` (release+debug binary):

- App JSON (`Char#===` / `to_json`) dominates overall samples (expected).
- GC hotspot: `Finalizers::Registry#notice_reclaim` + `Array(Entry)#[]` ≈ **15%+** self time, stacked under `realloc` → `free`.
- Cause: every explicit free scanned **all** ~5k finalizer entries (Crystal `File`/IO finalizers accumulate). Array growth realloc paid O(entries) each time.
- Fix: `BlockHeader` flags `FINALIZER` / `DISAPPEARING`; `notice_reclaim` returns immediately unless the object has the matching flag.

**acikturkiye** `/api/v1/` after fix (same-session Boehm re-run):

| GC | req/s | % Boehm | RSS | timeouts | notes |
|----|------:|--------:|----:|---------:|-------|
| Boehm | 160 | 100% | 35 MiB | 577 | same session |
| gcry | 159 | **~100%** | 166 MiB | 425 | was ~135 / ~88%; `notice_reclaim` gone from perf top; `ensure_chunk_index` (~3%) next |

Toy Kemal `/json`: ~39623 req/s (flat/noise vs prior).

### Incremental chunk index (WSL, same day)

`map_chunk` / `unlink_chunk` / empty-chunk drop now maintain the address-sorted `@chunk_index` with O(log C) locate + O(C) shift. Full `ensure_chunk_index` rebuild only if `@chunk_index_dirty` (fallback). Also drop redundant `is_heap_ptr` inside `owns_user_pointer?` (was double binary search on every `free`/`realloc`).

**perf:** `ensure_chunk_index` gone from top; `chunk_containing` ≈ 1.3% (steady binary search).

**acikturkiye** `/api/v1/`: **154 req/s** (flat vs ~159; still ≈ Boehm). Kemal `/json`: ~40629 req/s.

### Re-record after STW / static-root / stack fixes (WSL, 2026-07-23 evening)

Same load as above (`wrk -c 100 -d 30`, `ACIKTURKIYE_ENV=demo`, fresh `--release` binaries against current `../gcry`). Includes prior size-class / `notice_reclaim` / chunk-index work plus CI SIGBUS fixes (`[anon:…]` static-root skip, hole-aware safe stack scans).

| GC | req/s | % Boehm | RSS | timeouts | notes |
|----|------:|--------:|----:|---------:|-------|
| Boehm | 153 | 100% | 47 MiB | 476 | same session |
| gcry | 154 | **~101%** | 172 MiB | 357 | heap ≈ 291 MiB; `large_free` ≈ 15 MiB; pause p50 ≈ 16ms; mark ≈ 12ms; 18 majors; pause_total ≈ 0.33s / 30s |

Takeaway: real-app throughput remains **≈ Boehm** after the stack/static-root hardening. RSS / `heap_size` still ~3–4× Boehm (conservative retention + large freelist); STW is not the limiter. Toy Kemal re-record the same evening: `/` ~105%, `/json` ~100% of Boehm — see [PERF.md](PERF.md).

### After large exact-fit + RSS breakdown (WSL, same day)

Large freelist reuse is **exact mapped-size** only; `/gc-stats` adds `large_mapped_bytes` / `small_mapped_*`.

**Toy Kemal** (gate; absolute wrk host-noisy vs PERF.md):

| GC | path | req/s | % Boehm | RSS | notes |
|----|------|------:|--------:|----:|-------|
| Boehm | `/json` | 35714 | 100% | 17 MiB | same session |
| gcry | `/json` | 37592 | **~105%** | 92 MiB | `large_mapped` ≈ 0.3 MiB; `small_mapped` ≈ 95 MiB |
| Boehm | `/` | 89781 | 100% | 16 MiB | |
| gcry | `/` | 101565 | **~113%** | 98 MiB | no `/json` regression |

**acikturkiye** `/api/v1/` (paired A/B, then instrumented re-run for breakdown):

| GC | req/s | % Boehm | RSS | timeouts | notes |
|----|------:|--------:|----:|---------:|-------|
| Boehm | 139 | 100% | 44 MiB | 566 | same session |
| gcry | 146 | **~105%** | 183 MiB | 515 | throughput OK |

Instrumented gcry re-run after wrk: heap ≈ **254 MiB**; **`small_mapped` ≈ 235 MiB**, `large_mapped` ≈ 20 MiB (`large_free` ≈ 7 MiB); pause p50 ≈ 20ms; 15 majors. Takeaway: remaining RSS gap is **size-class / conservative retention**, not the large freelist (~7–15 MiB free). Exact-fit removes fat-VMA live waste; it does not close the 3–4× RSS gap alone.

### After deferred empty-chunk release + occupancy (WSL, same day)

Empty-chunk `munmap` runs **outside STW** (queued in sweep). `/gc-stats` adds `fully_free_chunk_bytes` / `size_class_chunk_count` / `released_chunk_bytes`.

**Toy Kemal** `/json` (paired A/B):

| GC | req/s | % Boehm | RSS | notes |
|----|------:|--------:|----:|-------|
| Boehm | 40938 | 100% | 16 MiB | same session |
| gcry | 41069 | **~100%** | 92 MiB | `fully_free` ≈ **76 MiB** retained; 380 size-class chunks |
| gcry + `GCRY_RELEASE_CHUNKS=1` | 37838 | **~92%** | (steady-state varies) | last major released ≈76 MiB; stays opt-in |

**acikturkiye** `/api/v1/`:

| GC | req/s | % Boehm | RSS | timeouts | notes |
|----|------:|--------:|----:|---------:|-------|
| Boehm | 159 | 100% | 42 MiB | 434 | same session |
| gcry | 164 | **~103%** | 172 MiB | 508 | `fully_free` ≈ **24 MiB**; `small_mapped` ≈ 250 MiB |
| gcry + chunks | 155 | **~98%** | 166 MiB | 331 | released ≈26 MiB; RSS almost flat; pause p50 rose (freelist rebuild) |

Takeaway: on the real app, empty-chunk release frees only ~**25 MiB** of ~250 MiB `small_mapped` — **not** the RSS lever. Remaining mass is conservative-live / sparse chunks. Kemal shows large fully-free retention (~76 MiB) so release helps toy RSS more. Keep `GCRY_RELEASE_CHUNKS` opt-in.

### Next experiments

1. ~~Same-load RSS / `heap_size` Boehm vs gcry.~~ **Done.**
2. Speed up mark (`find_object` / candidate reject) — pause already small; limited wrk win. **Deferred.**
3. ~~Raise size-class ceiling to **16 KiB**.~~ **Done.**
4. Longer-term: write barriers + nursery / incremental for Boehm-like mutator behavior (RSS / locality).
5. ~~Extend ceiling to **32 KiB**.~~ **Done.**
6. ~~Skip clear on zeroed freelist / `fit`.~~ **Done** (neutral on steady-state).
7. ~~perf → fix `notice_reclaim` O(n) on free.~~ **Done** (~88%→~**100%** of Boehm on `/api/v1/`).
8. ~~`ensure_chunk_index` dirty rebuilds.~~ **Done** (incremental index; symbol gone from perf).
9. ~~Re-record Kemal `docs/PERF.md` + acikturkiye.~~ **Done** (both ≈ Boehm; cut as **v0.6.0**).
10. ~~Large freelist: exact mapped-size reuse (no fat VMA for smaller need).~~ **Done** (Phase 10 start).
11. ~~Empty-chunk munmap outside STW + occupancy counters; measure RELEASE_CHUNKS.~~ **Done** — acikturkiye RSS unchanged; next is sparse-chunk / barriers.
12. Sparse size-class chunks (partially live) or write barriers — empty-chunk release is insufficient for acikturkiye RSS.

## Non-goals (still)

- `GCRY_INCREMENTAL=1` / nursery as process default without barriers (unsound on JSON/Hash).
- `GCRY_RELEASE_CHUNKS=1` as default (Kemal still ~92%; acikturkiye RSS win negligible).
- Chasing Boehm RSS parity without write barriers / better large-object policy.
