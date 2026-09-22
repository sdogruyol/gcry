# The UAF sampler's budget is spent in runs; the statement it makes is in windows

**Date:** 2026-09-22 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `5023c58` · `make thread-uaf-sample`, `make thread-churn-uaf`

## What was measured

The amplified reproducer first, because the item still describes it as
one: `GCRY_THREAD_UNSTAGE_ON_DEATH=1` on `thread_churn_uaf --child`,
which `ROADMAP.md` records at **7 of 40**.

| arm | result |
|---|---|
| amplified, bare | **0 of 40** |
| amplified, `GCRY_POISON_HOLDERS=1` | **0 of 40** |
| `make thread-churn-uaf` shipped, 24 attempts × 4 arms | 0 |
| `make thread-churn-uaf --control`, 8 attempts | 6–7 of 8, both layouts |

So the amplified arm's crashes were the large-object / mark-clear defect
fixed on 2026-09-13, not a thread-family reproducer: the control still
reproduces at 75–87%, the shipped arms do not reproduce at all. That
line in the item is stale and is corrected.

## The window, which is the part that still matters

Six churn children with the sampler's own environment
(`UNSTAGE_ON_DEATH` + `POISON_HOLDERS` + `THREAD_BLOCK_AUDIT`):

| | |
|---|---|
| give-up windows (`the wait GAVE UP`) | **120** |
| caught (the safe path) | 18 |
| dying-`Thread` reports | 5 712 |
| of which with a holder | **0** |
| crashes | 0 |

Twenty windows a run, on this host. The aarch64 sampler's last four CI
batches, ten runs each: **2, 3, 4 and 5**. A hundredfold difference in
what a run buys, and the sampler's budget was counted in runs — so the
same job is a real sample on one runner and almost none on the other.

## What changed

`make thread-uaf-sample` runs extra churn children after its fixed runs
until the batch has `THREAD_UAF_MIN_WINDOWS` (100) give-up windows or
`THREAD_UAF_CHURN_BUDGET_S` (300 s) is gone, and the headline names the
bound that stopped it:

```
thread-uaf-sample: 1 runs + 3 churn (windows), 0 crashed, 3808 dying-Thread
report(s) of which 0 with a holder; staged-thread window 72 gave-up / 16 caught
thread-uaf-sample: 1 runs + 2 churn (budget), 0 crashed, 2856 …  80 gave-up
```

57 s for the first, 40 s for the second. On aarch64 the budget will be
the bound and the number will be honest about it; on x86_64 it stops at
the windows.
