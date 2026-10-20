"""Interleaved Kemal A/B (bench/kemal) on Linux and macOS: req/s and peak RSS.

usage: kemal_ab.py --out DIR --trials N --arm boehm=bin/kemal-boehm
                   --arm base=... --arm var=... [--paths /json,/]
                   [--stats N --stats-arm base=... --stats-arm var=...]

Per trial and path, every arm in random order: start the server fresh, wait
until `/` answers, warm with wrk for --warm seconds, measure with wrk for
--duration seconds, then read the server's peak RSS and SIGTERM it. Linux
reads `VmHWM` from /proc before the signal: `wait4`'s `ru_maxrss` there
carries the pre-`exec` high-water mark, Python's ~20 MiB, which is above a
Kemal server's peak. macOS has no /proc and does not inherit it in the same
way: there `ru_maxrss` (bytes) is read after the exit, and the floor of the
method is measured by running `true` the same way (`floor` in the outputs).
No CPU pinning: macOS has no `taskset`, and a hosted runner's few vCPUs are
shared by wrk and the server, so absolute req/s are low and noisy — the
paired per-trial ratio is the number to read.

Each run also records the server's user and kernel CPU seconds and page
faults (`wait4` rusage), the requests wrk completed in the warm-up and the
measurement, and, from gcry arms, `/gc-stats` read after the measurement
(collections, pauses, heap size; Boehm has no such route). A second table
puts them per request served: the same source should do the same collector
work per request whatever its speed, so a slower arm with equal work per
request is running the same code slower.

`--stats N` runs each `--stats-arm` (a counter build: bench/runner_ab/
gc_counters.cr in front of server.cr) N times per path the same way, and
writes its `GCSTATS` line at exit, with the requests served, to
`kemal-gc-counters.txt`: the bytes allocated per request are there.

Outputs `kemal-runs.json` and `kemal-summary.md` in --out. Windows is not
supported: there is no wrk.
"""
import argparse, json, os, random, re, signal, statistics, subprocess, sys, tempfile, time, urllib.request


def wait_up(port):
    for _ in range(200):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1).read()
            return True
        except OSError:
            time.sleep(0.05)
    return False


def wrk(port, path, secs, threads, conns):
    """(req/s, non-2xx responses, requests completed) of one wrk run."""
    out = subprocess.run(["wrk", f"-t{threads}", f"-c{conns}", f"-d{secs}s", f"http://127.0.0.1:{port}{path}"],
                         capture_output=True, text=True).stdout
    m = re.search(r"Requests/sec:\s+([0-9.]+)", out)
    non2xx = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", out)
    n = re.search(r"(\d+) requests in", out)
    return (float(m.group(1)) if m else None), (int(non2xx.group(1)) if non2xx else 0), (int(n.group(1)) if n else None)


def gc_stats(port):
    """The fields of gcry's `/gc-stats` this summary reads, or None (Boehm)."""
    try:
        s = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/gc-stats", timeout=5).read())
    except (OSError, ValueError):
        return None
    return {k: s.get(k) for k in ("collections", "major_collections", "minor_collections", "pause_count",
                                  "pause_total_ns", "pause_max_ns", "heap_size", "live_objects")}


def quart(xs):
    q = statistics.quantiles(xs, n=4, method="inclusive") if len(xs) > 1 else [xs[0]] * 3
    return q[0], statistics.median(xs), q[2]


