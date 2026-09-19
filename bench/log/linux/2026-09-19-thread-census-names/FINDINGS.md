# The thread census could count and not name, and one of the things it counted was gcry

2026-09-19, this host (12 cores, x86_64, Linux 7.0.0, Crystal 1.21.0),
`-Dgc_none`, headerless default. CI numbers from `test (aarch64 native)`
(`ubuntu-24.04-arm`).

## What this started as

`ROADMAP.md`'s aarch64 item opens with "The aarch64 job hangs in
`ec-queue-audit`, about one run in seven, and it has been reading as
`cancelled`". That is the claim this note went to check, and it does not hold on
this tree. What it found on the way is that the census the *other* open thread
item rests on has been reporting gcry's own mark helpers as unscanned mutators,
and could never have said so, because it counts and does not name.

## Retraction: the aarch64 job is not hanging

Every `test (aarch64 native)` job of the last 300 CI runs, 2026-08-24 →
2026-09-19 (299 jobs; one run had none):

    success    282
    failure     13
    cancelled    4

    duration   min 30 s   p50 355 s   p90 405 s   max 443 s

**Zero jobs reached the 20-minute timeout**, and the longest was 7 m 23 s. The
four `cancelled` are 208 s, 229 s, 235 s and 239 s — the concurrency group
killing a superseded push, two of them mid-`find_block_race` — not the job
deadline. The `timeout 300` / `timeout 600` wrappers added for exactly this
turned the shape into a failure with output; the item's headline rate is a
description of the tree before them.

The last aarch64 failure of any kind is **2026-09-17T15:29Z**. The 36 jobs since
are 33 success and 3 concurrency-cancelled, 0 failures.

### What the 13 failures actually were

| shape | n | last seen |
|---|---|---|
| the five chunk-residency specs together | 4 | 2026-09-17 12:05 |
| `invariant_spec` only (same cause, mid-fix) | 1 | 2026-09-17 12:14 |
| `process_spec` regression 6/8 | 2 | 2026-09-05 |
| a gate exiting 2 | 5 | 2026-09-13 |
| `stw-ack-window` listed_delta=1 | 1 | 2026-09-13 |

## Retraction: the five retention specs were not a page-size problem

`ROADMAP.md` says of that cluster: "the candidate worth checking when it recurs
is the runner's page size, since every one of them reasons about chunk
residency." The specs were made to print their state for the next recurrence,
and the next recurrence printed it (run `35219192363`, job `105194861088`,
2026-09-17):

    no chunk went dormant — chunks=8 dormant=0 dormant_bytes=0 fully_free=1048576
      unmapped=0 live_objects=0 heap_size=1048576 retain=67108864 warm_retain=0
      page=4096 compiled_page=4096

**`page=4096 compiled_page=4096`.** The runner's page size is the same as the
compiled one and the same as x86_64's. The cause was found the same day and is
already on master: one live thread left over from an earlier example turns the
empty-chunk release path off entirely (`release_empty_chunks_this_collect?`
returns false under `sweep_multi_mutator?`), so every assertion in those five
fails for a reason unrelated to what it tests — `8ba3660` "specs: one extra
thread was turning the empty-chunk release off", then `e75d362`. The specs now
set `invariant_sole_mutator` / `parallel_empty_chunk_dormant` /
`parallel_empty_chunk_munmap`. No recurrence in the 36 jobs since.

## What the green runs are actually printing

40 consecutive green `test (aarch64 native)` logs, counted per run:

| marker | runs | per run |
|---|---|---|
| `SUSPEND STALLED` | 40/40 | 3 |
| `SUSPEND ABANDONED` | 40/40 | 6 |
| `STOP-THE-WORLD STALLED` | 40/40 | 2–3 |
| `EC QUEUE SLOT CORRUPT` | 40/40 | 2 |
| `EC STRUCTURE CORRUPT` | 40/40 | 1 |
| dying-type **death** report | **0/40** | 0 |
| `… at least one is unrecorded` | **40/40** | **11** |
| the staged wait `GAVE UP` | 3/40 | 2 |

The first five are constant across runs because they are the gates' own planted
controls — `stw-epoch` has three red arms by design, `ec-queue-audit` plants two
values. A constant is not a sighting, and reading those lines as one is a
mistake this table exists to prevent.

The one that is not a planted control is the census, and it fires **every run,
eleven times**.

## The census gap is not the birth window

The gap is in `scheduler_roots --control` among others — the arm that builds no
execution context and starts no worker:

    gcry: thread census — the OS reports 3 thread(s) and Crystal's list yielded 2,
      so 1 thread(s) are outside Crystal's list; gcry has staged 0, fewer than the
      gap — at least one is unrecorded. collection 0

Collections 0, 1, 2, 3 …, always `gap = 1`, always `staged 0`. The item this
census belongs to measures "about one collection in a thousand, one thread,
during worker startup". A gap of exactly one on *every* collection of a program
that starts nothing is not that. The same binary and arm on this x86_64 host
reports **0 gaps**.

