# M7 second pass: research knobs no gate sets (2026-10-16)

Base `4fcee559` (release-0.37.0), head = branch `knobs-m7b`. Linux x86_64,
QEMU guest, 12 vCPUs, Crystal 1.21.0, shared with other agents.

## Method

Every `GCRY_*` name in `src/` (180) was checked for references in
`Makefile`, `.github/workflows/*`, `ci/*`, `spec/`, `process_spec/`,
`samples/`, `bench/micro/` and every `bench/**/*.{cr,sh,py}` outside
`bench/log/`. 27 names have none. A further 12 are referenced only from
comments; those were read one by one. A knob was removed only if (1) nothing
sets it, (2) the docs call it research / diagnostic / A-B or say it restores
old behaviour, (3) it is not a tuning knob or escape hatch, (4) it is not part
of `GCRY_SOUND` or soundness reporting, and, for instruments, only if the
docs do not send crash hunts to it.

Bench harnesses that nothing runs: `bench/acik_live_attr.sh` (driven only
by `bench/acik_live_attr_ab.sh`, which nothing runs), `bench/acik_nonstack_ab.sh`
and `bench/scrub_audit.cr`. None exists only to drive a removable knob:
the first drives `GCRY_LIVE_ATTR` / `GCRY_PRECISE_STACK`, the second
`GCRY_LARGE_CACHE`, the third is the evidence `docs/SOUND-DEFAULTS.md` cites
and sets its property itself. All three stay.

## Removed

| Knob | Criteria | What went |
|------|----------|-----------|
| `GCRY_DYING_GREG_DUMP` | unset anywhere; docs: diagnostic that found the all-zeros capture (fixed) | env read, `Heap#dying_greg_dump`, the per-thread register dump in `report_dying_type_block` |
| `GCRY_SEGV_REPORT_STACK` | unset anywhere; docs: "Research only", the measurement that led to the 256 KiB report stack | env read, `SegvReport.probe_stack`, `@@stack_probe`, `report_stack_margin` |
| `GCRY_MARK_AUDIT_ALL` | unset anywhere; docs: audit mode whose question is answered (no dying holder in five crashing runs, ROADMAP) | env read, `Heap#mark_audit_all_parents`, the unmarked-parent branch, `mark_audit_dying_edges` (getter and `/gc-stats` key), `report_missed_edge`'s `parent_marked` argument |
| `GCRY_RELEASE_OCCUPIED` | only comments name it; docs: research, restores a defect | env read only. `Heap#release_occupied_anyway` stays (`make occupied-release --broken` sets it) |
| `GCRY_SCRUB_AUDIT` | only a usage comment in `bench/scrub_audit.cr`, which sets the property itself ("so a forgotten GCRY_SCRUB_AUDIT=1 cannot turn the check into a silent pass"); docs: research | env read only. `Heap#scrub_audit_foreign_sp` stays (`bench/scrub_audit.cr`, `bench/scrub_midswap.cr`, `bench/stw_startup_hang.cr`) |

Code: `src/` +28 / −150 (−122 lines).

## Kept, with the reason

| Knob | Reason |
|------|--------|
| `GCRY_ADDRESS_SPACE_AUDIT` | crash instrument listed in DESIGN.md "Crash instruments" and ROADMAP; also the `=0` off switch for `GCRY_THREAD_BLOCK_AUDIT`'s expensive half |
| `GCRY_ADDRESS_SPACE_REPORT_LIMIT`, `GCRY_DYING_AUDIT_MIN_BYTES`, `GCRY_MARK_AUDIT_EVERY` | make a documented crash instrument usable on the crash it hunts (EVERY: a full audit suppresses the crash; MIN_BYTES: the acik block is 65 536 B and the audit fires once per collection) |
| `GCRY_RELEASE_QUARANTINE` | mitigation that bounds the acikturkiye unmap hazard (HARDENING); not research |
| `GCRY_ALLOC_PFW`, `GCRY_FIBER_SCRUB_BYTES`, `GCRY_INCREMENTAL_WORK`, `GCRY_SOFT_DIRTY_MAX`, `GCRY_THRESHOLD_FACTOR`, `GCRY_THRESHOLD_PACE`, `GCRY_EMPTY_CHUNK_WARM_RETAIN`, `GCRY_MOSTLY_EMPTY_PCT`, `GCRY_MOSTLY_EMPTY_BUDGET` | tuning knobs (criterion 3) |
| `GCRY_DISABLE_ADAPTIVE_NURSERY`, `GCRY_DISABLE_MPROTECT`, `GCRY_DISABLE_SOFT_DIRTY`, `GCRY_DISABLE_LAZY_SWEEP`, `GCRY_DISABLE_PAGE_RELEASE`, `GCRY_PARKED_FIBER_SP` | escape hatches (criterion 3) |
| `GCRY_TIGHT_GROW`, `GCRY_DISABLE_TIGHT_GROW_GC` | opt-in RSS option for the freelist allocator that POLICY.md and ACIKTURKIYE.md recommend (criterion 3) |
| `GCRY_CLEAR_STACK`, `_BYTES`, `_EVERY` | HARDENING's `/gc-stats` table tells users to try it; the `Heap` properties are spec'd (`spec/stack_scrub_spec.cr`) |
| `GCRY_BLACKLIST` | named by the soundness profile and SOUND-DEFAULTS.md (criterion 4) |
| `GCRY_HUGEPAGES` | a measured no-op, but the docs keep it on purpose as the hook for the reserved arena (criterion 2 not met) |
| `GCRY_STACKMAP_MISS_LOG`, `GCRY_STACKMAP_NEAR_DELTA`, `GCRY_LIVE_ATTR_WATCH_TID`, `GCRY_DISABLE_FIBER_FP_FILL` | `bench/acik_live_attr.sh` reads and re-exports them across its env scrub (criterion 1) |
| `GCRY_LARGE_CACHE` | user knob, documented escape from the large-recycle default |
| `GCRY_TRACE_LARGE`, `GCRY_RELEASE_LEDGER`, `GCRY_DYING_TYPE_ID` | comment-only references, but crash instruments the docs and ROADMAP send hunts to |

