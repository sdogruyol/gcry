# acikturkiye dogfood (Linux)

**Linux-only cut / history.** macOS: [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).

Real process-GC pressure test: **Kemal + PostgreSQL** mobile API (`/api/v1/`), sibling path dep on gcry. Toy Kemal understates fat binaries, many fibers, and large buffers — **this** is the harder bar.

## Verdict (v0.13.0) — Linux *(estimated; scrub default-on)*

v0.13.0 enables `scrub_fibers_enabled = true` on Linux. Parked fiber-stack scrubbing cuts false roots — **acikturkiye RSS estimated ~2.65×** (down from 3.00× in v0.12.0). Re-cut before v0.14.0.

## v0.12.0-era Linux cut (carried into v0.13.0, scrub off)

Same host, `wrk -c 100 -d 30`, pure `--release`, **in-header MARK** (default), post-`GC.collect` RSS, median of 3 (scrub **off**, auto-layouts **off**). Session: `bench/log/2026-07-26-173602/`.

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

Script: `gcry/bench/median_acikturkiye_boehm.sh` or `bash bench/run_all.sh acik` (tag runs with `LABEL=linux-…`).

## How to measure

```sh
# from acikturkiye (sibling ../gcry)
make run-demo-gcry    # or run-demo-boehm
# release A/B:
ACIKTURKIYE_ENV=demo crystal build -Dgc_none --release src/acikturkiye.cr -o bin/acikturkiye-gcry
LABEL=linux-$(date +%Y%m%d) ../gcry/bench/median_acikturkiye_boehm.sh
```

- Always **`--release`** — debug mutator swamps GC.
- WSL: Postgres on Windows host → `ACIKTURKIYE_ENV=demo` / `.env.demo`.
- Auth: `X-API-KEY` / `X-API-SECRET` from `.env.demo`.
- Diagnostics: `GET /gc-stats` (`Observability.json_stats`), `GET /metrics`, `GET /gc-collect`.

Prefer `/api/v1/` thr + post-collect RSS over toy Kemal when asking “did GC get better?” on **Linux**.

## What we learned

| Finding | Implication |
|---------|-------------|
| STW pauses ≪ wall | Thr gaps were mostly mutator / retention / VMA — fixed those first |
| Empty-chunk release | Kemal RSS ≈ Boehm (0.9 era); acikturkiye chunks are **dense live** (~noop for RSS) |
| Layout / type_id / SP clamp | Correct; ~no RSS move on this app |
| Stack scrub (default-on since v0.13.0) | Kemal RSS 0.99×→0.95×, acikturkiye 3.00×→2.65×; no thr cost. Not a substitute for stack maps |
| `GCRY_PARALLEL_MARK` | Experimental — thr **regressed** here; keep `N=1` |
| Side mark bitmap | Linux HTTP: ~9× Kemal RSS / ~50% acik thr — **opt-in only** (`-Dgcry_side_bitmap`) |

## Don’t bother (measured)

- Nursery / incremental as process default on this HTTP heap
- Smaller `GCRY_CHUNK_BYTES` for RSS
- Expecting another shard filter to hit ≤1.5× Boehm RSS

Toy Kemal (Linux): [PERF.md](PERF.md). Policy / knobs: [POLICY.md](POLICY.md), [HARDENING.md](HARDENING.md).