And the message says `at least one is unrecorded`, which reads as the open
unscanned-mutator defect. Nothing in the census could confirm or deny it,
because a count cannot name a thread. That is where this had sat since
2026-08-17.

## gcry was one of the threads it was counting

`parallel_mark.cr` creates its helpers with raw `pthread_create` on purpose — a
`Crystal::Thread` would freeze in `stop_world`. Raw pthreads are outside
Crystal's list **by construction**, so the census counts every one of them:

    GCRY_THREAD_CENSUS=1 GCRY_PARALLEL_MARK=4, nothing else running
      → the OS reports 5 … Crystal's list yielded 2 … 3 thread(s) are outside …
        at least one is unrecorded
      → checks=3 gaps=3 gap_max=3

Three helpers, three "unscanned mutators". They touch mark state and block
headers only — no `Fiber`, no managed allocation — so they can hold no mutator
reference and are not that defect. Any run with `GCRY_PARALLEL_MARK>1` has been
reporting pure noise in the collector's own soundness instrument.

## What changed

The census now walks `/proc/self/task` on a gap (raw `getdents64` +
`/proc/self/task/<tid>/comm` into stack buffers — no allocation, callable inside
the pause) and prints each task by kernel thread id and name. gcry names its own
helpers `gcry-mark` so they can be subtracted. `thread_census_unexplained` is
the number `thread_census_gaps` was being read to mean.

    gcry: thread census — OS tasks: 159115:thread_census_n 159116:SYSMON
      159117:gcry-probe — 0 are gcry's own mark helpers, leaving 1 unexplained

    gcry: thread census — OS tasks: 159121:thread_census_n 159122:SYSMON
      159131:gcry-mark 159132:gcry-mark 159133:gcry-mark — 3 are gcry's own mark
      helpers, leaving 0 unexplained

## The gate, and both directions measured

`make thread-census-names`, five arms and two output assertions:

| arm | gaps | own | unexplained | named |
|---|---|---|---|---|
| `--control` | 0 | 0 | 0 | — |
| plant (raw pthread `gcry-probe`) | 6 | 0 | 6 | `gcry-probe` |
| `--noname` (twin) | 6 | 0 | 6 | none |
| `--mark` (`GCRY_PARALLEL_MARK=4`) | 6 | 18 | **0** | 3 × `gcry-mark` |
| `--mark --noname` (twin) | 6 | 0 | **6** | none |

`own` is summed over the six collections that gapped (3 helpers × 6). The
`--mark` pair is the fix measured both ways: with the naming on, gcry's own
helpers explain the whole gap; with it off, the same run leaves all six
collections unexplained, which is what the census did before this change.

## Two holes the break tests found, both in the gate

Breaking the collector on purpose is the only thing that says a gate can go red,
and it caught the gate being wrong twice.

**1. The plant arm passed with the walk dead.** Stubbing `each_os_thread` to
return `false` left `own=0` and `unexplained=gaps` — identical to a walk that
ran and attributed nothing — and the arm went green:

    checks=6 gaps=6 gap_max=1 own=0 unexplained=6 unanswered=0   → ok — plant

`thread_census_unwalked` now counts a gap the walk could not look at, and the
arm requires it to be zero. Same rule `_unanswered` already existed for, one
level down.

