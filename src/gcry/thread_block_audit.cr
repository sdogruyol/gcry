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

    # Collections the arm walked, and the two preconditions worth counting.
    getter thread_pop_collections : UInt64 = 0_u64
    getter thread_pop_gap_collections : UInt64 = 0_u64
    getter thread_pop_staged_collections : UInt64 = 0_u64
    # The subset that gave up: those stopped the world with a thread unscanned.
    getter thread_pop_staged_timeouts : UInt64 = 0_u64
    # Collections that stopped the world with a thread staged after the wait.
    getter thread_pop_staged_now_collections : UInt64 = 0_u64

    # Research only: walk every used block whatever the collection is, which is
    # what this arm did before it was taught the sweep's predicate. The gate
    # uses it to show the phantom deaths coming back.
    property dying_audit_all_collections : Bool = false

    # Sightings reported per run, per kind. The counters carry the rest.
    THREAD_POP_REPORT_LIMIT = 3

    @thread_pop_gaps_reported = 0
    @thread_pop_staged_reported = 0
    @thread_pop_staged_now_reported = 0

    # Called with the world stopped, after `mark_loop` and before `sweep`.
    #
    # *major* is the sweep's own flag and this walk needs it, because "unmarked"
    # only means "about to be swept" in a full collection. A minor marks the
    # nursery and reclaims the nursery, so every old live object reads unmarked
    # and reads that way correctly — `sweep` skips it on exactly the two
    # conditions repeated below (`collect_sweep.cr:67` and `:144`). Without
    # them the arm reported live objects as dying: measured on
    # `stw_mt_property_test --tlab --nursery`, **262 reports in one run**,
    # against 0 for the same harness with the nursery off. Every one of them
    # was a `Thread` that the report itself said was still on Crystal's list,
    # which is what an audit looks like when it is asking the wrong question
    # rather than finding an answer.
    protected def audit_dying_type_blocks(major : Bool) : Nil
      return unless @thread_block_audit
      note_thread_preconditions
      watched = dying_type_id
      reported = 0
      each_chunk do |chunk|
        next if ChunkHeader.dormant?(chunk)
        next if ChunkHeader.large?(chunk)
        # `sweep` will not touch this chunk at all, so nothing in it is dying.
        next unless major || @dying_audit_all_collections || ChunkHeader.nursery?(chunk)
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
          next if !diag_allocated?(header)
          # Same test the sweep applies per block.
          next unless major || @dying_audit_all_collections || BlockHeader.nursery?(header)
          @dying_type_walked &+= 1
          user = diag_user(header)
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
            report_dying_type_block(addr, diag_payload(header), watched)
          end
          # Every place gcry looks is about to say no. Ask the kernel where the
          # value is (src/gcry/address_space_audit.cr).
          audit_address_space_for_type(addr, diag_payload(header))
        end
      end
    end

    # `GCRY_DYING_GREG_DUMP=1`.
    property dying_greg_dump : Bool = false

    # Suspended threads that reported no registers at the stop the audit ran in.
    getter greg_missing_threads : UInt64 = 0_u64

    private def report_dying_type_block(addr : UInt64, size : UInt64, watched : UInt32) : Nil
      greg_words = 0_u64
      in_registers = false
      threads_listed = 0_u64
      threads_with_gregs = 0_u64
      current = Thread.current
      Thread.unsafe_each do |thread|
        threads_listed &+= 1
        before = greg_words
        Platform.each_thread_greg(thread.to_unsafe) do |value|
          greg_words &+= 1
          in_registers = true if value.address == addr
        end
        if greg_words > before
          threads_with_gregs &+= 1
        elsif thread != current
          # A suspended thread that contributed no registers is a hole in the
          # root set that no stack scan closes: a value the compiler kept only
          # in a callee-saved register of that thread is invisible. The
          # collecting thread is expected here — it has no ucontext — so it is
          # not counted against the total.
          @greg_missing_threads &+= 1
        end
      end
      # `GCRY_DYING_GREG_DUMP=1`: print every captured register word for every
      # thread. "Not in any register" is a claim about the capture as much as
      # about the value, and the two have never been told apart here.
      if @dying_greg_dump
        Thread.unsafe_each do |thread|
          dbuf = uninitialized UInt8[480]
          dlen = 0
          dlen = RawOut.append(dbuf.to_unsafe, dlen, "gcry:   gregs of thread 0x")
          dlen = RawOut.append_hex(dbuf.to_unsafe, dlen, thread.to_unsafe.unsafe_as(UInt64))
          if thread == Thread.current
            dlen = RawOut.append(dbuf.to_unsafe, dlen, " (the collecting thread)")
          end
          if nm = thread.@name
            dlen = RawOut.append(dbuf.to_unsafe, dlen, " \"")
            dlen = RawOut.append_bytes(dbuf.to_unsafe, dlen, nm.to_unsafe, nm.bytesize)
            dlen = RawOut.append(dbuf.to_unsafe, dlen, "\"")
          else
            dlen = RawOut.append(dbuf.to_unsafe, dlen, " (unnamed)")
          end
          dlen = RawOut.append(dbuf.to_unsafe, dlen, ":")
          any = false
          Platform.each_thread_greg(thread.to_unsafe) do |value|
            any = true
            if dlen < 400
              dlen = RawOut.append(dbuf.to_unsafe, dlen, " 0x")
              dlen = RawOut.append_hex(dbuf.to_unsafe, dlen, value.address)
            end
          end
          dlen = RawOut.append(dbuf.to_unsafe, dlen, any ? "\n" : " (none)\n")
          RawOut.flush(dbuf.to_unsafe, dlen)
        end
      end

      offered = mutator_offered?(addr)

      # The question that splits the mechanism, and it can be answered on every
      # catch rather than only on one where the address-space walk finds a
      # holder.
      #
      #   **on the list** — `Thread.threads` is a class variable, so the list is
      #   a static root and every `Thread` on it should be reachable. One dying
      #   while listed means that root is not covering it, which is a
      #   root-coverage defect in the same family as v0.19.0's two.
      #
      #   **not on the list** — the thread has exited and `start`'s `ensure`
      #   removed it, so the object *is* garbage and the sweep is right. The
      #   defect is then downstream: something still walks to it. `LinkedList`
      #   is intrusive — `@previous` / `@next` live on the `Thread` objects
      #   themselves — so a freed-and-reissued node puts garbage in the chain
      #   that `Thread.unsafe_each` follows, which is the walk
      #   `snapshot_pthread_stack_bounds` faults in.
      #
      # The self-check is part of the answer: a "not on the list" from a walk
      # that cannot find the *collecting* thread either is a broken comparison,
      # not a finding.
      listed_hit = false
      self_seen = false
      chain_hit = false
      links = 0_u64
      current = Thread.current.as(Void*).address
      Thread.unsafe_each do |thread|
        object = thread.as(Void*).address
        listed_hit = true if object == addr
        self_seen = true if object == current
        # And the chain itself. `LinkedList#delete` fixes up both neighbours, so
        # a *live* node whose `@next` or `@previous` still points at a block the
        # sweep is about to free means the removal did not happen or did not
        # hold — and the walk that follows those links is
        # `snapshot_pthread_stack_bounds`'s, which is where this defect faults.
        if n = thread.@next
          links &+= 1
          chain_hit = true if n.as(Void*).address == addr
        end
        if pv = thread.@previous
          links &+= 1
          chain_hit = true if pv.as(Void*).address == addr
        end
      end

      # Three lines, not one. `RawOut::LIMIT` is 480 bytes and truncates in
      # silence — the first version of this report grew past it and lost the
      # end of its own verdict, which is the failure mode of every instrument
      # in this file written down one more time.
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
      len = RawOut.append(buf.to_unsafe, len, " words from ")
      len = RawOut.append_u64(buf.to_unsafe, len, threads_with_gregs)
      len = RawOut.append(buf.to_unsafe, len, " of ")
      len = RawOut.append_u64(buf.to_unsafe, len, threads_listed)
      len = RawOut.append(buf.to_unsafe, len, " threads). Offered by the collecting thread's own stack scan: ")
      len = RawOut.append(buf.to_unsafe, len, offered ? "yes" : "no")
      len = RawOut.append(buf.to_unsafe, len, ". collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)

      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry:   on Crystal's thread list: ")
      if listed_hit
        len = RawOut.append(buf.to_unsafe, len, "YES — the list is a static root and did not keep it alive")
      else
        # Off the list has **two** causes and this line asserted one of them
        # until 2026-08-20, when the first catch to reach it was the other: a
        # thread that had not published *yet*, not one that had exited.
        len = RawOut.append(buf.to_unsafe, len, "no — it has either not published yet or exited")
      end
      len = RawOut.append(buf.to_unsafe, len, ". Still linked from a live thread's list node: ")
      len = RawOut.append(buf.to_unsafe, len, chain_hit ? "YES" : "no")
      len = RawOut.append(buf.to_unsafe, len, " (")
      len = RawOut.append_u64(buf.to_unsafe, len, links)
      len = RawOut.append(buf.to_unsafe, len, " links read; self-check: the collecting thread was ")
      len = RawOut.append(buf.to_unsafe, len, self_seen ? "found)" : "NOT FOUND, so this proves nothing)")
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)

      report_birth_evidence(addr) unless listed_hit
      report_thread_population
    end

    # What the pre-stop wait recorded, next to this block's own handle.
    #
    # The handle comparison is **consistent with** the object being the thread
    # that was being born; it is not proof, and the reason is in this file's own
    # local runs: the same `pthread_t` value appeared in eight different
    # collections while the staged total climbed from 4 to 11. glibc recycles
    # thread ids, so a match can also be an old object holding an id that has
    # since been handed to somebody else. Said here rather than left for a
    # reader to discover, because the line above it is the one that would
    # otherwise read as an identification.
    private def report_birth_evidence(addr : UInt64) : Nil
      handle = Pointer(UInt64).new(addr &+ offsetof(Thread, @system_handle)).value
      matched = staged_ids_at_stop_count > 0 && staged_id_at_stop?(handle)

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry:   its @system_handle 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, handle)
      if staged_timed_out_at_stop
        len = RawOut.append(buf.to_unsafe, len, "; the wait GAVE UP on ")
        len = RawOut.append_u64(buf.to_unsafe, len, staged_seen_at_stop)
        len = RawOut.append(buf.to_unsafe, len, " staged thread(s), so the world stopped with one unpublished and unscanned")
      elsif staged_seen_at_stop > 0
        len = RawOut.append(buf.to_unsafe, len, "; ")
        len = RawOut.append_u64(buf.to_unsafe, len, staged_seen_at_stop)
        len = RawOut.append(buf.to_unsafe, len, " were staged at the stop and the wait caught them all")
      else
        len = RawOut.append(buf.to_unsafe, len, "; nothing was staged at the stop, so an exit is the reading left")
      end
      if matched
        len = RawOut.append(buf.to_unsafe, len, ". That handle is one of the staged ids — consistent with the thread being born, though ids are recycled")
      end
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # The consequence — a `Thread` dying with its address on a stack gcry owns
    # nothing of — fires in about one CI job in three, in bursts, and in none of
    # 60 local runs. Waiting for it is not the only way to learn something.
    #
    # Its **precondition** is countable in every collection, crash or not: a
    # thread that gcry has no stack bounds for. There are two kinds and they are
    # the two candidate mechanisms —
    #
    #   - `staged` — created, recorded by `Platform` at `pthread_create`, not yet
    #     on Crystal's list, so `stop_world` neither suspends nor scans it;
    #   - a **gap** — on the list, and the pre-stop snapshot got no bounds for
    #     it, which is the visited/read shortfall v0.20.0 made countable.
    #
    # A green run that never shows either says the unowned stack in the catches
    # is neither of them and the hunt has to widen. A green run full of one of
    # them names the fix without waiting for another crash. Counted every
    # collection under the arm, reported the first few times each is seen.
    private def note_thread_preconditions : Nil
      @thread_pop_collections &+= 1
      listed = 0_u64
      bounded = 0_u64
      Thread.unsafe_each do |thread|
        listed &+= 1
        bounded &+= 1 if Platform.snapshotted_stack_bounds(thread.to_unsafe)
      end
      # Not `Platform.staged_count`: `wait_for_staged_threads` runs before the
      # world stops and either drains every published entry or drops the rest on
      # timeout, so that number is zero by construction here. What matters is
      # what the wait *saw*, and whether it gave up — a wait that timed out
      # stopped the world with a thread still unpublished, which is the
      # precondition itself and not a proxy for it.
      staged = staged_seen_at_stop
      timed_out = staged_timed_out_at_stop

      # And the reading the wait cannot account for at all: a thread staged
      # *after* the wait ran. `pthread_create` returns, the entry appears, and
      # the collector is already past the point where it looks — the world then
      # stops without it. Entries are otherwise only released when the thread
      # publishes itself, so a non-zero count here is not the wait's leftovers:
      # it is a thread that exists, is not on Crystal's list, and was never
      # waited for. Zero by construction only on the timeout path, which is
      # reported separately above.
      staged_now = Platform.staged_count.to_u64

      if bounded < listed
        @thread_pop_gap_collections &+= 1
        if @thread_pop_gaps_reported < THREAD_POP_REPORT_LIMIT
          @thread_pop_gaps_reported += 1
          report_thread_precondition("a thread on Crystal's list has no snapshotted stack bounds",
            listed, bounded, staged)
        end
      end

      if staged_now > 0 && !timed_out
        @thread_pop_staged_now_collections &+= 1
        if @thread_pop_staged_now_reported < THREAD_POP_REPORT_LIMIT
          @thread_pop_staged_now_reported += 1
          report_thread_precondition(
            "a thread was staged AFTER the wait ran — the world stopped without it and nothing waited",
            listed, bounded, staged_now)
        end
      end

      if staged > 0
        @thread_pop_staged_collections &+= 1
        @thread_pop_staged_timeouts &+= 1 if timed_out
        if @thread_pop_staged_reported < THREAD_POP_REPORT_LIMIT
          @thread_pop_staged_reported += 1
          report_thread_precondition(
            timed_out ? "the wait for a staged thread GAVE UP — the world stopped with it unpublished" : "a thread was staged when the world stopped, and the wait caught it",
            listed, bounded, staged)
        end
      end
    end

    private def report_thread_precondition(what : String, listed : UInt64, bounded : UInt64,
                                           staged : UInt64) : Nil
      buf = uninitialized UInt8[384]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: dying-type audit — precondition: ")
      len = RawOut.append(buf.to_unsafe, len, what)
      len = RawOut.append(buf.to_unsafe, len, ". ")
      len = RawOut.append_u64(buf.to_unsafe, len, listed)
      len = RawOut.append(buf.to_unsafe, len, " listed, ")
      len = RawOut.append_u64(buf.to_unsafe, len, bounded)
      len = RawOut.append(buf.to_unsafe, len, " bounded, ")
      len = RawOut.append_u64(buf.to_unsafe, len, staged)
      len = RawOut.append(buf.to_unsafe, len, " staged. collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
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
