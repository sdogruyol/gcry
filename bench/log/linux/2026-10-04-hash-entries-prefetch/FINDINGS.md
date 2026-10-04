# Hash entries: prefetch before the walk — JsonParsePure mark −13 to −15%

Linux, Crystal 1.21.0, base `ea65d06`. crystal-metric, `-Dgc_none --release`.

## Why

CI probe, layouts on against `GCRY_DISABLE_LAYOUT=1`, 8 interleaved rounds:

| bench | x86_64 mark | arm64 mark | x86_64 time | arm64 time |
|---|---:|---:|---:|---:|
| JsonParsePure | 2953 → 1841 ms (−37.7%) | 2441 → 1590 ms (−34.8%) | −31.8% | −29.8% |
| everything else | within ±7% | within ±7% | within ±3.3% | within ±3.3% |

Layouts were costing JsonParsePure a third of its mark. Locally, at equal live
objects (4 200 136), one collection marked in 188-212 ms with layouts and 148
ms without.

## What it was

The SIGPROF sampler put 16.6% of the run on one line, the first read of each
entry in `scan_hash_object` (`hash_word = slot.as(UInt32*).value`). `@entries`
is a block of its own that the mark loop's prefetch ring never saw, and
JsonParsePure has millions of small `Hash(String, JSON::Any)`: one waited-on
miss each. Conservatively, the same blob is pushed and goes through the ring.

## Change

- Prefetch `@entries` as soon as the shape check passes, scan the Hash's own
  words (`scan_hash_body`) while it loads, then walk.
- `scan_hash_object`'s three field loops (scan offsets, noscan offsets,
  `@block`) re-marked words `scan_hash_body` already reads with the same
  rules; they are gone and the walk is `scan_hash_entries`. The `Layout`
  fields only they read (`hash_block_off`, `hash_block_bytes`) are removed.
  `spec/layout_spec.cr` "hash precise scan keeps the default block's closure
  alive" fails if the body scan is skipped.
- `mark_noscan` resolved the same chunk three times (`find_object`,
  `heap_marked?`, `heap_set_mark`), and `heap_set_mark` read the block size
  from a header that under headerless is the object's first word, then walked
  every size class for it. It now takes `find_object_with_chunk` and the
  chunk-in-hand pair `mark_impl_unlocked` uses. No measurable change on its
  own (1470 → 1533 ms, noise), kept for the lookups it removes.

## Measured

Local, 3-4 runs each, JsonParsePure mark: base 1406-1483 ms, prefetch
1165-1292 ms, layouts off 926-1007 ms.

CI `Perf A/B` (run 37217509259, 10 interleaved reps):

| bench | x86_64 mark | arm64 mark | x86_64 time | arm64 time |
|---|---:|---:|---:|---:|
| JsonParsePure | −14.9% | −12.8% | −12.6% | −9.6% |
| JsonParseSerializable | +6.4% | −1.2% | +0.8% | +0.9% |
| JsonGenerate | +5.1% | −1.7% | −5.1% | +0.4% |
| Primes | +2.5% | −2.6% | +2.3% | −0.5% |
| Binarytrees | +4.4% | −3.4% | +0.1% | −0.9% |
| Knuckeotide | +1.8% | +4.2% | +0.0% | +1.3% |

Off JsonParsePure the signs disagree between architectures.

## Tried and dropped

| variant | JsonParsePure mark | verdict |
|---|---:|---|
| defer each walk 8 Hash scans in a ring (serial drain only) | 1296-1324 ms vs 1183-1241 | worse |
| prefetch up to four lines of entries (`@size + @deleted_count`) | 1172-1266 vs 1165-1262 | no change |
| conservative word scan of the live entry range instead of the walk | 1259-1266 vs 1258-1313 | no change |
| push `@entries` through the mark ring, no walk | 1190-1252 vs 1165-1224 | no change |
| `Layout.entry_for` rejects ids above the largest registered one | 1171-1232 vs 1148-1246 | no change |

## Open

About 20% of mark time still separates layouts on from off on
JsonParsePure (local 1190-1270 against 930-1000 ms). The last four rows rule
out the entries miss and the walk's shape; the profiles of the two arms do
not concentrate the difference on any one line.
