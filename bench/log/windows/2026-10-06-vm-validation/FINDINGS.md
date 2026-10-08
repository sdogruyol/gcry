# Windows x86_64: first workload numbers against Boehm, and the PR #44 checks

The first run of real workloads on Windows. It was done on `readiness` at
`8b3372c`, and then on the fixes in the same push.

**Machine.** A 12-vCPU QEMU/KVM virtual machine (Proxmox), **not physical
hardware**: Windows 11 Pro 25H2, build 26200.9457, 16 GiB (`machine.txt`).
- Toolchain: Crystal 1.21.0 MSVC. Crystal picks the newest MSVC by itself: VS
  Build Tools 2026, cl 19.51.36257, link 14.51.36257.
- Shells: GNU Make 4.4.1 under Git Bash, and PowerShell 7.6.6.
- Power plan: High performance.
- Defender real-time scanning stayed on. Every benchmark executable got one
  discarded warm-up run instead.

## CI on Windows

- `ci/windows.ps1` **default**: 294 library and 89 process examples, 0 failures.
- `ci/windows.ps1` **headers / freelist**: 316 library and 89 process examples
  each, 0 failures, apart from spec 35 below.
- All 19 lines of the `test (windows x86_64, gates)` job pass with their red
  arms on the first run (`gates-summary.txt`, 912 s).

**Spec 35 was flaky on Windows**
(`35_thread_birth_table_growth_spec.cr`):

| how it ran | failing runs |
|---|---|
| suite binary, default | 5 / 20 |
| suite binary, headers | 5 / 20 |
| suite binary, freelist | 2 / 20 |
| standalone | 11 / 20 |

The failures read `Expected 5..121 to be LessOrEqual 3`
(`spec35-before-*.txt`). The cause is the test, not a leak:

