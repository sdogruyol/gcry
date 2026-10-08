# Windows support

Windows supports x86_64 with Crystal's MSVC distribution and ARM64 with the
GNU/MinGW distribution. Build from a PowerShell terminal with Crystal and its
matching linker dependencies available:

```powershell
crystal build -Dgc_none app.cr -o app.exe
.\app.exe
```

The application must `require "gcry"`, as on Linux and macOS. WSL is not needed.

## ARM64 toolchain

The `windows-11-arm` CI jobs use the native
[Crystal 1.21.0 ARM64 GNU archive](https://github.com/crystal-lang/crystal/releases/download/1.21.0/crystal-1.21.0-windows-aarch64-gnu-unsupported.zip).
This distribution is labelled `unsupported` upstream. MSYS2's `CLANGARM64`
environment supplies the matching linker and import libraries. The installer
pins the archive's SHA-256 and the CI runner verifies the compiler target and
PE machine type of each sample, so x86 emulation cannot satisfy the ARM64 gate.
The ARM64 port is validated on GitHub's native runner; no local ARM Windows
installation is used.

The ARM64 backend captures X0-X30, SP, and all 32 SIMD registers, preserves X18
(the thread-environment pointer), and excludes Windows' 16-byte red zone when
scrubbing dead stack. Conservative root scans include that red zone.

## Backend

- `VirtualAlloc` reserves and commits heap memory. Releasing whole chunks uses
  `VirtualFree`; adjacent reservations are released separately. Reclaiming dead
  pages decommits and recommits them at the same address, guaranteeing zeros.
  This reduces resident working set, but immediate recommit retains commit
  charge: `PagefileUsage` / Task Manager's Commit need not fall. Whole-chunk
  release returns both the reservation and its commit charge.
- `VirtualQuery` bounds conservative scanning and stack scrubbing to committed,
  readable memory. Root scans advance by region, including across unreadable
  holes, and leave `PAGE_GUARD` pages intact.
- Writable sections of the main PE executable supply static roots, including
  zero-initialized class variables. Since 2026-10-05 so do loaded DLLs, as
  under Boehm: writable `MEM_IMAGE` regions are walked again whenever a DLL
  notification changes the module generation (`windows_roots.cr`).
  Per-thread TLS copies are not scanned, matching Linux/macOS policy. Crystal
  threads and fibers are rooted through the runtime thread list and fiber roots;
  application references held only in native TLS require explicit roots.
- `SuspendThread` and `GetThreadContext` stop Crystal threads and capture stack
  pointers, integer registers, and floating-point/SIMD registers; nothing is
  written below the stopped SP, so the stack scan starts at it
  (`GCRY_SUSPENDED_SP_SLACK` is 0 here). `ResumeThread`
  releases them after collection. A thread that has already exited (its handle
  is signaled) is skipped: it has no stack or registers left to scan. Any other
  failed suspend/capture resumes all threads already stopped and fails the
  collection instead of scanning incomplete roots.
  Failure is reported without allocating until suspension and collector locks
  are released. Exception creation then suppresses process-GC auto-collection,
  including when suspension is requested directly through `GC.stop_world`.
- A `gc-idle` thread runs one releasing collection once the process has
  allocated nothing for two minutes (`GCRY_IDLE_RELEASE_MS`, `=0` turns it
  off), as on Linux and macOS. The stop suspends it like any other thread.
- Stopped-world stderr diagnostics use `WriteFile` on the standard error handle,
  bypassing CRT descriptor locks that a suspended mutator might hold.
- Thread creation publishes its birth root before resuming the new thread, and
  writes the thread's handle before the thread is listed, so a stop never sees
  a listed thread with a zero handle.
  SRW locks and FLS provide collector mutexes and cursor TLS; deleting a TLS key
  does not invoke cursor exit callbacks.

## Current limits

- The capture table starts at 64 threads and grows, sized before the first
  `SuspendThread`. A thread that appears between the count and the stop and
  does not fit is suspended and scanned without its SP clamp or registers
  (`stw_capture_no_slot`), the trade Linux makes.
- Fork, Unix signal diagnostics, soft-dirty, and the mprotect write barrier are
  unavailable. The conservative full-collection path remains available.
- The research stack-map walker assumes a SysV fiber context. Windows ignores
  `GCRY_PRECISE_STACK` and `GCRY_PRECISE_FIBERS` with a warning and retains
  conservative stack scanning.
- Boehm C ABI (`c_abi.cr`): a C-created thread registers with
  `GC_register_my_thread` as on Linux and macOS, and one that exits still
  registered comes off the thread list through an FLS callback;
  `GC_beginthreadex` starts a thread that is registered for its routine,
  and the stop-signal getters answer -1, as Boehm's do here. See
  [INTEGRATION.md § Boehm parity](INTEGRATION.md#boehm-parity).
- The large-object recycler and the `realloc` page move are Linux-only:
  `GCRY_LARGE_RECYCLE` and `GCRY_REALLOC_MOVE` have no effect on Windows
  (`bench/log/windows/2026-10-06-vm-validation/FINDINGS.md`, specs 30 and 32).
- Crystal's own suites (`spec/std`, `compiler_spec`) are not run on Windows;
  their CI jobs are Linux-only.
- Workload numbers so far come from one 12-vCPU Windows 11 QEMU/KVM VM, not
  physical hardware (`bench/log/windows/2026-10-06-vm-validation/`). Windows
  ARM64 workloads are unmeasured; ARM64 has CI coverage only.
  - **Throughput.** crystal-metric runs at 87–114% of Boehm's speed, within
    the Linux band on every row except Binarytrees (112% here). Kemal reaches
    106.5% of Boehm on `/json` and 102.9% on `/`.
  - **Memory.** Peak working set (`PeakWorkingSetSize`) is not Linux RSS:
    decommitted pages that are recommitted count again. It is at or below
    Boehm on 10 of 13 rows. The exceptions are transient peaks, not
    retention (heaps at exit match Boehm or are small): JsonParsePure 1.14×,
    Knuckeotide 1.62–1.73× (+39 MiB) and Matmul 1.18×. Kemal is at 1.14×.
  - **`err` rows.** Eight crystal-metric benches print `err` on Windows under
    Boehm too, with the same value in every arm, so the A/B compares
    identical work.
  - **Idle mark helpers.** They wait on `WaitOnAddress` and are woken when
    work is published, as Linux helpers are on a futex. Until 2026-10-08
    they slept in `Sleep(1)` naps with no wake, about 15.6 ms each at the
    default timer resolution, so helpers took almost no work: CI steals per
    `make parallel-mark-process` run fell from 330 k to 0.7–5.6 k. The
    VM numbers above predate the change.
- Parallel stress has run on CI runners: about 15 000 bounded runs, no
  failures on fast runners
  (`bench/log/linux/2026-09-30-cross-platform-stress/`).

## Tests and CI

Run the same checks as the Windows CI matrix. `ci/windows.ps1` needs
PowerShell 7 (`pwsh`); Windows PowerShell 5.1 refuses it:

```powershell
./ci/windows.ps1 -Variant default    # headerless layout, bitmap allocator
./ci/windows.ps1 -Variant headers    # -Dgcry_block_headers, bitmap allocator
./ci/windows.ps1 -Variant freelist   # -Dgcry_block_headers, GCRY_BITMAP_ALLOC=0
# On ARM64, add -Architecture aarch64 to each command.
```

Each arm runs library specs, process-GC specs, and optimized hello, allocation /
fiber stress, JSON churn, and suspended-stack samples. `-Suite specs` or
`-Suite samples` runs only that part. The default arm also builds a legacy-scheduler
(`-Dwithout_mt`) smoke sample. Every native exit code is checked.

The `make` gates run from Git Bash with GNU make, as the `test (windows
x86_64, gates)` job does. `shards install` (for `bench/kemal`) needs symlink
rights: enable Developer Mode or use an elevated shell.

Windows-specific regressions cover:
- PE roots, and loaded-DLL roots
  (`process_spec/regression/36_windows_dll_static_roots_spec.cr`, which
  builds its DLL with `cl` found through vswhere, or with `cc`/`clang` on the
  GNU target);
- guard pages inside root ranges;
- zero-filled page reuse;
- thread identity;
- TLS destruction;
- independent integer and SIMD register roots;
- stale-context cleanup;
- suspension-capacity recovery.

Unix-only barrier tests and the Linux shared-object specs (16, 34) remain
skipped on Windows.
