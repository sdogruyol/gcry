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
| `scrub_fibers_enabled` | `false` (was `true`) | Zeroes bytes below a parked fiber's **estimated** SP, from another thread. bdwgc's `GC_clear_stack` only ever wipes below the *calling* thread's own hardware SP — a much stronger guarantee. **Now off by default** — the audit never reached the EC1 window and its RSS justification does not reproduce; see *What `scrub_fibers` costs*. The estimate is exact only because Crystal records `stack_top` before it clears the running flag; when it is not, the wipe lands on live frames and the mid-swap guard is the only thing that prevents it — measured, see *The mid-swap window*. Opt in with `GCRY_SCRUB_FIBERS=1`. |
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

Session 3 `…-2026-08-09-063211-sound-profile/` re-took it on the tip default
(scrub off) at the published methodology — 9 rounds × 30 s, interleaved,
order rotated:

| Config | % of Boehm | RSS × | pause p50 | run spread |
|--------|-----------:|------:|----------:|-----------:|
| gcry tuned | 81.8% | 0.75× | 0.59 ms | 6.14% |
| gcry sound roots | 83.0% | 0.76× | 0.59 ms | 5.98% |
| gcry sound + conservative bodies | 83.6% | 0.74× | 0.59 ms | 8.77% |

It puts sound ahead of tuned again, by +1.39% against a 6% spread — i.e. the
same unresolved reading as session 2, not a confirmation of it. Note that
"sound ahead of tuned is physically implausible" is no longer true *in
general*: since the low-water skip, `lag = 0` starts the parked-fiber scan at
the stack's low-water mark while the 256 KiB default window does not, so sound
can genuinely scan **less** than tuned. That mechanism does not apply here —
the lag knobs are inert on Kemal at EC1, where STW never sees more than two
mutator threads — but it does apply on the fat app, and there it is measured
(see *Pause composition*).

**So: there is still no valid cut that resolves what the sound profile costs
in throughput on Kemal `/json`** — three sessions, three unresolved readings.
An earlier version of this document claimed ~1pp. That figure came from the
holed profile and is retracted.

**What all three sessions agree on: RSS does not move.** 0.756/0.754/0.746×,
0.795/0.794/0.797×, and 0.75/0.76/0.74× — flat within each session, across all
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
the later pause-composition cut found those knobs costing 14.5× on this same
fat app *at EC1*, once its heap crosses ~60 MiB. The knobs are emphatically not
inert here — though the *sign* of their cost has since reversed, because the
low-water skip reaches `lag = 0` and not the 256 KiB default. See below.

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

### The lag cost was 99.95% zeros — and is now mostly gone

Everything above is **pre-fix**, and the fix says something about what those
numbers were measuring.

`lag = 0` scanned each parked fiber `guard → bottom`. A Crystal fiber stack is
8 MiB of *reserved* address space, and measured on a Kemal-shaped population,
69 parked stacks held 552 MiB of virtual stack and **284 KiB** of touched
pages — 0.05%. The regression was almost entirely minor-faulting pages that had
never been written, to read zeros out of them.

Scanning now starts at the stack's low-water mark
(`Platform.stack_low_water`), on both the parked-fiber and pthread-mapping
paths. **This is not a precision trade.** A page with neither the present nor
the swapped bit in `/proc/self/pagemap` has never been faulted, so it is zero:
`guard → bottom` and `low_water → bottom` see exactly the same words.
`mincore(2)` would have been the wrong instrument — it answers "resident", so a
written page that was later swapped out reads absent, and skipping it would drop
a root. Any failure to read pagemap falls back to the full range, so the
degradation direction is always "scan more". `GCRY_STACK_LOW_WATER=0` restores
the old behaviour for A/B.