**2. The output assertion matched the harness's own banner.** `grep -q
"gcry-probe"` was satisfied by the mode line `plant (a raw pthread named
gcry-probe, …)`, so it passed with the census silent. Tightened to
`grep -q "OS tasks:.*gcry-probe"`, which only the census line can satisfy.

With both fixed, the two breaks are red where they should be:

    walk stubbed to false      → FAIL: /proc/self/task could not be walked on 6 of 6 gaps
    helper naming removed      → FAIL: the walk found no gcry-mark helper, so the gap
                                       was not attributed
                                 FAIL: 6 gap(s) left unexplained with only gcry's own
                                       helpers running

## The answer, from the first CI run that carried the instrument

Run `35448312165`, job `105910998136`, `test (aarch64 native)`, commit
`ed86d2c`. `thread_census_names --control` — a process that plants nothing:

    gcry: thread census — OS tasks: 7009:thread_census_n 7010:SYSMON
      7011:thread_census_n — 0 are gcry's own mark helpers, leaving 1 unexplained

and `scheduler_roots`, the arm this question came from:

    gcry: thread census — OS tasks: 4062:scheduler_roots 4063:SYSMON
      4064:scheduler_roots — 0 are gcry's own mark helpers, leaving 1 unexplained

**Three tasks: the main thread, `SYSMON`, and a third carrying the process's
own `comm`.** A raw pthread inherits its creator's `comm`, so a task with the
program's own name that Crystal's list never yields is an unnamed raw thread —
the shape predicted above from break 2, now observed. It is present at
collection 0, before the harness creates anything, on every binary, and it is
not gcry's: `attributed = 0`. Not a birth window, not a mark helper, and not
reproducible on this x86_64 host.

That is as far as naming goes. What it is *for* — and whether anything is
reachable only from it — is the next question, and it now has a tid to ask
about rather than a count.

## The control arm was wrong, and the runner said so

The first version asserted `gaps == 0` in `--control`, i.e. that a host has no
thread outside Crystal's list. aarch64 does, so the gate went red on its first
run for a correct reason it had no way to express. An absolute is the wrong
assertion for a property of the host.

Rewritten to measure a **delta** in one process — `COLLECTS` collections of
baseline, then plant, then `COLLECTS` more — and a relationship that carries
the baseline in both terms: `attributed = gap_max - unexplained_max` is the
number of threads the walk credited to gcry, whatever else the host is
running. Verified against a copy of the harness with a simulated
pre-existing unlisted thread:

| arm | gap_max | unexplained_max | attributed | verdict |
|---|---|---|---|---|
| `--control` | 1 | 1 | 0 | baseline reported, nothing miscredited |
| plant | 1 → **2** | 1 → **2** | 0 | the planted thread widened both |
| `--noname` | 1 → 2 | 1 → 2 | 0 | same gap, no names |
| `--mark` | 4 | **1** | **3** | the three helpers subtracted, the host's one left |
| `--mark --noname` | 4 | **4** | 0 | pre-fix: all four unexplained |

The `--mark` row is the one worth reading twice: on a host that already has an
unlisted thread, the walk subtracts exactly gcry's three and leaves the host's
one standing. That is the discrimination the raw gap could never make.

## And a third thing the runner caught: the helper named itself too late

With the control arm fixed, the next aarch64 run (`35448782491`) failed on
`--mark` instead, and the log says why on its own:

    OS tasks: … 7743:gcry-mark 7744:gcry-mark 7745:thread_census_n
              — 2 are gcry's own mark helpers, leaving 2 unexplained
    OS tasks: … 7743:gcry-mark 7744:gcry-mark 7745:gcry-mark
              — 3 are gcry's own mark helpers, leaving 1 unexplained

The third helper existed and had not yet run `pthread_setname_np` **on
itself**, so it still wore the `comm` it inherited from its creator — and for
that one collection it was counted as a mutator gcry had never heard of. A
thread that names itself is unnamed for a window, and the census lands in it.
x86_64 never showed this: four cores and a slower spawn on the runner widen
the window enough to be sampled.

Naming moved to the **creating** side — `pthread_setname_np` takes a handle,
and `ensure_mark_pthreads` has it the instant `pthread_create` returns. That
is the same placement, for the same reason, as `thread_staging.cr`'s record.
It closes the window rather than narrowing it: the creator is the collector,
so it cannot be inside `ensure_mark_pthreads` and inside a stop at the same
time. `--mark` now reads `unexplained_max=0` from the first collection
instead of 2 then 1.

## And a fourth: the print budget was spent before the interesting collection

With the race closed, all five arms went green on aarch64 and the *output*
assertion failed instead (run `35449252433`): `the census did not name the
planted raw pthread`, with `gap_max=2 unexplained_max=2` in the very same run.
The counters saw the plant; the log never showed it.

The census printed "the first five gaps and then nothing", which is the right
budget only on a host that does not gap. aarch64 gaps on **every** collection,
so the baseline phase spent the whole budget on its own thread and the planted
one was never printed. x86_64 has a baseline of 0, so its first five gaps were
the interesting ones — the cap was wrong everywhere and only wrong *visibly*
on the host that has something to say.

Now: the first few unconditionally, and after that whenever the gap **changes**,
to a ceiling of 32 reports. A repeat of the same gap is noise; a different one
is news. Reproduced and fixed locally against the simulated baseline —

    OS tasks: 246883:tcn_noise 246884:SYSMON 246885:tcn_noise — … leaving 1 unexplained
    OS tasks: 246883:tcn_noise 246884:SYSMON 246885:tcn_noise 246886:gcry-probe
              — 0 are gcry's own mark helpers, leaving 2 unexplained

— where the second line is printed only because the gap moved 1 → 2.

Three of the four defects in this note were found by CI and could not have
been found here, and all three were in the *gate*, not the instrument: an
absolute assertion about the host, a self-naming race, and a print budget.
The instrument's own numbers were right in every one of those runs.

## What is still open

**What the aarch64 task is.** Named, not identified. The tid is in the log and
the `comm` is the program's own, so the next step is what created it — nothing
in gcry did, and nothing in the harness did.

**Whether the gap matters.** Naming a thread is not showing that anything is
reachable only from it. That half of the item is untouched.

## A locale bug in a gate, found by running it

`ci/knob-doc-check.sh` failed on this host and passes on CI. `sort` orders by
collation and `comm` compares bytes; glibc's UTF-8 collation ignores `_`, so
`sort` emits `GCRY_PRECISE_FIBER_LEAF` before `GCRY_PRECISE_FIBERS` while `comm`
wants the reverse (`S` 0x53 < `_` 0x5F). `comm` then exits 1 with "input is not
in sorted order" and `set -e` reddens a green tree. The failure direction here
was the harmless one; the same mismatch can also walk `comm` past a genuinely
missing knob, which is the direction that matters. `export LC_ALL=C`.
