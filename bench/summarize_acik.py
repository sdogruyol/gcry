#!/usr/bin/env python3
"""Summarize acikturkiye median-of-N TSV -> markdown table."""
import sys, os, statistics

tsv_path = sys.argv[1]
out_path = sys.argv[2] if len(sys.argv) > 2 else sys.stdout
trials = os.environ.get("TRIALS", "3")

rows = []
with open(tsv_path) as f:
    header = next(f)
    for line in f:
        cols = line.strip().split("\t")
        try:
            tag, trial, rps, rss = cols[0], int(cols[1]), float(cols[2]), int(cols[3])
        except (ValueError, IndexError):
            continue
        rows.append((tag, trial, rps, rss))

b = [r for r in rows if r[0] == "boehm"]
g = [r for r in rows if r[0] == "gcry"]

lines = [f"acikturkiye median-of-{trials} /api/v1/", ""]

if b and g:
    lines += [
        "| Trial | Boehm req/s | gcry req/s | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |",
        "|------:|-----------:|----------:|-------:|----------------:|---------------:|------:|",
    ]
    for i in range(min(len(b), len(g))):
        bt, gt = b[i], g[i]
        tp = 100.0 * gt[2] / bt[2] if bt[2] else 0
        rr = gt[3] / bt[3] if bt[3] else 0
        lines.append(
            f"| {i+1} | {bt[2]:,.0f} | {gt[2]:,.0f} | {tp:.1f}% | {bt[3]:,} | {gt[3]:,} | {rr:.2f}× |"
        )
    bm = statistics.median([r[2] for r in b])
    gm = statistics.median([r[2] for r in g])
    br = statistics.median([r[3] for r in b])
    gr = statistics.median([r[3] for r in g])
    pct = 100.0 * gm / bm if bm else 0
    rx = gr / br if br else 0
    lines.append(
        f"| **median** | {bm:,.0f} | {gm:,.0f} | **{pct:.1f}%** | {br:,} | {gr:,} | **{rx:.2f}×** |"
    )
elif b or g:
    xs = b or g
    tag = xs[0][0]
    lines += [
        f"| Trial | {tag} req/s | {tag} RSS (KiB) |",
        "|------:|-----------:|---------------:|",
    ]
    for i, r in enumerate(xs):
        lines.append(f"| {i+1} | {r[2]:,.0f} | {r[3]:,} |")
    rm = statistics.median([r[2] for r in xs])
    rs = statistics.median([r[3] for r in xs])
    lines.append(f"| **median** | {rm:,.0f} | {rs:,} |")
else:
    lines.append("_no trials_")

lines.append("")
text = "\n".join(lines) + "\n"
if isinstance(out_path, str):
    with open(out_path, "w") as f:
        f.write(text)
    print(f"Wrote {out_path}")
else:
    print(text)
