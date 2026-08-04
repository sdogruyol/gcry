# Non-stack med-of-3 summary

See [FINDINGS.md](FINDINGS.md).

| knob | RSS med KiB | live med MiB | thr med |
|------|------------:|-------------:|--------:|
| control | 306752 | 382 | 252.1 |
| disable_layout | 319492 | 455 | 262.6 |
| auto_layouts | 335596 | 444 | 266.4 |

No knob beats control on RSS. Boehm trial RSS ~35 MiB → control ~8.6× band.
