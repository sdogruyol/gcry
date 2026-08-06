# Performance vs Boehm (Linux)

**Canonical cut numbers for version bumps live here (Linux only).** macOS: [PERF-macos.md](PERF-macos.md).

**One number:** `gcry req/s ÷ Boehm req/s` on the same host. Prefer **`/json`**. Absolute wrk is noise; **% of Boehm** is the score.

Load: `bench/kemal`, `wrk -c 100 -d 30`, fresh process per path, `--release` (`-Dgc_none` for gcry).

**RSS:** after wrk, `GET /gc-collect`, then read process RSS (`ps` / VmRSS) — end-of-run noise otherwise dominates.

## Headline (v0.16.0) — Linux *(measured)*

Same host, Crystal 1.21.0, WSL2 x86_64 (i3-12100F), median of 3, pure `--release`, **in-header MARK** (default), scrub **on** (EC1 **4 KiB** blind parked-fiber clear), auto-layouts **off**, EC1 non-atomic heap counters. Session: `bench/log/linux/2026-08-01-093130/` (`cb4d7f2`); idle `/` from `slash-recut/` (same binaries; first `/` pass noisy).

| Path | % of Boehm | post-GC RSS × |
|------|----------:|--------------:|
| `/json` | **~87%** | **~0.80×** |
| `/` | **~82%** | **~0.79×** |

Alloc-heavy `/json` is the gate. Idle `/` is sanity. **0.16.0 recovers EC1 thr** after Parallel-era STW/scrub/counter fallout (fair Boehm ~40k baseline). **v0.17–v0.18** carry this Linux Kemal headline. Fat-app (acikturkiye): tagged v0.17 i3 cut was thr **~90%** @ RSS **~3.43×** (`2026-08-02-064142/`); **v0.18 after finalizer + Linux retain=0** is thr **~90–96%** @ RSS **~1–1.6×** (i3 headline **~96%** @ **~1.63×**; 9950X **~90–102%** @ **~1.0–1.8×**) — [ACIKTURKIYE.md](ACIKTURKIYE.md). Opt-in `GCRY_TIGHT_GROW=1` closes the freelist residual on acik (**~103%** @ **~0.92×**, `…/acik-tight-grow-v2-med3/`); Kemal `/json` soft (~**78%**) — not default. Quiet Kemal smokes land **~80–85%** `/json` @ **~0.74–0.79×** (host/Boehm noise; retain=0 no cliff) — **headline stays the v0.16 cut above**.

### Sound-roots cut — what the default heuristics actually cost

Every number above is measured with gcry's **root-completeness heuristics
armed**: base-pointer-only ambient roots, the static-root `type_id` gate,
256 KiB STW stack/pthread lags, and parked-fiber scrub. Each of those can
decline to mark a pointer that is genuinely live, so a throughput number
produced with them on does not answer "what does a *correct* gcry cost?".

`GCRY_SOUND=1` turns the whole class off. Same host, same session, `wrk -c 100
-d 20`, median of 7 — `bench/log/linux/2026-08-06-052109-sound-profile/`
(`make bench-sound-profile`). Each `sound` row is confirmed applied via its own
`/gc-stats` `root_soundness`, not assumed from the env var.

| Kemal `/json` config | % of Boehm | post-GC RSS × | run spread |
|----------------------|-----------:|--------------:|-----------:|
| tuned (process defaults) | 78.3% | **0.795×** | 5.06% |
| sound roots (`GCRY_SOUND=1`) | 81.0% | **0.794×** | 6.54% |
| sound + conservative bodies (`+GCRY_DISABLE_LAYOUT=1`) | 84.4% | **0.797×** | 10.47% |

**RSS does not move — that reproduces across two sessions.** Throughput did not
resolve, and the table above carries the defect that explains why: **WSL2 steps
`CLOCK_REALTIME` backwards ~1.6 s every ~32 s** and wrk derives its duration
from that clock, so any pass containing a step reports ~19% high. A 10 s pass
catches one about a third of the time, and which config it lands on is random —
so it biased the comparison, not just widened it. That is the mechanism behind
"sound ahead of tuned", and the rows above should be read as suspect for that
reason as well as the retracted ~1pp figure (which predated the raw-buffer fix).