| Kemal EC4, same run | tuned | `GCRY_SOUND=1` | `+GCRY_STACK_LOW_WATER=0` |
|---------------------|------:|---------------:|--------------------------:|
| pause | 7.1 ms | **13.0 ms (+83%)** | 147.2 ms (+1977%) |
| roots | 6.2 ms | 11.0 ms | 140.8 ms |
| post-GC RSS | — | +0.3% | +0.3% |

**147 ms → 13 ms, 11.3×**, nothing traded in RSS.
`bench/log/linux/2026-08-07-110231-root-phase/FINDINGS.md`.

Two things follow. The residual +83% is no longer a constant worst case — it
tracks how much stack was actually touched, so its distribution is wide (p5
3.4 ms, p95 19.1 ms) where the old path's was flat (IQR 0.6%). And `sound`'s p5
is now *below* `tuned`'s, because tuned's fixed 256 KiB window can itself
include untouched pages: the same skip should help the default path, which is
not done here.

### The fat-app large-heap case, re-cut — the sign reversed

`bench/log/linux/2026-08-09-071144-root-phase/` (21 paired reps, interleaved,
order rotated; confirmed by `…-062117-root-phase/` at 9 reps). Same
stratification as above, because the app is still bistable and the harness
still refuses to compare the mixed medians — IQR ran 393–1455% unstratified.

| Stratum | reps (tuned / sound) | tuned pause | `GCRY_SOUND=1` pause | tuned root work | sound root work |
|---------|---------------------:|------------:|---------------------:|----------------:|----------------:|
| small heap (~46 MiB) | 15 / 15 | 2.7 ms | 2.7 ms (**+1.7%**) | 1112 µs | 1142 µs (+2.7%) |
| large heap (~70 MiB) | 10 / 13 | 24.3 ms | **18.1 ms (−25.4%)** | 20 364 µs | **11 449 µs (−43.8%)** |

At the time, `GCRY_SOUND=1` was cheaper than the default on the shape it used to
be 1347% more expensive on. The mechanism was clear: the low-water skip applied
on the `lag = 0` path and **not** on the `lag > 0` default, so tuned still
faulted in its fixed 256 KiB window per parked fiber while sound started at the
low-water mark and skipped the untouched head.

> **Superseded.** The skip now applies on the default path too, and that
> reverses this table again — the default is the cheapest of the three. The
> rows above are kept because they are what identified the mechanism; do not
> cite them as current. See *The skip on the default path*, below.

**The 213 ms / 14.5× figure is retired.** It described the pre-low-water
collector and should not be cited for the current one.

### The skip on the default path

`fiber_stack_scan_top` gated the low-water skip on `lag == 0`. It no longer
does: the default path starts at `max(stack_top − lag, low_water)` — bounded by
the lag *and* clear of the untouched head, where `lag = 0` has only the second
protection and `lag > 0` previously had only the first.

**Kemal EC4** (`bench/log/linux/2026-08-09-104417-root-phase/`, 9 paired reps,
~2300 collections per config, single ~93 MiB heap regime so no stratification
is needed). This is the shape the change had to be proven on: `lag = 0` still
costs here, so a skip on the default path could plausibly have cost too.

| config | pause | Δ | root work | Δ | IQR |
|--------|------:|--:|----------:|--:|----:|
| `tuned` (with the skip) | **3.60 ms** | — | **3002 µs** | — | 24% |
| `tuned` + `GCRY_STACK_LOW_WATER=0` | 8.06 ms | +124.1% | 7424 µs | +147.3% | 12% |
| `GCRY_SOUND=1` | 16.39 ms | +355.8% | 15 777 µs | +425.6% | 63% |

**Pause 8.06 → 3.60 ms**, RSS flat to 0.2% across all three, `mark` and `sweep`
unchanged — the saving is entirely in `roots + stacks`, which is what a
root-scan change should look like.

**Fat app** (`…-105503-root-phase/`, 21 reps, stratified): at the ~72 MiB
regime `tuned` 10.7 ms against the old default's 28.8 ms and sound's 18.2 ms;
±2% at the ~46 MiB regime. Softer than the EC4 number — see that session's
FINDINGS for the thread-count confound.

