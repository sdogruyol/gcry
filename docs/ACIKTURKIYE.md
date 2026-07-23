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

## Remaining gap (~2× vs Boehm)

Not explained by pause totals (~1% of wall). Likely:

- Mutator / allocator path cost vs Boehm
- Conservative retention → larger `heap_size` / worse locality
- Large-object cache RSS trade-off
- App/DB interaction under load (timeouts)

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

### Next experiments

1. ~~Same-load RSS / `heap_size` Boehm vs gcry.~~ **Done** (WSL baseline above).
2. Speed up mark (`find_object` / candidate reject) — pause already small; limited wrk win. **Deferred.**
3. ~~Raise size-class ceiling to **16 KiB**.~~ **Done** (~54%→~68% of Boehm on `/api/v1/`; `large_free` ↓).
4. Longer-term: write barriers + nursery / incremental for Boehm-like mutator behavior.
5. Follow-up: extend ceiling to **32 KiB** and/or mutator-path profiling (allocator freelist / clear).

## Non-goals (still)

- `GCRY_INCREMENTAL=1` / nursery as process default without barriers (unsound on JSON/Hash).
- `GCRY_RELEASE_CHUNKS=1` as default (Kemal wrk regression).
- Tagged PERF.md row until same-host kemal + acikturkiye stabilize.