`bench/sound_profile_ab.sh` now times passes with `CLOCK_MONOTONIC` and takes
wrk's request count rather than its rate.

That was one of four defects, all of them **bias rather than variance** — which
is why more runs never helped:

1. wrk's rate came from a clock WSL2 steps backwards (~19% on affected passes).
2. The first fix *discarded* stepped passes, which made the 9×30 s methodology
   impossible — steps arrive faster than a 30 s pass completes.
3. Configs ran as consecutive blocks, confounding config with time: the three
   gcry blocks came out monotonically faster in execution order (+0%, +2.11%,
   +2.80%).
4. Interleaving alone left a fixed order *within* each round. Whichever config
   ran first came out ~2% slow — the same ~2% for three different knob
   configurations, which is position, not knobs.

Fixed: monotonic timing, round-robin interleaving, order rotated each round.
The apparent sound-vs-tuned gap fell +2.27% → +2.11% → **+0.82%** as each
confound came out.

**Result** (`bench/log/linux/2026-08-06-140037-sound-profile/`, 9 rounds × 30 s,
paired): the sound profile is **throughput-neutral** on Kemal `/json` at EC1 —
+0.82% at 1.7σ, not distinguishable from zero. The class costs under ~1% here,
in either direction.

The exception is `scrub_fibers`: disabling it *gains* **1.29%** (8/9 rounds,
3.2σ), and the per-collection trace independently has it saving 1.7% of root
work. It loses on throughput, pause and root completeness at once.

**Default-path control** (`…-153032-sound-profile/`): the branch adds an ivar
load and a branch to the hot mark path. Against `master` built from its own
worktree, both interleaved in one job at default configuration: **+0.12%, 95%
CI −1.42% … +1.66%** — no measurable regression, and the −2.13% figure that
had been carried for this is excluded.

Kemal is also the workload these knobs were *least* expected to matter on —
they were argued on fat-app RSS (fiber scrub at acik 3.00× → 2.65×, the STW
lags at EC4 `phase_roots`).

**Unmeasured in throughput is not free.** The pause cost *has* been measured,
per collection off the `GCRY_TRACE=1` records (`bench/root_phase_ab.sh`), and
it is not small where the root scan is large:

| Cut | tuned pause | `GCRY_SOUND=1` pause | |
|-----|------------:|---------------------:|--|
| Kemal `/json`, EC1 | 398 µs | 398 µs | +0.1% |
| Kemal `/json`, **EC4** | 7.2 ms | **141.7 ms** | **+1866%** |
| acik `/api/v1/`, EC1, heap ≥55 MiB | 17 ms | **213 ms** | **+1347%** |

In every case the entire cost is the two STW lag knobs — the other five
heuristics stay within ±6%. They are not EC4-specific: they bite whenever the
root scan is expensive, whether from thread count or heap size. Full method,
per-knob decomposition, and the limits of each cut:
[SOUND-DEFAULTS.md](SOUND-DEFAULTS.md).

### Supported Parallel opt-in (TLAB off + lazy sweep) — v0.17.0

Not the process default — apps must `ExecutionContext.default.resize(N)`
(`EC_PARALLELISM=N` in kemal benches). Keep **`GCRY_TLAB` off**; lazy
post-STW sweep is default for that shape (`GCRY_DISABLE_LAZY_SWEEP=1`
escapes). Soft soak **0/40**. Quiet cut:

| Path | % of Boehm | gcry (med) | pause p50 | RSS × | Session |
|------|----------:|-----------:|----------:|------:|---------|
| `/json` | **~78.8%** | ~69k | ~**8.5 ms** | ~**5.8×** | `2026-08-01-ec4-lazy-sweep/` |

Same-host follow-ups often land **~83–88%** (Boehm noise). Stretch ~80%
closed as accepted. **Unsupported** (stderr warn; not product):
`GCRY_TLAB=1`, Parallel empty munmap (`GCRY_PARALLEL_RELEASE`). Hub:
`bench/log/linux/2026-07-29-parallel-tlab-FINDINGS.md`.

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|-------:|--------------:|
| `/` | 81846 | 66841 | **81.7%** | **0.79×** |
| `/json` | 35780 | 31067 | **86.8%** | **0.80×** |

