| bench | result | arm | n | median wall s | min–max s | median CPU s | median peak WS MiB | speed vs Boehm | peak WS × Boehm |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| Primes | ok | boehm | 11 | 0.684 | 0.644–0.964 | 1.33 | 667.0 | 100% | 1.00× |
| Primes | ok | gcry | 11 | 0.719 | 0.683–0.732 | 1.00 | 613.8 | 95% | 0.92× |
| Primes | ok | gcry_serial | 11 | 0.905 | 0.868–1.200 | 0.95 | 615.5 | 76% | 0.92× |
| Primes | ok | gcry_nopace | 11 | 0.852 | 0.795–1.003 | 1.39 | 601.4 | 80% | 0.90× |
| JsonParsePure | err (same in every arm) | boehm | 11 | 0.370 | 0.361–0.427 | 1.58 | 519.2 | 100% | 1.00× |
| JsonParsePure | err (same in every arm) | gcry | 11 | 0.420 | 0.405–0.469 | 1.14 | 591.0 | 88% | 1.14× |
| JsonParsePure | err (same in every arm) | gcry_serial | 11 | 0.441 | 0.430–0.466 | 1.08 | 587.5 | 84% | 1.13× |
| JsonParsePure | err (same in every arm) | gcry_nopace | 11 | 0.491 | 0.473–0.527 | 1.45 | 547.3 | 75% | 1.05× |
| JsonParseSerializable | err (same in every arm) | boehm | 11 | 0.285 | 0.273–0.305 | 1.19 | 556.1 | 100% | 1.00× |
| JsonParseSerializable | err (same in every arm) | gcry | 11 | 0.329 | 0.309–0.344 | 1.03 | 513.4 | 87% | 0.92× |
| JsonParseSerializable | err (same in every arm) | gcry_serial | 11 | 0.329 | 0.305–0.369 | 1.02 | 508.1 | 87% | 0.91× |
| JsonParseSerializable | err (same in every arm) | gcry_nopace | 11 | 0.328 | 0.303–0.361 | 1.28 | 444.9 | 87% | 0.80× |
| JsonParsePull | err (same in every arm) | boehm | 11 | 0.277 | 0.267–0.306 | 1.30 | 556.5 | 100% | 1.00× |
| JsonParsePull | err (same in every arm) | gcry | 11 | 0.313 | 0.291–0.328 | 1.02 | 513.3 | 88% | 0.92× |
| JsonParsePull | err (same in every arm) | gcry_serial | 11 | 0.319 | 0.290–0.339 | 0.97 | 518.2 | 87% | 0.93× |
| JsonParsePull | err (same in every arm) | gcry_nopace | 11 | 0.314 | 0.293–0.332 | 1.14 | 444.9 | 88% | 0.80× |
| JsonGenerate | err (same in every arm) | boehm | 11 | 0.653 | 0.640–0.799 | 2.42 | 1336.1 | 100% | 1.00× |
| JsonGenerate | err (same in every arm) | gcry | 11 | 0.625 | 0.605–0.636 | 2.00 | 860.7 | 104% | 0.64× |
| JsonGenerate | err (same in every arm) | gcry_serial | 11 | 0.626 | 0.596–0.662 | 1.81 | 873.0 | 104% | 0.65× |
| JsonGenerate | err (same in every arm) | gcry_nopace | 11 | 0.618 | 0.599–0.638 | 2.25 | 860.2 | 106% | 0.64× |
| Binarytrees | ok | boehm | 11 | 0.696 | 0.679–0.717 | 0.81 | 45.0 | 100% | 1.00× |
| Binarytrees | ok | gcry | 11 | 0.621 | 0.607–0.664 | 0.64 | 42.3 | 112% | 0.94× |
| Binarytrees | ok | gcry_serial | 11 | 0.615 | 0.597–0.644 | 0.64 | 42.1 | 113% | 0.94× |
| Binarytrees | ok | gcry_nopace | 11 | 0.635 | 0.617–0.701 | 0.66 | 25.7 | 110% | 0.57× |
| RegexDna | err (same in every arm) | boehm | 11 | 1.822 | 1.813–1.843 | 2.48 | 528.8 | 100% | 1.00× |
| RegexDna | err (same in every arm) | gcry | 11 | 1.851 | 1.834–1.900 | 2.50 | 286.5 | 98% | 0.54× |
| RegexDna | err (same in every arm) | gcry_serial | 11 | 1.860 | 1.838–1.942 | 2.53 | 286.3 | 98% | 0.54× |
| RegexDna | err (same in every arm) | gcry_nopace | 11 | 1.853 | 1.838–1.872 | 2.52 | 267.0 | 98% | 0.50× |
| Revcomp | err (same in every arm) | boehm | 11 | 0.525 | 0.513–0.539 | 2.00 | 734.1 | 100% | 1.00× |
| Revcomp | err (same in every arm) | gcry | 11 | 0.603 | 0.585–0.611 | 2.06 | 549.2 | 87% | 0.75× |
| Revcomp | err (same in every arm) | gcry_serial | 11 | 0.595 | 0.587–0.611 | 2.03 | 548.8 | 88% | 0.75× |
| Revcomp | err (same in every arm) | gcry_nopace | 11 | 0.605 | 0.588–0.611 | 2.02 | 548.8 | 87% | 0.75× |
| Knuckeotide | err (same in every arm) | boehm | 11 | 0.712 | 0.697–0.755 | 0.81 | 53.8 | 100% | 1.00× |
| Knuckeotide | err (same in every arm) | gcry | 11 | 0.720 | 0.708–0.738 | 0.81 | 93.1 | 99% | 1.73× |
| Knuckeotide | err (same in every arm) | gcry_serial | 11 | 0.726 | 0.717–0.749 | 0.81 | 89.5 | 98% | 1.66× |
| Knuckeotide | err (same in every arm) | gcry_nopace | 11 | 0.719 | 0.713–0.742 | 0.81 | 74.9 | 99% | 1.39× |
| Brainfuck | ok | boehm | 11 | 2.598 | 2.543–2.841 | 2.62 | 10.8 | 100% | 1.00× |
| Brainfuck | ok | gcry | 11 | 2.594 | 2.550–2.735 | 2.59 | 10.1 | 100% | 0.93× |
| Brainfuck | ok | gcry_serial | 11 | 2.631 | 2.557–2.772 | 2.61 | 9.9 | 99% | 0.92× |
| Brainfuck | ok | gcry_nopace | 11 | 2.625 | 2.542–2.887 | 2.64 | 10.1 | 99% | 0.93× |
| Brainfuck2 | ok | boehm | 11 | 1.159 | 1.145–1.176 | 1.17 | 10.8 | 100% | 1.00× |
| Brainfuck2 | ok | gcry | 11 | 1.158 | 1.138–1.236 | 1.17 | 10.1 | 100% | 0.93× |
| Brainfuck2 | ok | gcry_serial | 11 | 1.155 | 1.147–1.226 | 1.16 | 9.9 | 100% | 0.92× |
| Brainfuck2 | ok | gcry_nopace | 11 | 1.158 | 1.149–1.189 | 1.16 | 10.1 | 100% | 0.93× |
| Matmul | ok | boehm | 11 | 0.354 | 0.352–0.357 | 0.38 | 35.9 | 100% | 1.00× |
| Matmul | ok | gcry | 11 | 0.350 | 0.348–0.365 | 0.36 | 42.3 | 101% | 1.18× |
| Matmul | ok | gcry_serial | 11 | 0.349 | 0.346–0.361 | 0.36 | 42.0 | 101% | 1.17× |
| Matmul | ok | gcry_nopace | 11 | 0.352 | 0.347–0.359 | 0.36 | 42.3 | 101% | 1.18× |
| Threadring | ok | boehm | 11 | 0.450 | 0.419–0.496 | 0.48 | 13.0 | 100% | 1.00× |
| Threadring | ok | gcry | 11 | 0.396 | 0.371–0.465 | 0.41 | 12.2 | 114% | 0.94× |
| Threadring | ok | gcry_serial | 11 | 0.389 | 0.372–0.430 | 0.44 | 12.1 | 116% | 0.93× |
| Threadring | ok | gcry_nopace | 11 | 0.411 | 0.378–0.465 | 0.42 | 12.3 | 109% | 0.94× |
