# Σ mark on Revcomp and RegexDna after the mark unroll: cold instruction lines (2026-11-02)

The question: `cbf1b2e8` (payload word loop unrolled by four) raised Σ mark on
Revcomp (+15% x86 Linux, +6.5% arm64, +10% Windows) and RegexDna (+10.6%
x86) in Perf A/B 41233405753, wall level; the keep-rule probe attributed it
to the unroll (`../2026-11-01-0.40-keep-rule/` §5). Tip `07b61d28`, probe
`e9e9f0a9` (tip with `cbf1b2e8` reverted, tag `archive/probe/keep-040-unroll`).
Host: the QEMU x86-64 guest (no PMU), Crystal 1.21.0, crystal-metric
`--release`, `taskset -c 0-3`, every heavy step under the shared lock.

**Verdict: explained; not fixed on x86 Linux, so no code lands.** The best
shape (one-copy batch loop for a cycle after a short major,
`dropped-batch-twin.patch`) keeps the JSON rows' gain and takes the loss back
locally, on arm64 and on Windows Revcomp, but on `ubuntu-latest` Revcomp and
RegexDna stay 9–13% over the probe.

## 1. The heaps

`survey-tip.txt`: Revcomp, RegexDna and the Base64 rows scan 71–73 KiB per
collection, every collection: about 64 KiB of one large or untagged block
(through `scan_edges_inline`) and ~100–140 small objects (through the batch
scan). Σ mark is 0.4 ms over 25–28 collections, ~15 µs each. Revcomp and
RegexDna hold 100+ MiB of atomic strings, so they mark **in parallel**
(32 MiB live floor): locally Σ mark is 0.331 ms default against 0.167 ms
with `GCRY_DISABLE_PARALLEL_MARK=1`; half the mark is the parallel cycle's
wake and termination. The Base64 rows mark serially.

## 2. The cause: five copies of the candidate code, run cold

The unroll inlines `resolve_candidate` four times in the quad loop and once
in the tail: `scan_batch_prefetched` grew 1 536 → 3 600 bytes (serial) and
1 665 → 4 023 (shard), `scan_edges_inline` 590 → 2 502 / 648 → 2 879. With
~100 objects a collection every copy is reached in every collection, and
Revcomp streams hundreds of MiB between collections, so the code starts cold.

Callgrind on Revcomp, counting inside the batch scan (`callgrind-revcomp.txt`,
28 collections):

| tree | Ir | I1 misses | from memory (ILmr) | branch misses |
|---|---:|---:|---:|---:|
| probe | 1.98 M | 898 | 779 | 13 974 |
| tip | 1.39 M | 1 600 | 1 383 | 13 477 |

The tip runs 30% fewer instructions (the 64 KiB scan gets the unroll's
gain) but misses 25 more instruction lines a collection, 22 of them from
memory; all of the increase is in the batch scan (537 → 1 231). Not the
cause: payload length, the `quad_end` setup or the two-branch span test —
instructions fell and branch misses are level.

Micro (`main_mark.cr` `small`, 100 small objects held, 300 collections,
`small.py`, 21 trials): with 64 MiB written between collections the tip
marks 13.24 µs a collection against the probe's 12.24 (+8%; second session
12.04 / 11.11); with nothing written, 4.86 against 5.66 (−14%). The unroll
is faster warm and slower cold.

## 3. Shapes

**One copy behind an unrolled search** (three shapes, `dropped-one-*.patch`):
the quad loop exits to one shared candidate block on a word at or above the
low end (`one-exit`), on an in-span word (`one-span-exit`; LLVM fused the two
compares into `setcc`/`and`, six instructions a word), or with a shared
high-end test (`one-lo-exit`). Batch-scan instructions on a held parsed-JSON
graph, 5 collections, one marker (`callgrind-micro-jsonparse.txt`):

| tree | batch scan Ir | vs probe |
|---|---:|---:|
| probe | 2.819 G | — |
| tip (unrolled) | 2.534 G | −10.1% |
| one-exit | 3.098 G | +9.9% |
| one-lo-exit | 3.394 G | +20.4% |
| one-span-exit | 3.905 G | +38.5% |

Every exit and re-entry costs 7–11 instructions (pointer re-bias, re-test,
spills), and a payload full of words above the span (text) pays it per word.
Dropped: they give back more than the unroll saved. (Whole-run callgrind of
crystal-metric JsonGenerate was not usable for this: identical machine code
read 6.6 G and 7.4 G in two runs, the work moving with heap placement.)

**Batch twins** (`5b8ec420`, tag `archive/mark-short-040/batch-twin`): the
batch scan as two out-of-line copies, unrolled and one-copy, chosen per cycle
by whether the last major scanned 512 KiB (`@mark_scan_unrolled`, set in
`reset_mark_scanned_bytes`). The unrolled twin is byte-identical to the
tip's batch scan; the one-copy twin is the probe's size. `make mark-audit`
gained `hold-unrolled`/`clean-unrolled` arms (1 MiB of pointer slots held)
whose children report which loop ran; both loops fire the planted miss
(198 missed, 0 on clean). Revcomp callgrind: 834 I1 misses, 720 from
memory; micro cold 11.26 µs (probe 11.11). Local Revcomp Σ mark 0.339 ms
(tip 0.378, probe 0.349), Base64Encode 1.249 (tip 1.493, probe 1.524)
(`local-revcomp.txt`).

