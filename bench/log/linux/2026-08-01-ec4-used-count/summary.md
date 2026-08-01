# EC4 used_count sweep skip v1 — REJECT (hot-path)

See [`../2026-08-01-ec4-used-count-v2/summary.md`](../2026-08-01-ec4-used-count-v2/summary.md)
for the full reject (v1 + v2).

v1: `ChunkHeader::SIZE` 24→32 + `chunk_containing` on every small alloc.
Soft **0/40**, quiet `/json` **56.3%** Boehm (`2026-08-01-103613/`). Sweep
cut; thr collapsed on mutator lookup cost.
