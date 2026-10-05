# crystal-metric Boehm vs gcry (secondary, process-fresh)

- platform: `linux`
- mode: **process-fresh** (one OS process per bench × GC)
- trials: 7 (median wall)
- filter: `Primes,JsonParsePure,JsonParseSerializable`
- role: **secondary GC suite** — not a ship headline

| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × | RSS × |
|-------|-------------:|-------------:|-------------:|-------:|------:|
| Primes | 0.613 | 0.83 | 73.9 | 1.354 | 0.922 |
| JsonParsePure | 0.343 | 0.487 | 70.4 | 1.42 | 0.837 |
| JsonParseSerializable | 0.279 | 0.359 | 77.7 | 1.287 | 0.986 |

Peak RSS × (median of per-bench peaks): **0.876**

speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).
