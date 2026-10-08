| bench | result | arm | n | median wall s | min–max s | median CPU s | median peak WS MiB | speed vs Boehm | peak WS × Boehm |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| Primes | ok | boehm | 11 | 0.642 | 0.632–0.650 | 1.34 | 667.0 | 100% | 1.00× |
| Primes | ok | gcry | 11 | 0.707 | 0.692–0.742 | 1.00 | 613.7 | 91% | 0.92× |
| JsonParsePure | err (same in every arm) | boehm | 11 | 0.361 | 0.355–0.368 | 1.72 | 519.2 | 100% | 1.00× |
| JsonParsePure | err (same in every arm) | gcry | 11 | 0.417 | 0.397–0.451 | 1.16 | 591.9 | 87% | 1.14× |
| JsonParseSerializable | err (same in every arm) | boehm | 11 | 0.276 | 0.268–0.280 | 1.11 | 556.1 | 100% | 1.00× |
| JsonParseSerializable | err (same in every arm) | gcry | 11 | 0.310 | 0.300–0.328 | 0.98 | 505.6 | 89% | 0.91× |
| JsonParsePull | err (same in every arm) | boehm | 11 | 0.272 | 0.268–0.276 | 1.19 | 556.6 | 100% | 1.00× |
| JsonParsePull | err (same in every arm) | gcry | 11 | 0.295 | 0.287–0.311 | 1.00 | 508.5 | 92% | 0.91× |
| Revcomp | err (same in every arm) | boehm | 11 | 0.527 | 0.521–0.547 | 1.98 | 898.2 | 100% | 1.00× |
| Revcomp | err (same in every arm) | gcry | 11 | 0.598 | 0.589–0.608 | 2.03 | 548.9 | 88% | 0.61× |
| Knuckeotide | err (same in every arm) | boehm | 11 | 0.705 | 0.699–0.713 | 0.81 | 53.7 | 100% | 1.00× |
| Knuckeotide | err (same in every arm) | gcry | 11 | 0.720 | 0.702–0.741 | 0.80 | 87.3 | 98% | 1.62× |
| Matmul | ok | boehm | 11 | 0.352 | 0.351–0.355 | 0.39 | 35.9 | 100% | 1.00× |
| Matmul | ok | gcry | 11 | 0.348 | 0.346–0.352 | 0.36 | 42.2 | 101% | 1.18× |
