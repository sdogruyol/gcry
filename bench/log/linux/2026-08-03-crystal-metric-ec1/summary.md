# crystal-metric Boehm vs gcry (secondary)

- platform: `linux` (WSL2 i3-12100F)
- trials: 3 (median wall)
- filter: GC-sensitive subset
- role: **secondary GC suite** — not a ship headline
- peak RSS × (GNU time med): **0.79**

| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × |
|-------|-------------:|-------------:|-------------:|-------:|
| Binarytrees | 1.181 | 2.945 | 40.1 | 2.494 |
| Brainfuck | 3.946 | 4.02 | 98.2 | 1.019 |
| Brainfuck2 | 1.675 | 1.663 | 100.7 | 0.993 |
| JsonGenerate | 1.17 | 1.261 | 92.8 | 1.078 |
| JsonParsePull | 0.542 | 0.785 | 69.0 | 1.448 |
| JsonParsePure | 0.616 | 12.552 | 4.9 | 20.377 |
| JsonParseSerializable | 0.554 | 0.897 | 61.8 | 1.619 |
| Knuckeotide | 1.158 | 2.116 | 54.7 | 1.827 |
| Matmul | 0.558 | 0.567 | 98.4 | 1.016 |
| Primes | 1.069 | 9.182 | 11.6 | 8.589 |
| RegexDna | 1.114 | 1.087 | 102.5 | 0.976 |
| Revcomp | 1.043 | 1.453 | 71.8 | 1.393 |
| Threadring | 1.047 | 1.045 | 100.2 | 0.998 |

speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).
