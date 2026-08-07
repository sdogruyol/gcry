# Sound defaults — what gcry costs when it isn't allowed to guess

gcry's process defaults include a class of knobs that trade **root-scan
completeness** for throughput or RSS. Each one can decline to mark a pointer
that is genuinely live. Each is individually argued at its definition site, and
each earned its default on a benchmark.

That is a defensible engineering position. It is *not* a position you can
measure from: a throughput number produced with those knobs armed answers
"how fast is gcry when it may drop a root?", which is not the question anyone
asking about a default GC is actually asking.

`GCRY_SOUND=1` turns the whole class off in one flag so the honest number can
be measured and published. This document is that number.

```sh
GCRY_SOUND=1 ./your-app
```

---

## The knobs, and what each one can lose

| Knob | Default | What it can drop |
|------|---------|------------------|
| `allow_interior_pointers` | `false` | Two things at once. **(a) Ambient roots:** LLVM may keep only an **interior** pointer live in a register or spill slot while the base is dead — a strength-reduced loop over a `String`/`Array` buffer is the canonical shape. bdwgc as Crystal links it treats interiors as valid, so base-only ambient roots are strictly less conservative than what Crystal's codegen has ever been validated against. **(b) Heap edges out of raw buffers:** `scan_object`'s conservative fallback marks untyped allocations base-only, so an interior pointer stored *inside* a `Slice` or raw buffer is dropped too. That path also keys off `type_id_plausible?`, which made the type_id heuristic steer marking even with `type_id_gate` off — this flag switches both off together. |
| `scan_unaligned_candidates` | `false` | The same, for `str.to_unsafe + 3`. A misaligned interior is a root bdwgc resolves via `GC_base`; gcry drops it before `find_block` ever runs. |
| `type_id_gate` | `true` (static roots) | Rejects a static root whose payload's first `Int32` is `<= 0` or `> 1_000_000`. That is a heuristic applied to a real reference. The collector already counts when it was wrong: `type_id_root_false_negatives`. |
| `stw_multi_stack_lag` | `256 KiB` | Bounds how far below a parked fiber's `stack_top` another thread's stack is scanned. A live pointer deeper than the lag is never seen. `0` means full `guard → bottom`. |
| `stw_multi_pthread_lag` | `256 KiB` | Same, for the OS thread mapping when SP sits on a pool fiber. |
| `scrub_fibers_enabled` | `true` | Zeroes bytes below a parked fiber's **estimated** SP, from another thread. bdwgc's `GC_clear_stack` only ever wipes below the *calling* thread's own hardware SP — a much stronger guarantee. |
| `blacklist_enabled` | `true` | Steers allocation away from pages the type_id gate called false. With the gate off nothing feeds it; the profile turns it off so `sound` has exactly one meaning. |
| `scan_static_roots` | `true` (process) | A heap that never walks BSS/data misses roots by construction. `GCRY_DISABLE_STATIC_ROOTS=1` turns it off and will crash a real program — it is in the profile so the label can never report `sound` while it is off. Library heaps default it *off*, so a library heap must opt in before it can report sound roots. |

`GCRY_SOUND=1` sets all of these to their complete-scan values. It is applied
**before** the individual `GCRY_*` knobs, so an explicit knob still wins:

```sh
GCRY_SOUND=1 GCRY_SCRUB_FIBERS=1 ./app   # sound, except scrub is back on
```

### The second axis: object-body scan precision

`Gcry::Layout` keys precise field offsets off the payload's first `Int32`. A
raw buffer whose first word happens to collide with a registered type id has
produced real use-after-frees before (see the `size_match` and
"leaf + pointer-shaped header" guards in `collect_mark.cr#scan_object`, both
added after a crash). That is a *different* risk from root completeness — it is
about how an object's body is scanned once it is already known live.

`GCRY_SOUND` deliberately does **not** touch it, so the two costs stay
attributable. Measure it separately:

```sh
GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1 ./app   # fully conservative
```

