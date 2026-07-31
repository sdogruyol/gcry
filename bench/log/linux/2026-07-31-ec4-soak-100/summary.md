# EC4 long soak (100×)

Commit: `deb9d24` / binary from HEAD at run (`4d78af0` lineage + thr docs)
Method: `EC_PARALLELISM=4`, TLAB **off**, LAG+mutex+coalesce, `wrk -c 100 -d 8` `/json`, fresh process/trial, `timeout 20` on wrk.

## Result

| | |
|--|--:|
| ok | **96** |
| fail | **4** |
| boot fail | 0 |
| wrk timeout | 0 |

Fail notes: **SEGV×2**, **MARK_MISS×2** (`pointer is not a gcry allocation`).

OK thr (n=96): med **36485**, min 26832, max 42527.

## Fail trials

| n | thr before die | class |
|--:|---------------:|-------|
| 6 | 6279 | SEGV @ `0xfffffffffffffff0` |
| 10 | 21718 | MARK_MISS |
| 48 | 10175 | MARK_MISS |
| 74 | 22098 | SEGV (backtrace during Log/fiber) |

## Verdict

~**4%** residual fail rate under short HTTP soak — collect/mark class, not boot. Correctness quieter than pre-LAG Parallel but **not** soak-green for promoting EC>1. Next: mark-miss/SEGV triage (or accept experimental + document rate).
