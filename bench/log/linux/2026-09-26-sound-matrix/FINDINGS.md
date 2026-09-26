# Is the complete root scan affordable now? Yes, on both — after one Darwin fix

**Date:** 2026-09-26 · tree `90753ba` (0.28.0 + bench changes) · CI run
`36244503011`, dispatch input `sound_matrix_rounds=10`, jobs "sound matrix"
on `ubuntu-latest` and `macos-latest` · `bench/sound_matrix.py`, raw samples
beside this file.

`docs/SOUND-DEFAULTS.md` ends on one open condition for shipping
`GCRY_SOUND=1` (the complete root scan, `lag = 0`): that it be affordable
"when the scan is large — many threads or a big heap". It also refused to
decide from one workload on one host. This measures three process shapes on
two hosts that are not the developer's. It pairs tuned and sound within each
round and checks each arm's `soundness` label against the profile it is
named for.

## Result

Kemal `/json`, 10 rounds, `wrk -t4 -c100 -d10` after a 2 s warm-up.
Sound ÷ tuned, per-round median (throughput range in brackets):

| shape | Linux: req/s | Linux: pause | macOS: req/s | macOS: pause | macOS: RSS |
|---|---|---:|---|---:|---:|
| EC1 (2 threads) | 1.036 [0.93–1.10] | 0.99× | 1.046 [1.00–1.10] | 1.00× | 1.01× |
| EC1 + one extra thread | 0.979 [0.88–1.07] | **1.51×** | **0.724** [0.66–1.02] | **6.52×** | 0.99× |
| EC4 | 0.969 [0.94–1.02] | **1.46×** | **0.870** [0.82–1.16] | **5.79×** | **1.37×** |

Absolute medians (tuned → sound): Linux EC4 pause 3.07 → 4.55 ms,
EC1+thread 2.56 → 3.87 ms. macOS EC4 3.08 → 17.47 ms, EC1+thread
2.70 → 17.59 ms. Linux RSS is equal in every shape.

## Reading

- **EC1 is free on both hosts**, as `SOUND-DEFAULTS.md` already said.
  The lag knobs cannot run with two threads.
- **Linux**, where the scan is large: +46–51% pause, throughput within noise
  (median −2 to −3%, ranges straddling 1.0), no RSS. This was 19× in August
  and +356% in the 2026-08-09 cut; the low-water skip on the default path and
  0.28.0's SYSMON fix took most of it.
- **macOS**, where the scan is large: 5.8–6.5× pause, 13–28% of throughput,
  and +37% RSS at EC4. The Darwin EC4 root-phase cut the same afternoon
  (CI run `36245905484`) places all of it in the root phase: roots 2.4 ms
  tuned, 19.3 ms sound, stacks equal, and **no page query refused**
  (`page_query_errors` 0).

So the condition `SOUND-DEFAULTS.md` names is met on Linux in the shapes
measured here, and not on macOS. The fat app, the other large-scan shape,
could not be re-measured (it is not on this host).

## Why macOS pays

**The page query is charged per page.** The timing arm added to
`make darwin-page-query` (push run on `fa36212`), on an 8 MiB region with the
top three pages written:

| pages per call | µs per call | ns per page |
|---:|---:|---:|
| 16 | 5.6 | 350 |
| 64 | 18.1 | 283 |
| 512 | 140.8 | 275 |

Finding a parked fiber's low-water mark from its guard asks about every page
up to the first written one, ~512 pages: **141 µs per fiber**. That is paid
per collection, and ~120 parked fibers under Kemal `-c100` make ~17 ms, the
measured root-phase gap. Tuned starts at the lag floor and asks about 16
pages (5.6 µs). The Linux probe for the same stack is one `pread` of page-table
entries (110 of them take 40 µs in all, `../2026-09-26-sysmon-guard-scan/`).
Batching the calls cannot help; only asking about fewer pages can.

**Where it could come from.** Stacks are used from the top, so the written
pages are nearly always a short run under `bottom`, and what costs is proving
the ~500 pages under it untouched. A per-object resident count
(`mach_vm_region` `VM_REGION_TOP_INFO`, `private_pages_resident`, read from
the VM object rather than per page) could prove it, on two conditions. The
top window's touched pages must equal the object's resident count. And no
page of the task may be in the compressor (`TASK_VM_INFO` `compressed == 0`),
because a compressed page is not resident and would otherwise go uncounted.
When either fails, fall back to the full query, which is today's behaviour.
Unmeasured: whether that count is O(1) here, and whether a fiber stack's
entry maps a private object of its own.

## After: the resident-count low-water (`6ed9fc9`)

Implemented the same afternoon (`src/gcry/platform/darwin_low_water.cr`) and
re-measured with the same dispatch (CI run `36253830147`, 10 rounds;
`*-after-resident-count.json`). Sound ÷ tuned:

| shape | macOS before | macOS after | Linux before | Linux after |
|---|---|---|---|---|
| EC1 pause | 1.00× | 1.01× | 0.99× | 0.99× |
| EC1 + thread pause | 6.52× | **1.22×** | 1.51× | 1.45× |
| EC4 pause | 5.79× | **1.25×** | 1.46× | 1.45× |
| EC4 req/s | 0.870 | **1.016** | 0.969 | 1.006 |
| EC4 RSS | 1.37× | **1.00×** | 1.00× | 1.00× |

macOS EC4 absolute: tuned 3.33 ms, sound 4.06 ms. The +37% RSS was the long
pause, not the scan: it went with it. Linux is unchanged, as it should be;
the change is Darwin-only.

The Darwin EC4 root-phase cut in the same run
(`../../macos/2026-09-26-ec4-sound-resident-count/`): sound roots
**19 267 → 3 068 µs**, pause **20.8 → 3.86 ms** (tuned 3.10 ms). The resident
path answered 7 555–8 708 ranges per rep, fell back 0 times, and no page
query was refused.

**Where that leaves `GCRY_SOUND=1`.** The complete root scan now costs
+22–25% of the pause on macOS and +45% on Linux where the scan is large, and
nothing measurable in throughput or RSS on either. At EC1, the shape most
programs run, it costs nothing. That meets the condition
`docs/SOUND-DEFAULTS.md` set for putting sound defaults back on the table,
on these shapes. The fat app is still unmeasured. Whether to flip is a
decision, not a measurement, and it is not taken here.