Note that under `GCRY_SOUND` the `type_id_plausible?` heuristic no longer
influences liveness *at all*: the ambient path is ungated (`type_id_gate`) and
the raw-buffer heap-edge path is ungated (`allow_interior_pointers`). It
survives only in `Gcry::Layout` entry lookup — the body-scan axis above — and
in the `type_id_root_false_negatives` diagnostic counter.

### The third axis: barriers

Generational (`GCRY_NURSERY`) and incremental (`GCRY_INCREMENTAL`) collection
make liveness depend on the old→young / dirty-page remembered set. Soft-dirty
has measured false-negatives — the nursery note in `gc_override.cr` cites
"Kemal Hash key UAF / SEGV at 0x0..0x11" under WSL. Complete roots do not save
you if the barrier misses a write.

Both are off by default, and `GCRY_SOUND` sets them off explicitly so the
profile does not depend on that default holding. If you turn one back on, the
label says so rather than reporting a clean bill of health:

| Config | `soundness` | `root_soundness` | `barrier_soundness` |
|--------|-------------|------------------|---------------------|
| defaults | `tuned` | `tuned` | `sound` |
| `GCRY_SOUND=1` | **`sound`** | `sound` | `sound` |
| `GCRY_SOUND=1 GCRY_NURSERY=1` | `sound-roots-only` | `sound` | `tuned` |
| `GCRY_SOUND=1 GCRY_INCREMENTAL=1` | `sound-roots-only` | `sound` | `tuned` |
| `GCRY_NURSERY=1` | `tuned` | `tuned` | `tuned` |

`soundness` is the label a correctness claim should cite. The per-axis fields
say *which* assumption is in play when it is not `sound`.

### What the label still does not cover

**Body-scan precision** (`Gcry::Layout`) — see the axis above. It is left out
deliberately so its cost stays attributable, not because it is risk-free. A
configuration with no caveat on any axis is
`GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1` — the "sound + conservative bodies" row
in the numbers below.

---

## Verifying the profile applied

Don't trust that the env var took. `/gc-stats` reports the *live field values*
plus a derived label:

```json
{
  "soundness": "sound",
  "root_soundness": "sound",
  "barrier_soundness": "sound",
  "allow_interior_pointers": true,
  "scan_unaligned_candidates": true,
  "scan_static_roots": true,
  "type_id_gate": false,
  "stw_multi_stack_lag": 0,
  "scrub_fibers_enabled": false,
  "blacklist_enabled": false,
  "nursery_enabled": false,
  "incremental_auto": false,
  "layout_precise": true
}
```

In-process: `Gcry.sound?` / `Gcry.soundness`, with `Gcry.sound_roots?` and
`Gcry.sound_barriers?` for the individual axes. All derive from the heap
fields, so they report what the collector *is*, not what an env var asked for.
`bench/sound_profile_ab.sh` fails the run if a config labelled `sound` reports
otherwise, and `samples/sound_profile.cr` fails CI if a knob on either axis is
added later and forgotten in `apply_sound_profile`.

---

## Numbers

Host for the two throughput cuts below: WSL2 x86_64 (i3-12100F), Crystal
1.21.0, `--release`, EC parallelism 1. The pause-composition cuts that follow
them ran on a 9950X and state their own shape. Every `sound` row is confirmed
applied from the run's own `/gc-stats` `root_soundness`, not assumed from the
env var.

### Kemal `/json` — throughput unresolved, RSS flat

`wrk -c 100 -d 20`, median with min/max discarded, then `/gc-collect` and
post-GC `VmRSS`. Two sessions:

| Config | session 1 (5 runs) | session 2 (7 runs) | RSS × s1 | RSS × s2 |
|--------|-------------------:|-------------------:|---------:|---------:|
| gcry tuned | 84.9% | 78.3% | 0.756× | 0.795× |
| gcry sound roots | *(invalid)* | 81.0% | *(invalid)* | 0.794× |
| gcry sound + conservative bodies | *(invalid)* | 84.4% | *(invalid)* | 0.797× |

