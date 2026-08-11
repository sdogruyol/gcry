# gcry drops a live object — a regression in `75a9d25..d36effe`, exposed only by the probe compiler

**Status: reproduced on demand, isolated to a gcry commit range. No root cause.**

A fat-app re-cut lost trials to `Non-2xx=1`. The cause is memory corruption, not
a flaky demo DB. This file is the isolation; the session that first hit it is
`../2026-08-10-093443-acik-stackmap-tip/`.

## The signature — always the same object

```
ERR ... > Unknown column: user_profile_picture\0\0\0\0<
  deserializing AcikTurkiye::DB::Submission::SubmissionStruct  (DB::MappingException)
|   from array.cr:1414 in 'on_unknown_db_column'
|   from lib/db/src/db/serializable.cr:105:7 in 'read'
```

The real alias (`acikturkiye/src/models/submission.cr:146`) is
`u.profile_picture_path AS user_profile_picture_path` — **25 characters**. The
corrupted name is also **25 bytes**: `user_profile_picture` intact, then
`\0\0\0\0<` where `_path` should be.

Correct length, correct head, clobbered tail. Not a truncated read, not a
corrupted `bytesize`, not a misparse of the row description — the allocation is
intact and correctly sized and **its tail was written over in place**: four
bytes of zeroed storage plus one byte (`0x3C`) of a later write. That is a live
object whose memory was reissued.

It is always this same string, never another, across every failing trial in four
sessions. That points at one allocation site rather than at general heap damage.

## Arms — the 2×2 that isolates it

Detection is NUL bytes in the server log (nothing in a clean run of this app
emits one), cross-checked against `wrk`'s `Non-2xx`. The two agree trial for
trial, in every session.

| arm | GC | compiler | EC flags | corrupt |
|-----|----|----------|----------|--------:|
| `boehm` | Boehm | asdf 1.21.0 | no | 0/3 |
| `boehmec` | Boehm | probe 1.22.0-dev `4a965f423` | **yes** | 0/3 |
| `sys` | **gcry** | asdf 1.21.0 | no | **0/5** |
| `run_all.sh` gcry | **gcry** | asdf 1.21.0 | no | **0/18** |
| `tipnoec` | **gcry** | probe 1.22.0-dev | no | **2/5** |
| `base` | **gcry** | probe 1.22.0-dev | **yes** | **5/6** |

Both factors are necessary and neither is sufficient: Boehm on the probe
compiler is clean, gcry on 1.21.0 is clean across 23 trials, gcry on the probe
compiler corrupts with or without the EC flags. `sys` and `tipnoec` run in *this*
harness with the same load and the same detection, differing only in compiler,
so the harness is not the explanation either.

## It is a gcry regression, not a compiler incompatibility

`../2026-08-04-acik-stackmap/` built `base` with the **same probe compiler**
(`4a965f423`) and is **clean — 0 NULs across all 15 trials**, signature absent.
That session was gcry `75a9d25`; these are `d36effe`.

So the probe compiler is the *exposure condition*, not the change. Something in
gcry between **`75a9d25`** and **`d36effe`** introduced this, and only the code
the probe compiler generates reveals it. That range is bisectable with this
harness — 5 trials at 30 s per candidate, ~8 min per step.

## What has been ruled out

* **Both precision axes.** `GCRY_SOUND=1` (verified `root_soundness: sound`,
  lags 0, gate off, blacklist off) corrupts 2/5 —
  `../2026-08-11-081725-acik-ec-sound/`. Adding `GCRY_DISABLE_LAYOUT=1`
  (verified `layout_precise: false`, `layout_precise_scans: 0`) corrupts 4/5 —
  `../2026-08-11-082032-acik-ec-nolayout/`. The most conservative configuration
  gcry offers still drops the object, so this is not something the collector
  decided to skip.
* **The parked-fiber scrub, in both directions.** Off by default in every arm
  above. Forced **on** (verified `runs=710`, 306 MB wiped) it corrupts **4/5** —
  `../2026-08-11-083653-acik-scrubon/` — with more damage per trial (`non2xx` 1,
  2, 2, 17 against a uniform 1 elsewhere; 16 NULs in two trials, i.e. two
  separate corruptions). Consistent with the mechanism: scrub *writes*, so it can
  only add risk here. It does not mask the bug and did not cause it.
* **Thread count.** Measured under load with `top -stats th`: 2 OS threads in
  both the `base` and `run_all.sh` gcry builds, and `CRYSTAL_WORKERS=1` changes
  neither. Parallelism is not the variable.

## Scope corrections, kept on purpose

This was mis-scoped three times before it was pinned, each reading defensible on
the evidence available and each falsified by the next arm:

1. *"multi-threaded EC"* — killed by the thread count: there is no extra thread.
2. *"the `-Dpreview_mt -Dexecution_context` runtime"* — killed by `tipnoec`,
   which corrupts without the EC flags.
3. *"gcry + Crystal 1.22.0-dev"* — killed by the 2026-08-04 session, which is
   that pair, clean, at an older gcry.

Anyone extending this should expect the fourth reading to be wrong too until a
bisect names a commit.

## Not established

* **No root cause.** "A live object was reused" is the observation.
* **Linux.** Never tried.
* **No link to the 2026-08-08 production SIGSEGV.** Same class, and prod runs
  this app on gcry, so it is worth asking which compiler and which gcry commit
  prod builds from. Nothing here connects them, and that diagnosis remains an
  unproven bet.

## Reproducing

```sh
ACIK_STACKMAP_OUT=bench/log/macos/$(date +%Y-%m-%d-%H%M%S)-acik-repro \
VARIANTS="sys tipnoec" TRIALS=5 WRK_DURATION=30 \
  bash bench/acik_stackmap_ab.sh
```

`sys` is the clean control and `tipnoec` the reproducer; they differ only in the
compiler. `REQUIRE_2XX=1` already rules a corrupted trial invalid for the RSS
gate, which is why this surfaced as a failed benchmark rather than a silently
wrong number.
