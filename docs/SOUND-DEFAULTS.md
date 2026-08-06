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

### Known limits of the label

`root_soundness` covers **root completeness only**. It does not assert
anything about:

- **Barrier soundness.** `GCRY_SOUND=1 GCRY_NURSERY=1` or `GCRY_INCREMENTAL=1`
  still reports `sound` while running a generational/incremental path whose
  old→young remembered set depends on soft-dirty, which has measured
  false-negatives under WSL (see the nursery note in `gc_override.cr`). Both
  are off by default; do not turn them on and read `sound` as reassurance.
- **Body-scan precision.** See the layout axis above.

If you need a single configuration with neither caveat, that is
`GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1` with nursery and incremental left off —
the "sound + conservative bodies" row in the numbers below.

---

## Verifying the profile applied

Don't trust that the env var took. `/gc-stats` reports the *live field values*
plus a derived label:

```json
{
  "root_soundness": "sound",
  "allow_interior_pointers": true,
  "scan_unaligned_candidates": true,
  "type_id_gate": false,
  "stw_multi_stack_lag": 0,
  "scrub_fibers_enabled": false,
  "blacklist_enabled": false,
  "layout_precise": true
}
```

In-process: `Gcry.sound_roots?` / `Gcry.root_soundness`. Both derive from the
heap fields, so they report what the collector *is*, not what an env var asked
for. `bench/sound_profile_ab.sh` fails the run if a config labelled `sound`
reports otherwise, and `samples/sound_profile.cr` fails CI if a
root-completeness knob is added later and forgotten in `apply_sound_profile`.

---

## Numbers

Host for both cuts: WSL2 x86_64 (i3-12100F), Crystal 1.21.0, `--release`,
EC parallelism 1. Every `sound` row is confirmed applied from the run's own
`/gc-stats` `root_soundness`, not assumed from the env var.

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

One thing the run does establish: `phase_stacks` is 0.02–0.54 ms in every
trial, both configs. The STW lag knobs are **inert at parallelism 1** — which
matches their rationale (they were introduced against EC4 `phase_roots`
~100 ms/collect). The configuration most likely to show a real cost for the
sound profile is `EC_PARALLELISM=4`, and nothing here has measured it.

### What this does and does not license

| Claim | Supported? |
|-------|-----------|
| "Sound roots cost nothing in RSS on Kemal at EC1" | Yes — two sessions, flat to three digits |
| "Sound roots cost ~1pp of throughput" | **No — retracted.** Measured against a holed profile; the re-cut cannot resolve it |
| "Sound roots are free in throughput" | **No** — unresolved is not free |
| "The heuristics should be off by default" | **No** — one workload, one host, EC1 only |
| "Sound roots are free on the fat app" | **No** — not measured to a usable precision |
| "Sound roots are free under Parallel EC" | **No** — not measured at all, and this is where the lag knobs do work |

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

---

## How to read this

`sound` is the configuration a correctness claim has to cite, and the one any
conversation about becoming a language default has to start from. Publishing
the tuned number alone means quoting a price for a collector that is allowed
to lose objects.

The tuned defaults remain the shipping default — not because this data
vindicates them, but because it is not yet enough to overturn them. One
workload, one host, parallelism 1. The knobs were argued on fat-app RSS and on
EC4 root-scan cost, and neither of those has been measured to a usable
precision here.

What the data does say is narrower than the first draft of this document
claimed: on Kemal at EC1 the heuristics buy **no RSS at all**, and their
throughput value is currently **unmeasured** — not zero, unmeasured. If a quiet
re-cut, a fat-app cut at `TRIALS=9`, and an EC4 cut all show the class buying
little, the honest move is to flip: ship sound, and demote the heuristics to
opt-in tuning profiles for applications that have measured their own workload.
That is the open question this document exists to settle, not one it settles.

See [PERF.md](PERF.md) for the full Linux methodology and the tuned-defaults
history, and [COMPARISON.md](COMPARISON.md) for the feature-level gcry↔bdwgc
matrix.
