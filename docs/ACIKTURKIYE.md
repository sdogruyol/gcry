# acikturkiye dogfood (Linux)

**Linux-only cut / history.** macOS: [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).

Real process-GC pressure test: **Kemal + PostgreSQL** mobile API (`/api/v1/`), sibling path dep on gcry. Toy Kemal understates fat binaries, many fibers, and large buffers — **this** is the harder bar.

## Verdict — tip+EC Linux *(current)*

After LibC finalizer registry (`3a0bffe`) + Linux **retain=0** process defaults
(`9228bb9`). `wrk -c100 -d30`, dual `/gc-collect`, median of 3.

| Host | Cut | Session | thr % | RSS × |
|------|-----|---------|------:|------:|
| **i3-12100F** (headline) | tip defaults | `…/2026-08-04-acik-i3-retain0-med3/` | **~96%** | **~1.63×** |
| 9950X | release0 env → defaults | `…/acik-release0-med3/` | **~94%** | **~1.00×** |
| 9950X | defaults-as-code verify | `…/acik-defaults-verify-med3/` | **~90%** | **~1.40×** |
| 9950X | tip control (office) | `…/2026-08-04-acik-mostly-empty-control-med3/` | **~100%** | **~1.56×** |
| 9950X | v0.18 post-tag confirm | `…/2026-08-05-091820/` | **~102%** | **~1.76×** |

Cite tip band **~90–96% thr @ ~1–1.6× RSS** (9950X soft high ~**1.8×**; was v0.17
i3 **~3.43×** / 9950X pre-fix **~8.5×**). Residual anatomy on i3: mapped
freelist / sparse chunks (`…/2026-08-04-acik-i3-residual/`) — not live-graph.
9950X verify had one unreproduced Monitor SEGV — `…/acik-segv-bisect/`.
Stack-map notes: [STACK_MAPS.md](STACK_MAPS.md).

### Opt-in: `GCRY_TIGHT_GROW=1` *(closes freelist residual)*

Sticky newest-chunk freelist + sparse GC-before-grow (no HOLED / DONTNEED).
**Not** a process default — Kemal `/json` thr soft (~78%). Hub:
`bench/log/linux/2026-08-04-acik-tight-grow/FINDINGS.md`.

| Host | Session | thr % | RSS × |
|------|---------|------:|------:|
| 9950X tip + `TIGHT_GROW` | `…/2026-08-04-acik-tight-grow-v2-med3/` | **~103%** | **~0.92×** |
| 9950X tip control (same day) | `…/acik-mostly-empty-control-med3/` | **~100%** | **~1.56×** |

Escape: `GCRY_DISABLE_TIGHT_GROW=1`, `GCRY_DISABLE_TIGHT_GROW_GC=1`. Prefer this
for fat HTTP on Linux tip when RSS under Boehm matters; keep default path for
Kemal-class thr.

## v0.17.0 tagged cut — Linux i3 *(superseded on tip)*

Tagged-release cut on Crystal 1.21.0, WSL2 x86_64 (i3-12100F), `wrk -c 100 -d 30`, pure `--release`, scrub **on**, EC1, median of 3. Session: `bench/log/linux/2026-08-02-064142/` (readiness hub `2026-08-02-ec1-readiness/`). **Do not cite as tip RSS** — finalizer + retain=0 closed that gap on 9950X.

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~90%** | **~3.43×** |

| Trial | thr % Boehm | post-GC RSS × | gcry / Boehm req/s |
|------:|------------:|--------------:|-------------------:|
| 1 | 114.7% | 2.86× | 94 / 82 |
| 2 | 88.4% | 3.44× | 108 / 122 |
| 3 | 92.3% | 3.46× | 111 / 120 |
| **median** | **89.8%** | **3.43×** | — |

**Thr holds** vs v0.15 (~90%). On that tree/host, RSS was worse than v0.15 **~2.54×**. Script: `bash bench/run_all.sh acik`.

### v0.15.0 Linux cut (superseded RSS; thr same band)

Session: `bench/log/linux/2026-07-29-112202/` (`9decd01`). thr **~90%** @ RSS **~2.54×**.

## v0.12.0-era Linux cut (carried into v0.13.0, scrub off)

Same host, `wrk -c 100 -d 30`, pure `--release`, **in-header MARK** (default), post-`GC.collect` RSS, median of 3 (scrub **off**, auto-layouts **off**). Session: `bench/log/linux/2026-07-26-173602/`.

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~93%** | **~3.0×** |
| side-bitmap A/B (`2026-07-26-171942`) | ~50% | ~5.6× |
| v0.9.0 (same method) | ~93% | ~2.84× |

Back near the 0.9.0 Linux cut once side bitmap is no longer default. Prefer this over toy Kemal when asking “did GC get better?” on **Linux**.

| Trial | thr % Boehm | post-GC RSS × | gcry / Boehm req/s |
|------:|------------:|--------------:|-------------------:|
| 1 | 91.0% | 3.00× | 112 / 123 |
| 2 | 94.9% | 2.60× | 114 / 120 |
| 3 | 89.5% | 3.41× | 116 / 130 |
| **median** | **92.8%** | **3.00×** | — |

Script: `bash bench/run_all.sh acik`.

## How to measure

```sh
# from gcry (sibling ../acikturkiye with .env.demo)
FORCE_REBUILD=1 TRIALS=3 WRK_DURATION=30 WRK_CONNECTIONS=100 GC=both \
  bash bench/run_all.sh acik
```

- Always **`--release`** — debug mutator swamps GC.
- WSL: Postgres on Windows host → `ACIKTURKIYE_ENV=demo` / `.env.demo`.
- Auth: `X-API-KEY` / `X-API-SECRET` from `.env.demo`.
- Diagnostics: `GET /gc-stats` (`Observability.json_stats`), `GET /metrics`, `GET /gc-collect`.

