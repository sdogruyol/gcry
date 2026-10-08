# crystal-metric Boehm vs gcry (secondary, process-fresh)

- platform: `linux`
- mode: **process-fresh** (one OS process per bench × GC)
- trials: 7 (median wall)
- filter: `Primes,JsonParsePure,JsonParseSerializable`
- role: **secondary GC suite** — not a ship headline

| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × | RSS × |
|-------|-------------:|-------------:|-------------:|-------:|------:|
| Primes | 0.617 | 1.018 | 60.6 | 1.65 | 0.9 |
| JsonParsePure | 0.349 | 0.557 | 62.7 | 1.596 | 0.799 |
| JsonParseSerializable | 0.27 | 0.299 | 90.3 | 1.107 | 0.784 |

Peak RSS × (median of per-bench peaks): **0.832**

speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).
