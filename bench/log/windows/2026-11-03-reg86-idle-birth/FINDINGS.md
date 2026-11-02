# Regression 86's arms and the idle thread's birth (2026-11-03)

`test (windows x86_64, freelist)` failed in run 41360733235 (job
125010338086, `b1cfbba0`) at
`process_spec/regression/86_alloc_slow_path_clean_frames_spec.cr:132`,
`heap.collections.should be > collections_before`: `Expected 2 to be
GreaterThan 2`. `collections_before` is 2 at the third arm (wipe on, no
gap), so the third arm's allocation, with `gc_threshold = 1`, did not
collect. The planted-gap rework had passed there once (run 41344711745,
`23b6689a`); nothing between the two trees touches this path.

**Cause: the idle collector's birth, not the threshold or the pace.** The
idle thread (`IdleRelease`, on by default on Windows) is started at the end
of the process's first collection, which in this spec is the control arm's,
and `Thread#start` allocates on the new thread (its main `Fiber`, the
UTF-16 name for `system_name=`) until `loop_forever` makes it signal-exempt.
On windows-latest that birth runs late enough to land inside a later arm's
window, between `gc_threshold = 1` and the `ensure` that restores it. The
idle thread's allocation then sees debt ≥ 1 and collects, and when that
collection is still running as the arm allocates, `maybe_collect` returns at
`return if @collecting`, before it counts the operation: no collection on the
arm's allocation, and `stale` stays -1. When it is not still running, the
arm passes with one collection more than it caused, and the hook could have
measured the idle thread's collection (from its SP) rather than the arm's.

## Evidence

Probe workflow `probe-win86.yml` on `probe/win86-collect` (deleted after;
the last run's workflow is reproduced below, the earlier runs differed only
in shards and loop counts), windows-latest, Crystal 1.21.0, the
freelist job's configuration (`GCRY_BITMAP_ALLOC=0`, `crystal build
--release -Dgc_none -Dgcry_block_headers` of the spec file alone, as
`ci/windows.ps1` builds it), the binary looped. The spec carried
`diag.patch`: the heap state read just before and just after each arm's
allocation, printed after the `ensure`. It reads; it changes no behaviour.

Run 41365744631 (`b1cfbba0` + diagnostics), 2 × 100 runs: **5 failures**,
all at the third arm, all with the same state:

```
diag86: nocollect wipe=true gap=false before=3 coll_pre=3 bsg_pre=32 bsg_post=112 ops 273->273 enabled=true collecting=true suppress=0 inc=false thr=33554432 idle=0
diag86: nocollect wipe=true gap=false before=2 coll_pre=2 bsg_pre=576 bsg_post=656 ops 273->273 enabled=true collecting=true suppress=0 inc=false thr=33554432 idle=0
```

The debt is positive (`bsg_pre` 32 and 576 ≥ the threshold of 1), the heap
enabled, nothing suppressed, no incremental cycle: `collecting=true`, and
`@alloc_ops` did not move, so `maybe_collect` returned at `@collecting`. In
the passing runs other allocators show up in the windows: `@alloc_ops`
(heap-wide) advanced by 2 in the second arm's window in 69 of 200 runs and
by 2–3 in the first's (+2 on Linux too; [INFERENCE] the extra one is
`ensure_started`'s `Thread.new` on the main thread), and the third arm started at 3
collections instead of 2 in 66 of 195: the idle thread had collected once
inside the second arm's window. Linux (local, `GCRY_BITMAP_ALLOC=0`, 200
runs) did not fail: the birth is over before the second arm there.

## Fix

The spec waits the birth out before any arm (`stale86_settle_idle_thread`):
it runs the process's first collection itself (`GC.collect`, which starts
the idle thread if `IdleRelease.armed?`) and waits until a listed thread is
`IdleRelease.signal_exempt?`, which `loop_forever` sets after `Thread#start`
has done all its allocating; failing after 10 s. From then on the idle
thread allocates nothing until it collects at idle, two minutes away. The
first try looked the thread up once right after the collection and failed
every run (600 of 600, run 41366279331): the thread puts itself on
Crystal's list from its own `Thread#start`, so it is not listed yet when
the collection returns; the wait covers both. No check changed.

Run 41366725026 (fix + the same diagnostics), 4 × 150 runs: **0 failures**.
Every arm of all 600 moved `@alloc_ops` by exactly 1 and `collections` by
exactly 1 (1→2, 2→3, 3→4: the settle's collection is the first);
`stale86: control 44, fixed 0, no gap 0; wipe starts 0 bytes below the
entry SP` in every run. Run 41367466992 (the pushed spec itself, no
diagnostics, rebased on `782e7510`), 2 × 100 runs: **0 failures**, the same
`stale86` line in all 200.

Local, Linux x86-64, the fixed spec: 100 runs each of the freelist and the
default (headerless) release builds, 0 failures (`control 29`/`27, fixed
0, no gap 0`); the debug `crystal spec` of the file passes (it skips the
measure).

## Probe workflow

```yaml
name: probe-win86
on:
  push:
    branches: ["probe/win86-collect"]
jobs:
  loop:
    runs-on: windows-latest
    timeout-minutes: 40
    strategy:
      fail-fast: false
      matrix:
        shard: [a, b]
    steps:
      - uses: actions/checkout@v7
      - uses: crystal-lang/install-crystal@v1
        with:
          crystal: "1.21.0"
      - name: Loop regression 86 (freelist, release)
        shell: pwsh
        run: |
          $env:GCRY_BITMAP_ALLOC = '0'
          New-Item -ItemType Directory -Force bin | Out-Null
          crystal build --release -Dgc_none -Dgcry_block_headers process_spec/regression/86_alloc_slow_path_clean_frames_spec.cr -o bin/r86.exe --error-trace
          if ($LASTEXITCODE -ne 0) { throw 'build failed' }
          $fails = 0
          for ($i = 1; $i -le 100; $i++) {
            $out = & ./bin/r86.exe 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
              $fails++
              Write-Host "=== run $i FAILED"
              Write-Host $out
            } else {
              ($out -split "`n") | Where-Object { $_ -match '^(diag86|stale86)' } | Select-Object -First 4 | ForEach-Object { Write-Host "run ${i}: $_" }
            }
          }
          Write-Host "fails=$fails of 100"
          if ($fails -ne 0) { exit 1 }
```