Prefer `/api/v1/` thr + post-collect RSS over toy Kemal when asking “did GC get better?” on **Linux**.

Harness note: `bench/acik_stackmap_ab.sh` defaults `REQUIRE_2XX=1` — a missing
demo schema (`submissions`) yields 500s and fake RSS (was ~15×). Migrate + seed
before cuts (`./bin/micrate up`, locations dump, `demo_organization_seeder.cr`).

### tip+EC vs system (9950X, 2026-08-03)

Same host, med-of-3 `wrk -c100 -d30`, non2xx=0. Session:
`bench/log/linux/2026-08-03-acik-tip-baseline2-med3/`.

| | thr % Boehm | post-GC RSS × |
|--|------------:|--------------:|
| sys (1.21.0 + gcry) | ~103% | **~8.51×** |
| tipec (tip + EC + gcry) | ~102% | **~8.46×** |

tip+EC ≈ system gcry — not a tip regressor. The ~8.5× here was dead
`TCPSocket`/`Digest` retention (finalizer registry), not a tip-compiler
regressor vs the v0.17 i3 ~3.43× cut. **Superseded** by the tip Verdict above.

### Post-finalizer → retain=0 path (9950X, 2026-08-03)

Detail behind the tip Verdict above. After LibC finalizer registry + Boehm
resurrect (`3a0bffe`), tip+EC `base` vs Boehm was thr **~91.5%** @ RSS
**~1.81×** (`…/acik-finalizer-gate-med3/`) — was ~8.5× pre-fix. Residual was
allocator caches, not live-graph: `GCRY_LARGE_CACHE=0` +
`GCRY_EMPTY_CHUNK_RETAIN=0` → **~94% @ 1.00×** (`…/acik-release0-med3/`), now
Linux process defaults. Lever was finalizer correctness + retain policy, not
exclusivef / layouts / pool caps.

### Non-stack knobs (9950X, 2026-08-03)

Exclusive bin (`GCRY_PRECISE_STACK=2`), med-of-3 `wrk -c100 -d30`. Session:
`bench/log/linux/2026-08-03-acik-nonstack-med3/`. Script: `bench/acik_nonstack_ab.sh`.

Post-collect `size_class_live_bytes` ~380 MiB (dense chunks; dual-collect
flat). `GCRY_AUTO_LAYOUTS`, `SCAN_CAPS`, large-cache/`EMPTY_CHUNK_RETAIN` floor,
and `DISABLE_LAYOUT` — **no RSS win**. Gap is marked-live / conservative edges,
not reclaim.

## What we learned

| Finding | Implication |
|---------|-------------|
| STW pauses ≪ wall | Thr gaps were mostly mutator / retention / VMA — fixed those first |
| Empty-chunk release | Kemal RSS ≈ Boehm (0.9 era); acikturkiye chunks are **dense live** (~noop for RSS) |
| Layout / type_id / SP clamp | Correct; ~no RSS move on this app |
| Stack scrub (default-on since v0.13.0) | Kemal RSS ~**0.80×** (v0.16). Acik: scrub ≠ substitute for correct finalizers; tip closed with finalizer + retain=0 → **~1×** (9950X) |
| Finalizer Array tables as GC roots | Kept every finalizable alive — acik ~80–100 MiB IO atomics; LibC registry + resurrect → ~1.81×, then retain=0 → ~1× |
| Linux large/empty retain defaults → 0 | Mapped-free caches were the residual after finalizer fix; escape via `GCRY_LARGE_CACHE` / `GCRY_EMPTY_CHUNK_RETAIN` |
| Post-retain=0 ~1.4–1.6× | Idle live_sc falls; heap/RSS stay — **mapped freelist** / sparse chunks (`…/acik-i3-residual/`) |
| `GCRY_TIGHT_GROW=1` | Closes freelist floor on acik (**~103%** @ **~0.92×**); Kemal thr soft — **opt-in only** |
| `GCRY_PARALLEL_MARK` | Experimental — thr **regressed** here; keep `N=1` |
| Side mark bitmap | Linux HTTP: ~9× Kemal RSS / ~50% acik thr — **opt-in only** (`-Dgcry_side_bitmap`) |

## Don’t bother (measured)

- Nursery / incremental as process default on this HTTP heap
- Smaller `GCRY_CHUNK_BYTES` for RSS
- Linux **HOLED** `GCRY_PAGE_DONTNEED` as process default — thr and RSS both worse (HOLED freelist rebuild blows sweep; free-only pages abandoned → chunk churn). Stay opt-in.
- **`GCRY_MOSTLY_EMPTY`** as process default — MADV_FREE thr-safe but **no RSS win**; `MODE=dontneed` COLLECT_HANG / thr cliff (`…/2026-08-04-acik-mostly-empty/`). Research opt-in only.
- Process-default curated `HTTP::Headers` Hash layout — Kemal `/json` thr soft vs builtins-only; register app-side if needed (`bench/nursery_headers.cr` / `GCRY_AUTO_LAYOUTS`)
- Collect-time mutator `clear_stack` / Linux 1 MiB large-cache floor as defaults — no durable win over fiber scrub + 4 MiB cache
- Expecting page-advice on sparse chunks to close the ~1.4–1.6× freelist floor (HOLED + mostly-empty exhausted) — use **`GCRY_TIGHT_GROW=1`** instead; Darwin ~18× still wants stack maps
- Shipping `GCRY_TIGHT_GROW` as process default — acik win, Kemal `/json` ~78% soft gate MISS

Toy Kemal (Linux): [PERF.md](PERF.md). Policy / knobs: [POLICY.md](POLICY.md), [HARDENING.md](HARDENING.md).
