#!/usr/bin/env python3
"""Extract request latency and bracketing GC snapshots from a completed raw run."""
import argparse
import json
from pathlib import Path

from analyze import analyze
from kemal_ab import parse_wrk


def extract(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    trials = [json.loads(line) for line in (directory / "trials.jsonl").read_text().splitlines()]
    expected = {(r, arm["name"]) for r in range(manifest["config"]["rounds"]) for arm in manifest["arms"]}
    if {(row["round"], row["arm"]) for row in trials} != expected:
        raise ValueError("cannot extract an incomplete run")
    analyze(trials, manifest["arms"][0]["name"])
    result = []
    for trial in trials:
        raw = directory / f"{trial['round']:03d}-{trial['arm']}"
        row = {key: trial[key] for key in ("arm", "round")}
        row["request_latency_us"] = parse_wrk((raw / "wrk.txt").read_text())["latency_us"]
        if not row["request_latency_us"]:
            raise ValueError(f"missing request latency: {raw}")
        if (raw / "stats-before.json").exists():
            before = json.loads((raw / "stats-before.json").read_text())
            after = json.loads((raw / "stats-after.json").read_text())
            for key in ("collections", "pause_total_ns"):
                delta = after[key] - before[key]
                if delta < 0:
                    raise ValueError(f"counter went backwards: {raw}/{key}")
                row[key + "_delta"] = delta
            # This interval includes the stats endpoint requests surrounding
            # wrk. It is not a window-specific GC pause histogram.
            row["approx_gc_duty_percent"] = row["pause_total_ns_delta"] / trial["wall_ns"] * 100
            row["policy_after"] = {key: after[key] for key in
                                   ("gc_threshold", "adaptive_threshold", "empty_chunk_warm_retain", "bitmap_alloc")}
        result.append(row)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw_directory", type=Path)
    args = parser.parse_args()
    for row in extract(args.raw_directory):
        print(json.dumps(row))


if __name__ == "__main__":
    main()