Session 1 `bench/log/linux/2026-08-06-042555-sound-profile/` had tight spreads
(0.73–3.96%) but its **sound rows are invalid**: they were measured before
`allow_interior_pointers` covered raw-buffer heap edges, so they under-priced
sound. Session 2 `…-052109-sound-profile/` is post-fix but ran on a busier
host — spreads 5.1–10.5%, wider than the gaps being measured. It even puts
sound *ahead* of tuned (81.0% vs 78.3%), which is not physically plausible
since sound does strictly more work.

**So: there is currently no valid cut that resolves what the sound profile
costs in throughput on Kemal `/json`.** An earlier version of this document
claimed ~1pp. That figure came from the holed profile and is retracted.

**What both sessions agree on: RSS does not move.** 0.756/0.754/0.746× and
0.795/0.794/0.797× — flat to three digits within each session, across all
three configs. Post-GC RSS is a far lower-variance measurement here than wrk
throughput, and it is the one claim the data supports.

That is a real negative result, not a null one: closing the raw-buffer hole
made sound retain strictly *more*, and post-GC RSS still did not move. On this
workload those interior edges are either rare, or they resolve to objects that
were already reachable another way.

### acikturkiye (fat app) — **inconclusive**

`wrk -c 100 -d 20` on `/api/v1/`, `TRIALS=3` median, two sessions with Boehm
re-measured in each. Sessions: `bench/log/linux/2026-08-06-043527/` (tuned),
`…-044017/` (sound). Write-up:
`bench/log/linux/2026-08-06-acik-sound-profile/FINDINGS.md`.

| Config | % of Boehm | RSS × | pause p50 | pause p99 |
|--------|-----------:|------:|----------:|----------:|
| tuned | 99.0% | 1.21× | 2.90 ms | 19.35 ms |
| sound | 90.4% | 1.04× | 2.88 ms | 15.66 ms |

**Do not quote these.** Per-trial spread swamps the difference: tuned's
throughput band (91.7–120.3%) contains sound's entire band (88.4–96.5%), the
RSS bands overlap, and p99 has a 3–4× outlier trial in *each* config in
opposite directions. Boehm itself moved 102 → 141 req/s across three trials.
`TRIALS=9`+ on a quiet host is needed before the fat app says anything.

This run also reported `phase_stacks` at 0.02–0.54 ms in every trial and
concluded from it that the STW lag knobs are "inert at parallelism 1".
**That conclusion is withdrawn.** It generalised a Kemal-shaped observation:
the later pause-composition cut finds those knobs costing 14.5× on this same
fat app *at EC1*, once its heap crosses ~60 MiB. See below.

### Pause composition — where the profile actually spends

The throughput channel could not answer this at the time these cuts were taken.
On a 9950X/WSL2 box, *one server process with no restart and no config change*
appeared to vary 40,500–51,646 req/s across 8 consecutive 10 s passes — 27%
spread, at 99–100% idle.

Much of that was the harness: WSL2 steps `CLOCK_REALTIME` backwards ~1.6 s
every ~32 s and wrk derived its duration from it, inflating any pass that
caught a step by ~19%. Timing with `CLOCK_MONOTONIC` and redoing stepped passes
cuts the apparent spread to 4–7% and restores the physically correct ordering
(`bench/log/linux/2026-08-06-112252-sound-profile/`). The residual is real but
unattributed, and the gap being measured is still smaller than it.

Either way the collector is the better instrument for *attribution*, and it is
the one these cuts use — it also has the property that the clock bug never
touched it, since the collector timestamps its phases with `monotonic_ns`. `GCRY_TRACE=1` emits one `collect_end` record
per collection with a full phase breakdown, giving ~370 samples per config at
1–7% IQR. `bench/root_phase_ab.sh`. Basis is `roots + scrub + stacks`, because
`roots_ns` excludes scrub (itself a knob) and `stacks_ns` is a separate
additive phase, not a sub-timing of roots.