Two things this settles and one it does not. It settles that the default path
was paying for pages nothing ever wrote, on both shapes. It settles that
`lag = 0` remains the wrong default at EC4 — the skip makes the *bounded* scan
cheap, it does not make the complete scan affordable (16.4 ms against 3.6 ms).
It does **not** touch Kemal at EC1, where `multi_mutator_threads?` is false at
2 threads and the lag branch is unreachable.

Engagement is now observable rather than inferred: `low_water_skips` and
`low_water_skipped_bytes` on `/gc-stats`, reset per collection. That matters
because the gate is `Thread` count > 2 and a real app can sit on that boundary
— the fat app reported 2 threads from one build and 3 from another.

### Guarding it

None of the three cuts above is reproducible in CI — they need a server, a fat
app, or an EC4 build. CI ran the correctness suite under `GCRY_SOUND=1` and
passed at any pause, so the 19× was invisible to it.

`bench/stw_lag_pause.cr` (`make stw-lag-pause`) closes that. The expensive path
does not need EC: `stw_multi_stack_lag = 0` makes `fiber_stack_scan_top` return
`guard` for every parked fiber under multi-mutator STW, so all it takes is >2
live OS threads and a parked fiber population. 32 fibers reproduced **15×** in
under 6 s on a stock runner, against the 19× measured at EC4.

Since the low-water skip landed, that ratio is **1.03×** — which is what the
guard was designed for. It bounds the penalty from above rather than asserting a
number, so it keeps passing as the cost falls, and it still fails if the full
scan comes back. `GCRY_STACK_LOW_WATER=0` reproduces the old 13.9× on demand.

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

**Resolved by defaulting it off.** The audit below closes the foreign-thread
half of the question and explicitly leaves the other half open. A knob that (a)
cannot show a benefit, (b) cannot show a cost, and (c) is the only default-on
heuristic that *writes* into memory the collector does not own does not get to
keep its default while the correctness question is open — the burden runs the
other way. It is now `false` on both platforms; `GCRY_SCRUB_FIBERS=1` opts back
in, and `bench/root_phase_ab.sh` / `bench/scrub_audit.cr` still drive it.

#### The flip on Darwin — verified, belatedly

"Both platforms" was a code change on both platforms and a *verification* on
one. macOS CI runs `crystal spec`, `process_spec` and a few samples; the 18
fuzz/property/soak targets the flip was cleared against on Linux have no macOS
gate at all. Closed on a Darwin host (Apple M2 Pro, Darwin 25.5.0 arm64, Crystal
1.21.0, 2026-08-10):

| target | default (scrub off) | `GCRY_SCRUB_FIBERS=1` |
|--------|--------------------|------------------------|
| `pattern-fuzz` (200 phases × 5000 objs) | PASS, 520 s | PASS, 516 s |
| `stw-mt-property-test` (200 iters, workers 2,4) | PASS | — |
| `thread-storm` | PASS | — |
| `soak-smoke` | PASS | — |
| `oom-test` | PASS | — |
| `finalizer-complex` | PASS | — |

Nothing broke either way, so there was nothing to attribute to the flip. The
`GCRY_SCRUB_FIBERS=1` column is only worth reading because the knob was shown to
engage in these binaries first — a `-Dgc_none` probe reports `runs=0 bytes=0`
unset against `runs=10 bytes=1171456` set. Without that, a green under the old
default would only have proved the env var was ignored, which is the failure
mode `scrub_audit` was rewritten to avoid.

### Auditing the scrub — what it now answers

`bench/scrub_audit.cr` (`GCRY_SCRUB_AUDIT=1`) moves the charge against
`scrub_fibers` from argument to measurement: per collection it counts the parked
fibers scrubbed while a thread's SP was still on them, and how often the wipe
reached at or above that SP — over live frames.

