# The `Thread` use-after-free sampler has been counting the wrong denominator

2026-09-20. CI history for `thread UAF sampler (aarch64)`, the 299 jobs of the
300 most recent CI runs, 2026-08-25 → 2026-09-20. Local reruns on this host
(12 cores, x86_64, Linux 7.0.0, Crystal 1.21.0).

## Why this was looked at

`ROADMAP.md`'s `Thread` use-after-free item ends with: "**Next**: leave the
sampler running and revisit the rate once more pushes have accumulated; the
item stays open until CI has enough runs to say so." The pushes have
accumulated. This is that revisit, and the first thing to establish was
whether the sampler is still sampling — a job that finishes in 40 seconds and
is `continue-on-error` is exactly the shape that rots unnoticed.

## It is not rotted

Every one of the 299 jobs printed its summary line, and the reporting path
works: pointed at `bin/thread_storm`, where a dying `Thread` is routine, one
run produces **17** dying-`Thread` reports with their logs kept and their
details printed. A sampler that has never been seen to report something says
nothing when it reports nothing; this one has been seen.

## The tally

    299 sampler jobs        2 990 harness runs (5 980 processes: hold + control)
      0 crashed
      0 dying-Thread reports
 11 965 "precondition" sightings

11 965 preconditions and no death reads as overwhelming evidence that the
`thread_birth_root` fix holds. **It is not.**

## There are two preconditions and only one of them is the window

The audit prints two lines under the same "precondition:" label:

    … a thread was staged when the world stopped, and the wait caught it.
    … the wait for a staged thread GAVE UP — the world stopped with it unpublished.

The first is the **safe path** — the pre-stop wait did its job, the thread
published, and it was suspended and scanned like any other. The second is the
window this defect needs: a thread that exists, is not on Crystal's list, is
neither suspended nor scanned, and is still dereferencing itself.

Split:

| | count | share |
|---|---|---|
| the wait caught it | **11 960** | 99.96% |
| the wait **gave up** | **5** | 0.04% |

So the real statement is **0 deaths in 5 windows**, not 0 in 11 965. Summing
them overstated the coverage by a factor of ~2 400, and the summary line was
printing the sum.

## And the five are all old

| job | date | detail |
|---|---|---|
| `97902840845` | 2026-08-25 | 5 listed, 5 bounded, 5 staged, collection 0 |
| `97959288817` | 2026-08-25 | 4 listed, 4 bounded, 2 staged, collection 3 |
| `98613436426` | 2026-08-27 | 5 listed, 5 bounded, 5 staged, collection 0 |
| `101283872841` | 2026-09-05 | 5 listed, 5 bounded, 5 staged, collection 0 |
| `101596145117` | 2026-09-07 | 5 listed, 5 bounded, 5 staged, collection 0 |

None since **2026-09-07** — roughly 150 jobs and 1 500 harness runs with the
window never built once. That is consistent with the pre-stop wait's drain fix
(the wait now releases published entries inside its own loop, and its timeout
rate went from 398-of-400 to nil), and it means the sampler as configured can
no longer observe this defect at all: it spends 2 990 runs a fortnight
exercising the path where the wait works.

## What changed

`make thread-uaf-sample` counts and reports the two apart:

    thread-uaf-sample: 2 runs, 0 crashed, 0 dying-Thread report(s);
      staged-thread window 0 gave-up / 8 caught in bench/log/ci-samples
    thread-uaf-sample: this batch never built the window — the wait caught
      every staged thread, so a silent batch is an absence of the window and
      not an absence of the defect

That second line prints only when the batch is silent **and** built no window,
which is the case where its zero means nothing. Against `thread_storm`, where
reports do appear, it stays quiet and the reports speak:

    thread-uaf-sample: 1 runs, 0 crashed, 17 dying-Thread report(s);
      staged-thread window 0 gave-up / 6 caught

Log retention moved with the meaning: a run is kept when it has a death **or**
a give-up. A run whose only preconditions are the caught kind is the boring
case and is deleted, which is what the artifact upload should have been
carrying all along.

## What this does and does not say

**Does**: the sampler's 299 green jobs are not evidence that the `Thread`
use-after-free is fixed. They are evidence that the window has not occurred on
that harness since 2026-09-07. Those are different claims and the summary line
was making the stronger one.

**Does not**: say the defect is still live. 0 of 5 is weak in both directions.
The sampler needs an arm that *builds* the window rather than waiting for it.

## Correction, same day: a report is a trigger, not a verdict

The paragraph above originally ended "pointing the sampler at
`GCRY_THREAD_UNSTAGE_ON_DEATH=1` is the next step". Doing it exposed a second
miscount, and this one would have been worse than the first.

`bench/thread_churn_uaf.cr` already exists, already carries that knob as its
amplified arm, already asserts that the arm still reproduces, and already runs
in CI (`ci.yml:805`). Pointed at one of its children with the dying-type audit
on, the sampler's hit counter goes from 0 to thousands — and every one of them
is ordinary garbage:

    six `thread_churn_uaf --child` runs, audit + poison + unstage
      dying-Thread reports                        5 712
      still on Crystal's list                         0
      still linked from a live thread's list node     0
      in a suspended thread's registers               0
      offered by the collecting thread's stack scan   0
      SIGSEGV                                         0

A `Thread` object dying after its thread has exited is the collector working.
The audit fires on any watched block the mark did not reach, so on a workload
where threads exit it fires constantly; the four holder lines underneath it
are the verdict. `ec_queue_audit` reports 0 only because no thread exits in
it — 0 of 0, not 0 of 5 712.

So the counter had to learn the difference before the arm could be added:
`make thread-uaf-sample` now sums `dying-Thread report(s)` and `of which …
with a holder` apart, and keeps a run's logs for a holder or a give-up, plus
one death-only log per batch as an exemplar and at most four in all.

## And the churn arm builds the window too

The unexpected part. The arm was added for the death side; it also produces
the give-up the whole note is about, at a rate the old sampler never came near:

| | runs | give-ups | deaths examined |
|---|---|---|---|
| `ec_queue_audit` only, CI history | 2 990 | **5** | 0 |
| with the churn arm, this host | 3 | **16** | 2 856 |

That is ~5 give-ups per run against ~0.0017, about three thousand times the
rate, and it turns the sampler's headline from "0 of 0" into "0 of 2 856
deaths, none with a holder, across 16 windows". Still no defect — but for the
first time that zero has a denominator.

## One thing measured and dropped

An early batch showed 6 of 8 churn children exceeding a 90 s timeout, which
looked like a hang worth reporting. It does not survive: with the knobs
isolated, `none` runs in ≤1 s, `audit` 8 s, `unstage` 2–3 s, `poison` ≤1 s and
all three together 10–11 s, three for three, and nine further runs produced no
timeout. Output volume was 865 KB a run against 4.5 GB free on the tmpfs, so
that is not it either. Unattributable, most likely host load on a shared
12-vCPU guest, and recorded here only so the number is not quietly reused.
