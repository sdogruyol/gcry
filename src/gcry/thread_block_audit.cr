# Where does a dying `Thread` live?
#
# The second use-after-free is the same shape as the first, one object along.
# gcry calls `pthread_getattr_np` under `stop_world` on a `pthread_t` that is
# **gcry's own freed-block poison** (`0xdeadff…`), i.e. it read a `Thread`'s
# `@system_handle` out of a block it had already reclaimed
# (`bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md`,
# occurrence 5). The `Thread` object is swept while something still uses it.
#
# The fiber family was cracked by asking the kernel where the dying block's
# address actually lived at the moment it died
# (`src/gcry/address_space_audit.cr`), and that instrument is general — but it
# cannot see this defect, for two reasons that are both size:
#
#   - the dying-register audit that triggers it only walks size classes at or
#     above `DYING_AUDIT_MIN_SIZE` (384 B, the `Deque(Fiber::Stack)` capacity
#     band). A `Thread` is 192 B and is never looked at;
#   - and it fires for the *first* unreferenced dying block of a collection,
#     which in a program that is churning fibers is never the one we want.
#
# So this arm aims the same question at one type. After the mark and before the
# sweep — the only window where "about to be freed" exists and nothing has been
# reclaimed yet — walk the used blocks, read Crystal's `type_id` word out of
# each payload, and for every block of the watched type that the mark did
# **not** reach: say so, and hand its address to the address-space audit, which
# names the region that holds it. The answers are the same shape as the fiber
# family's and each one is a different defect:
#
#   - **held on a thread stack / in a fiber stack below the scan window** — a
#     root the scan does not cover, which is what both v0.19.0 defects were;
#   - **held in a live heap block** — the mark missed an edge, and
#     `GCRY_MARK_AUDIT` would have to explain how;
#   - **held nowhere** — the `Thread` is live only in a register or a frame of
#     the thread that is starting, i.e. the birth window
#     (`bench/log/linux/2026-08-16-birth-grace/FINDINGS.md`), and the fix lives
#     there rather than in a root source.
#
# `GCRY_THREAD_BLOCK_AUDIT=1` watches `Thread`. `GCRY_DYING_TYPE_ID=<n>` aims
# the same arm at any other type_id, which is what makes it testable: the gate
# (`make thread-block-audit`) points it at a type whose death it controls and
# requires the arm to name it, and requires the same arm to say nothing when
# those objects are held alive.
#
# Two things it counts, because a "no dying `Thread`" answer from an arm that
# never ran, or that was pointed at the wrong id, is not an answer:
#
#   - `dying_type_walked` — used blocks whose type word it read;
#   - `dying_type_live` — blocks of the watched type the mark **did** reach. A
#     zero here with a non-zero walk means the arm is looking for a type that is
#     not in this heap, not that the type is never freed.
#
# What it reads is a guess by construction: the first payload word is a
# `type_id` only for a Crystal reference object, and a raw `GC.malloc` buffer
# whose first word happens to equal the watched id will be reported. That is
# what `dying_type_live` is for — a heap where the count of live watched blocks
# does not track the number of live `Thread`s is a heap where this arm is
# reading noise.