The probe used to be structurally blind (see the history below). It now reads
foreign thread SPs from `/proc/self/task/<tid>/syscall`
(`Platform.audit_snapshot_sps`), which needs no signal and no cooperation, so it
can see signal-exempt threads. The tid table is refreshed outside STW; the read
path uses raw `open`/`read` into stack buffers, because allocating while the
world is stopped can deadlock on a lock a suspended thread holds.

**Result — the wipe never reached live frames, and not for the stated reason:**

| Shape | scrub runs | foreign SP on a *parked* fiber | reached live frames | foreign SP on a *running* fiber |
|-------|-----------:|-------------------------------:|--------------------:|--------------------------------:|
| EC1 | 200 | 0 | 0 | 200 |
| EC4, guard on | 300 | 0 | 0 | 1170 |
| EC4, guard off (control) | 300 | 0 | 0 | 1167 |

Every foreign SP sighting — 200 of 200 collections at EC1, 1170 at EC4 — was on
a fiber that still reported `running?`, so it was excluded before any scrub
logic ran. The Monitor's stack is protected by the `running?` check, not by the
foreign-SP machinery. At EC1 that machinery is not even applied, so the
exemption's justification —

> EC1: SYSMON is suspended on its fiber during our STW — foreign-SP skip would
> never scrub it. Only skip under Parallel.

— does not describe what happens. SYSMON's fiber is *running*, not parked-with-a-
thread-on-it. The exemption is harmless; its rationale was wrong.

The Parallel guard now has a real negative rather than a blind one: with the
mid-swap skip deliberately off, 300 collections produced 1167 SP sightings and
**none** in the window the guard exists for (SP on a stack whose fiber already
reports parked). That bounds the window's rate on this workload; it does not
make it zero, and it is not a licence to remove the guard.

What this does **not** settle: whether a pointer can live only in the wiped
region in some shape not exercised here. It settles that the wipe is not
landing on a thread's live frames in the two shapes gcry actually ships.

### The other half — how far the window sits from live data

That remaining question cannot be answered the same way, and the reason is
structural: for a *genuinely parked* fiber there is no foreign SP to compare
against, because `@context.stack_top` is the only record of where its stack
ends. Nothing independent exists to check the window against.

So `bench/scrub_margin.cr` (`make scrub-margin`) does not check it. It finds the
boundary instead. `GCRY_SCRUB_OVERSHOOT=N` — research only, default 0 — slides
the wipe window *up* by N bytes, over `stack_top` and into frames that must be
live. Sweeping N in child processes (most of the ladder is expected to die) buys
two things at once: a **positive control**, so a clean run at 0 means something,
and the **margin**. 64 fibers × 40 park/collect rounds, x86_64:

| overshoot | verdict |
|----------:|---------|
| 0 … 56 bytes | clean |
| **60 bytes** | **CORRUPT (SEGV)** |
| 64 … 4096 bytes | CORRUPT |

**The margin is zero.** 56 bytes is not an arbitrary boundary: on x86_64-sysv
`swapcontext` saves six callee-saved registers plus the return address *above*
the SP it records, i.e. seven words. The wipe window ends exactly where live
data begins.

That is the answer to the open half, and it is not the reassuring one. The
scrub is not clearing a comfortable dead zone below live frames — it is
clearing right up against them, with nothing in hand. Its correctness rests
entirely on `@context.stack_top` being exact: every collection, on every
platform, through any future change to how Crystal spills registers in
`swapcontext`. A mid-swap window, a different ABI, or one extra pushed register
lands on live data directly.

This is why the knob is opt-in. It is not that a defect was found at the
shipping window — none was, across the whole ladder at 0. It is that the design
has no tolerance, and the argument for keeping it was already a wash on every
other axis.

