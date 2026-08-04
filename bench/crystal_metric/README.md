# crystal-metric (gcry A/B)

Vendored [kostya/crystal-metric](https://github.com/kostya/crystal-metric) for **same-host Boehm vs gcry** wall-time A/B.

This is a **secondary** GC suite — not the product headline. Ship bar stays Kemal `/json` + acikturkiye ([PERF.md](../../docs/PERF.md)).

## Process-fresh (default)

Each bench runs in a **new OS process**. Shared-process suite order used to inflate
`JsonParsePure` (~20× after `JsonGenerate`) and muddy `Primes`; fresh runs are the
numbers to cite.

## Filters

| `FILTER=` | Benches |
|-----------|---------|
| `gc` (default) | core + stress |
| `core` | Binarytrees, Brainfuck*, Knuckeotide, RegexDna, Revcomp, Threadring, Matmul, JsonGenerate, JsonParseSerializable, JsonParsePull |
| `stress` | Primes, JsonParsePure (`JSON::Any` / sieve storms) |
| `all` | Full upstream language suite (compute-bound noise included) |
| `A,B,C` | Explicit class names |

## Run

From repo root:

```sh
# Default GC subset, process-fresh, median of 3 → bench/log/<platform>/<stamp>/
bash bench/run_crystal_metric_ab.sh

# Core only / stress only / smoke
FILTER=core TRIALS=1 bash bench/run_crystal_metric_ab.sh
FILTER=stress TRIALS=1 bash bench/run_crystal_metric_ab.sh
TRIALS=1 FILTER=Binarytrees,Threadring,JsonParsePure bash bench/run_crystal_metric_ab.sh

# Full upstream language suite (not a GC gate)
FILTER=all TRIALS=1 bash bench/run_crystal_metric_ab.sh
```

Or: `make bench-crystal-metric`

## Metrics

- Primary: wall seconds per bench, **speed % of Boehm** = Boehm_s / gcry_s × 100 (>100 ⇒ gcry faster)
- Per-bench peak RSS × from GNU `time -v` when available
- Absolute “award” / Crystal release score: ignore for GC claims
- Checksum `err` on Crystal ≥1.21 is OK for timing A/B

See [UPSTREAM.md](UPSTREAM.md).
