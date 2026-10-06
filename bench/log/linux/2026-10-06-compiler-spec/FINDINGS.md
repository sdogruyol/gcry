# The Crystal compiler built with gcry: self-host, `crystal i`, `compiler_spec`

CI run [37437660646](https://github.com/sdogruyol/gcry/actions/runs/37437660646),
job `compiler built with gcry` (112183369025), `workflow_dispatch` on
`readiness` at `a4c0dbd`, ubuntu-latest, Crystal 1.21.0 (`57cf7da50`).
`ci/compiler-spec.sh`; the lines below are `ci-summary.txt`, cut from that
job's log.

| step | result |
|---|---|
| Build the compiler with gcry (`-Dgc_none`, `require "gcry"`) | built |
| Self-host: that compiler builds `crystal-gcry-stage2`, which builds and runs `samples/hello.cr` | ok |
| `crystal i` in the gcry-built compiler: `1_hello.cr`, `2_alloc_heavy.cr`, `3_finalizers_weakref.cr` (`ci/compiler-interp/`) | 3 of 3 |
| `compiler_spec` run by the gcry-built compiler | **13 640 examples, 0 failures, 0 errors, 18 pending** (15:20 min) |

The first three steps run on every push and pull request. Until 2026-10-06
`compiler_spec` ran only on `schedule` and `workflow_dispatch`; it now also
runs on `pull_request`.
