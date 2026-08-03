# crystal-metric (gcry A/B)

Vendored [kostya/crystal-metric](https://github.com/kostya/crystal-metric) for **same-host Boehm vs gcry** wall-time A/B.

This is a **secondary** GC suite — not the product headline. Ship bar stays Kemal `/json` + acikturkiye ([PERF.md](../../docs/PERF.md)).

## Default filter (GC-sensitive)

`Binarytrees`, JSON gen/parse, string/Hash (Knuckeotide, RegexDna, Revcomp), Brainfuck*, Threadring, Matmul, Primes.

Compute-bound benches (Mandelbrot, Nbody, …) are **noise for GC** — use `FILTER=all` only for language scores.

## Run

From repo root:

```sh
# GC subset (default), median of 3 trials → bench/log/<platform>/<stamp>/
bash bench/run_crystal_metric_ab.sh

# Smoke (3 benches, 1 trial)
TRIALS=1 FILTER=Binarytrees,JsonParsePure,Threadring bash bench/run_crystal_metric_ab.sh

# Full upstream language suite (not a GC gate)
FILTER=all TRIALS=1 bash bench/run_crystal_metric_ab.sh
```

Or manually:

```sh
cd bench/crystal_metric && shards install
crystal build --release main.cr -o ../../bin/crystal-metric-boehm
crystal build -Dgc_none --release main.cr -o ../../bin/crystal-metric-gcry
../../bin/crystal-metric-boehm Binarytrees,JsonGenerate
../../bin/crystal-metric-gcry Binarytrees,JsonGenerate
```

## Metrics

- Primary: wall seconds per bench, **speed % of Boehm** = Boehm_s / gcry_s × 100 (same host; >100 ⇒ gcry faster)
- Absolute “award” / Crystal release score: ignore for GC claims
- Optional: peak RSS from `/usr/bin/time -v` when available
- Some benches print `err` on Crystal ≥1.21 (checksum / float drift). Timing A/B still counts them; the runner does not gate on award.

See [UPSTREAM.md](UPSTREAM.md).