**EC1** (`bench/log/linux/2026-08-06-081512-root-phase/`, 2873 collections):
the profile is effectively free — **+1.3% root work, +0.1% pause**, ~1.9 µs on
a 398 µs pause. Per knob, against tuned:

| Knob | Δ work | Note |
|------|-------:|------|
| `GCRY_UNALIGNED_CANDIDATES=1` | +4.3% | largest single cost |
| `GCRY_DISABLE_BLACKLIST=1` | +2.4% | a real cost, not free |
| `GCRY_STW_*_LAG=0` | +1.1% | inert at EC1 — see below |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | +0.2% | |
| `GCRY_INTERIOR=1` | −0.1% | |
| `GCRY_DISABLE_SCRUB_FIBERS=1` | **−1.7%** | **pays for itself** (re-cut: −9.1%, below) |

Scrub zeroes the words below a parked fiber's estimated SP, and those zeros are
then cheap to reject during the root scan. Dropping it makes root scanning
~11 µs more expensive but removes a 14 µs phase, so the collection comes out
ahead. That saving is most of why the whole profile lands at +1.3% and not at
the +7.9% its cost knobs sum to.

**EC4** (`…-085309-root-phase/` and the knob split `…-090503-root-phase/`,
`-Dpreview_mt -Dexecution_context`, `EC_PARALLELISM=4`): the same profile is a
**19× pause regression — 7.2 ms → 141.7 ms per collection (+1866%)**.

All of it is the STW lag knobs. Zeroing them alone reproduces the entire
profile to within the measurement's spread (+1866.3% vs +1866.5%); the other
five heuristics together stay under 1.5%. Split:

| Knob | Δ pause | Lands in |
|------|--------:|----------|
| `GCRY_STW_STACK_LAG=0` | **+1802%** | `roots_ns`, 6.4 ms → 137 ms |
| `GCRY_STW_PTHREAD_LAG=0` | **+64%** | `stacks_ns`, 304 µs → 4.7 ms |

The two are additive and act on different phases, so they are two pieces of
work, not two dials on one mechanism. This is the cost the lag knobs were
introduced to prevent (EC4 `phase_roots` ~100 ms/collect); `GCRY_SOUND=1`
zeroes them and it returns.

**acikturkiye (fat app), EC1** (`…-100611-root-phase/`, 2709 collections):
the same knobs again, and the reason the EC1 Kemal number must not be
generalised.

This app has two collection regimes — heap ~43 MiB and heap ≥55 MiB — whose
root-scan cost differs 15×, and the transition is driven by the app's growth,
not the config. Medians over the mixture are meaningless (they make sound look
*cheaper* than tuned); these are stratified, and stable across reps:

| Stratum | tuned | `GCRY_SOUND=1` | `GCRY_STW_*_LAG=0` | other five |
|---------|------:|---------------:|-------------------:|-----------:|
| small heap (~43 MiB) | 1039 µs | 1042 µs (+0%) | 1002 µs (−4%) | ±7% |
| large heap (≥55 MiB) | 14580 µs | **210970 µs (+1347%)** | **210504 µs (+1344%)** | ±6% |

The large-heap pause is **213 ms against tuned's 17 ms**.

So the three cuts tell one story. The five root-completeness heuristics are
cheap everywhere measured. The STW lag knobs are the entire cost, and they bite
whenever the root scan is expensive enough to matter — many threads (Kemal EC4,
7.2 → 141.7 ms) *or* a large heap (acik EC1, 17 → 213 ms). Kemal at EC1 has
neither, which is why it reads +0.1% and why that figure describes one small
workload rather than the profile.

### Guarding it

None of the three cuts above is reproducible in CI — they need a server, a fat
app, or an EC4 build. CI ran the correctness suite under `GCRY_SOUND=1` and
passed at any pause, so the 19× was invisible to it.

