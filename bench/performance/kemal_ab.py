#!/usr/bin/env python3
"""Build and measure rotated, paired Kemal trials. See README.md for config."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import socket
import subprocess
import time
import urllib.error
import urllib.request


def command(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def proc_stats(pid):
    # comm may contain spaces or parentheses: fields after the final ')' start at 3.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    status = Path(f"/proc/{pid}/status").read_text()
    return {
        "minflt": int(fields[7]),
        "cpu_ticks": int(fields[11]) + int(fields[12]),
        "hwm_kb": int(re.search(r"VmHWM:\s+(\d+)", status)[1]),
        "rss_kb": int(re.search(r"VmRSS:\s+(\d+)", status)[1]),
    }


def parse_wrk(output):
    count = re.search(r"(\d+) requests in", output)
    if not count or int(count[1]) == 0:
        raise ValueError("wrk returned no completed requests")
    errors = dict.fromkeys(("connect", "read", "write", "timeout", "http"), 0)
    sockets = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", output)
    if sockets:
        errors.update(zip(("connect", "read", "write", "timeout"), map(int, sockets.groups())))
    http = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", output)
    if http:
        errors["http"] = int(http[1])
    latency = {}
    for percentile, value, unit in re.findall(r"^\s*(50|75|90|99)%\s+([\d.]+)(us|ms|s)\s*$", output, re.MULTILINE):
        latency["p" + percentile] = float(value) * {"us": 1, "ms": 1000, "s": 1000000}[unit]
    return {"requests": int(count[1]), "errors": errors, "latency_us": latency}


def fetch(base, path):
    with urllib.request.urlopen(base + path, timeout=2) as response:
        return response.read()


def run_wrk(args, base, seconds):
    start = time.monotonic_ns()
    result = subprocess.run(
        ["wrk", f"-t{args.threads}", f"-c{args.connections}", f"-d{seconds}s",
         "--latency", "--timeout", "5s", base + args.path],
        capture_output=True, text=True, timeout=seconds + 15,
    )
    elapsed = time.monotonic_ns() - start
    output = result.stdout + result.stderr
    try:
        parsed = parse_wrk(output)
    except ValueError as error:
        parsed = {"requests": 0, "errors": {}, "error": str(error)}
    parsed.update(wall_ns=elapsed, rps=parsed["requests"] * 1e9 / elapsed,
                  exit_code=result.returncode, output=output)
    return parsed


def check_port(port):
    # SO_REUSEADDR accepts TIME_WAIT but still rejects a live listening socket.
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", port))


def trial(args, arm, directory, port):
    base = f"http://127.0.0.1:{port}"
    env = os.environ.copy()
    # Do not inherit an unnoticed tuning variable into every arm.
    for key in list(env):
        if key.startswith("GCRY_") or key in ("EC_PARALLELISM", "CRYSTAL_WORKERS", "BENCH_HEADER_POLICY"):
            del env[key]
    env.update(arm["env"], PORT=str(port))
    row = {"arm": arm["name"], "load1": os.getloadavg()[0], "clk_tck": os.sysconf("SC_CLK_TCK")}
    check_port(port)
    with (directory / "server.log").open("w") as log:
        server = subprocess.Popen([arm["binary"]], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 20
            while True:
                if server.poll() is not None:
                    raise RuntimeError(f"server exited: {server.returncode}")
                try:
                    fetch(base, args.path)
                    break
                except (OSError, urllib.error.URLError):
                    if time.monotonic() >= deadline:
                        raise RuntimeError("server readiness timed out")
                    time.sleep(0.1)
            warm = run_wrk(args, base, args.warmup)
            (directory / "warmup.txt").write_text(warm.pop("output"))
            if warm.get("error") or warm["exit_code"] or any(warm["errors"].values()):
                row["warmup"] = warm
                raise RuntimeError("warmup failed")
            if arm["gcry"]:
                stats = json.loads(fetch(base, "/gc-stats"))
                (directory / "stats-before.json").write_text(json.dumps(stats, indent=2))
            before = proc_stats(server.pid)
            measured = run_wrk(args, base, args.seconds)
            after = proc_stats(server.pid)
            (directory / "wrk.txt").write_text(measured.pop("output"))
            row.update(measured)
            row.update({key: after[key] - before[key] for key in ("minflt", "cpu_ticks")})
            row.update({key: after[key] for key in ("hwm_kb", "rss_kb")})
            if row.get("error") or row["exit_code"] or any(row["errors"].values()):
                raise RuntimeError("measurement contains request errors")
            if arm["gcry"]:
                (directory / "stats-after.json").write_bytes(fetch(base, "/gc-stats"))
            fetch(base, "/gc-collect")
            row["post_gc_rss_kb"] = proc_stats(server.pid)["rss_kb"]
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            row["error"] = str(error)
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGKILL)
            server.wait()
    row["load1_end"] = os.getloadavg()[0]
    return row


def build_arms(config, output):
    arms = []
    names = set()
    # Worktrees omit the ignored shard.lock. Share one dependency resolution
    # across all arms without copying lib/ (which can point at another gcry).
    shared_lock = next((lock.read_bytes() for entry in config if "root" in entry
                        for lock in [Path(entry["root"]) / "bench/kemal/shard.lock"]
                        if lock.exists()), None)
    for entry in config:
        name = entry["name"]
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", name) or name in names:
            raise ValueError(f"invalid or duplicate arm name: {name}")
        names.add(name)
        if "copy_of" in entry:
            source = next((arm for arm in arms if arm["name"] == entry["copy_of"]), None)
            if source is None or set(entry) != {"name", "copy_of"}:
                raise ValueError("copy_of must name an earlier arm and preserve its configuration")
            arms.append(dict(source, name=name, copy_of=entry["copy_of"]))
            continue
        root = Path(entry["root"]).resolve()
        flags = entry.get("flags", ["--release", "-Dgc_none", "-Dgcry_headerless"])
        if not isinstance(flags, list) or not all(isinstance(flag, str) for flag in flags):
            raise ValueError("flags must be a string array")
        env = entry.get("env", {})
        if not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
            raise ValueError("env must map strings to strings")
        binary = output / name
        app = root / "bench/kemal"
        build = ["crystal", "build", *flags, "src/server.cr", "-o", str(binary)]
        # Includes dirty/untracked source so a tree hash alone cannot hide an edit.
        source_hash = hashlib.sha256()
        for source in sorted((root / "src").rglob("*.cr")):
            source_hash.update(str(source.relative_to(root)).encode())
            source_hash.update(source.read_bytes())
        arm = dict(name=name, root=str(root), flags=flags, env=env, binary=str(binary),
                   gcry="-Dgc_none" in flags, commit=command(["git", "rev-parse", "HEAD"], root),
                   tree=command(["git", "rev-parse", "HEAD^{tree}"], root),
                   dirty=command(["git", "status", "--porcelain"], root),
                   source_sha256=source_hash.hexdigest(), build=build)
        print(f"Building {name}", flush=True)
        with (output / f"{name}-build.log").open("w") as log:
            lock = app / "shard.lock"
            if shared_lock is not None:
                if lock.exists() and lock.read_bytes() != shared_lock:
                    raise ValueError(f"dependency lock differs between arms: {lock}")
                if not lock.exists():
                    lock.write_bytes(shared_lock)
            subprocess.run(["shards", "install", *(["--production"] if shared_lock is not None else [])],
                           cwd=app, stdout=log, stderr=log, check=True)
            if shared_lock is None:
                shared_lock = lock.read_bytes()
            (output / "shared-shard.lock").write_bytes(shared_lock)
            subprocess.run([str(root / "bench/assert_gcry_lib.sh"), "lib/gcry", str(root)],
                           cwd=app, stdout=log, stderr=log, check=True)
            subprocess.run(build, cwd=app, stdout=log, stderr=log, check=True)
        arm["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        arm["shard_lock_sha256"] = hashlib.sha256(shared_lock).hexdigest()
        arm["server_source_sha256"] = hashlib.sha256((app / "src/server.cr").read_bytes()).hexdigest()
        arm["gcry_lib"] = str((app / "lib/gcry").resolve())
        arms.append(arm)
    return arms


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("output", type=Path, help="new directory; existing results are never overwritten")
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--seconds", type=int, default=15)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--connections", type=int, default=100)
    parser.add_argument("--port", type=int, default=4400)
    parser.add_argument("--path", default="/json")
    args = parser.parse_args()
    if min(args.rounds, args.seconds, args.warmup, args.threads, args.connections) <= 0:
        parser.error("rounds, durations, threads and connections must be positive")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "runner.py").write_bytes(Path(__file__).read_bytes())
    config = json.loads(args.config.read_text())
    if len(config) < 2:
        parser.error("supply at least two arms, including a reference")
    arms = build_arms(config, args.output)
    manifest = dict(arms=arms, compiler=command(["crystal", "--version"]),
                    platform=platform.platform(), cpu=Path("/proc/cpuinfo").read_text().split("\n\n", 1)[0],
                    cpu_count=os.cpu_count(), affinity=sorted(os.sched_getaffinity(0)),
                    clk_tck=os.sysconf("SC_CLK_TCK"), config=vars(args),
                    rate_clock="monotonic_ns around wrk subprocess, including startup/exit overhead")
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2, default=str))
    failed = False
    with (args.output / "trials.jsonl").open("w") as output:
        for round_id in range(args.rounds):
            for position in range(len(arms)):
                arm = arms[(position + round_id) % len(arms)]
                directory = args.output / f"{round_id:03d}-{arm['name']}"
                directory.mkdir()
                try:
                    row = trial(args, arm, directory, args.port + round_id * len(arms) + position)
                except OSError as error:
                    row = {"arm": arm["name"], "error": str(error)}
                row.update(round=round_id, position=position)
                output.write(json.dumps(row) + "\n")
                output.flush()
                failed |= "error" in row
                print(json.dumps(row), flush=True)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