## Alloc fast path

`bench/micro/alloc_ns.cr`, `--release -Dgc_none`, base and head built from
their own trees. 15 rounds; each round runs 1 thread × 5 M × 48 B, the same
atomic, and 4 threads × 2 M × 48 B, base/head order alternating per round
(`alloc_ns.raw`). ns per allocation (aggregate for 4 threads):

| Case | base median [min, max] | head median [min, max] | head/base | paired head-slower rounds |
|------|------------------------|------------------------|-----------|---------------------------|
| 1 thread | 8.423 [7.673, 9.267] | 9.040 [7.999, 9.426] | 1.073 | 11/15 |
| 1 thread atomic | 7.603 [6.923, 9.065] | 7.917 [7.246, 9.085] | 1.041 | 10/15 |
| 4 threads | 5.361 [3.882, 6.104] | 4.961 [3.937, 6.430] | 0.925 | 5/15 |

The spread inside each arm (up to 20%) is larger than any difference
between the arms, and the host is shared. So the instruction count was
measured too: callgrind, 1 thread × 1 M × 48 B (`callgrind_*.txt`).
`Heap#malloc` costs 77 014 212 Ir in both builds, with the same split by
source line (pointer.cr 16 122 933, bitmap_alloc.cr 15 035 596,
indexable.cr 7 153 091, invariant.cr 3 000 177), and `GC::malloc` costs
13 000 013 in both. Program totals are 182.33 M (base) and 179.04 M (head);
the 3.3 M difference is in `stop_world_quiescing_roots` / `start_world`,
which depends on thread scheduling. Disassembled, `Heap#malloc` has the same
489 instructions in both. The `Heap` field offsets drop by 16 bytes (two
`Bool`s and one `UInt64` gone) and LLVM moves one flag test two
instructions earlier. The function's alignment also changes (base 0x20 mod
64, head 0x10). [INFERENCE] The 1-thread wall-clock lean is noise plus code
placement, not extra work: the instruction counts on the path are identical.

## Checks

Local, each under `heavy.lock`, on the tree before the comment fix below
(it differs from the final tree only in three source comments):
`crystal spec -Dgc_none spec/all_specs.cr` 281 examples, 0 failures;
`-Dgcry_block_headers` 303, 0; `crystal spec -Dgc_none process_spec` 200, 0;
`GCRY_BITMAP_ALLOC=0 … -Dgcry_block_headers process_spec` 201, 0;
`make windows-typecheck`, the darwin aarch64 `--no-codegen` cross-compile,
`make lint` (224 files, 0 failures), and the gates that run the touched
code: `make mark-audit`, `occupied-release`, `thread-block-audit`,
`poison-holders`, `segv-report`, all exit 0. `ci/knob-doc-check.sh` passes
on the final tree (175 knobs).

GitHub Actions `ci.yml`, dispatched on branch `knobs-m7b`:

- run 38891441487 (`187f8fcd`): `test (x86_64, crystal 1.21.0)` failed at
  "Env knob reference is complete". Three source comments still named
  removed knobs, and `ci/knob-doc-check.sh` counts every `GCRY_*` in
  `src/`. The comments were reworded and the run was cancelled.
- run 38894319835 (`685cd4f3`, the same code as the final branch): 40 of 43
  jobs green and none failed. The three 5-hour `soak` arms were still
  running when this was written.
