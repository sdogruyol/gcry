# Windows support

Native Windows x86_64 is supported with Crystal 1.21 or newer and the MSVC
toolchain used by the official Windows Crystal distribution. Build from a
PowerShell terminal with Crystal and its linker dependencies available:

```powershell
crystal build -Dgc_none app.cr -o app.exe
.\app.exe
```

The application must `require "gcry"`, as on Linux and macOS. WSL is not needed.

## Backend

- `VirtualAlloc` reserves and commits heap memory. Releasing whole chunks uses
  `VirtualFree`; adjacent reservations are released separately. Reclaiming dead
  pages decommits and recommits them at the same address, guaranteeing zeros.
- `VirtualQuery` bounds conservative scanning and stack scrubbing to committed,
  readable pages. Scans leave `PAGE_GUARD` pages intact.
- Writable sections of the main PE executable supply static roots, including
  zero-initialized class variables. Globals in DLLs require explicit roots.
- `SuspendThread` and `GetThreadContext` stop Crystal threads and capture stack
  pointers, integer registers, and floating-point/XMM registers. `ResumeThread`
  releases them after collection. A failed suspend/capture resumes all threads
  already stopped and fails the collection instead of scanning incomplete roots.
- Thread creation publishes its birth root before resuming the new thread.
  SRW locks and FLS provide collector mutexes and cursor TLS; deleting a TLS key
  does not invoke cursor exit callbacks.

## Current limits

- x86_64 only. The native suspension table supports up to 64 other Crystal
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
```

Each arm runs library specs, process-GC specs, and optimized hello, allocation /
fiber stress, JSON churn, and suspended-stack samples. `-Suite specs` or
`-Suite samples` runs only that part. The default arm also builds a legacy-scheduler (`-Dwithout_mt`) smoke sample.
Every native exit code is checked.

Windows-specific regressions cover PE roots, guard pages inside root ranges,
zero-filled page reuse, thread identity, TLS destruction, and independent integer
and XMM register roots, stale-context cleanup, and suspension-capacity recovery. Unix-only barrier tests remain skipped on Windows.