Still genuinely open: the positive control shows this workload *can* detect
corruption, which is what the first audit lacked. It does not prove the shipping
window is safe under shapes this workload does not produce — a mid-swap suspend
being the obvious one, and the one no harness here has managed to hit.

#### The same measurement on aarch64 — and what it corrects

"A different ABI lands on live data directly" was the argument. It is now a
measurement: the same ladder, refined around the two numbers this ABI can
distinguish, on a Darwin host (Apple M2 Pro, Darwin 25.5.0 arm64, Crystal
1.21.0, 2026-08-10).

| overshoot | verdict |
|----------:|---------|
| 0 … 64 bytes | clean |
| **72 bytes** | **CORRUPT (exit 11, `address 0x0`)** |
| 80 … 4096 bytes | CORRUPT |

Deterministic: 3/3 reps per rung at 48/56/64/72/80 on an idle machine. Every
failing rung dies at **address 0x0** — a return through a zeroed `lr`, which
makes this a confirmation of the mechanism rather than an unexplained crash.
(Darwin reports these as `exit 11` rather than a signal death, because Crystal's
own SIGSEGV handler prints a backtrace and exits 11 itself.)

**The number this was expected to land on was 176, and that is falsified.**
`stack_maps.cr` records `PARKED_AARCH64_SPILL_WORDS = 22` — Crystal's aarch64
`swapcontext` spills 22 words, 176 bytes, and the caller's SP on return is
`stack_top + 176`. The constant is not wrong; the step from it to a margin was.
It answers where the caller's frame starts, not which word has to survive.

What the two platforms agree on is the *rule*, which now has two instances
instead of one:

> The wipe window ends immediately below the **saved return address**.

x86_64 puts the return address at `stack_top + 56`, as the last word of its
spill block, so "end of the block" and "first word that must survive" name the
same byte — 56 could be read either way, and was. aarch64 separates them: its
layout is `[0..7]` d15…d8, `[8]` **x30/lr**, `[9]` x29/fp, `[10..19]` x28…x19,
`[20..21]` x0,x1, so the return address is the *ninth* word of twenty-two. The
boundary follows `lr` to 64 and ignores 176.

So aarch64 reaches the same conclusion, slightly sharper. The 64 bytes below the
boundary are not margin the design reserved: they are eight callee-saved **FP**
registers, and they read clean only because this workload has no reason to hold
a pointer in one. A workload keeping a `Float64` live across a yield has less
room than the table suggests, and the shipping window still has none. What the
scrub depends on is now two things, not one: `@context.stack_top` being exact,
*and* where the platform's `swapcontext` happens to spill the return address.

### The mid-swap window — why it cannot be hunted, and what the guard is worth

That last shape is now answered, in two parts: reading the ABI says why no
harness ever hit it, and `bench/scrub_midswap.cr` (`make scrub-midswap`) measures
what the guard against it is worth.

**Why it cannot be hunted.** Crystal's context switch fixes the order, and all
five backends (`x86_64-sysv`, `x86_64-microsoft`, `aarch64-generic`,
`aarch64-microsoft`, `arm`) do the same thing:

```
stack_top = sp          # exact — every saved register sits at an address >= sp
(dmb ish on aarch64)    # the register stores are ordered before the flag
current.resumable = 1   # only now does running? go false, i.e. "parked"
new.resumable = 0       # the resumed fiber is marked running...
sp = new.stack_top      # ...before any SP lands on its stack
```

So the window where a fiber reports parked while a thread's SP is still on its
stack is real, and a few instructions wide — but in it `stack_top == sp` exactly,
and the wipe covers `[stack_top - wipe, stack_top)`, strictly below that SP. It
cannot reach live frames. This is the same boundary the overshoot ladder found
from the other side: the wipe ends exactly where the saved registers begin.