def vm_hwm(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            return next(int(l.split()[1]) * 1024 for l in f if l.startswith("VmHWM:"))
    except OSError:
        return None


def serve(exe, env, a, path, stats_route):
    """One server process: start, warm, measure, stop. Returns the run's row
    without its trial/arm keys, and the server's stderr."""
    with tempfile.TemporaryFile() as err:
        p = subprocess.Popen([exe], env=env, stdout=subprocess.DEVNULL, stderr=err)
        up = wait_up(a.port)
        rps = non2xx = warm_n = n = gc = None
        if up:
            _, _, warm_n = wrk(a.port, path, a.warm, a.threads, a.connections)
            rps, non2xx, n = wrk(a.port, path, a.duration, a.threads, a.connections)
            gc = gc_stats(a.port) if stats_route else None
        hwm = vm_hwm(p.pid)
        p.send_signal(signal.SIGTERM)
        _, status, ru = os.wait4(p.pid, 0)
        err.seek(0)
        stderr = err.read().decode(errors="replace")
    peak = hwm or ru.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    row = dict(path=path, rps=rps, non2xx=non2xx, peak=peak, up=up, warm_requests=warm_n, requests=n,
               utime=ru.ru_utime, stime=ru.ru_stime, faults=ru.ru_minflt + ru.ru_majflt, gc=gc)
    time.sleep(0.3)  # let the port go before the next server binds it
    return row, stderr


def per_request_table(rows, names, paths):
    """CPU, faults and collector work per 1 000 requests served (warm-up and
    measurement both; the server's whole life), medians over trials."""
    lines = ["## Work per request", "",
             "Per 1 000 requests served (warm-up included), medians over trials [IQR]. "
             "Collections and pause from `/gc-stats` (gcry arms only).", ""]
    for path in paths:
        lines += [f"### `{path}`", "", "| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |",
                  "|---|---:|---:|---:|---:|---:|---:|"]
        for arm in names:
            rs = [r for r in rows if r["arm"] == arm and r["path"] == path and r["requests"] and r["warm_requests"]]
            if not rs:
                continue
            k = [1000 / (r["requests"] + r["warm_requests"]) for r in rs]

            def cell(f, fmt="{:.2f}"):
                xs = [f(r) * kk for r, kk in zip(rs, k) if f(r) is not None]
                if not xs:
                    return "—"
                q = quart(xs)
                return f"{fmt.format(q[1])} [{fmt.format(q[0])}, {fmt.format(q[2])}]"

            lines.append(f"| {arm} | {cell(lambda r: 1000 * (r['utime'] + r['stime']))} | "
                         f"{cell(lambda r: 1000 * r['utime'])} | {cell(lambda r: 1000 * r['stime'])} | "
                         f"{cell(lambda r: r['faults'], '{:.1f}')} | "
                         f"{cell(lambda r: r['gc'] and r['gc']['collections'], '{:.3f}')} | "
                         f"{cell(lambda r: r['gc'] and r['gc']['pause_total_ns'] and r['gc']['pause_total_ns'] / 1e6, '{:.3f}')} |")
        lines.append("")
    return lines


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--trials", type=int, default=9)
    ap.add_argument("--arm", action="append", required=True, help="name=path")
    ap.add_argument("--paths", default="/json,/")
    ap.add_argument("--warm", type=int, default=3)
    ap.add_argument("--duration", type=int, default=10)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--connections", type=int, default=50)
    ap.add_argument("--port", type=int, default=3101)
    ap.add_argument("--stats", type=int, default=0, help="counter runs per --stats-arm and path")
    ap.add_argument("--stats-arm", action="append", default=[], help="name=path of a counter build")
    a = ap.parse_args()
    arms = dict(s.split("=", 1) for s in a.arm)
    names, paths = list(arms), a.paths.split(",")
    os.makedirs(a.out, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("GCRY_")}
    env["PORT"] = str(a.port)
    rows = []
    t0 = subprocess.Popen(["true"])
    floor = os.wait4(t0.pid, 0)[2].ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    for t in range(a.trials):
        for path in paths:
            order = names[:]
            random.shuffle(order)
            for arm in order:
                row, _ = serve(arms[arm], env, a, path, stats_route=arm != "boehm")
                rows.append(dict(trial=t, arm=arm, **row))
        print(f"trial {t + 1}/{a.trials} done", file=sys.stderr, flush=True)
        with open(os.path.join(a.out, "kemal-runs.json"), "w") as f:
            json.dump(dict(arms=arms, args=vars(a), platform=sys.platform, floor=floor, runs=rows), f, indent=0)
    ref = "boehm" if "boehm" in arms else names[0]
    lines = [f"Kemal, {a.trials} trials, wrk -t{a.threads} -c{a.connections} {a.duration} s after {a.warm} s warm-up; "
             f"cells: req/s as % of {ref} and peak RSS × {ref}, medians of per-trial paired ratios [IQR]. "
             + ("Peak RSS: VmHWM." if sys.platform.startswith("linux") else
                f"Peak RSS: ru_maxrss; floor of the method (`true`): {floor / 2**20:.1f} MiB."), ""]
    for path in paths:
        by = {(r["arm"], r["trial"]): r for r in rows if r["path"] == path and r["rps"]}
        lines += [f"## `{path}`", "", "| arm | req/s (median) | % of " + ref + " | peak RSS | × " + ref + " |",
                  "|---|---:|---:|---:|---:|"]
        for arm in names:
            ts = [t for t in range(a.trials) if (arm, t) in by and (ref, t) in by]
            if not ts:
                continue
            rps = statistics.median(by[(arm, t)]["rps"] for t in ts)
            pk = statistics.median(by[(arm, t)]["peak"] for t in ts) / 2**20
            sp = quart([100 * by[(arm, t)]["rps"] / by[(ref, t)]["rps"] for t in ts])
            mx = quart([by[(arm, t)]["peak"] / by[(ref, t)]["peak"] for t in ts])
            lines.append(f"| {arm} | {rps:.0f} | {sp[1]:.1f}% [{sp[0]:.1f}, {sp[2]:.1f}] | {pk:.1f} MiB | "
                         f"{mx[1]:.2f}× [{mx[0]:.2f}, {mx[2]:.2f}] |")
        lines.append("")
    lines += per_request_table(rows, names, paths)
    bad = [r for r in rows if not r["up"] or not r["rps"] or r["non2xx"]]
    if bad:
        lines.append(f"Failed or non-2xx runs: {bad}")
    summary = "\n".join(lines) + "\n"
    with open(os.path.join(a.out, "kemal-summary.md"), "w") as f:
        f.write(summary)
    print(summary)

    # Counter builds, after the timed trials so they don't share a trial's
    # conditions with the arms being compared.
    stats_arms = dict(s.split("=", 1) for s in a.stats_arm)
    for i in range(a.stats):
        for path in paths:
            for arm, exe in stats_arms.items():
                row, stderr = serve(exe, env, a, path, stats_route=False)
                line = next((l for l in stderr.splitlines() if l.startswith("GCSTATS")), "GCSTATS missing")
                served = (row["warm_requests"] or 0) + (row["requests"] or 0)
                out = f"{arm} {path} {i + 1} rps={row['rps']} requests={served} {line}"
                print(out, flush=True)
                with open(os.path.join(a.out, "kemal-gc-counters.txt"), "a") as f:
                    f.write(out + "\n")


if __name__ == "__main__":
    main()