`GCRY_KEEP_CHUNKS=1` re-measured in the 0.18 campaign (**95%** `/json` @ **3.07×** RSS) — see notes below; not a release headline. Soft-dirty nursery stays opt-in (HTTP too dirty for a win). Side bitmap: `-Dgcry_side_bitmap` (see escape table).

### v0.18.0 campaign / confirm notes *(not the Kemal headline)*

Working notes — **Kemal release cite stays the v0.16 cut above.**
Hub: `bench/log/linux/2026-08-02-018-FINDINGS.md`.

| Session | Config | `/json` % | RSS × |
|---------|--------|----------:|------:|
| `2026-08-02-120500/` | EC1 tip baseline (i3) | **87.9%** | **0.81×** |
| `2026-08-02-152806/` | EC1 confirm soft (i3) | **85.4%** | **0.76×** |
| `2026-08-02-121411/` | `GCRY_KEEP_CHUNKS=1` (i3) | **95.0%** | **3.07×** |
| `2026-08-02-145600/` | EC4 reclaim-off (i3) | **80.5%** | **5.48×** |
| `2026-08-03-072122/` | EC1 tip (9950X) | **82.5%** | **0.76×** |
| `2026-08-03-072954/` | EC1 confirm (9950X) | **80.3%** | **0.76×** |
| `2026-08-03-080248/` | `KEEP_CHUNKS=1` (9950X) | **90.1%** | **3.23×** |
| `2026-08-04-042404/` | retain=0 defaults (9950X) | **85.0%** | **0.78×** |
| `2026-08-04-045839/` | tip i3 | **~80%** | **0.75×** |
| `2026-08-04-kemal-thr-profil/` | tip + KEEP contrast (9950X) | **~80%** / KEEP abs **~+4%** | **0.79×** / **~3.4×** |
| `2026-08-04-085740/` | `GCRY_TIGHT_GROW=1` (9950X) | **77.6%** | **0.78×** |
| `2026-08-05-091154/` | post-tag confirm (9950X) | **80.0%** | **0.74×** |
| `2026-08-05-090449/` | post-tag repeat (9950X) | **80.6%** | **0.74×** |

Gate **≥95% @ ≤1.0×** and soft **≥90% @ ≤0.85×** missed without KEEP RSS tax.
9950X hunt closed MISS; post-tag reconfirm still MISS (quiet ~80% band).
Parallel dormant default-on rejected; `GCRY_PARALLEL_DORMANT=1` remains the
Parallel RSS opt-in (~75% @ ~4×). Fat-app freelist residual:
`GCRY_TIGHT_GROW=1` (acik **~0.92×**; Kemal thr soft — [ACIKTURKIYE.md](ACIKTURKIYE.md)).

### v0.15.0 Linux cut (superseded headline)

Same host method. Session: `bench/log/linux/2026-07-29-151144/` (`bebedae`). `/json` **86.3%** @ **0.77×** RSS; `/` **86.2%** @ **0.76×**. Correctness release (TLAB+process STW); thr within host noise of v0.14.

### v0.14.0 Linux cut (superseded headline)

Same host method. Session: `bench/log/linux/2026-07-29-035426/` (`015d66d`). `/json` **89.1%** @ **0.79×** RSS; `/` **88.9%** @ **0.78×**.

### v0.12.0-era Linux cut (scrub off; superseded)

Same host method, scrub **off**. Session: `bench/log/linux/2026-07-26-173602/`. `/json` **88.8%** @ **0.99×** RSS; `/` **90.4%** @ **0.99×**.
## History (Linux)

Kemal `% of Boehm` on `/` and `/json`. Prefer `/json` when reading the arc. RSS column is post-`GC.collect` where recorded.

