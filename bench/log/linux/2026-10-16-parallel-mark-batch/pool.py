#!/usr/bin/env python3
"""pool.py METRIC A B SESSION[:ARM_A:ARM_B]... — one arm against another,
per session and pooled over sessions.

Each SESSION is a `marksum.py` raw file stem under logs/ (`s1p` reads
logs/s1p-raw.json); ARM_A/ARM_B name the arms in that session that stand for
A and B (default A and B themselves). For every bench and config (the arm
name's suffix after the last `_`: 1, d, 4), prints per session the medians
and whether B's runs all sit below A's (`max(B) < min(A)`, "beyond the
spread"), then the pooled medians with the Mann-Whitney U statistic as
P(B < A) over all run pairs and its two-sided p (normal approximation, ties
corrected). Plain Python: no scipy on this host."""
import sys, json, math, statistics as st


def mwu(a, b):
    """P(b < a) over all pairs, and the two-sided normal-approximation p."""
    n1, n2 = len(a), len(b)
    allv = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks = [0.0] * len(allv)
    i = 0
    ties = 0.0
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and allv[j + 1][0] == allv[i][0]:
            j += 1
        r = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[k] = r
        t = j - i + 1
        ties += t ** 3 - t
        i = j + 1
    ra = sum(r for r, (_, g) in zip(ranks, allv) if g == 0)
    ua = ra - n1 * (n1 + 1) / 2  # pairs with a > b
    n = n1 + n2
    sd = math.sqrt(n1 * n2 / 12 * ((n + 1) - ties / (n * (n - 1))))
    z = (ua - n1 * n2 / 2) / sd if sd else 0.0
    p = math.erfc(abs(z) / math.sqrt(2))
    return ua / (n1 * n2), p


metric, A, B = sys.argv[1], sys.argv[2], sys.argv[3]
pooled = {}
for spec in sys.argv[4:]:
    parts = spec.split(':')
    sess = parts[0]
    aa, bb = (parts[1], parts[2]) if len(parts) == 3 else (A, B)
    d = json.load(open(f"logs/{sess}-raw.json"))
    for bench, arms in d["runs"].items():
        for name, rows in arms.items():
            arm, cfg = name.rsplit('_', 1)
            if arm not in (aa, bb):
                continue
            pooled.setdefault((bench, cfg), {}).setdefault(sess, {})[A if arm == aa else B] = [r[metric] for r in rows]
for (bench, cfg), sessions in sorted(pooled.items()):
    pa, pb = [], []
    cells = []
    for sess, ab in sessions.items():
        if A not in ab or B not in ab:
            continue
        a, b = ab[A], ab[B]
        pa += a
        pb += b
        beyond = "<" if max(b) < min(a) else (">" if min(b) > max(a) else " ")
        cells.append(f"{sess} {st.median(a):7.2f}→{st.median(b):7.2f} ({(st.median(b) / st.median(a) - 1) * 100:+5.1f}%){beyond}")
    if not pa:
        continue
    pr, p = mwu(pa, pb)
    print(f"{bench:14} {cfg}  " + "  ".join(cells) +
          f"  | pooled n={len(pa)}/{len(pb)} {st.median(pa):.2f}→{st.median(pb):.2f} "
          f"({(st.median(pb) / st.median(pa) - 1) * 100:+.1f}%) P(B<A)={pr:.2f} p={p:.2g}")
