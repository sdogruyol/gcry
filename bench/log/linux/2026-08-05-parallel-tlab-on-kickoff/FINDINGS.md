# Parallel TLAB-on kickoff — Phase A start

**Date:** 2026-08-05 · Host: WSL2 R9-9950X · Crystal 1.21.0  
**Branch:** `plan/parallel-tlab-on` @ `f027c06` (+ plan docs)  
**Plan:** [docs/PARALLEL_TLAB_ON.md](../../../../docs/PARALLEL_TLAB_ON.md)

## A1 — STW property (done)

| Command | Result |
|---------|--------|
| `stw_mt_property_test --tlab --seed=1 --iterations=50 --workers=2,4` | **PASS** |
| `… --tlab --nursery --seed=1 --iterations=50 --workers=2,4` | **PASS** |

CI-shaped gate; not a substitute for soft-soak.

## Next

- **A2** `make soft-soak-ec4` (TLAB-off control; script refuses TLAB today)
- **A3** needs harness escape (`SOFT_SOAK_ALLOW_TLAB=1` or sibling script) then
  EC4 + `GCRY_TLAB=1` soft-soak
- **A4** quiet Kemal EC4 med-of-3 off vs on

No thr micro-opts until A3 is green.