| Version | `/` | `/json` | RSS × | What changed |
|---------|----:|--------:|------:|--------------|
| 0.4.0 | ~86% | ~83% | — | STW default |
| 0.5.0 | ~92% | ~82% | — | pause p50/p99; STW hot path; chunk release still opt-in |
| 0.6.0 | **~105%** | **~100%** | — | size-class 32 KiB, `notice_reclaim`, chunk index, STW/root fixes |
| 0.7.0 | ~92% | ~90% | **~0.93×** | empty-chunk release **default-on**; layout / type_id / SP clamp |
| 0.8.0 | ~91% | ~89% | **~0.93×** | barriers, TLAB, blacklist, atfork, aarch64, metrics |
| **0.9.0** | **~89%** | **~92%** | **~0.97×** | stack scrub (opt-in); parallel-mark experimental; observability |
| 0.10.0 | *(carry 0.9.0)* | *(carry 0.9.0)* | *(carry)* | **macOS process GC** — Linux not re-cut this release; see [PERF-macos.md](PERF-macos.md) |
| 0.11.0 | *(carry 0.9.0)* | *(carry 0.9.0)* | *(carry)* | side mark bitmap landed on Darwin host; Linux not re-cut at tag |
| pre-0.12 (bitmap A/B) | ~78% | ~82% | ~9.2× | Linux A/B with side bitmap still default (`2026-07-26-171942`) |
| **0.12.0** | **~90%** | **~89%** | **~0.99×** | in-header MARK default again; side bitmap opt-in (`-Dgcry_side_bitmap`) |
| **0.13.0** | **~90%** | **~89%** | **~0.95×** *(est.)* | **Linux: scrub default-on** — Kemal/acik RSS estimated; macOS: 256 KiB chunk, fiber scrub, threshold tuning. |
| **0.14.0** | **~89%** | **~89%** | **~0.79×** | Measured Linux re-cut (`2026-07-29-035426`, scrub on). Thr flat; Kemal RSS better than 0.13 est. Test suite + Trace/dump. Fat-app not re-cut. |
| **0.15.0** | **~86%** | **~86%** | **~0.77×** | Correctness: TLAB+process STW freelist fix + STW MT harness. Kemal re-cut `2026-07-29-151144`; acik ~90% / ~2.54× (`112202`). |
| **0.16.0** | **~82%** | **~87%** | **~0.80×** | EC1 thr recover after Parallel fallout (cheap STW scans, 4 KiB scrub, non-atomic counters, sweep batch). Cut `2026-08-01-093130` (+ `/` slash-recut). |
| **0.17.0** | *(carry 0.16)* | *(carry 0.16)* | *(carry)* | Darwin Kemal re-cut; Parallel TLAB-off + lazy **supported opt-in** (~79% EC4 `/json`, ~5.8× RSS). Linux Kemal not re-cut. `2026-08-01-ec4-lazy-sweep/`. |
| **0.18.0** | *(carry 0.16)* | *(carry 0.16)* | *(carry)* | Finalizer + Linux retain=0; fat-app tip ~**90–96%** @ ~**1–1.6×**; Darwin acik tip ~**0.63×**; `GCRY_TIGHT_GROW` opt-in; stack maps **dormant**. Linux Kemal not re-cut. |

**Escape knobs (same era, not defaults):**

| Config | `/` | `/json` | RSS × | Note |
|--------|----:|--------:|------:|------|
| 0.5.0 + `GCRY_RELEASE_CHUNKS=1` | ~56% | ~49% | — | release too early to be default |
| 0.6.0 + `GCRY_RELEASE_CHUNKS=1` | ~92% | ~92% | — | thr cost for RSS |
| 0.7-dev + keep chunks | — | ~100% | high | empty retain ≈ waste |
| 0.7-dev Phase 12 (pre-tag) | — | ~93% | ~0.93× | release default-on landed |
| `GCRY_KEEP_CHUNKS=1` (0.18 campaign re-cut) | **~89%** | **~95%** | **~3.07×** | thr escape only — `2026-08-02-121411/` |
| `GCRY_TIGHT_GROW=1` (0.18) | **~95%** | **~78%** | **~0.78×** | fat-app RSS win; Kemal thr soft — `2026-08-04-085740/` |
| `-Dgcry_side_bitmap` (pre-0.12 A/B) | **~78%** | **~82%** | **~9.2×** | side mmap marks; see `bench/log/bitmap-ab/FINDINGS.txt` |

