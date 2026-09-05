# Native ARM process regression investigation

The new medium-buffer cursor stress exposed a defect in the **reviewed header
allocator baseline**, as well as in the performance implementation. It remains
unresolved. Header production defaults are unchanged; resolving this defect is
an additional prerequisite for changing them.

The original [PR CI failure](https://github.com/sdogruyol/gcry/actions/runs/33976253435/job/101333354204)
was on Ubuntu 24.04 ARM, Crystal 1.21.0, using
`crystal spec -Dgc_none process_spec --error-trace`. The medium-buffer test
reported a buffer check failure; a later existing accounting test reported
`free_bytes > heap_size`. Its excerpt is `original-failure.txt`.

## Controlled comparison

The [exact-command diagnostic run](https://github.com/stakach/gcry/actions/runs/33977215745)
used diagnostic commit `b2719253fa5d21728fc16d9cd5317da296c4392f`.
Every variant received the identical, initially unguarded medium-buffer test.
Each trial launched a fresh compiler/test process with a 60-second SIGKILL
bound and a 10-second STW watchdog. The source workflow, every trial exit code,
and test output are adjacent. The diagnostic job collects failures; its green
job conclusion does **not** mean all variants passed.

| Collector variant | Failed trials / 10 | Observed failure |
|---|---|---|
| Reviewed baseline `b360bcd`, header | 10 | Accounting in all ten; buffer check in one |
| Performance head `3a65fda`, header | 10 | Accounting |
| Performance head with atomic enqueue skip removed, header | 10 | Accounting |
| Performance head, bitmap with headers | 0 | None |
| Performance head, headerless | 0 | None |

This establishes that the header failure predates the performance changes;
it does not establish its internal cause or prove the new code free of defects.

An earlier [diagnostic run](https://github.com/stakach/gcry/actions/runs/33976804034)
compiled an explicitly sorted entrypoint and passed all five repetitions of
all five variants. Those 25 results are retained in `sorted-entry-trials.jsonl`.
They did not reproduce the original test order: Crystal's normal directory
spec command uses filesystem enumeration, and the accounting test ran after
the pressure test in the failing command. The exact-command results supersede
that first comparison. Reproduction can depend on test order and heap layout.

## Regression scope and remaining work

The cursor regression now runs by default only when bitmap allocation is
active. The existing header accounting assertion is unchanged. To run the
known header pressure reproducer explicitly on the final source:

```bash
HEADER_MEDIUM_STRESS=1 crystal spec -Dgc_none process_spec --error-trace
```

No stress iterations, byte assertions, accounting checks or allocator behavior
were weakened. Default header process runs report the bitmap-specific example
as pending. Native ARM CI now runs both bitmap process configurations as well
as its existing header checks; Darwin already covers all three configurations.
The scoped local suites pass 32 examples each, with one intentional pending
example in header mode and none in either bitmap mode; transcripts are adjacent.

Track the header accounting and buffer-lifetime failure as open correctness
work before selecting a header policy. These diagnostics measure correctness,
not native performance. Collector source did not change during this follow-up,
so the recorded performance source hashes still describe the delivered code.
