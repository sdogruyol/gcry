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
  zero-initialized class variables. Globals in DLLs require explicit roots.
  Per-thread TLS copies are not scanned, matching Linux/macOS policy. Crystal
  threads and fibers are rooted through the runtime thread list and fiber roots;
  application references held only in native TLS require explicit roots.
- `SuspendThread` and `GetThreadContext` stop Crystal threads and capture stack
  pointers, integer registers, and floating-point/SIMD registers. `ResumeThread`
  releases them after collection. A failed suspend/capture resumes all threads
  already stopped and fails the collection instead of scanning incomplete roots.
  Failure is reported without allocating until suspension and collector locks
  are released. Exception creation then suppresses process-GC auto-collection,
  including when suspension is requested directly through `GC.stop_world`.
- Stopped-world stderr diagnostics use `WriteFile` on the standard error handle,
  bypassing CRT descriptor locks that a suspended mutator might hold.
- Thread creation publishes its birth root before resuming the new thread.
  SRW locks and FLS provide collector mutexes and cursor TLS; deleting a TLS key
  does not invoke cursor exit callbacks.

## Current limits

- The native suspension table supports up to 64 other Crystal
  threads per collection, including runtime service threads. Exceeding that
  capacity raises an error after resuming the threads already suspended.
- Fork, Unix signal diagnostics, soft-dirty, and the mprotect write barrier are
  unavailable. The conservative full-collection path remains available.
- The research stack-map walker assumes a SysV fiber context. Windows ignores
  `GCRY_PRECISE_STACK` and `GCRY_PRECISE_FIBERS` with a warning and retains
  conservative stack scanning.
- Existing Linux/macOS throughput and RSS measurements do not describe Windows.
  Windows workload benchmarks and long-running parallel stress remain future work.

## Tests and CI

Run the same checks as the Windows CI matrix:

```powershell
./ci/windows.ps1 -Variant default
./ci/windows.ps1 -Variant freelist
./ci/windows.ps1 -Variant headerless
# On ARM64, add -Architecture aarch64 to each command.
```

Each arm runs library specs, process-GC specs, and optimized hello, allocation /
fiber stress, JSON churn, and suspended-stack samples. `-Suite specs` or
`-Suite samples` runs only that part. The default arm also builds a legacy-scheduler
(`-Dwithout_mt`) smoke sample. Every native exit code is checked.

Windows-specific regressions cover PE roots, guard pages inside root ranges,
zero-filled page reuse, thread identity, TLS destruction, and independent integer
and SIMD register roots, stale-context cleanup, and suspension-capacity recovery.
Unix-only barrier tests remain skipped on Windows.
