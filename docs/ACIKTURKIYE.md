# acikturkiye dogfood

Real process-GC pressure test: **Kemal + PostgreSQL** mobile API (`/api/v1/`), sibling path dep on gcry. Toy Kemal understates fat binaries, many fibers, and large buffers — **this** is the harder bar.

## Verdict (v0.9.0)

Same host, `wrk -c 100 -d 30`, `--release`, post-`GC.collect` RSS, median of 3 (scrub **off**):

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~93%** | **~2.84×** |
| v0.8.0 (same method) | ~95% | ~3.20× |

Throughput is in the fight. RSS is not — dense conservative-live, not empty-chunk waste. Shard levers (layout, type_id gate, SP clamp, empty release) were measured; they don’t close ≤1.5×. **Next real win needs compiler stack maps.**

| Trial | thr % Boehm | post-GC RSS × | gcry / Boehm req/s |
|------:|------------:|--------------:|-------------------:|
| 1 | 96.1% | 2.60× | 127 / 132 |
| 2 | 93.3% | 2.84× | 124 / 133 |
| 3 | 90.9% | 3.25× | 128 / 141 |
| **median** | **93.3%** | **2.84×** | — |

Script: `gcry/bench/median_acikturkiye_boehm.sh`.

## How to measure

```sh
# from acikturkiye (sibling ../gcry)
make run-demo-gcry    # or run-demo-boehm
# release A/B:
ACIKTURKIYE_ENV=demo crystal build -Dgc_none --release src/acikturkiye.cr -o bin/acikturkiye-gcry
```

- Always **`--release`** — debug mutator swamps GC.
- WSL: Postgres on Windows host → `ACIKTURKIYE_ENV=demo` / `.env.demo`.
- Auth: `X-API-KEY` / `X-API-SECRET` from `.env.demo`.
- Diagnostics: `GET /gc-stats` (`Observability.json_stats`), `GET /metrics`, `GET /gc-collect`.

Prefer `/api/v1/` thr + post-collect RSS over toy Kemal when asking “did GC get better?”

## What we learned

| Finding | Implication |
|---------|-------------|
| STW pauses ≪ wall | Thr gaps were mostly mutator / retention / VMA — fixed those first |
| Empty-chunk release | Kemal RSS ≈ Boehm; acikturkiye chunks are **dense live** (~noop for RSS) |
| Layout / type_id / SP clamp | Correct; ~no RSS move on this app |
| Stack scrub (opt-in) | Can cut live some; thr cost; not a substitute for stack maps |
| `GCRY_PARALLEL_MARK` | Experimental — thr **regressed** here; keep `N=1` |

## Don’t bother (measured)

- Nursery / incremental as process default on this HTTP heap
- Smaller `GCRY_CHUNK_BYTES` for RSS
- Expecting another shard filter to hit ≤1.5× Boehm RSS

Toy Kemal numbers: [PERF.md](PERF.md). Policy / knobs: [POLICY.md](POLICY.md), [HARDENING.md](HARDENING.md).