**Edge scans following the cycle too** (`d3aeaca9`,
`archive/mark-short-040/edges-twin`): `scan_edges_inline` one-copy in short
cycles as well. Base64Encode +37.0% [+33.8, +42.5] and Base64Decode +30.0%
Σ mark on `ubuntu-latest` against the tip (Perf A/B 41294029368): on the
64 KiB block mostly below the span the one-copy loop is a taken branch per
word. Reverted (`ddee0bcf`, `archive/mark-short-040/ab`, same machine code
as `5b8ec420`).

## 4. Runner A/Bs (15 reps, stats 5, no Boehm; `ci/`)

Σ mark, var against base, median [IQR]:

| row | run | ubuntu-latest | ubuntu-24.04-arm | macos-latest | macos-15-intel | windows-latest |
|---|---|---|---|---|---|---|
| Revcomp | twins vs tip, 41290993670 | −5.6% [−11.5, +2.2] | −1.3% [−4.9, +0.8] | −7.3% [−11.1, +20.4] | −6.3% [−12.1, +1.8] | −0.3% [−4.3, +6.2] |
| RegexDna | twins vs tip | +4.4% [−14.2, +15.7] | −3.0% [−5.1, −1.3] | −11.7% [−19.2, −4.8] | −2.7% [−5.9, +0.7] | −2.5% [−4.9, +2.6] |
| Base64Encode | twins vs tip | −4.3% [−8.2, −1.5] | −4.7% [−8.7, −0.0] | −2.2% | −5.6% [−8.2, −2.7] | −11.3% [−16.3, −9.2] |
| Revcomp | twins vs probe, 41298289986 | **+13.0% [−0.5, +16.5]** | +1.9% [−0.9, +5.0] | −6.5% [−13.0, +0.2] | +1.3% [−6.6, +7.9] | +1.0% [−3.9, +2.5] |
| RegexDna | twins vs probe | **+8.6% [+2.5, +21.9]** | +2.7% [−0.4, +5.4] | −5.0% [−12.8, −1.8] | **+9.5% [+4.1, +15.1]** | +4.5% [+0.1, +5.3] |
| JsonParsePure | twins vs probe | +0.9% | −7.5% [−8.1, −7.1] | −9.1% | −7.6% | −14.0% [−24.7, −10.6] |
| JsonParseSerializable | twins vs probe | +5.2% | −7.6% [−9.4, −5.7] | −4.0% | −5.6% | −14.8% [−16.7, −5.5] |
| JsonParsePull | twins vs probe | +3.3% | −9.7% [−11.2, −8.4] | −6.7% | +4.4% | −9.0% [−15.9, −3.7] |

The JSON rows keep the unroll's gain (arm64 JsonGenerate +6.9% is its
fifteenth collection, the pace step of `../2026-11-01-0.40-keep-rule/` §4).
Revcomp and RegexDna come back inside the spread on arm64 and on Windows
Revcomp, and below the probe on M1, but not on `ubuntu-latest` (+1–2 µs a
collection over the probe, per-rep ranges 0.46–0.62 / 0.53–0.72 ms
overlapping) nor Intel RegexDna. No wall or timed-section row moved with
any of it. Cross-session Σ mark on these rows moves by 15–30% (the tip read
0.550 ms in 41290993670 and 0.623 in 41294029368), so only same-run pairs
are compared.

Why x86 Linux keeps the residual is open [INFERENCE: these two rows mark in
parallel, so half their Σ mark is helper wake-up and termination on cold
cores, which the serial Base64 rows, improved everywhere, do not have; a
serial-only pair of both trees would separate it]. The keep-rule run on the
twins (41298298311) was cancelled once the change was not taken.

## Decision

Not landed: the change was asked to remove the Revcomp/RegexDna loss with
the JSON gain kept, and on the runner the loss was measured on (x86 Linux)
it does not. The tree stays at the tip's unrolled loop. The patch, the gate
arms and the measurements are here for a parallel-path follow-up.

Correctness of the twins (not landed): `make mark-audit`,
`make parallel-mark-termination`, `make parallel-mark-process`, `verify.sh`
(format, lint, specs, process_spec three ways), `make windows-typecheck`,
`make darwin-typecheck`, `make alloc-entry-frame`, process_spec on Crystal
1.22.2 (330 examples, 0 failures): all green.

## Tools

`cg.sh`/`cgi.sh` (callgrind of crystal-metric, batch scan only), `cgm.sh`
(callgrind of the micro inside `GC.collect`), `main_mark.cr` +
`micro-build.sh` + `small.py` (the micro), `survey.sh` (scanned bytes per
collection, every crystal-metric row), local runs with
`../2026-10-31-parallel-mark-floor/ms.py`. Scripts read `MS_SCRATCH` (default
`$PWD`).
