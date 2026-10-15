# `crystal spec`'s image delete in the Makefile gates on Windows

## What failed

`make bitmap-marks-freelist` on windows arm64, 2026-10-14 (run 38633380085,
job 116090337173): the specs printed `0 failures` and the step failed with
"Error deleting file ... crystal-run-spec.tmp.exe ... you've found a bug in the
Crystal compiler". The rerun passed. This is the race `ci/windows.ps1` has
worked around since 0.27.0 (its comment over `Invoke-CrystalSpec`): `crystal
spec` deletes the image it just ran, and on these runners a handle on that
image can outlive the process.

## Which Makefile targets were exposed

The Windows gates steps (`test (windows x86_64, gates)`,
`test (windows arm64, gates)` in `.github/workflows/ci.yml`) run 16 Makefile
targets plus `ci/sound-suite.sh`. Of those, only `bitmap-marks-freelist` calls
`crystal spec` (twice: unit specs on the header layout, process specs on the
header layout); none of the others has a prerequisite that does, and
`ci/sound-suite.sh` builds its binaries. The Makefile's other spec runs
(`spec`, `spec-process`, `invariants`, `kernels-broken`) are not in the Windows
jobs but go through the same helper, so `make spec` on a Windows checkout does
not hit the race either.

## The change

`ci/crystal-spec.sh`: plain `exec crystal spec "$@"` unless `uname -s` is
MINGW*/MSYS*/CYGWIN* (or `GCRY_SPEC_BUILD=1`). On that path it writes
`$BIN/crystal_spec_<cksum of args>.cr` with one `require` per spec file (the
`skip_file` pitfall the ps1 comment records rules out passing them as main
sources), builds it with the same flags and runs the binary. Nothing is
deleted. The path taken is printed to stderr.

## Evidence

`results.txt` has the raw lines.

- Linux, local, Crystal 1.21.0, `crystal spec` vs `GCRY_SPEC_BUILD=1` on the
  same tree, one run each (serialised under the shared heavy lock): `make spec`
  294 / 294, `bitmap-marks-freelist`'s unit line 316 / 316 and process line
  201 / 201, `spec/kernels_spec.cr` 13 / 13 — all 0 failures.
- Windows CI, `bitmap-marks-freelist`'s two spec lines, master run
  38709043581 (plain `crystal spec`) against run 38721725009 (this branch):
  x86_64 310 / 310 and 160 / 160, arm64 308 / 308 and 160 / 160; both gates
  jobs green.
- Run 38727540906 (ed8fc89a, the code as committed, with the stderr line): both Windows
  gates jobs print `ci/crystal-spec.sh: 60 spec files via
  bin/crystal_spec_715557650.cr -> bin/crystal_spec_715557650.exe (built and
  run, not `crystal spec`)` and the same for the 73 process spec files, then
  the same counts (310 + 160, 308 + 160), green (jobs 116397022350,
  116397022766).

## Not shown

The flake was seen once in the 0.36.0 cycle; one green run after the change
does not show its rate went to zero. That rests on the mechanism: on the
build-then-run path there is no `crystal-run-spec.tmp.exe` and no delete.
[INFERENCE] `crystal build -o` itself does not delete a previous output image
before linking over it; if a stale handle on `bin/crystal_spec_*.exe` from an
earlier run in the same job ever blocked the link, it would fail at link time
instead. Each argument list has its own name, and no job runs the same list
twice.
