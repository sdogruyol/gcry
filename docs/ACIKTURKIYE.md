# acikturkiye dogfood (Linux)

**Linux-only cut / history.** macOS: [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).

Real process-GC pressure test: **Kemal + PostgreSQL** mobile API (`/api/v1/`), sibling path dep on gcry. Toy Kemal understates fat binaries, many fibers, and large buffers — **this** is the harder bar.

## Verdict (v0.17.0) — Linux *(measured)*

Same host, Crystal 1.21.0, WSL2 x86_64 (i3-12100F), `wrk -c 100 -d 30`, pure `--release`, **in-header MARK** (default), scrub **on**, auto-layouts **off**, EC1, median of 3. Session: `bench/log/linux/2026-08-02-064142/` (readiness hub `2026-08-02-ec1-readiness/`).

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~90%** | **~3.43×** |

| Trial | thr % Boehm | post-GC RSS × | gcry / Boehm req/s |
|------:|------------:|--------------:|-------------------:|
| 1 | 114.7% | 2.86× | 94 / 82 |
| 2 | 88.4% | 3.44× | 108 / 122 |
| 3 | 92.3% | 3.46× | 111 / 120 |
| **median** | **89.8%** | **3.43×** | — |

**Thr holds** vs v0.15 (~90%). **RSS worse** than v0.15 **~2.54×** — dense conservative-live; empty-chunk reclaim does not close it. Kemal Linux headline still [PERF.md](PERF.md) v0.16 (~87% `/json` @ ~0.80×). Script: `bash bench/run_all.sh acik`.

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

tip+EC ≈ system gcry — not a tip regressor. Gap vs i3 tip headline ~3.43× is
host/demo-data/tree, not the tip compiler. **Superseded on this host** by the
finalizer-registry fix below (~8.5× was dead `TCPSocket`/`Digest` retention).

### Post-finalizer gate (9950X, 2026-08-03)

Same host/method, tip+EC `base` (no stackmaps) vs Boehm after LibC finalizer
registry + Boehm resurrect (`3a0bffe`). Session:
`bench/log/linux/2026-08-03-acik-finalizer-gate-med3/`.

| | thr % Boehm | post-GC RSS × |
|--|------------:|--------------:|
| tip+EC gcry (`base`) | **~91.5%** | **~1.81×** |

Was ~8.5× on the same host pre-fix. RSS lever was finalizer correctness, not
exclusivef / layouts / pool caps.

Follow-up (`…/acik-release0-med3/`): `GCRY_LARGE_CACHE=0` +
`GCRY_EMPTY_CHUNK_RETAIN=0` → RSS **~1.00×** Boehm, thr **~94%**. Those are
now the **Linux process defaults** (opt up via the same env vars).

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
| Stack scrub (default-on since v0.13.0) | Kemal RSS ~**0.80×** (v0.16); acik tip was ~3.43×/~~8.5×~~ until finalizer registry fix → **~1.81×** (9950X). Scrub ≠ substitute for correct finalizers / stack maps |
| Finalizer Array tables as GC roots | Kept every finalizable alive — acik ~80–100 MiB IO atomics; LibC registry + resurrect closed most of the Boehm gap |
| `GCRY_PARALLEL_MARK` | Experimental — thr **regressed** here; keep `N=1` |
| Side mark bitmap | Linux HTTP: ~9× Kemal RSS / ~50% acik thr — **opt-in only** (`-Dgcry_side_bitmap`) |

## Don’t bother (measured)

- Nursery / incremental as process default on this HTTP heap
- Smaller `GCRY_CHUNK_BYTES` for RSS
- Linux **HOLED** `GCRY_PAGE_DONTNEED` as process default — thr and RSS both worse (HOLED freelist rebuild blows sweep; free-only pages abandoned → chunk churn). Stay opt-in.
- Process-default curated `HTTP::Headers` Hash layout — Kemal `/json` thr soft vs builtins-only; register app-side if needed (`bench/nursery_headers.cr` / `GCRY_AUTO_LAYOUTS`)
- Collect-time mutator `clear_stack` / Linux 1 MiB large-cache floor as defaults — no durable win over fiber scrub + 4 MiB cache
- Expecting stack-maps alone to hit ≤1.5× Boehm RSS (finalizer fix + Linux retain=0 defaults closed the measured gap on this host)

Toy Kemal (Linux): [PERF.md](PERF.md). Policy / knobs: [POLICY.md](POLICY.md), [HARDENING.md](HARDENING.md).