`bench/stw_lag_pause.cr` (`make stw-lag-pause`) closes that. The expensive path
does not need EC: `stw_multi_stack_lag = 0` makes `fiber_stack_scan_top` return
`guard` for every parked fiber under multi-mutator STW, so all it takes is >2
live OS threads and a parked fiber population. 32 fibers reproduces **15×** in
under 6 s on a stock runner, against the 19× measured at EC4.

It asserts two things, both host-independent, so no quiet host is required:

1. **The lags the process booted with match `GCRY_SOUND`** — non-zero without
   it, zero with it. This is the one that fires if sound-by-default, or a lag
   default of 0, is reintroduced before the cheap root scan lands. An absolute
   ms budget was the obvious guard and is the wrong one: by the time it has
   enough headroom not to flake on a shared runner, it no longer separates
   30 ms from 480 ms.
2. **The lag-0 penalty is at most 30×** the tuned path. Upper bound only — if
   the root scan is ever made cheap enough that lag 0 is affordable, the ratio
   collapses toward 1 and this must pass, not fail.

The ratio is not a constant: it falls as the fiber population shrinks, because
the fiber-count-independent part of `roots_ns` dilutes it. `--fibers` and
`--live-mb` are therefore tied to `--max-ratio`; re-measure before changing
either.

Separately, the collector now warns once on stderr the first time a collect
actually lands in the expensive shape — `stw_multi_stack_lag == 0` under
multi-mutator STW. Boot is the wrong place for that warning: `GCRY_SOUND=1`
sets lag 0 unconditionally, but the knob is inert until STW runs with more than
two mutator threads, and at Kemal EC1 the whole profile is throughput-neutral.
Warning at boot would cry wolf on the configuration that is fine.

### What `scrub_fibers` costs — and why the axis that matters is not perf

This one knob was carried as the class's exception: cheap to remove, a net gain,
and the only member that could go without settling the wider question. A second
session (`…-192859-sound-profile/`, `…-194128-root-phase/`, `…-195929-root-phase/`)
re-cut every axis. None of it survived in the form it was written.

**Throughput: retracted, and unresolvable.** The claimed +1.29% (8/9 rounds,
3.2σ) came back as **−1.22%** (3/9 rounds, 1.25σ, 95% CI −3.47%…+1.04%) — same
host, same fixed harness, sign flipped. The reason is not host noise, it is
effect size: `roots + scrub + stacks` is 223 µs of each of 131 collections per
20 s, i.e. **0.146% of wall time**, and the knob moves 9.1% of that — **0.013%**.
Collections stay at 131, mark moves 230→228 µs, sweep 2127→2140 µs, so there is
no indirect path either. Both readings are ~100× the largest effect the
mechanism can produce. More rounds cannot fix an effect two orders of magnitude
under the noise floor.

**Root work: real, and larger than first measured.** −9.1% on Kemal at EC1 (379
samples/config, IQR 8–11%), against the −1.7% recorded earlier. The likely
reason for the gap is that the earlier cut ran blocked, one config's reps then
the next; `bench/root_phase_ab.sh` now interleaves and rotates them, the same
fix the throughput harness needed. Real, but see the arithmetic above for what
−9.1% of root work is worth in wall time.

**RSS on Kemal: flat.** 0.76× → 0.75× of Boehm, post-GC.

**RSS on the fat app: the justification does not reproduce.** This is the axis
scrub was turned on for (`gc_override.cr`: acik 3.00× → 2.65×). At n=3 reps
scrub-off looked **+46%** worse; at n=9 the same comparison came out **−34.9%
better**. The medians are not measuring the knob: acik is bistable between a
~44 MiB and a ~72 MiB heap regime, and each rep's post-GC RSS is essentially a
coin flip between them. tuned landed in the large regime 8/9 reps, scrub-off
3/9 — Fisher exact p = 0.0498, at a threshold this document chose after seeing
the data, with the transition falling in one unexplained block of reps. That is
a lead, not a result.

Stratified by regime, which is the only like-for-like comparison available, the
knob is close to a wash on the fat app:

