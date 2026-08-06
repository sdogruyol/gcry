# acikturkiye (fat app): the STW lag knobs are not inert at EC1

Host: AMD Ryzen 9 9950X (16C/32T), WSL2, Crystal 1.21.0, `--release`,
**EC parallelism 1**, demo env against the shared Postgres. Load: `wrk -c100`
on `/api/v1/` with API auth. Instrument: `bench/root_phase_ab.sh`, 8 configs ×
3 reps × 40 s. 2709 collections, all major.

This supersedes the `TRIALS=3` throughput cut in
`2026-08-06-acik-sound-profile/`, which was recorded INCONCLUSIVE. It does not
report throughput — see `2026-08-06-081512-root-phase/FINDINGS.md` for why that
channel would not resolve, and `2026-08-06-112252-sound-profile/FINDINGS.md`
for the correction (a harness clock bug, not the host).

## Read the strata, not the medians

**The raw per-config medians from this run are meaningless and the harness
printed them anyway.** They say the sound profile is *33% cheaper* than tuned,
which is impossible — sound does strictly more work.

The fat app has two collection regimes:

| Regime | heap | tuned root scan |
|--------|-----:|----------------:|
| small | ~43 MiB | ~0.95 ms |
| large | ≥55 MiB (settles 60–76) | ~14.1 ms |

Root-scan cost differs **15×** between them. The transition is one-way and
driven by the app's own growth, not by the config: rep 1 never entered it,
rep 2 crossed at collection 44, rep 3 at collection 13. So each config lands a
different share of its samples in each regime, and a median over the mixture
reports whichever regime happened to hold the majority. That is the whole
explanation for the nonsense ordering.

Within a stratum the samples are tight and reproducible across reps — tuned
large: 14440 / 13965 µs; sound large: 209164 / 222061 / 207000 µs.

`stratified.json` carries the table below; the harness now refuses to let an
IQR > 50% of median pass without a loud warning.

## Result, stratified

work = `roots + scrub + stacks`, microseconds, median within stratum:

| Config | n small | work small | Δ | n large | work large | Δ | pause large |
|--------|--------:|-----------:|--:|--------:|-----------:|--:|------------:|
| tuned | 169 | 1039 | — | 163 | 14580 | — | 17132 |
| `GCRY_SOUND=1` | 235 | 1042 | +0% | 79 | **210970** | **+1347%** | **213329** |
| `GCRY_STW_*_LAG=0` | 257 | 1002 | −4% | 65 | **210504** | **+1344%** | **212010** |
| `GCRY_UNALIGNED_CANDIDATES=1` | 289 | 1005 | −3% | 62 | 15499 | +6% | 17910 |
| `GCRY_DISABLE_SCRUB_FIBERS=1` | 55 | 998 | −4% | 286 | 14630 | +0% | 17359 |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | 164 | 963 | −7% | 185 | 14016 | −4% | 16502 |
| `GCRY_INTERIOR=1` | 185 | 978 | −6% | 166 | 13716 | −6% | 15981 |
| `GCRY_DISABLE_BLACKLIST=1` | 225 | 995 | −4% | 124 | 13776 | −6% | 16227 |

**Small-heap collections: the sound profile is free.** +0% on tuned, every
knob inside ±7% — which is the same order as the noise, so the negative signs
are not savings.

**Large-heap collections: the sound profile is a 14.5× regression, and again
it is entirely the STW lag knobs.** Zeroing them alone reproduces the whole
profile (+1344% vs +1347%); the other five stay within ±6%. In absolute terms
this is a **213 ms GC pause** against tuned's 17 ms.

## What this corrects

`docs/SOUND-DEFAULTS.md` and the earlier acik write-up both concluded the STW
lag knobs are **"inert at parallelism 1"**, inferred from `phase_stacks` being
0.02–0.54 ms in every trial. That inference was sound for Kemal and wrong as a
general claim. Here, at EC1, they are the difference between a 17 ms and a
213 ms pause.

The knobs are not EC4-specific. They bite whenever the root scan is expensive
enough to matter — many threads (EC4 on Kemal, 7.2 → 141.7 ms) *or* a large
heap (this run at EC1, 17 → 213 ms). Kemal at EC1 has neither, which is why it
saw +0.1% and why that number should never have been generalised.

That makes the defaults case worse, not better: shipping sound by default now
has a demonstrated 100-ms-scale pause cost on an ordinary single-threaded fat
app, not just under the Parallel EC opt-in.

## Limits

- Pause composition, not throughput.
- The stratum boundary (55 MiB) is drawn where the gap is, not from any
  property of the collector. The regimes are well separated, so the exact cut
  does not matter, but it is a description of this workload's behaviour.
- Which of the two lag knobs dominates is not split here. On Kemal at EC4 it
  was `stw_multi_stack_lag` by 28:1; the same split has not been run on acik.
- Sample counts per stratum are uneven (large-heap n ranges 62–286) because the
  transition point varies per rep. Within-stratum medians were checked
  per-rep for stability before being pooled.
- The app talks to a shared remote Postgres, so its heap trajectory is not
  fully under this harness's control — that is the source of the uneven strata.

The stored `.ndjson.gz` traces keep only `collect_end` records, which is
everything the analysis reads. The raw traces were 59 MB, almost entirely
`finalizer` register lines (29553 lines per rep against 117 collections); they
are not reproducible input for anything here and were dropped rather than
committed.
