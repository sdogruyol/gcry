# 0.39 on the Linux host against 0.38.0 and Boehm (2026-10-24), not yet README-grade

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

The README's Linux table stays at 0.38.0's numbers until a session on an idle
host; these are recorded so that session has something to compare with.