| Stratum | n (tuned / off) | Δwork | Δpause |
|---------|----------------:|------:|-------:|
| small heap (~44 MiB) | 184 / 449 | −4.3% | −4.0% |
| large heap (≥55 MiB) | 359 / 100 | +1.4% | +10.3% |

So the honest position on `scrub_fibers` is that **no perf axis decides it**:
its stated benefit does not reproduce, and its measured cost is too small to
matter. What is left is the reason it appears in this document at all — it
zeroes memory below a parked fiber's *estimated* SP, from another thread, where
bdwgc only ever wipes below the calling thread's own hardware SP. The decision
belongs on that question, and settling it means a test that either exhibits a
dropped live pointer or shows the wipe window cannot contain one. Benchmarking
it further is spending effort on the axis that has already answered.

### Auditing the scrub — and why it does not yet answer

`bench/scrub_audit.cr` (`GCRY_SCRUB_AUDIT=1`) exists to move the charge against
`scrub_fibers` from argument to measurement. It counts, per collection, the
parked fibers scrubbed while a suspended thread's SP was still on them, and —
the number that would decide it — how often the wipe window reached at or above
that SP, i.e. over live frames.

**It has not produced an answer, and the reason is worth recording.**

*The probe cannot see the EC1 case at all.* `Platform.thread_sp` is populated
only by the STW suspend signal handler (`install_stw_sp_capture`). The EC
Monitor (`SYSMON`) is signal-exempt — it cooperates through `@world_stopped`
instead — so its SP is never recorded, and no foreign-SP logic, guard or audit,
can observe it. Measured: 300 collections at EC1 yield **1** suspended-thread SP
observation in total. So the comment justifying the EC1 exemption —

> EC1: SYSMON is suspended on its fiber during our STW — foreign-SP skip would
> never scrub it. Only skip under Parallel.

— is right that the skip would not fire, but not for the reason it gives: the
skip *cannot* fire, because the SP it tests for is never recorded. Whatever
safety the EC1 path has rests entirely on `fiber.running?` being true for the
Monitor's fiber, which nothing here checks.

*The Parallel case has no positive control.* With the mid-swap guard deliberately
disabled (`--no-skip`, `scrub_skip_foreign_sp = false`), 3000 collections across
128 tightly-yielding fibers on 5 threads still observed **zero** foreign-SP
scrubs. The window is a fraction of the time a thread spends inside
`swapcontext`, and this workload never lands a suspend inside it. Until an
unguarded run shows the counters can move, a zero from a guarded run is not
evidence of anything.

Both runs therefore exit **non-zero and INCONCLUSIVE** rather than printing a
pass. That is the point of the tool as it stands: an audit whose green is
reachable without observing anything is worse than no audit, because it would
have closed this question with a number that meant nothing.

### What this does and does not license

| Claim | Supported? |
|-------|-----------|
| "Sound roots cost nothing in RSS on Kemal at EC1" | Yes — two sessions, flat to three digits |
| "Sound roots cost ~1pp of throughput" | **No — retracted.** Measured against a holed profile; the re-cut cannot resolve it |
| "Sound roots are free in throughput" | **No** — unresolved is not free |
| "The heuristics should be off by default" | **No** — one workload, one host, EC1 only |
| "Sound roots cost ~nothing in pause on Kemal at EC1" | Yes — +0.1% pause, 2873 collections at 1–7% IQR |
| "Sound roots cost ~nothing in throughput on Kemal at EC1" | Yes — +0.82% at 1.7σ over 9 paired rounds, i.e. under ~1% either way |
| "Parked-fiber scrub earns its default" | **Unproven either way** — its RSS justification does not reproduce, and the throughput claim is retracted (see *What scrub_fibers costs*) |
| "Disabling parked-fiber scrub gains 1.29% throughput" | **No — retracted.** A second session measured −1.22%; the effect is ~0.01% of wall time and unresolvable by throughput |
| "Sound roots are free on the fat app" | **No — measured, and false.** 14.5× on large-heap collections, a 213 ms pause |
| "Sound roots are free under Parallel EC" | **No — measured, and false.** 19× pause at EC4 |
| "The STW lag knobs are inert at parallelism 1" | **No — withdrawn.** True of Kemal, false of the fat app at EC1 |
| "The cost is spread across the heuristics" | **No** — it is the two STW lag knobs, on every workload measured |
| "Turning fiber scrub off costs throughput" | **No** — but neither does it gain any; it is a net saving in *root work* (−9.1% on Kemal at EC1) worth ~0.01% of wall time |
| "Fiber scrub buys RSS on the fat app" | **Unreproduced.** The 3.00× → 2.65× that put it on default does not appear at n=9; the measurement is dominated by a bistable heap regime |

