# Hand-crafted mutants for gcry (Phase 7.3)

Each `NN_*.mut` is a `sed` expression applied to a source file.  
`./bench/mutations/run.sh` applies one mutant, runs a short test set, restores the file, and appends to `SCORE.log`.

```sh
./bench/mutations/run.sh          # all
./bench/mutations/run.sh 01       # one
```

Kill = tests fail (exit ≠ 0). Survive = tests still green (bad — mutant not detected).
