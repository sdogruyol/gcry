# acik non-stack A/B

| knob | thr | RSS KiB | × Boehm | live MiB | prec/cons | layouts |
|------|----:|--------:|--------:|---------:|----------:|--------:|
| boehm | 243.1 | 43732 | 1.00× | 0 | 0/0 | 0 |
| control | 238.8 | 195160 | 4.46× | 220 | 131/8988 | 51 |
| auto_layouts | 250.1 | 204912 | 4.69× | 230 | 5624/8663 | 483 |
| scan_caps | 267.0 | 204708 | 4.68× | 244 | 600/16261 | 585 |
| floor | 257.6 | 198708 | 4.54× | 238 | 807/14737 | 51 |
| auto_scan | 265.3 | 207216 | 4.74× | 245 | 527/13484 | 599 |
| disable_layout | 220.0 | 156048 | 3.57× | 165 | 0/16053 | 0 |

Source: `/home/uzumaki/playground/gcry/bench/log/linux/2026-08-03-acik-nonstack/nonstack.tsv`
Bin variant ambient precise-stack per script.