---

## Reproducing

```sh
BENCH_RUNS=5 WRK_DURATION=20 WRK_CONNECTIONS=100 make bench-sound-profile
```

Four configurations, one host, one run: Boehm, gcry tuned, gcry sound,
gcry sound + conservative bodies. Median of 5 with min and max discarded, then
`/gc-collect` and post-GC RSS. Absolute req/s is host noise — the only portable
score is % of Boehm measured in the same job. The run aborts if a config
labelled `sound` did not actually boot sound.

Pause composition, per knob — the cut that works on a noisy host:

```sh
BENCH_REPS=3 WRK_DURATION=20 ./bench/root_phase_ab.sh

# Parallel EC. The build flags are not optional: the server raises
# parallelism with ExecutionContext.default.resize(n), which is a no-op
# without them, so an EC4 run would silently measure EC1 again. Each rep
# records the server's thread count as proof of the shape (5 at EC4, 2 at EC1).
CRYSTAL_BUILD_FLAGS="-Dpreview_mt -Dexecution_context" \
  BENCH_BIN=kemal-gcry-sound-mt EC_PARALLELISM=4 \
  BENCH_REPS=3 WRK_DURATION=20 ./bench/root_phase_ab.sh
```

Both harnesses take a config list via `BENCH_CONFIGS` (one `key [ENV=V ...]`
per line), which is how the per-knob decomposition is run — all knobs in one
job, so they share host conditions.

---

## How to read this

`sound` is the configuration a correctness claim has to cite, and the one any
conversation about becoming a language default has to start from. Publishing
the tuned number alone means quoting a price for a collector that is allowed
to lose objects.

The tuned defaults remain the shipping default, and there is now a positive
reason rather than an absence of one. Flipping — shipping sound and demoting
the heuristics to opt-in — was the open question earlier drafts of this
document existed to settle. On the evidence here it is **not defensible in this
shape**: it costs a 19× pause under the Parallel EC opt-in and 14.5× on an
ordinary single-threaded fat app once its heap grows, in both cases a
100-ms-scale pause where tuned is at 17 ms.

The rest of the class is close to free everywhere it has been measured. The
heuristics buy **no RSS at all**, **+0.1% of pause** on Kemal at EC1 and **+0%**
on the fat app's small-heap collections; their throughput value remains
**unmeasured** — not zero, unmeasured — because the host noise is three orders
of magnitude larger than the effect. For one of them (`scrub_fibers`) that gap
has since been quantified rather than merely asserted: the effect is ~0.01% of
wall time, so throughput will never resolve it, and its own RSS justification
does not reproduce either.

That reshapes the question rather than closing it. The blocker is one pair of
knobs, not a class: make root scanning cheap enough that
`stw_multi_stack_lag = 0` is affordable when the scan is large — many threads
or a big heap — and the case for sound defaults is back on the table. Until
then, "sound by default" means "sound by default except when the root scan is
big", which is exactly the case a soundness claim cannot carve out, because it
is the case where dropping a root is most likely.

See [PERF.md](PERF.md) for the full Linux methodology and the tuned-defaults
history, and [COMPARISON.md](COMPARISON.md) for the feature-level gcry↔bdwgc
matrix.