The *dangerous* shape is the opposite one — a fiber reporting parked while a
thread runs **deeper** than its recorded `stack_top`, so the window sits above
the SP, over live frames. Two orderings rule it out. On resume, the fiber is
marked running *before* the SP moves onto its stack (last two lines). On
teardown, `Fiber#run` calls `Fiber.inactive` — delisting the fiber from
`Fiber.unsafe_each` — before the stack is handed to the pool, so the scrub never
sees a fiber whose stack now belongs to someone else.

That is an argument from source, not a measurement, and it is pinned to Crystal
at `c361ac6e7`. It is exactly the kind of thing that changes silently.

**What the guard is worth.** `scrub_skip_foreign_sp` exists for that state, and
the audit could never observe it doing anything — 0 sightings over 300
collections, 0 over 3000. So manufacture it: `Heap#scrub_force_parked`
(research only, default nil) makes the scrub treat one nominated fiber as parked
while a thread spins six frames below its recorded `stack_top`.

| scenario | verdict | overlaps | `midswap_skips` | canaries |
|----------|---------|---------:|----------------:|----------|
| `stale-off` — guard off | **SEGV at 0x0** | **1 of 1** | 0 | destroyed |
| `stale-on` — guard on | clean | 0 | **1** | intact |
| `real` — no manufacturing (control) | clean | 0 | 0 | intact |

30 runs, all three rows identical. The guard-off child dies because the wipe
zeroed a return address in the frames it was standing on; that is the first time
`fiber_scrub_live_frame_overlaps` has ever moved, so the counter is now known to
work rather than assumed to. The guard-on row is the first observation of the
guard doing its job, and it is readable only because the skip is now counted —
`fiber_scrub_midswap_skips` on `/gc-stats`. Before that counter, a guarded run
reported `overlaps == 0` whether the guard saved something or had nothing to do.

Both directions of the gate were broken on purpose and observed to fail:
deleting the guard's `next` turns `stale-on` red (and note it still counts the
skip — so asserting on the counter alone would have been a false green, the
assertion pair is skip *and* survival); disabling the scrub turns `stale-off`
green and the tool then refuses the run for having no positive control.

**What this does not license.** It does not show the genuine window occurs — the
`real` row is a control, not a rate, and the spinner never yields so it cannot
produce the window at all. `bench/scrub_audit.cr`'s 0-of-300 and 0-of-3000
remain the only bound on that. What it settles is the conditional: *if*
`stack_top` is ever stale while a thread is on the stack, the wipe lands on live
frames and the process dies, and the guard is what stands between those two
outcomes. The scrub's correctness rests on the ordering above holding, on every
platform, through any future change to how Crystal spills — which is the same
conclusion the zero margin reached, now with the guard's value measured instead
of argued.

<details>
<summary>Why this took a second probe (kept — the failure mode is instructive)</summary>

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

Both runs therefore exited **non-zero and INCONCLUSIVE** rather than printing a
pass. That was the point of the tool as it stood: an audit whose green is
reachable without observing anything is worse than no audit, because it would
have closed this question with a number that meant nothing.

The fix was not to look harder at the signal path but to stop depending on it —
`/proc` reports a blocked thread's SP without asking the thread for anything.
The second thing that had to change was the *question*: counting only parked
fibers made a zero unreadable, because it could not distinguish "no thread's
stack was ever in range" from "the thread's fiber was excluded earlier for an
unrelated reason". Counting the running-fiber sightings separated those, and
the answer turned out to be entirely the second.

</details>

### What this does and does not license

