# crystal-metric Boehm vs gcry (secondary, process-fresh)

- platform: `linux`
- mode: **process-fresh** (one OS process per bench × GC)
- trials: 3 (median wall)
- filter: `gc`
- role: **secondary GC suite** — not a ship headline

| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × | RSS × |
|-------|-------------:|-------------:|-------------:|-------:|------:|
| Binarytrees | 1.277 | 3.997 | 31.9 | 3.13 | 1.231 |
| Brainfuck | 4.214 | 3.767 | 111.9 | 0.894 | 1.456 |
| Brainfuck2 | 1.754 | 1.747 | 100.4 | 0.996 | 1.479 |
| Knuckeotide | 1.269 | 2.185 | 58.1 | 1.722 | 2.033 |
| RegexDna | 1.771 | 2.003 | 88.4 | 1.131 | 0.625 |
| Revcomp | 1.068 | 1.486 | 71.9 | 1.391 | 0.536 |
| Threadring | 1.073 | 1.11 | 96.7 | 1.034 | 1.556 |
| Matmul | 0.613 | 0.597 | 102.7 | 0.974 | 1.254 |
| JsonGenerate | 1.341 | 1.323 | 101.4 | 0.987 | 0.739 |
| JsonParseSerializable | 0.564 | 0.812 | 69.5 | 1.44 | 0.945 |
| JsonParsePull | 0.566 | 0.802 | 70.6 | 1.417 | 0.904 |
| Primes | 1.32 | 9.634 | 13.7 | 7.298 | 1.13 |
| JsonParsePure | 0.681 | 4.35 | 15.7 | 6.388 | 0.749 |

Peak RSS × (median of per-bench peaks): **0.625**

speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).
