#!/usr/bin/env python3
"""Compare root_phase_ab.sh samples within a heap regime instead of across two.

`root_phase_ab.sh` refuses to quote medians when a config's IQR exceeds 50% of
its median, and prints:

    *** WARNING: multimodal samples — these medians are NOT comparable ***
        Stratify (heap_size is the usual discriminator) and compare within a
        stratum before quoting anything.

That instruction had no tool behind it. This is the tool. The fat app
(acikturkiye) is bistable between a ~46 MiB and a ~70 MiB heap regime and draws
its regime *per process*, so an unstratified median is a median over two
different machines — and the two regimes differ by ~10x in root-scan cost, so
the mixture ratio, not the config, decides the answer.

Sample selection matches the harness: `collect_end` records only, dropping the
first BENCH_SKIP_COLLECTS (default 5) of each rep, where the heap is still
growing and the collections are not samples of the steady state.

Usage:
    bench/stratify_root_phase.py bench/log/linux/<session>-root-phase
    bench/stratify_root_phase.py <dir> --skip=5 --cut=55 --base=tuned

`--cut` is the heap size in MiB that splits the regimes; put it in the trough
between the two modes, which the harness prints as `heap MiB p10/p50/p90`.
Reads `*.ndjson` or `*.ndjson.gz` (committed sessions are gzipped).

Read the caveats it prints. Unequal rep counts per stratum are expected and not
fixable from here — the regime is drawn per process, so more reps buy more
draws, not balance. A within-stratum IQR still near 50% means the magnitude is
soft even when the sign reproduces.
"""
import glob
import gzip
import json
import os
import statistics as st
import sys


def parse_args(argv):
    if not argv or argv[0].startswith("-"):
        sys.exit(__doc__)
    opts = {"dir": argv[0], "skip": 5, "cut": 55.0, "base": None}
    for a in argv[1:]:
        if a.startswith("--skip="):
            opts["skip"] = int(a.split("=", 1)[1])
        elif a.startswith("--cut="):
            opts["cut"] = float(a.split("=", 1)[1])
        elif a.startswith("--base="):
            opts["base"] = a.split("=", 1)[1]
        else:
            sys.exit(f"unknown argument: {a}\n\n{__doc__}")
    return opts


def opener(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def sample_files(d):
    return sorted(glob.glob(f"{d}/*-rep*.ndjson") + glob.glob(f"{d}/*-rep*.ndjson.gz"))


def config_of(path):
    return os.path.basename(path).rsplit("-rep", 1)[0]


def rep_of(path):
    return os.path.basename(path).rsplit("-rep", 1)[1].split(".")[0]


def load(d, cfg, skip):
    out = []
    for p in sample_files(d):
        if config_of(p) != cfg:
            continue
        recs = []
        with opener(p) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("event") == "collect_end":
                    r["_rep"] = rep_of(p)
                    recs.append(r)
        out.extend(recs[skip:])
    return out


def iqr_pct(xs):
    """IQR as % of median — the harness's own comparability test (>50% = mixed)."""
    if len(xs) < 4:
        return float("nan")
    q = st.quantiles(xs, n=4)
    m = st.median(xs)
    return (q[2] - q[0]) / m * 100 if m else float("nan")


def main():
    o = parse_args(sys.argv[1:])
    d, skip, cut = o["dir"], o["skip"], o["cut"]

    configs = sorted({config_of(p) for p in sample_files(d)})
    if not configs:
        sys.exit(f"no *-rep*.ndjson[.gz] under {d}")
    base = o["base"] or ("tuned" if "tuned" in configs else configs[0])
    if base not in configs:
        sys.exit(f"base {base!r} not among configs: {', '.join(configs)}")

    rows = {}
    for cfg in configs:
        recs = load(d, cfg, skip)
        strata = (("small", lambda h: h < cut), ("large", lambda h: h >= cut))
        for name, keep in strata:
            s = [r for r in recs if keep(r["heap_size"] / 2**20)]
            if not s:
                continue
            # roots + scrub + stacks: the phases a root-completeness knob moves.
            work = [(r["roots_ns"] + r["scrub_ns"] + r["stacks_ns"]) / 1e3 for r in s]
            pause = [r["pause_ns"] / 1e6 for r in s]
            rows[(cfg, name)] = {
                "n": len(s),
                "reps": len({r["_rep"] for r in s}),
                "heap": st.median([r["heap_size"] / 2**20 for r in s]),
                "pause": st.median(pause),
                "pause_iqr": iqr_pct(pause),
                "work": st.median(work),
                "work_iqr": iqr_pct(work),
                "mark": st.median([r["mark_ns"] / 1e3 for r in s]),
                "sweep": st.median([r["sweep_ns"] / 1e6 for r in s]),
            }

    print(f"\n{d}")
    print(f"stratified at heap = {cut:.0f} MiB; skip={skip} collects/rep; base={base}\n")
    hdr = (f"{'config':<12}{'stratum':<8}{'n':>6}{'reps':>6}{'heap':>7}"
           f"{'pause ms':>10}{'IQR%':>7}{'Δpause':>9}"
           f"{'work µs':>11}{'IQR%':>7}{'Δwork':>9}{'mark µs':>10}{'sweep ms':>10}")
    print(hdr)
    print("-" * len(hdr))

    soft = []
    for stratum in ("small", "large"):
        b = rows.get((base, stratum))
        for cfg in configs:
            r = rows.get((cfg, stratum))
            if not r:
                continue
            dp = f"{(r['pause']/b['pause']-1)*100:+.1f}%" if b and b["pause"] else "—"
            dw = f"{(r['work']/b['work']-1)*100:+.1f}%" if b and b["work"] else "—"
            print(f"{cfg:<12}{stratum:<8}{r['n']:>6}{r['reps']:>6}{r['heap']:>7.0f}"
                  f"{r['pause']:>10.1f}{r['pause_iqr']:>7.0f}{dp:>9}"
                  f"{r['work']:>11.1f}{r['work_iqr']:>7.0f}{dw:>9}"
                  f"{r['mark']:>10.1f}{r['sweep']:>10.1f}")
            if r["pause_iqr"] > 40 or r["work_iqr"] > 40:
                soft.append(f"{cfg}/{stratum}")
        print()

    reps = {(c, s): rows[(c, s)]["reps"] for (c, s) in rows}
    for stratum in ("small", "large"):
        counts = {c: reps[(c, stratum)] for c in configs if (c, stratum) in reps}
        if counts and max(counts.values()) - min(counts.values()) >= 3:
            print(f"NOTE {stratum} stratum has unequal rep counts "
                  f"({', '.join(f'{c}={n}' for c, n in counts.items())}) — the regime "
                  f"is drawn per process and cannot be pinned from the harness.")
    if soft:
        print(f"NOTE within-stratum IQR still > 40% for: {', '.join(soft)}. "
              f"Treat the sign as the result and the magnitude as soft.")
    print()


if __name__ == "__main__":
    main()
