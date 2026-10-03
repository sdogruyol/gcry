# crystal-metric, Boehm vs gcry, on every CI platform

gcry at `ae97bd0` (0.33.0 plus the large-trim and Windows idle commits),
Crystal 1.21.0, GitHub-hosted runners. 13 crystal-metric benchmarks, each run
5 times per GC; cells are medians. Peak is the process's peak RSS. Built and
run by the scripts in this directory, which lived on the throwaway branches
`probe-winmetric` and `probe-metric-unix`.

| platform | gcry speed, % of Boehm (median of 13) | peak RSS × Boehm (median) |
|---|---:|---:|
| Linux x64 (ubuntu-latest) | 92.7 | 0.88 |
| Windows x64 | 97.0 | 0.88 |
| Windows arm64 | 98.9 | 0.85 |
| macOS arm64 (run 1) | 94.3 | 0.93 |
| macOS arm64 (run 2) | 98.3 | 0.93 |

Full tables: `rows-*.txt` through `metric_summary.py`.

## The same two outliers everywhere

| bench | Linux x64 | Win x64 | Win arm64 | macOS arm64 (1 / 2) |
|---|---:|---:|---:|---:|
| Primes | 27.4% | 28.2% | 33.0% | 27.3% / 29.0% |
| JsonParsePure | 26.8% | 30.4% | 31.0% | 26.1% / 28.7% |
| Binarytrees | 84.3% | 100.5% | 99.8% | 77.0% / 78.4% |

Every other benchmark is 74–117% of Boehm on every platform. Primes and
JsonParsePure are not platform effects: they are the two benchmarks whose live
set grows into hundreds of MiB of small pointer-bearing objects (a trie of
`Hash(Char, Node)`; a tree of `JSON::Any`), and on Linux their pauses are
entirely the mark phase (`../2026-10-03-mark-prefilter/FINDINGS.md`). gcry
marks the same heap in ~5× Boehm's time per collection; the collection counts
are about the same.

Memory is the other side of it: peak RSS is below Boehm's on most rows
everywhere, at 0.42–0.70× on Binarytrees, RegexDna, Revcomp and JsonGenerate.
The rows above 1.2× are small absolute numbers (Brainfuck 4.4 vs 3.6 MiB,
Matmul ~36 vs ~29 MiB) except Knuckeotide on macOS (84.8 vs 40–47 MiB,
1.8–2.1×). [INFERENCE] That one is the macOS 256 KiB chunk size on a heap
of many small size classes; not measured here.

## Follow-up

The first mark-path fix (heap-span prefilter in the scan loops) landed after
these runs; on Linux it moved Primes from 30% to 37% of Boehm and JsonParsePure
from 32% to 35%. The rest of the gap is per-candidate resolution cost; see
that findings file.