module Gcry
  class Heap
    # `GCRY_THREAD_BLOCK_AUDIT=1`. See src/gcry/thread_block_audit.cr.
    property thread_block_audit : Bool = false

    # `GCRY_DYING_TYPE_ID=<n>`; 0 means "the default", which is `Thread`.
    @dying_type_id : UInt32 = 0_u32

    getter dying_type_walked : UInt64 = 0_u64
    getter dying_type_live : UInt64 = 0_u64
    getter dying_type_deaths : UInt64 = 0_u64

    # Per collection. The address-space audit that follows each report is the
    # expensive half, and it is bounded to one per collection on its own; this
    # bounds the raw output when a batch of them dies at once.
    THREAD_BLOCK_REPORT_LIMIT = 4

    def dying_type_id : UInt32
      id = @dying_type_id
      id == 0_u32 ? Thread.crystal_instance_type_id.to_u32! : id
    end

    def dying_type_id=(id : UInt32) : UInt32
      @dying_type_id = id
    end

    # Called with the world stopped, after `mark_loop` and before `sweep`.
    protected def audit_dying_type_blocks : Nil
      return unless @thread_block_audit
      watched = dying_type_id
      reported = 0
      each_chunk do |chunk|
        next if ChunkHeader.dormant?(chunk)
        next if ChunkHeader.large?(chunk)
        class_index = chunk.value.size_class.to_i32!
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        payload = SizeClasses.payload(class_index)
        # No room for a type_id word, so nothing here can be the watched type.
        next if payload < 4
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          cursor += block_bytes
          next if BlockHeader.free?(header)
          @dying_type_walked &+= 1
          user = BlockHeader.user_from(header)
          # Unsigned: a `type_id` read as Int32 out of a payload that is not one
          # sign-extends, and the comparison then depends on the garbage's top
          # bit rather than on the id.
          next unless user.as(UInt32*).value == watched
          if heap_marked?(header)
            @dying_type_live &+= 1
            next
          end
          @dying_type_deaths &+= 1
          addr = user.address
          if reported < THREAD_BLOCK_REPORT_LIMIT
            reported += 1
            report_dying_type_block(addr, header.value.size.to_u64, watched)
          end
          # Every place gcry looks is about to say no. Ask the kernel where the
          # value is (src/gcry/address_space_audit.cr).
          audit_address_space_for_type(addr, header.value.size.to_u64)
        end
      end
    end

    private def report_dying_type_block(addr : UInt64, size : UInt64, watched : UInt32) : Nil
      greg_words = 0_u64
      in_registers = false
      Thread.unsafe_each do |thread|
        Platform.each_thread_greg(thread.to_unsafe) do |value|
          greg_words &+= 1
          in_registers = true if value.address == addr
        end
      end
      offered = mutator_offered?(addr)

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: dying-type audit — block 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, addr)
      len = RawOut.append(buf.to_unsafe, len, " size ")
      len = RawOut.append_u64(buf.to_unsafe, len, size)
      len = RawOut.append(buf.to_unsafe, len, " type_id ")
      len = RawOut.append_u64(buf.to_unsafe, len, watched.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " is unmarked and about to be swept. In a suspended thread's registers: ")
      len = RawOut.append(buf.to_unsafe, len, in_registers ? "yes" : "no")
      # A "no" from a walk that read no registers at all is not a no.
      len = RawOut.append(buf.to_unsafe, len, " (of ")
      len = RawOut.append_u64(buf.to_unsafe, len, greg_words)
      len = RawOut.append(buf.to_unsafe, len, " words). Offered by the collecting thread's own stack scan: ")
      len = RawOut.append(buf.to_unsafe, len, offered ? "yes" : "no")
      len = RawOut.append(buf.to_unsafe, len, ". collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
      report_thread_population
    end

    # The line that separates the two mechanisms a "held in a region gcry owns
    # nothing of" answer leaves open.
    #
    # The first four catches (2026-08-20, aarch64 CI) put the dying `Thread`'s
    # address six times in one 16 MiB anonymous mapping, at byte-identical
    # offsets below its top, that the classifier could name as neither a fiber
    # stack, a pooled stack, nor a thread stack. A used region at the top of a
    # large anonymous mapping is a **stack**; the question is whose. Either
    #
    #   - it belongs to a thread that has not published itself on Crystal's list
    #     yet, so gcry has no bounds for it and scans nothing of it — the birth
    #     window `Platform` already records from `pthread_create`; or
    #   - it belongs to a thread that *is* on the list and whose bounds the
    #     snapshot failed to read, which is the visited/read gap that has been
    #     countable since v0.20.0.
    #
    # The fix is different in each case, so the counts go next to the report
    # rather than into a later reading of it: what Crystal's list holds, what
    # gcry staged and has not seen published, how many of those threads the
    # snapshot actually got bounds for, and what the kernel says the process
    # has. `nil` from the kernel prints as `unknown` — a count nobody could read
    # must not arrive as a zero.
    private def report_thread_population : Nil
      listed = 0_u64
      bounded = 0_u64
      Thread.unsafe_each do |thread|
        listed &+= 1
        bounded &+= 1 if Platform.snapshotted_stack_bounds(thread.to_unsafe)
      end

      buf = uninitialized UInt8[320]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry:   threads at that moment: ")
      len = RawOut.append_u64(buf.to_unsafe, len, listed)
      len = RawOut.append(buf.to_unsafe, len, " on Crystal's list, ")
      len = RawOut.append_u64(buf.to_unsafe, len, bounded)
      len = RawOut.append(buf.to_unsafe, len, " of them with snapshotted stack bounds, ")
      len = RawOut.append_u64(buf.to_unsafe, len, Platform.staged_count.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " staged and unpublished (")
      len = RawOut.append_u64(buf.to_unsafe, len, Platform.staged_total)
      len = RawOut.append(buf.to_unsafe, len, " ever staged, ")
      len = RawOut.append_u64(buf.to_unsafe, len, Platform.staged_overflows)
      len = RawOut.append(buf.to_unsafe, len, " overflowed), the kernel says ")
      if os = Platform.os_thread_count
        len = RawOut.append_u64(buf.to_unsafe, len, os.to_u64)
      else
        len = RawOut.append(buf.to_unsafe, len, "unknown")
      end
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end
  end
end
