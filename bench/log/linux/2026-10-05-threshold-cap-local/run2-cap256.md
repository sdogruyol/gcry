# crystal-metric Boehm vs gcry (secondary, process-fresh)

- platform: `linux`
- mode: **process-fresh** (one OS process per bench × GC)
- trials: 3 (median wall)
- filter: `Primes,JsonParsePure,JsonGenerate,JsonParseSerializable,RegexDna,Binarytrees`
- role: **secondary GC suite** — not a ship headline

| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × | RSS × |
|-------|-------------:|-------------:|-------------:|-------:|------:|
| Primes | 0.622 | 0.835 | 74.5 | 1.342 | 0.922 |
| JsonParsePure | 0.344 | 0.494 | 69.6 | 1.436 | 0.837 |
| JsonGenerate | 0.639 | 0.605 | 105.6 | 0.947 | 0.711 |
| JsonParseSerializable | 0.273 | 0.363 | 75.2 | 1.33 | 0.968 |
| RegexDna | 1.722 | 1.746 | 98.6 | 1.014 | 0.902 |
| Binarytrees | 0.517 | 0.634 | 81.5 | 1.226 | 0.43 |

Peak RSS × (median of per-bench peaks): **0.919**

speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).
