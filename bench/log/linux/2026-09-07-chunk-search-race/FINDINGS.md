# Chunk search and header mutation races

Baseline: `ce87856`, Crystal 1.21.0. Investigation prompted by the locked arm
of the native ARM `large-cache-race` gate crashing after otherwise green runs.

## Reproduction

The unchanged branch was sampled on native ARM in
[run 34082760828](https://github.com/stakach/gcry/actions/runs/34082760828/job/101621065372).
One of 200 locked children printed:

```text
gcry: SIGSEGV at 0xffa7ce601010 — inside the heap span but in no live chunk — the chunk was unmapped, or the address is in a hole between chunks
```

That child subsequently timed out. The previous summary counted it only as a
timeout, despite the recorded SIGSEGV. The unchanged branch's other 199 locked
children passed; all 200 deliberately unlocked controls failed. See
[arm-before.log](arm-before.log). The unrelated long soak jobs from that
dispatch were cancelled after the sample completed.

`bench/chunk_search_race.cr` schedules the unsafe interleaving directly. An
allocation search holds a pointer to a cached large chunk. A peer checks
whether the search excludes list removal; if it does not, the peer trims the
chunk before allowing the search to read its kind. The released mapping is
protected with `PROT_NONE`, so address reuse cannot hide the stale access.
Synchronization uses atomics, with a ten-second child deadline.

On the baseline all three search paths SIGSEGV at `chunk + 16`, the
`size_class` read in `ChunkHeader.large?`:

- Bitmap pool rebuild (`bitmap_pool_candidate?`).
- Bitmap dormant search (`bitmap_revive_dormant`).
- Header allocator dormant search (`revive_dormant_chunk`).

Full backtraces are in [search-before.log](search-before.log). This is the same
field offset as the ARM failure. The ARM sample lacks a complete backtrace,
so the exact search responsible for that particular child remains unknown.

## Fix

Allocation searches now hold `@chunk_list_lock` while traversing the list.
This excludes large-cache unlink and release. Dormant searches release that
lock before taking `@alloc_lock` to revive the selected small chunk, preserving
the order `class -> alloc -> list -> index`. Stopped-world searches skip the
lock because its owner may be suspended. Deferred small-chunk release also
takes the list lock after restarting the world, protecting a search suspended
while the sweep detached a chunk.

A separate race could recreate a dangling link even with those locks:
`ChunkHeader` flag setters copied the entire header back while unlink used a
different lock to update `next`. A stale copy could restore the removed
successor. Unlink's own header copy could likewise erase cursor flags.
Disassembly confirmed whole-header stores in the normal development build.

Even `chunk.value.flags = value` is a struct copyback in Crystal. Updates now
use explicit field addresses: atomic OR/AND for flags and a pointer store for
`next`. All sweep link writes use the same field-specific operation. Atomic
flag updates also preserve other bits if a collector interrupts a mutator.

The seven specs in `spec/chunk_field_race_spec.cr` inject the competing field
update at the copied-property setter, or immediately after the indivisible
field operation. The same spec file produces seven failures against baseline
sources and passes with the fix; see [fields-before.log](fields-before.log).

## Validation

- Scheduled searches: all three now survive; an additional stopped-world
  case verifies the search does not wait on an already-held list lock.
- Full unit suite: 290 examples, zero failures, one existing pending example.
- Process specs: 32 examples each, zero failures with bitmap allocation,
  header allocation, and the headerless build.
- Local large-cache stress: zero failures in 20 locked children; all 20
  unsafe controls fail with SIGSEGV.
- Formatting and Ameba pass.

The scheduled gate is added to x86, native ARM, and Darwin CI. Failed locked
stress children now print their complete captured output rather than dropping
the backtrace. Native ARM validation of the fix is recorded below when complete.

These are reproducible memory-safety fixes. A finite stress sample alone cannot
prove the absence of other crashes.
