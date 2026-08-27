# Is the runtime's thread list still readable when `stop_world` reaches it?
#
# The oldest open crash in this tree is a fault at address `0x18` inside
# `stop_world`:
#
#     pthread_mutex_lock <- Thread::Mutex#lock <- Thread::lock
#     <- Gcry::Heap#stop_world
#
# `Thread::Mutex#lock` is a real frame, so the receiver was fetched and then
# `pointerof(@mutex)` came out at `0x18` — a null reference, not a stray
# pointer. The reference lives in `Thread::LinkedList`'s `@mutex`, a field of a
# heap object written once during boot and only ever read afterwards. A field of
# a live object reading zero is what a released page leaves behind.
#
# Every instrument aimed at this so far has gone quiet, and gone quiet for the
# same reason: it watched objects the *harness* owns, and the victim here is one
# the runtime allocated before any harness existed
# (`bench/log/linux/2026-08-23-threads-null-0x18/FINDINGS.md`).
#
# This one watches the victim. If the list object's memory has been zeroed then
# `@head` is zero along with `@mutex`, so a walk that yields nothing is the same
# damage the fault is about — reported one instruction *before* the fault, with
# the collection number, instead of as an unexplained signal afterwards.
#
# The walk is unlocked on purpose: `Thread.lock` is the call being protected, so
# taking it first would defeat the point. That is safe here in the only sense
# that matters — a concurrent `push` can make the walk miss a node, and missing
# a node cannot turn a non-empty list into an empty one, because a push writes
# `@head` last.
#
# `GCRY_THREAD_LIST_TRIPWIRE=1`, and off by default, because the walk is not
# free of hazards of its own: a worker thread that has exited has removed
# itself from the list and its `Thread` object is ordinary garbage, so an
# unlocked walk that reads a stale `next` can follow it into a chunk gcry has
# legitimately released. A fault raised *by the instrument* under those rules
# says nothing about the defect it was built for, and it looks identical in a
# log. Default-off keeps the two apart: every arm can be run with the walk and
# without it.
#
# Silence is not an answer on its own, so the walk also records the largest
# count it has seen. A tripwire that reports zero threads on a run whose maximum
# was also zero never saw the list at all.
#
# 2026-08-27, after the first batch: the walk's own faults said the list holds
# large-block user pointers (`+0x50` = a bogus node at `chunk base + 0x28`,
# which is exactly `ChunkHeader::SIZE + BlockHeader::SIZE`), so the watch below
# was added. It records the list object's address at the first walk and then
# every large-cache insertion, large-cache hand-out, release, and page-madvise
# range is checked against it — the corrupting *event* named at its own call
# site, instead of the crash that follows it
# (`bench/log/linux/2026-08-27-thread-list-tripwire/FINDINGS.md`).
module Gcry
  # Module-level, not a Heap field: the madvise wrappers in
  # `Platform` have no heap in scope, and a plain class-var read is
  # signal-handler safe.
  module ThreadListWatch
    # A `case`, not a Hash constant: a Hash literal initializes through
    # `Crystal.once`, which must not run on a collection path.
    def self.site_name(site : UInt8) : String
      case site
      when SITE_DONTNEED  then "MADV_DONTNEED"
      when SITE_MADV_FREE then "MADV_FREE"
      when SITE_MADV_COLD then "MADV_COLD"
      when SITE_RELEASE   then "a release (munmap/guard/quarantine)"
      when SITE_CACHE_IN  then "a large-cache insertion"
      when SITE_CACHE_OUT  then "a large-cache hand-out"
      when SITE_HDR_WRITE  then "a large block-header write"
      when SITE_LINK_WRITE then "a large freelist link write"
      when SITE_SET_FREE   then "a block set_free"
      when SITE_SET_USED   then "a block set_used (hand-out)"
      when SITE_SWEEP        then "the sweep reclaiming the block"
      when SITE_INDEX_REMOVE then "an index remove of the chunk"
      else                        "site ?"
      end
    end
    SITE_DONTNEED   = 1_u8
    SITE_MADV_FREE  = 2_u8
    SITE_MADV_COLD  = 3_u8
    SITE_RELEASE    = 4_u8
    SITE_CACHE_IN   = 5_u8
    SITE_CACHE_OUT  = 6_u8
    SITE_HDR_WRITE  = 7_u8
    SITE_LINK_WRITE = 8_u8
    SITE_SET_FREE   = 9_u8
    SITE_SET_USED   = 10_u8
    SITE_SWEEP        = 11_u8
    SITE_INDEX_REMOVE = 12_u8

    # The watched object's extent. `Thread::LinkedList(Thread)` is 32 bytes —
    # type_id + @head + @tail + @mutex — and a write that touches any of them
    # is the event.
    OBJECT_BYTES = 32_u64

    @@addr = 0_u64
    # The watched object's chunk base, for hooks whose range arithmetic
    # depends on a header the defect may have already rewritten.
    @@chunk_base = 0_u64
    @@hits = 0_u64

    def self.arm(addr : UInt64, chunk_base : UInt64) : Nil
      @@addr = addr
      @@chunk_base = chunk_base
    end

    def self.armed? : Bool
      @@addr != 0
    end

    def self.addr : UInt64
      @@addr
    end

    def self.chunk_base : UInt64
      @@chunk_base
    end

    def self.hits : UInt64
      @@hits
    end

    # Did any root/edge candidate land inside the watched object this cycle?
    # Split "the scan never offered the slot's value" from "offered and then
    # rejected" — different defects, same unmarked header.
    @@offered = false

    def self.new_cycle : Nil
      @@offered = false
    end

    def self.offered? : Bool
      @@offered
    end

    # True when the candidate lands inside the watched object.
    def self.note_candidate(a : UInt64) : Bool
      addr = @@addr
      return false if addr == 0
      return false unless a >= addr && a < addr &+ OBJECT_BYTES
      @@offered = true
      true
    end

    # Two compares on the paths it hooks; a report only when a range overlaps
    # the watched object — which is never legal, so there is no false-positive
    # arm to argue about. Overlap, not containment: a 16-byte header write that
    # clips the object's first word is the defect as much as one that covers it.
    # Returns true on a report so the caller can add context of its own.
    def self.check(base : UInt64, len : UInt64, site : UInt8, flags : UInt32 = 0_u32) : Bool
      addr = @@addr
      return false if addr == 0
      return false unless base < addr &+ OBJECT_BYTES && addr < base &+ len

      @@hits &+= 1
      return true if @@hits > 8
      buf = uninitialized UInt8[224]
      n = 0
      n = RawOut.append(buf.to_unsafe, n, "gcry: ")
      n = RawOut.append(buf.to_unsafe, n, site_name(site))
      n = RawOut.append(buf.to_unsafe, n, " covers the thread list object 0x")
      n = RawOut.append_hex(buf.to_unsafe, n, addr)
      n = RawOut.append(buf.to_unsafe, n, " — range [0x")
      n = RawOut.append_hex(buf.to_unsafe, n, base)
      n = RawOut.append(buf.to_unsafe, n, ", 0x")
      n = RawOut.append_hex(buf.to_unsafe, n, base &+ len)
      n = RawOut.append(buf.to_unsafe, n, ")")
      if flags != 0
        n = RawOut.append(buf.to_unsafe, n, " prior flags 0x")
        n = RawOut.append_hex(buf.to_unsafe, n, flags.to_u64)
      end
      n = RawOut.append(buf.to_unsafe, n, "\n")
      RawOut.flush(buf.to_unsafe, n)
      true
    end
  end