- **Why.** In Crystal 1.21, a thread that finishes its block before it is
  joined detaches itself (`Thread#start`'s `ensure`). `Thread#join` of a
  detached thread then returns without `WaitForSingleObject`. Checked right
  before each join, ≥ 299 of 300 threads had already detached, in 30 of 30
  runs (`spec35-probe-detached.txt`).
- **Effect.** On Windows a birth root ends only once gcry's own handle on the
  thread signals (`release_exited`). So three collections straight after the
  joins can still find threads that are exiting.
- **Not a leak.** The roots drain one or two collections later, in 40 of 40
  probe runs (`spec35-probe-slow-drain.txt`, `spec35-probe.cr`).
- **Fix.** The spec now collects until the roots are back, under a 5 s
  deadline. Result: 0 failures in 40 standalone runs. With
  `GCRY_THREAD_BIRTH_NOGROW=1` (the fixed 256-slot table) it still fails
  (`Expected 256 to be GreaterOrEqual 303`).

## What PR #44 changed, on Windows

| item | result |
|---|---|
| Foreign threads (spec 29) | Compiles. `GC_register_my_thread` answers `GC_UNIMPLEMENTED` (3). |
| Boehm ABI (specs 25, 27, 28, 31, each alone) | 5, 6, 6 and 4 examples, 0 failures. |
| `realloc` self-copy (spec 30) | 0 wrong bytes for `IO::Memory`, `String::Builder` and `Array#concat`, with and without `GCRY_REALLOC_MOVE=1`. The page move is Linux-only. |
| `GC.free`'d large blocks (spec 32) | Passes, so 0 bytes unmapped and 0 recycles. |
| Large blocks, `make gzip-free-reuse` | 2000 iterations in 58.2 ms, 136 KiB unmapped. |
| Large blocks, 20 000 iterations (`gzip-free-loop-20000.txt`) | gcry 397–456 ms, Boehm 1385–1444 ms. `GCRY_LARGE_RECYCLE=0` changes nothing, since the recycler is Linux-only. |
| Idle mark helpers (`mark-list-heap.txt`, 7 trials) | See below. |
| Loaded-DLL roots | Specs 16 and 34 are Linux-only, so nothing ran this until `process_spec/regression/36_windows_dll_static_roots_spec.cr`. It passes 20 of 20, and its control arm (library roots off) collects the object. |

Idle mark helpers (`mark-list-heap.txt`, 7 trials). The helpers sleep-poll
here, since Windows has no futex, and that costs nothing measurable:

| workers | median pause | CPU / wall |
|---|---:|---:|
| 1 (serial) | 30.4 ms | 0.99 |
| default (4) | 29.3 ms | 1.00 |
| 4 | 29.4 ms | 1.01 |

## crystal-metric vs Boehm

**Method** (`ab_win.py`):
- 11 trials. In each trial and for each bench, the four arms run in a
  freshly shuffled order, each as a fresh process.
- Wall time is the bench's own `in X s`.
- CPU and peak working set are read with `GetProcessTimes` and
  `GetProcessMemoryInfo().PeakWorkingSetSize` from the process handle after
  the process exited.
- Data: `crystal-metric-summary.md` and `crystal-metric-raw.jsonl`.
- The rerun of the weak rows (`crystal-metric-rerun-*`) used a rebuilt binary.
  Its code is byte-identical, so the rerun is a second sample, not a
  code-placement test.

| bench | gcry speed vs Boehm | Linux, same branch | peak working set × Boehm |
|---|---:|---:|---:|
| Primes | 95% (rerun 91%) | 100% | 0.92× |
| JsonParsePure | 88% (87%) | 91% | 1.14× |
| JsonParseSerializable | 87% (89%) | 88% | 0.92× |
| JsonParsePull | 88% (92%) | 91% | 0.92× |
| JsonGenerate | 104% | 105% | 0.64× |
| Binarytrees | 112% | 94% | 0.94× |
| RegexDna | 98% | 99% | 0.54× |
| Revcomp | 87% (88%) | 84% | 0.75× |
| Knuckeotide | 99% (98%) | 97–107% | 1.73× (1.62×) |
| Brainfuck / Brainfuck2 | 100% / 100% | 97–107% | 0.93× |
| Matmul | 101% | 97–107% | 1.18× |
| Threadring | 114% | 97–107% | 0.94× |

**Speed.** Every row is within the ±5–7% code-placement band of Linux, except
Binarytrees, which is faster here.

**The other arms.**
- Serial mark (`GCRY_PARALLEL_MARK=1`) takes Primes from 95% to 76%.
- `GCRY_THRESHOLD_PACE=100` costs 15 points on Primes and 13 on
  JsonParsePure.

**Memory.**
- JsonParsePure (591 vs 519 MiB) and Knuckeotide (93 vs 54 MiB) are transient
  peaks, not retention. At exit the heaps match Boehm (471 vs 474 MiB) or are
  small (6 MiB): `crystal-metric-gcstats.txt`.
- Peak working set is not Linux RSS. Pages that are decommitted and then
  recommitted count again.

**`err` rows.** Eight benches print `err` (a wrong checksum) on Windows under
Boehm too, with the same value in every arm, so the A/B still compares
identical work:
- The JSON benches fail even in a full-suite run.
- RegexDna, Revcomp and Knuckeotide fail only when run alone. Their `Fasta`
  input keeps its RNG state in a class variable, so `expected` holds only in
  full-suite order.

## Kemal

**Setup** (`kemal_ab.py`, `kemal-summary.md`, `kemal-raw.jsonl`):
- 7 trials, `/json` and `/` interleaved, a fresh server per run.
- The server is pinned to CPUs 0–5 and `oha -c 100 -z 10s` to CPUs 6–11,
  after a 2 s warm-up.

| endpoint | Boehm req/s | gcry req/s | gcry ÷ Boehm | peak working set |
|---|---:|---:|---:|---:|
| `/json` | 11 673 | 12 428 | 106.5% | 53.9 vs 47.4 MiB |
| `/` | 13 861 | 14 261 | 102.9% | 55.2 vs 48.6 MiB |

**Before this push, the server did not build on Windows.**
- `bench/kemal/src/server.cr` used `LibC.pipe` for `EXTRA_THREADS`. It now
  parks those threads with `Sleep(INFINITE)` on Windows.
- `shards install` there needs symlink rights: Developer Mode, or an elevated
  shell.
- The numbers above came from a copy without the `EXTRA_THREADS` block.

## Not covered

- Physical hardware.
- ARM64 Windows.
- A code-placement rebuild.
