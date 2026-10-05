# crystal-metric Boehm vs gcry (secondary, process-fresh)

- platform: `linux`
- mode: **process-fresh** (one OS process per bench × GC)
- trials: 7 (median wall)
- filter: `Primes,JsonParsePure,JsonParseSerializable`
- role: **secondary GC suite** — not a ship headline

| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × | RSS × |
|-------|-------------:|-------------:|-------------:|-------:|------:|
| Primes | 0.619 | 1.019 | 60.7 | 1.646 | 0.9 |
| JsonParsePure | 0.344 | 0.559 | 61.5 | 1.625 | 0.796 |
| JsonParseSerializable | 0.27 | 0.3 | 90.0 | 1.111 | 0.816 |

Peak RSS × (median of per-bench peaks): **0.832**

speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).
