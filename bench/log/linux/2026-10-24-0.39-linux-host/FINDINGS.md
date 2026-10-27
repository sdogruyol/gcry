# 0.39 on the Linux host against 0.38.0 and Boehm (2026-10-24)

`release-0.39.0` at `c8e9ecdc` against `v0.38.0` and Boehm, built as before
(`--release`, `-Dgc_none` for gcry), Crystal 1.21.0, QEMU x86-64 guest, 12
vCPUs. `../2026-10-14-rss-budget-recheck/ab.py` (11 reps, arms in random order
per rep) and `../2026-10-18-0.37-kemal/kemal_ab.sh` (9 trials), two sessions
each, then a pad session. These were meant to replace the 0.38.0 README table,
measured beside the busy loops of `../2026-10-22-0.39-keep-rule/` ("Host
load"). They are not clean either: `load.txt` reads 1.2–3.2 during the first
four and 5.7 at the pad session, from the desktop (gnome-shell ~0.5 core,
ptyxis ~0.4) and from another agent session on the host running `crystal spec`
(`crystal-run-spec`, ~1.4 cores) at the time of the pad session.

**crystal-metric, 0.39 against 0.38.0, paired wall, median [IQR]**

| bench | session 1 | session 2 |
|---|---:|---:|
| Primes | +0.9% [−0.6, +2.0] | −0.5% [−2.7, +4.2] |
| JsonParsePure | +2.1% [+0.8, +3.0] | +2.8% [+1.1, +5.1] |
| Binarytrees | +3.4% [+1.6, +3.6] | +1.8% [+0.2, +4.5] |
| JsonGenerate | −1.5% [−3.0, −1.3] | −0.1% [−0.9, +0.7] |
| JsonParseSerializable | +3.1% [+2.1, +3.3] | +3.9% [+3.3, +4.3] |
| JsonParsePull | +3.3% [+2.2, +4.2] | +4.3% [+1.7, +5.0] |
| RegexDna | −0.5% [−1.2, +0.7] | +0.3% [−1.9, +0.6] |
| Revcomp | +1.8% [+1.0, +2.5] | +1.7% [+1.3, +2.2] |
| Knuckeotide | +0.1% (peak −16.9%) | −0.4% (peak −0.5%, IQR to −20.8%) |
| Brainfuck (allocates nothing) | −2.7% [−5.5, +2.9] | −4.9% [−7.7, −2.2] |

**Pad session** (`pads.md`): both trees built plain and with 16 and 64 bytes
of padding ahead of all code, one interleaved session. 0.39 against 0.38.0:
JsonParsePure 100%, JsonParseSerializable 101%, JsonParsePull 99%,
Binarytrees 103%, Revcomp 97%, Brainfuck 104% (speed, 0.38.0 = 100%). The pad
arms of the two trees span each other on every row (e.g. JsonParsePull
0.38.0 0.913–0.940 s, 0.39 0.924–0.939 s; Binarytrees 0.526–0.562 against
0.536–0.570 s), and Brainfuck, which allocates nothing, moves 9% between pads.

**Reading.** The JSON rows' and Binarytrees' 2–4% in the first two sessions do
not reproduce in the pad session, and padding alone moves the same rows by as
much; the five-runner runs (`../2026-10-22-0.39-keep-rule/`) put the same rows
on `ubuntu-latest` inside a 16-byte pad. [INFERENCE] placement, as there.
Kemal `/json`: 0.39 at 100.3% and 101.2% of 0.38.0 (medians), 105.9% and 105.7%
of Boehm, the same peak (19.9 MB, 1.24× Boehm's 16.1 MB). `/`: 102.3% and
97.2% of 0.38.0.

The four sessions above are kept for comparison; the clean session below replaces them for the README.

## The clean session (`clean-*`, 2026-10-24 15:13–15:42 UTC)

With the other agent session idle, the same builds plus 16- and 64-byte pad
arms of both trees in one crystal-metric session (11 reps, seven arms), then
Kemal (9 trials). `clean-load.txt`: load 1.6–3.6, the desktop's ~0.9 core
(gnome-shell, ptyxis) and nothing else. This is the README's Linux table.

| bench | Boehm | 0.38.0 | 0.39 | 0.39 vs 0.38.0, paired wall | pad range 0.38.0 | pad range 0.39 |
|---|---:|---|---|---:|---:|---:|
| Primes | 0.660 s, 659 MB | 101% / 0.94× | 105% / 0.94× | −0.5% [−2.7, +4.5] | 0.623–0.663 | 0.631–0.639 |
| JsonParsePure | 0.846 s, 689 MB | 103% / 0.81× | 101% / 0.81× | +2.1% [+0.3, +2.7] | 0.811–0.852 | 0.818–0.868 |
| Binarytrees | 0.530 s, 51 MB | 105% / 0.74× | 105% / 0.74× | +2.2% [−1.8, +3.8] | 0.487–0.503 | 0.491–0.503 |
| JsonGenerate | 1.575 s, 1304 MB | 105% / 0.59× | 106% / 0.59× | −0.9% [−3.4, −0.2] | 1.481–1.512 | 1.475–1.510 |
| JsonParseSerializable | 0.902 s, 559 MB | 108% / 0.73× | 107% / 0.73× | +0.5% [+0.1, +3.0] | 0.833–0.875 | 0.833–0.849 |
| JsonParsePull | 0.885 s, 523 MB | 108% / 0.78× | 106% / 0.78× | +2.2% [−0.1, +2.9] | 0.819–0.892 | 0.836–0.851 |
| RegexDna | 2.384 s, 450 MB | 99% / 0.49× | 98% / 0.49× | +0.4% [+0.1, +0.9] | 2.414–2.431 | 2.416–2.436 |
| Revcomp | 1.960 s, 824 MB | 98% / 0.64× | 96% / 0.64× | +2.0% [+1.2, +4.3] | 1.993–2.008 | 2.011–2.031 |
| Knuckeotide | 0.693 s, 40 MB | 102% / 1.75× | 102% / **1.37×** | +0.4% [−0.0, +3.1] | 0.680–0.688 | 0.683–0.687 |
| Brainfuck | 2.629 s, 14 MB | 96% / 1.00× | 100% / 1.00× | −4.8% [−7.3, −0.4] | 2.313–2.731 | 2.597–2.648 |

Every row's pad range for 0.39 overlaps 0.38.0's except Revcomp's, which sits
1–2% above it here and was +1.7–1.8% in both earlier sessions: on this host
Revcomp is 1–2% slower in 0.39 and not attributed (`ubuntu-latest`'s pad arm
covered it, `../2026-10-22-0.39-keep-rule/`). Brainfuck, which allocates
nothing, spans 15% across 0.38.0's pads. Knuckeotide's peak 1.75× → 1.37×.

Kemal (`clean-kemal-summary.txt`): `/json` 0.39 at 99.3% of 0.38.0 and 104.0%
of Boehm (46 983 against 45 157 req/s), peak 19.9 MB against Boehm's 16.1
(1.24×, 0.38.0 the same); `/` 0.39 at 97.3% of 0.38.0 and 100.6% of Boehm.
