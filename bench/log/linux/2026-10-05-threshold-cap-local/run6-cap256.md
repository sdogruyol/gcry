# crystal-metric Boehm vs gcry (secondary, process-fresh)

- platform: `linux`
- mode: **process-fresh** (one OS process per bench × GC)
- trials: 7 (median wall)
- filter: `Primes,JsonParsePure,JsonParseSerializable`
- role: **secondary GC suite** — not a ship headline

| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × | RSS × |
|-------|-------------:|-------------:|-------------:|-------:|------:|
| Primes | 0.616 | 0.832 | 74.0 | 1.351 | 0.916 |
| JsonParsePure | 0.372 | 0.49 | 75.9 | 1.317 | 0.83 |
| JsonParseSerializable | 0.282 | 0.362 | 77.9 | 1.284 | 0.975 |

Peak RSS × (median of per-bench peaks): **0.87**

speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).
