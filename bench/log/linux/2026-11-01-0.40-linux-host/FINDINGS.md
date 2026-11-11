# 0.40 on the Linux host against 0.39.0 and Boehm (2026-11-01)

The README's Linux table, measured the way 0.39's was
(`../2026-10-24-0.39-linux-host/` "The clean session"): `release-0.40.0` at
`69bfcaf2` (its `src/` is `2c600dfb`'s) against `v0.39.0` (`c0d570c5`) and
Boehm, Crystal 1.21.0, QEMU x86-64 guest, 12 vCPUs. Every arm is the tip's
`bench/crystal_metric` and `bench/kemal` with only `lib/gcry/src` swapped
(`build.sh`, as `bench/runner_ab/ab.sh` builds), `--release`, `-Dgc_none` for
gcry; 16- and 64-byte pad arms of both trees (nops ahead of all code, ab.sh's
`pN`). `session.sh`: crystal-metric with
`../2026-10-31-revcomp-host-placement/scripts/ab.py` (0.39's `ab.py` plus the
bench's timed section per run; same seed), 11 reps, ten benches, seven arms in
random order per rep, under one hold of the heavy lock; then Kemal with
`../2026-10-18-0.37-kemal/kemal_ab.sh`, 9 trials, the lock per run. Nothing
else was built or run on the host meanwhile.

Session 2026-10-31 23:46 – 2026-11-01 00:14 UTC. Load (`load.txt`, 30 s
samples): 1.03–1.96 during crystal-metric, 1.12–2.50 during Kemal (whose own
server and `wrk` are on the host); `host-snapshots.txt` has `uptime` and the
top processes before, at start, between, at the end and after: the desktop
(gnome-shell, ptyxis) and idle agent shells, no other benchmark or build. No
process of the session was left running.

Files: `cm.md` (ab.py's table, ratio of medians), `cm-runs.json`,
`cm-paired.txt` (per arm, paired against `v039`: wall, timed section, setup),
`kemal.tsv`, `kemal-summary.txt`, `malloc-atomic-phase.txt`
(`GC::malloc_atomic<UInt64>`'s address in each binary).

## crystal-metric

Speed % of Boehm / peak × Boehm (ratios of medians, as the README's table),
0.40 against 0.39.0 paired wall (median [IQR]), and each tree's spread of
median wall over its three placements (plain, p16, p64), in seconds:

| bench | Boehm | 0.39.0 | 0.40 | 0.40 vs 0.39.0, paired wall | pad range 0.39.0 | pad range 0.40 |
|---|---:|---|---|---:|---:|---:|
| Primes | 0.616 s, 659 MB | 105% / 0.94× | 104% / 0.94× | +2.0% [+0.9, +2.2] | 0.585–0.592 | 0.579–0.599 |
| JsonParsePure | 0.820 s, 689 MB | 106% / 0.81× | 105% / 0.80× | +1.0% [−0.1, +2.8] | 0.770–0.788 | 0.775–0.788 |
| Binarytrees | 0.513 s, 51 MB | 107% / 0.74× | 107% / 0.74× | −0.5% [−1.5, +1.1] | 0.478–0.481 | 0.478–0.484 |
| JsonGenerate | 1.498 s, 1228 MB | 107% / 0.63× | 107% / 0.63× | +0.1% [−1.4, +0.6] | 1.400–1.424 | 1.402–1.428 |
| JsonParseSerializable | 0.863 s, 540 MB | 107% / 0.76× | 106% / 0.76× | +0.7% [+0.1, +1.9] | 0.803–0.816 | 0.805–0.823 |
| JsonParsePull | 0.849 s, 539 MB | 106% / 0.76× | 107% / 0.76× | +0.3% [−0.7, +0.8] | 0.793–0.807 | 0.797–0.805 |
| RegexDna | 2.321 s, 397 MB | 97% / 0.55× | 99% / 0.55× | −1.6% [−2.6, +0.1] | 2.349–2.388 | 2.342–2.387 |
| Revcomp | 1.910 s, 827 MB | 96% / 0.64× | 97% / 0.64× | −0.7% [−1.4, −0.6] | 1.966–1.981 | 1.939–2.000 |
| Knuckeotide | 0.669 s, 47 MB | 100% / 1.19× | 99% / 1.17× | +0.3% [−1.1, +1.7] | 0.663–0.669 | 0.662–0.673 |
| Brainfuck | 2.468 s, 14 MB | 100% / 1.00× | 99% / 1.00× | +1.1% [−1.2, +4.2] | 2.475–2.545 | 2.456–2.548 |

- **Every row's pad ranges overlap.** Two rows are slower beyond their spread
  unpadded: Primes +2.0% [+0.9, +2.2] and JsonParseSerializable +0.7% [+0.1,
  +1.9]. Both are inside 0.39.0's placements: 0.40 padded by 16 bytes runs
  Primes at 0.579 s, under every 0.39.0 arm (0.585–0.592), and
  JsonParseSerializable at 0.805 s, inside 0.39.0's 0.803–0.816. Placement by
  the keep rule's test (`../2026-11-01-0.40-keep-rule/`).
- **Revcomp: 97% of Boehm, 0.39.0 96%.** `GC::malloc_atomic<UInt64>` starts
  at the same address in both unpadded binaries (`0x1c390`, ≡ 16 mod 64, the
  slow phase of `../2026-10-31-revcomp-host-placement/`), so the unpadded
  rows compare like with like: 0.40 −0.7% [−1.4, −0.6] wall. Timed sections
  over the three placements: 0.40 0.526–0.576 s (fastest padded by 16 bytes,
  ≡ 0), 0.39.0 0.546–0.569 s.
- **Peaks are the same per tree** (0.40 against 0.39.0 within ±1.5% on every
  row). Knuckeotide reads 1.17× (0.39.0 1.19×) against 1.37× in 0.39's clean
  session, and RegexDna 0.55× against 0.49×, with gcry's own peaks unchanged
  (Knuckeotide 55–56 MB in both sessions, RegexDna 219 MB): Boehm's peak is
  multimodal across reps (Knuckeotide 39 / 47 / 57 MB, RegexDna 383–525 MB in
  this session and 299–512 MB in 0.39's) and its median fell on 47 MB here
  against 39 MB there. The ratio moved with Boehm, not with gcry.
- Brainfuck, which allocates nothing, spans 3% across each tree's pads.

## Kemal

`kemal-summary.txt` (9 trials, ratios of medians; `kemal_ab.sh` prints them
against whichever arm comes first, here Boehm):

| route | Boehm | 0.39.0 | 0.40 | 0.40 vs 0.39.0, paired per trial |
|---|---:|---:|---:|---:|
| `/json` | 44 297 req/s, 16.0 MB | 104.4%, 1.24× | **106.8%, 1.24×** | +2.9% [−1.2, +3.0] |
| `/` | 68 016 req/s, 16.0 MB | 99.4%, 1.21× | **101.6%, 1.21×** | +3.8% [−6.6, +4.5] |

0.40 against 0.39.0: level on both routes (the IQRs span zero), the same
19.8 MB peak on `/json` (19.3 against 19.4 MB on `/`). 0.39.0 read 104.0% of
Boehm on `/json` in its own clean session; Boehm's 44 297 req/s here against
45 157 there is the host on the day.
