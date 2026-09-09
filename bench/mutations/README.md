# Hand-crafted mutants for gcry (Phase 7.3)

Each `NN_*.mut` is a `sed` expression applied to a source file.  
`./bench/mutations/run.sh` applies one mutant, runs a short test set, restores the file, and appends to `SCORE.log`.

```sh
./bench/mutations/run.sh          # all
./bench/mutations/run.sh 01       # one
```

Kill = tests fail (exit ≠ 0). Survive = tests still green (bad — mutant not
detected). **NOOP = the `sed` did not match**, and that is worse than a
survivor: the mutant never ran, so the line it was written for is unmeasured
while the score still looks like a score. Four of the ten had gone NOOP by
2026-09-09 as the code they named moved; they are repointed at the current
source, and a NOOP now means "fix this row", not "ignore it".

Current: 10/10 killed. Mutant 09 (`cursor += 1` → `cursor += 2`: the
conservative scan skips every other word) survived all 291 examples until
`spec/scan_completeness_spec.cr` was written for it — a root the scan skips
is an object freed while live, so that was the most expensive hole on the
board. Address-space exhaustion is *not* one of these mutants: the spec
suite cannot make `mmap` fail. `make oom-no-hang` covers it instead.
