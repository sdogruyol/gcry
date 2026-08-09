# Fat-app sound-pause re-cut, first pass (9 reps) — superseded by the 21-rep run

Host: 12th Gen Intel i3-12100F (4C/8T), WSL2, Crystal 1.21.0, `--release`, EC1.
Fat app (acikturkiye) `/api/v1/`, **9 paired reps** × 20 s, configs `tuned`,
`sound`, `scrub`.

**Cite `../2026-08-09-071144-root-phase/` instead.** This run reached the same
conclusion and is kept as the independent confirmation of it, but it put only
4–5 reps in the large-heap stratum, which is too few to quote a magnitude from.
The 21-rep run has 10 / 13.

Stratified at 55 MiB (the harness refused the unstratified medians — IQR
393–1455%):

| Stratum | config | reps | pause | Δ | root work | Δ |
|---------|--------|-----:|------:|--:|----------:|--:|
| ~46 MiB | tuned | 8 | 2.8 ms | — | 1127 µs | — |
| ~46 MiB | sound | 7 | 2.8 ms | +1.3% | 1152 µs | +2.2% |
| ~46 MiB | scrub | 9 | 2.7 ms | −2.7% | 1155 µs | +2.5% |
| ~70 MiB | tuned | 4 | 25.0 ms | — | 21 258 µs | — |
| ~70 MiB | **sound** | 5 | **17.8 ms** | **−28.8%** | **11 867 µs** | **−44.2%** |
| ~70 MiB | scrub | 6 | 26.2 ms | +4.8% | 20 974 µs | −1.3% |

Against the 21-rep run's −25.4% / −43.8%: agreement to 3pp on pause and 0.4pp
on root work, from independent draws.

Reproduce:

```sh
bench/stratify_root_phase.py bench/log/linux/2026-08-09-062117-root-phase --cut=55
```

The `scrub` column is incidental here — it tracks `tuned` closely, which is
consistent with the Kemal finding that scrub is a root-work cost rather than a
retention win. The Kemal cut (`../2026-08-09-061508-root-phase/`) is the one to
cite for that knob; it has 16% IQR instead of this run's regime mixing.