end

class Thread
  # gcry: the tripwire watches this object's memory. `object_id` of a
  # Reference is its address; nothing here allocates.
  def self.gcry_thread_list_address : UInt64
    @@threads.object_id
  end
end

module Gcry
  class Heap
    # Threads the last pre-lock walk found, and the most any walk has found.
    getter thread_list_seen_max : UInt32 = 0_u32
    # Walks that found an empty list after a non-empty one. This is the defect.
    getter thread_list_empty : UInt64 = 0_u64
    # Collection at whose walk the watched block's header first read bad,
    # OR'd with 1 so collection 0 still registers. 0 = never.
    getter thread_list_hdr_bad : UInt64 = 0_u64
    # First "post-mark but unmarked" observation, printed once — if this fires
    # on the first minor of every run it is minor behaviour, not the defect.
    @thread_list_unmarked_seen = false
    # First "chunk missing from the index" observation, printed once.
    @thread_list_unindexed_seen = false
    # Whether the collection currently running is a major, for the reports.
    protected property thread_list_last_major = false

    # `GCRY_THREAD_LIST_TRIPWIRE=1`.
    property thread_list_tripwire : Bool = false

    protected def check_thread_list_before_lock : Nil
      return unless @thread_list_tripwire
      n = 0_u32
      Thread.unsafe_each { n &+= 1 }

      unless ThreadListWatch.armed?
        addr = Thread.gcry_thread_list_address
        if addr != 0
          cbase = 0_u64
          wbuf = uninitialized UInt8[192]
          wlen = 0
          wlen = RawOut.append(wbuf.to_unsafe, wlen, "gcry: watching the thread list object at 0x")
          wlen = RawOut.append_hex(wbuf.to_unsafe, wlen, addr)
          if chunk = chunk_for(Pointer(Void).new(addr))
            cbase = chunk.address
            wlen = RawOut.append(wbuf.to_unsafe, wlen, ", chunk 0x")
            wlen = RawOut.append_hex(wbuf.to_unsafe, wlen, cbase)
            wlen = RawOut.append(wbuf.to_unsafe, wlen, " size_class ")
            wlen = RawOut.append_u64(wbuf.to_unsafe, wlen, chunk.value.size_class.to_u64)
          end
          ThreadListWatch.arm(addr, cbase)
          wlen = RawOut.append(wbuf.to_unsafe, wlen, "\n")
          RawOut.flush(wbuf.to_unsafe, wlen)
        end
      end
      probe_thread_list_header("the pre-lock walk")

      if n > @thread_list_seen_max
        @thread_list_seen_max = n
        return
      end
      return unless n == 0 && @thread_list_seen_max > 0

      @thread_list_empty &+= 1
      return unless @thread_list_empty == 1

      buf = uninitialized UInt8[256]
      len = 0
      len = RawOut.append(buf.to_unsafe, len,
        "gcry: the runtime thread list reads empty before Thread.lock — it held ")
      len = RawOut.append_u64(buf.to_unsafe, len, @thread_list_seen_max.to_u64)
      len = RawOut.append(buf.to_unsafe, len,
        " threads, so the list object's memory has been zeroed under it. collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # The moment the sweep decides the watched object is garbage — the answer
    # to "why was it unmarked" has to be readable here, not at the crash.
    protected def report_thread_list_sweep(header : BlockHeader*) : Nil
      buf = uninitialized UInt8[256]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry:   at the sweep: marked ")
      len = RawOut.append(buf.to_unsafe, len, BlockHeader.marked?(header) ? "yes" : "no")
      len = RawOut.append(buf.to_unsafe, len, ", header gen ")
      gen = ((header.value.flags & BlockHeader::Flags::MARK_GEN_MASK) >> BlockHeader::Flags::MARK_GEN_SHIFT).to_u64
      len = RawOut.append_u64(buf.to_unsafe, len, gen)
      len = RawOut.append(buf.to_unsafe, len, " current gen ")
      len = RawOut.append_u64(buf.to_unsafe, len, BlockHeader.mark_gen.to_u64)
      len = RawOut.append(buf.to_unsafe, len, ", static bytes this cycle ")
      len = RawOut.append_u64(buf.to_unsafe, len, @static_scanned_last)
      len = RawOut.append(buf.to_unsafe, len, @thread_list_last_major ? ", major " : ", minor ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # One header read at a named phase boundary. The first boundary whose read
    # is bad names the phase that contains the corrupting write. With
    # *expect_marked* (post-mark boundaries) an unmarked header is the trip:
    # the walked chunk is a nursery chunk, `clear_nursery_marks` zeroes every
    # used block's gen in it on every minor, so a mark that misses the object
    # on one minor is all a sweep needs.
    protected def probe_thread_list_header(where : String, expect_marked : Bool = false) : Nil
      return unless @thread_list_tripwire
      addr = ThreadListWatch.addr
      return if addr == 0 || @thread_list_hdr_bad != 0

      # The lookup-side check: header can be pristine while the chunk has
      # fallen out of the sorted index, which starves the mark of the object.
      # Two different defects share that symptom, so the report separates them
      # with a linear pass: the entry being *absent* (a remove or a rebuild
      # dropped it) against *present but unfindable* (the array is no longer
      # sorted, so the binary search turns away before reaching it).
      if !@thread_list_unindexed_seen && chunk_containing(addr).nil?
        @thread_list_unindexed_seen = true
        present_at = -1
        inversions = 0_u64
        # Unlocked on purpose: this runs inside the stopped world, and a
        # mutator suspended mid-index-operation still owns `@index_lock` — the
        # locked version of this walk hung 18 of 100 children on the deadline.
        prev = 0_u64
        base_at = -1
        cbase = ThreadListWatch.chunk_base
        i = 0
        while i < @chunk_index_count
          c = (@chunk_index + i).value
          b = c.address
          inversions &+= 1 if b < prev
          prev = b
          present_at = i if b <= addr && addr < b &+ c.value.mapped_bytes
          base_at = i if cbase != 0 && b == cbase
          i += 1
        end
        ibuf = uninitialized UInt8[288]
        ilen = 0
        ilen = RawOut.append(ibuf.to_unsafe, ilen, "gcry: the thread list chunk is GONE from the chunk index — ")
        if present_at >= 0
          ilen = RawOut.append(ibuf.to_unsafe, ilen, "present at slot ")
          ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, present_at.to_u64)
          ilen = RawOut.append(ibuf.to_unsafe, ilen, " but unfindable, ")
          ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, inversions)
          ilen = RawOut.append(ibuf.to_unsafe, ilen, " order inversions")
        elsif base_at >= 0
          # The entry never left; the *chunk header* stopped claiming the
          # object's page. Containment scans (and `chunk_containing`) read
          # `mapped_bytes` out of the header, so a header rewrite unindexes
          # every address past the new length without any index operation.
          ilen = RawOut.append(ibuf.to_unsafe, ilen, "entry PRESENT by base at slot ")
          ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, base_at.to_u64)
          ilen = RawOut.append(ibuf.to_unsafe, ilen, " — header now: mapped_bytes ")
          ch = Pointer(ChunkHeader).new(cbase)
          ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, ch.value.mapped_bytes)
          ilen = RawOut.append(ibuf.to_unsafe, ilen, ", size_class ")
          ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, ch.value.size_class.to_u64)
          ilen = RawOut.append(ibuf.to_unsafe, ilen, ", flags ")
          ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, ch.value.flags.to_u64)
        else
          ilen = RawOut.append(ibuf.to_unsafe, ilen, "absent from the array (")
          ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, inversions)
          ilen = RawOut.append(ibuf.to_unsafe, ilen, " order inversions)")
        end
        ilen = RawOut.append(ibuf.to_unsafe, ilen, ", first seen at ")
        ilen = RawOut.append(ibuf.to_unsafe, ilen, where)
        ilen = RawOut.append(ibuf.to_unsafe, ilen, @thread_list_last_major ? ", major " : ", minor ")
        ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, @collections)
        ilen = RawOut.append(ibuf.to_unsafe, ilen, "\n")
        RawOut.flush(ibuf.to_unsafe, ilen)
      end
      word = Pointer(UInt64).new(addr &- 16).value
      size = word & 0xffff_ffff_u64
      flags = (word >> 32).to_u32
      gen = (flags & BlockHeader::Flags::MARK_GEN_MASK) >> BlockHeader::Flags::MARK_GEN_SHIFT
      bad_shape = size != 32 || (flags & BlockHeader::Flags::FREE) != 0
      unmarked = expect_marked && gen != BlockHeader.mark_gen.to_u32 && !@thread_list_unmarked_seen
      return unless bad_shape || unmarked
      if bad_shape
        @thread_list_hdr_bad = @collections | 1_u64
      else
        @thread_list_unmarked_seen = true
      end
      buf = uninitialized UInt8[224]
      len = 0
      if bad_shape
        len = RawOut.append(buf.to_unsafe, len, "gcry: the thread list block's header went bad — raw 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, word)
      else
        len = RawOut.append(buf.to_unsafe, len, "gcry: the thread list block is UNMARKED — header gen ")
        len = RawOut.append_u64(buf.to_unsafe, len, gen.to_u64)
        len = RawOut.append(buf.to_unsafe, len, " current gen ")
        len = RawOut.append_u64(buf.to_unsafe, len, BlockHeader.mark_gen.to_u64)
        len = RawOut.append(buf.to_unsafe, len,
          ThreadListWatch.offered? ? ", offered to the mark this cycle" : ", NEVER offered to the mark this cycle")
      end
      len = RawOut.append(buf.to_unsafe, len, ", first seen at ")
      len = RawOut.append(buf.to_unsafe, len, where)
      len = RawOut.append(buf.to_unsafe, len, @thread_list_last_major ? ", major " : ", minor ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # Called on the offer itself, from `mark_impl_unlocked`, with the same
    # checks that method will apply — read-only, and silent when the candidate
    # is on course to be accepted, so the fatal cycle prints its reject reason
    # and the hundreds of healthy cycles print nothing.
    protected def report_thread_list_offer(pointer : Void*, gate : Bool) : Nil
      addr = pointer.address
      reason = if @heap_max == 0 || addr < @heap_min || addr >= @heap_max
                 "outside the heap span"
               elsif (header = find_block(pointer)).nil?
                 "find_block returned nothing"
               elsif BlockHeader.free?(header)
                 "the header reads FREE"
               elsif gate && !type_id_plausible?(header)
                 "the type-id gate rejected it"
               elsif @minor_only && !BlockHeader.nursery?(header)
                 # Expected on every minor: old blocks are not the minor's
                 # problem — and not the minor sweep's either, which is why the
                 # fatal cycle is always a major. Silent.
                 return
               else
                 return
               end
      buf = uninitialized UInt8[224]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: the thread list candidate will be REJECTED — ")
      len = RawOut.append(buf.to_unsafe, len, reason)
      len = RawOut.append(buf.to_unsafe, len, "; span [0x")
      len = RawOut.append_hex(buf.to_unsafe, len, @heap_min)
      len = RawOut.append(buf.to_unsafe, len, ", 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, @heap_max)
      len = RawOut.append(buf.to_unsafe, len, ")")
      len = RawOut.append(buf.to_unsafe, len, @thread_list_last_major ? ", major " : ", minor ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end
    # Runs under `@index_lock`, at the end of every index insert and remove:
    # a linear pass for the watched chunk's base. The operation that completes
    # with the entry missing is the one that lost it, whatever its mechanism —
    # a wrong-slot compaction, a lost update, a stale copy after a regrow.
    protected def verify_thread_list_indexed(op : String) : Nil
      cbase = ThreadListWatch.chunk_base
      return if cbase == 0 || @thread_list_unindexed_seen
      i = 0
      while i < @chunk_index_count
        return if (@chunk_index + i).value.address == cbase
        i += 1
      end
      @thread_list_unindexed_seen = true
      buf = uninitialized UInt8[192]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: ")
      len = RawOut.append(buf.to_unsafe, len, op)
      len = RawOut.append(buf.to_unsafe, len, " completed with the thread list chunk missing from the index — count ")
      len = RawOut.append_u64(buf.to_unsafe, len, @chunk_index_count.to_u64)
      len = RawOut.append(buf.to_unsafe, len, ", collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
      Exception::CallStack.print_backtrace
    end
  end
end
