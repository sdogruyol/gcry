# ASLR on vs off — does layout randomisation drive the per-rep spread?

**No.** 12 reps each, server under `setarch -R` for the `noaslr` row.

Written up together with the null control that motivated it:
[`../2026-08-07-050658-root-phase/FINDINGS.md`](../2026-08-07-050658-root-phase/FINDINGS.md) § 4.

Short version: per-rep scatter is unchanged (roots F=0.62, mark F=0.94, pause
F=1.12 — ns at .05), which is what should have been expected, since ASLR
randomises virtual addresses while L3 indexing is physical. The one thing it
does show is that post-GC RSS collapses to 8 distinct values across 12 reps with
randomisation off, versus 12/12 with it on — a quantised metric, consistent with
counting 128 KiB size-class chunks.