Detail tables for 0.7–0.9 cuts lived in git history / CHANGELOG; headline numbers above are the ones to cite. Fat-app (Linux): [ACIKTURKIYE.md](ACIKTURKIYE.md).

## Pauses

`Gcry.pause_stats` — ring of last 64 STW pauses: `last_ns`, `p50_ns`, `p99_ns`, `max_ns`, `total_ns`, `count`.

Default process GC = **full STW majors**. `GCRY_INCREMENTAL=1` + a dirty barrier can re-scan pages before sweep; nursery (`GCRY_NURSERY`) stays off for process HTTP unless you are measuring p99. Soft-dirty is **Linux-only**.

The one pause cliff worth knowing about is the STW root-scan lag pair, which
`GCRY_SOUND=1` zeroes: 19× at Kemal EC4 and 14.5× on a fat app, and nothing
outside those two shapes shows it. `make stw-lag-pause` (`bench/stw_lag_pause.cr`)
reproduces it in ~6 s without a server or an EC build, and gates it in CI —
[SOUND-DEFAULTS.md](SOUND-DEFAULTS.md#guarding-it).

## Secondary suite — crystal-metric (GC subset)

**Not a ship headline.** Product bar stays Kemal `/json` + [ACIKTURKIYE.md](ACIKTURKIYE.md).

Vendored [kostya/crystal-metric](https://github.com/kostya/crystal-metric) under `bench/crystal_metric/`. Same-host Boehm vs gcry **wall time**, **one fresh OS process per bench** (avoids suite-order pollution — shared-process `JsonParsePure` after `JsonGenerate` falsely looked ~20×). Filters: `FILTER=gc|core|stress|all` — see `bench/crystal_metric/README.md`. Compute-bound language benches (Mandelbrot, Nbody, …) are noise — omit from GC claims.

```sh
make bench-crystal-metric
# smoke: TRIALS=1 FILTER=Binarytrees,JsonParsePure,Threadring bash bench/run_crystal_metric_ab.sh
```

### Shared-process cut (superseded methodology)

`bench/log/linux/2026-08-03-crystal-metric-ec1/` — useful only as a cautionary tale (Pure/Primes inflated by prior benches). Prefer process-fresh cuts below.

### Process-fresh cut (cite this)

Session: `bench/log/linux/2026-08-03-crystal-metric-fresh/` (WSL2 i3-12100F, Crystal 1.21, med-of-3, `FILTER=gc`).

| Bench | speed % Boehm | wall × | Notes |
|-------|-------------:|-------:|-------|
| Brainfuck / Brainfuck2 / Matmul / JsonGenerate | **~100–112%** | ~0.9–1.0× | near parity / slight win |
| Threadring | **~97%** | ~1.03× | Channel/fiber |
| RegexDna | **~88%** | ~1.13× | |
| JsonParsePull / Serializable | **~70%** | ~1.4× | typed/pull JSON |
| Revcomp / Knuckeotide | **~58–72%** | ~1.4–1.7× | string/Hash |
| Binarytrees | **~32%** | ~3.1× | tree churn |
| JsonParsePure | **~16%** | ~6.4× | `JSON::Any` Hash forest (was ~20× shared-process) |
| Primes | **~14%** | ~7.3× | sieve alloc storm (real; not order artifact) |

Peak RSS × (median of per-bench peaks): **~0.63×**. Checksum `err` on Crystal ≥1.21 is OK for timing. Do **not** cite the upstream award total as a gcry score.

## How to record (Linux)

Same-day gcry + Boehm, both paths → update **this** file and the README Linux table. Do **not** overwrite these tables with macOS wrk — use [PERF-macos.md](PERF-macos.md).

```sh
make bench-kemal-wrk
LABEL=linux-$(date +%Y%m%d) ./bench/median_kemal_boehm.sh
LABEL=linux-$(date +%Y%m%d) ./bench/median_acikturkiye_boehm.sh
# or: GC=both COUNT=1 TRIALS=3 bash bench/run_all.sh all
# after wrk: curl …/gc-collect && read RSS
# secondary: make bench-crystal-metric
```
