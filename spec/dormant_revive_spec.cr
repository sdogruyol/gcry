require "./spec_helper"

# Review finding (PR #1): dormant chunks never revived under BITMAP_ALLOC. The
# pool's chunk walk skipped them and the only revive path was freelist-shaped,
# so every refill after a class went dormant mapped a new chunk while the
# dormant ones sat in the VMA forever. This pins the fix: after a class's
# chunks go dormant, allocating again must revive one rather than map another.
describe "bitmap pool revives dormant chunks" do
  it "reuses a dormant chunk instead of mapping a new one" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.release_empty_chunks = true
      # The empty-chunk release is gated on the *process* having one mutator
      # thread: `release_empty_chunks_this_collect?` returns false under
      # `sweep_multi_mutator?` unless one of these knobs is on, and
      # `munmap_empty_chunks_this_collect?` the same. A spec process's thread count
      # is not this example's to control — one thread left running by another
      # example turns the whole release path off, and every assertion here then
      # fails for a reason that has nothing to do with what it tests. Measured
      # 2026-09-17: one extra live thread reproduces the aarch64/kcov failure line
      # byte for byte (`chunks=8 dormant=0 fully_free=1048576 unmapped=0`), and
      # these two restore it exactly. They only affect the multi-mutator branch —
      # single-mutator returns true before reading them — so what this example
      # measures is unchanged.
      heap.parallel_empty_chunk_dormant = true
      heap.parallel_empty_chunk_munmap = true
      heap.empty_chunk_retain = 64_u64 * 1024 * 1024 # keep empties dormant, never munmap
      # Warm beats dormant in the sweep's priority (`collect_sweep.cr`: warm →
      # dormant → munmap), so an example that requires dormancy has to close
      # the warm path rather than rely on its default. Measured: with the warm
      # budget open this example's exact symptom appears —
      # `chunks=8 dormant=0 dormant_bytes=0 heap_size=1048576` against
      # `chunks=8 dormant=8 dormant_bytes=1048576` with it closed, which is the
      # 2026-09-17 failure line byte for byte. That does **not** establish it as
      # the cause: the property defaults to 0 here and nothing in the spec build
      # sets it. It removes one branch of the possibility space by construction.
      heap.empty_chunk_warm_retain = 0

      # Fill more than one chunk of one class, then free everything.
      ptrs = Array(Void*).new(20_000) { heap.malloc(48) }
      ptrs.each { |p| heap.free(p) }
      heap.collect(scan_stack: false, roots: [] of Void*)

      dormant = 0
      chunks = 0
      heap.each_chunk do |c|
        chunks += 1
        dormant += 1 if Gcry::ChunkHeader.dormant?(c)
      end
      # With the state, because this example and four others like it have
      # failed together on `test (aarch64 native)` three times in about thirty
      # runs while passing 80 of 80 locally, and "expected > 0" says nothing
      # about which of dormancy's preconditions was missing on that host. The
      # page size is in the line because `madvise` over a range aligned to the
      # wrong unit returns EINVAL and dormancy then silently does not happen.
      # `fully_free`, `warm_retain` and `unmapped` are in the line because the
      # first version could not tell three different failures apart: the chunks
      # were never empty (so the sweep's `unless any_live` branch never ran),
      # they were empty but kept **warm** (warm preempts dormant), or dormancy
      # was attempted and refused. The 2026-09-17 occurrence under kcov
      # reported `chunks=8 dormant=0 heap_size=1048576 retain=67108864
      # page=4096 compiled_page=4096`, which rules out the page-size hypothesis
      # above and distinguishes none of the other three.
      state = "chunks=#{chunks} dormant=#{dormant} dormant_bytes=#{heap.dormant_chunk_bytes} " \
              "fully_free=#{heap.fully_free_chunk_bytes} unmapped=#{heap.unmapped_bytes} " \
              "live_objects=#{heap.live_objects} " \
              "heap_size=#{heap.heap_size} retain=#{heap.empty_chunk_retain} " \
              "warm_retain=#{heap.empty_chunk_warm_retain} " \
              "page=#{Gcry::Platform::PAGE_SIZE} compiled_page=#{Gcry::Roots::PAGE_SIZE}"
      fail "no chunk went dormant — #{state}" if dormant == 0
      dormant_bytes = heap.dormant_chunk_bytes
      fail "chunks are dormant but dormant_chunk_bytes is 0 — #{state}" if dormant_bytes == 0

      chunks_before = 0
      heap.each_chunk { |_| chunks_before += 1 }
      revives_before = heap.bitmap_dormant_revives

      # Allocate again: the pool must revive, not map.
      again = Array(Void*).new(5_000) { heap.malloc(48) }
      chunks_after = 0
      heap.each_chunk { |_| chunks_after += 1 }

      heap.bitmap_dormant_revives.should be > revives_before
      heap.dormant_chunk_bytes.should be < dormant_bytes
      chunks_after.should eq(chunks_before)
      again.size.should eq(5_000)
      # And the revived chunk's memory is usable: write and read back.
      again.each_with_index { |p, i| p.as(UInt64*).value = i.to_u64 }
      again.each_with_index { |p, i| p.as(UInt64*).value.should eq(i.to_u64) }
    ensure
      heap.destroy
    end
  end
end