| Claim | Supported? |
|-------|-----------|
| "Sound roots cost nothing in RSS on Kemal at EC1" | Yes — two sessions, flat to three digits |
| "Sound roots cost ~1pp of throughput" | **No — retracted.** Measured against a holed profile; the re-cut cannot resolve it |
| "Sound roots are free in throughput" | **No** — unresolved is not free |
| "The heuristics should be off by default" | **No** — one workload, one host, EC1 only |
| "Sound roots cost ~nothing in pause on Kemal at EC1" | Yes — +0.1% pause, 2873 collections at 1–7% IQR |
| "Sound roots cost ~nothing in throughput on Kemal at EC1" | Yes — +0.82% at 1.7σ over 9 paired rounds, i.e. under ~1% either way |
| "Parked-fiber scrub earns its default" | **No — and it no longer has one.** Its RSS justification does not reproduce, the throughput claim is retracted, and the correctness question is open, so it now defaults `false` (see *What scrub_fibers costs*) |
| "Disabling parked-fiber scrub gains 1.29% throughput" | **No — retracted.** A second session measured −1.22%; the effect is ~0.01% of wall time and unresolvable by throughput |
| "Sound roots are free on the fat app" | **No, and the 14.5× / 213 ms is retired.** Pre-low-water it was 1347%; with the skip on `lag = 0` only, sound briefly came out *cheaper* than the default; with the skip on the default path too, the default is cheapest again — fat app ~72 MiB: tuned 10.7 ms, sound 18.2 ms |
| "The lag-0 scan has to read the whole stack" | **No.** 0.05% of a fiber stack is ever written; the rest is provably zero and is now skipped — EC4 147 ms → 13 ms |
| "Sound roots are free under Parallel EC" | **No — measured, and false.** 19× pause at EC4 |
| "The STW lag knobs are inert at parallelism 1" | **No — withdrawn.** True of Kemal, false of the fat app at EC1 |
| "The cost is spread across the heuristics" | **No** — it is the two STW lag knobs, on every workload measured |
| "Turning fiber scrub off costs throughput" | **No** — but neither does it gain any; it is a net saving in *root work* (−9.1% on Kemal at EC1) worth ~0.01% of wall time |
| "Fiber scrub buys RSS on the fat app" | **Unreproduced.** The 3.00× → 2.65× that put it on default does not appear at n=9; the measurement is dominated by a bistable heap regime |
| "The scrub margin is the size of the `swapcontext` spill block" | **No — falsified on aarch64.** It is the offset of the saved return address: 56 on x86_64 (last word of the block), 64 on aarch64 (ninth word of twenty-two, so the block's 176 is not the boundary) |
| "The 56/64 bytes below the boundary are margin" | **No.** They are spill slots the harness workload has no reason to hold a pointer in — GPRs on x86_64, FP registers on aarch64. The shipping window's margin is still zero |

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

The tuned defaults remain the shipping default — but the reason has narrowed,
and the argument above is **partly superseded**. Flipping — shipping sound and
demoting the heuristics to opt-in — was the open question earlier drafts of
this document existed to settle, and on the pre-low-water evidence it was not
defensible in any shape: a 19× pause under the Parallel EC opt-in, 14.5× on an
ordinary single-threaded fat app, in both cases a 100-ms-scale pause where
tuned sat at 17 ms.

Both of those numbers are stale, and so is their replacement. Kemal EC4 re-cut
147 ms → 13 ms; the fat-app case then reversed sign, with `GCRY_SOUND=1` coming
out cheaper than the default; and ungating the skip on the default path — the
fix that reversal pointed at — has now reversed it back. Current standing:

| Shape | tuned | `GCRY_SOUND=1` |
|-------|------:|---------------:|
| Kemal EC1 | 398 µs | 398 µs (+0.1%) |
| Kemal **EC4** | **3.60 ms** | 16.39 ms (+356%) |
| fat app, ~72 MiB heap | **10.7 ms** | 18.2 ms (+70%) |
| fat app, ~46 MiB heap | 2.9 ms | 3.0 ms (+6.5%) |

So the case for the tuned default is **stronger** than it was a session ago, not
weaker: the skip made the bounded scan cheap without making the complete scan
affordable, and the one shape that briefly argued for flipping no longer does.
The remaining argument for `lag = 0` is correctness, which is the argument this
document was always about — not pause, on any shape currently measured.

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
