# crystal-metric Boehm vs gcry (secondary, process-fresh)

- platform: `linux`
- mode: **process-fresh** (one OS process per bench × GC)
- trials: 3 (median wall)
- filter: `Primes,JsonParsePure,JsonGenerate,JsonParseSerializable,RegexDna,Binarytrees`
- role: **secondary GC suite** — not a ship headline

| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × | RSS × |
|-------|-------------:|-------------:|-------------:|-------:|------:|
| Primes | 0.622 | 1.023 | 60.8 | 1.645 | 0.901 |
| JsonParsePure | 0.349 | 0.572 | 61.0 | 1.639 | 0.8 |
| JsonGenerate | 0.631 | 0.601 | 105.0 | 0.952 | 0.704 |
| JsonParseSerializable | 0.276 | 0.301 | 91.7 | 1.091 | 0.808 |
| RegexDna | 1.697 | 1.765 | 96.1 | 1.04 | 0.713 |
| Binarytrees | 0.53 | 0.631 | 84.0 | 1.191 | 0.432 |

Peak RSS × (median of per-bench peaks): **0.821**

speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).
