#!/usr/bin/env python3
"""Summarize Kemal median-of-N TSV -> markdown table."""
import sys, os, statistics

tsv_path = sys.argv[1]
out_path = sys.argv[2] if len(sys.argv) > 2 else sys.stdout
trials = os.environ.get("TRIALS", "3")

rows = []
with open(tsv_path) as f:
    header = next(f)
    for line in f:
        tag, pth, trial, rps, rss = line.strip().split("\t")
        rows.append((tag, pth, int(trial), float(rps), int(rss)))

lines = [
    f"Kemal median-of-{trials}",
    "",
    "| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |",
    "|------|------------------:|-----------------:|-------:|----------------:|---------------:|------:|",
]
for pth in ("/", "/json"):
    b = sorted(r for r in rows if r[0] == "boehm" and r[1] == pth)
    g = sorted(r for r in rows if r[0] == "gcry" and r[1] == pth)
    if not b or not g:
        continue
    bm = statistics.median([r[3] for r in b])
    gm = statistics.median([r[3] for r in g])
    br = statistics.median([r[4] for r in b])
    gr = statistics.median([r[4] for r in g])
    pct = 100.0 * gm / bm if bm else 0
    rx = gr / br if br else 0
    lines.append(f"| `{pth}` | {bm:,.0f} | {gm:,.0f} | **{pct:.1f}%** | {br:,} | {gr:,} | **{rx:.2f}×** |")

lines.append("")
text = "\n".join(lines) + "\n"
if isinstance(out_path, str):
    with open(out_path, "w") as f:
        f.write(text)
    print(f"Wrote {out_path}")
else:
    print(text)