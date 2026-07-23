# acikturkiye / HTTP process-GC findings (2026-07-23)

Field notes from dogfooding gcry as process GC on **acikturkiye** (Kemal + PostgreSQL, `/api/v1`). Continue from branch `fix-stw`.

## How to measure

- Prefer **`--release`** for wrk A/B (debug/`--error-trace` makes mutator look ~5–10× worse than GC).
- Expose `GET /gc-stats` (see [bench/kemal/src/server.cr](../bench/kemal/src/server.cr)) or dump `Gcry.pause_stats` + `Heap#last_phase_*_ns` + `finalizer_entry_count` / `finalizer_link_count`.
- Toy Kemal `make bench-kemal-wrk` understates fat-binary / many-fiber / large-buffer costs.

## Release A/B (same host, wrk `-c 100 -d 30` `/api/v1`)

| GC | req/s | notes |
|----|------:|-------|
| Boehm `--release` | **~222** | baseline |
| gcry `-Dgc_none --release` | **~113** | **~51% of Boehm**; ~80 timeouts |
| gcry debug (earlier) | ~10–23 | not comparable |

gcry release `/gc-stats` snapshot after wrk:

- `pause_p50_ns` ≈ **12ms**, `pause_total_ns` ≈ **0.2s / 30s** → STW is no longer the throughput bottleneck.
- `phase_mark_ns` ≈ 8ms (largest phase); `phase_sweep_ns` ≈ 1.7ms.
- `heap_size` ≈ **445 MiB**, `large_free_bytes` ≈ 18 MiB, `unmapped_bytes` = 0.
- `finalizer_entries` ≈ 7.5k, `weak_links` ≈ 9.

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

### Next experiments (other machine)

1. Same-load RSS / `heap_size` Boehm vs gcry.
2. Speed up mark (`find_object` / candidate reject) — pause already small; limited wrk win.
3. Tune large-cache trim / raise size-class ceiling for medium buffers.
4. Longer-term: write barriers + nursery / incremental for Boehm-like mutator behavior.

## Non-goals (still)

- `GCRY_INCREMENTAL=1` / nursery as process default without barriers (unsound on JSON/Hash).
- `GCRY_RELEASE_CHUNKS=1` as default (Kemal wrk regression).
- Tagged PERF.md row until same-host kemal + acikturkiye stabilize.
