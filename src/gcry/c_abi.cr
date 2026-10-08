# Boehm's C entry points (`GC_*`), defined by every `-Dgc_none` gcry program,
# and stdlib's `lib LibGC` binding to them.
#
# Who calls them: code compiled against stdlib's `gc/boehm.cr` running inside
# a gcry process. That is the interpreter first of all — `crystal i` interprets
# the program with the Boehm prelude and resolves its `LibGC` calls from the
# compiler binary itself (`compiler/crystal/interpreter/context.cr`,
# `load_current_program_handle`) — then Crystal code calling this `LibGC`
# (readiness M8; Crystal's own `spec/std` calls `LibGC.size`) and C code
# linked into the program. A Crystal `lib` of its own that declares a `GC_*`
# name does not reach them: Crystal 1.21 then leaves gcry's definition of
# that name out of the program, and the link fails with "undefined
# reference", identical signature or not.
#
# The declarations are `gc/boehm.cr`'s, type for type, so code written against
# stdlib's `LibGC` calls them unchanged: Crystal rejects a `fun` definition
# whose signature differs from a `lib` declaration of the same symbol.
# (`GC_get_prof_stats` therefore returns nothing, as stdlib declares it, where
# Boehm's C returns the bytes written.) Boehm's thread-registration calls,
# which stdlib does not bind, are declared at the end.
#
# Each function either does what Boehm documents, on gcry's heap, or — where
# gcry has no equivalent and pretending would change the caller's program —
# prints what is missing and aborts (`Gcry::CAbi.unsupported`). Of Boehm's
# exported *variables*, only `GC_stackbottom` is defined, because `crystal i`
# cannot run a program without it (`gcry_c_stackbottom_storage` below). The
# other three (`GC_gc_no`, `GC_bytes_found`, `GC_current_warn_proc`) are not
# declared: using them is a compile error rather than a wrong answer.
#
# `-Dgcry_no_boehm_abi` leaves this file out (src/gcry.cr), for a program that
# links libgc itself (docs/INTEGRATION.md § Boehm's C ABI).
lib LibGC
  alias Int = LibC::Int
  alias SizeT = LibC::SizeT
  {% if flag?(:win32) && flag?(:bits64) %}
    alias Word = LibC::ULongLong
    alias SignedWord = LibC::LongLong
  {% else %}
    alias Word = LibC::ULong
    alias SignedWord = LibC::Long
  {% end %}

  struct StackBase
    mem_base : Void*
  end

  alias ThreadHandle = Void*

  struct ProfStats
    heap_size : Word
    free_bytes : Word
    unmapped_bytes : Word
    bytes_since_gc : Word
    bytes_before_gc : Word
    non_gc_bytes : Word
    gc_no : Word
    markers_m1 : Word
    bytes_reclaimed_since_gc : Word
    reclaimed_bytes_before_gc : Word
    expl_freed_bytes_since_gc : Word
    obtained_from_os_bytes : Word
  end

  fun init = GC_init
  fun malloc = GC_malloc(size : SizeT) : Void*
  fun malloc_atomic = GC_malloc_atomic(size : SizeT) : Void*
  fun realloc = GC_realloc(ptr : Void*, size : SizeT) : Void*
  fun free = GC_free(ptr : Void*)
  fun collect_a_little = GC_collect_a_little : Int
  fun collect = GC_gcollect
  fun add_roots = GC_add_roots(low : Void*, high : Void*)
  fun remove_roots = GC_remove_roots(low : Void*, high : Void*)
  fun enable = GC_enable
  fun disable = GC_disable
  fun is_disabled = GC_is_disabled : Int
  fun set_handle_fork = GC_set_handle_fork(value : Int)

  fun base = GC_base(displaced_pointer : Void*) : Void*
  fun is_heap_ptr = GC_is_heap_ptr(pointer : Void*) : Int
  fun general_register_disappearing_link = GC_general_register_disappearing_link(link : Void**, obj : Void*) : Int
  fun register_disappearing_link = GC_register_disappearing_link(link : Void**) : Int
  fun unregister_disappearing_link = GC_unregister_disappearing_link(link : Void**) : Int

  alias Finalizer = Void*, Void* ->
  fun register_finalizer = GC_register_finalizer(obj : Void*, fn : Finalizer, cd : Void*, ofn : Finalizer*, ocd : Void**)
  fun register_finalizer_ignore_self = GC_register_finalizer_ignore_self(obj : Void*, fn : Finalizer, cd : Void*, ofn : Finalizer*, ocd : Void**)
  fun invoke_finalizers = GC_invoke_finalizers : Int

  fun get_heap_usage_safe = GC_get_heap_usage_safe(heap_size : Word*, free_bytes : Word*, unmapped_bytes : Word*, bytes_since_gc : Word*, total_bytes : Word*)
  fun set_max_heap_size = GC_set_max_heap_size(Word)

  fun get_prof_stats = GC_get_prof_stats(stats : ProfStats*, size : SizeT)

  fun get_start_callback = GC_get_start_callback : Void*
  fun set_start_callback = GC_set_start_callback(callback : ->)

  fun set_push_other_roots = GC_set_push_other_roots(proc : ->)
  fun get_push_other_roots = GC_get_push_other_roots : ->

  fun push_all_eager = GC_push_all_eager(bottom : Void*, top : Void*)

  fun get_my_stackbottom = GC_get_my_stackbottom(sb : StackBase*) : ThreadHandle
  fun set_stackbottom = GC_set_stackbottom(th : ThreadHandle, sb : StackBase*) : ThreadHandle

  {% if flag?(:linux) || flag?(:darwin) %}
    # The main thread's stack bottom (`gcry_c_stackbottom_storage`).
    $stackbottom = GC_stackbottom : Void*
  {% end %}

  alias OnHeapResizeProc = Word ->
  fun set_on_heap_resize = GC_set_on_heap_resize(OnHeapResizeProc)
  fun get_on_heap_resize = GC_get_on_heap_resize : OnHeapResizeProc

  enum EventType
    START # COLLECTION
    MARK_START
    MARK_END
    RECLAIM_START
    RECLAIM_END
    END              # COLLECTION
    PRE_STOP_WORLD   # STOPWORLD_BEGIN
    POST_STOP_WORLD  # STOPWORLD_END
    PRE_START_WORLD  # STARTWORLD_BEGIN
    POST_START_WORLD # STARTWORLD_END
    THREAD_SUSPENDED
    THREAD_UNSUSPENDED
  end

  alias OnCollectionEventProc = EventType ->
  fun set_on_collection_event = GC_set_on_collection_event(cb : OnCollectionEventProc)
  fun get_on_collection_event = GC_get_on_collection_event : OnCollectionEventProc

  alias OnThreadEventProc = EventType, Void* ->
  fun set_on_thread_event = GC_set_on_thread_event(cb : OnThreadEventProc)
  fun get_on_thread_event = GC_get_on_thread_event : OnThreadEventProc

  fun size = GC_size(addr : Void*) : LibC::SizeT

  {% if flag?(:win32) %}
    fun beginthreadex = GC_beginthreadex(security : Void*, stack_size : LibC::UInt, start_address : Void* -> LibC::UInt,
                                         arglist : Void*, initflag : LibC::UInt, thrdaddr : LibC::UInt*) : Void*
  {% elsif !flag?(:wasm32) %}
    fun pthread_create = GC_pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start : Void* -> Void*, arg : Void*) : LibC::Int
    fun pthread_join = GC_pthread_join(thread : LibC::PthreadT, value : Void**) : LibC::Int
    fun pthread_detach = GC_pthread_detach(thread : LibC::PthreadT) : LibC::Int
  {% end %}

  alias WarnProc = LibC::Char*, Word ->
  fun set_warn_proc = GC_set_warn_proc(WarnProc)

  fun stop_world_external = GC_stop_world_external
  fun start_world_external = GC_start_world_external
  fun get_suspend_signal = GC_get_suspend_signal : Int
  fun get_thr_restart_signal = GC_get_thr_restart_signal : Int

  # Not in `gc/boehm.cr`: Boehm's registration of threads it did not create.
  # Declared here, ahead of their definitions, because a Crystal `lib`
  # declaring a `GC_*` name *after* gcry defines it leaves the definition
  # out of the program altogether ("undefined reference" at link, observed
  # with Crystal 1.21 for `GC_malloc` too), so Crystal code reaches them
  # through these. C code links against them directly.
  fun register_my_thread = GC_register_my_thread(sb : StackBase*) : Int
  fun unregister_my_thread = GC_unregister_my_thread : Int
  fun allow_register_threads = GC_allow_register_threads
  fun thread_is_registered = GC_thread_is_registered : Int
  fun get_stack_base = GC_get_stack_base(sb : StackBase*) : Int
end

module Gcry
  # :nodoc:
  module CAbi
    @@push_other_roots : Proc(Nil)? = nil
    @@start_callback : Proc(Nil)? = nil
    @@warn_proc : LibGC::WarnProc? = nil
    @@on_collection_event : LibGC::OnCollectionEventProc? = nil
    @@on_thread_event : LibGC::OnThreadEventProc? = nil
    @@on_heap_resize : LibGC::OnHeapResizeProc? = nil

    # `GC_add_roots` ranges: `[count, capacity, lo0, hi0, lo1, hi1, ...]`,
    # words in libc memory. Writers take `@@ranges_lock`. The collector takes
    # no lock — a mutator stopped holding it would stall the stop — so a
    # writer fills an entry before it publishes the count covering it, and
    # moves an end with one word store. A full table is copied into one of
    # twice the capacity and published whole. The table it replaces is not
    # freed: the hook may be reading it (a C thread gcry does not stop can
    # add mid-collection), and the tables left behind come to less than the
    # live one.
    #
    # Boehm keeps one entry per range (`GC_add_roots_inner`): a range inside
    # one already registered changes nothing, and one with the same start
    # extends it. Until 2026-10-07 every call appended a copy one entry longer
    # with no lock: duplicates piled up, each leaving the previous table
    # behind, and threads adding at once each published a copy of the same
    # old table — 16 at once kept 2 to 5 of their 16 ranges, and the
    # collector stopped scanning the rest
    # (`process_spec/regression/41_gc_add_roots_concurrent_spec.cr`).
    @@ranges = Atomic(UInt64*).new(Pointer(UInt64).null)
    # Taken by atomic exchange, not `Crystal::SpinLock`: that compiles to
    # nothing under `-Dwithout_mt` off Windows, and C threads add roots
    # whatever Crystal's threading flags say.
    @@ranges_lock = 0
    @@root_table_copies = 0

    def self.unsupported(name : String, why : String) : NoReturn
      buf = uninitialized UInt8[RawOut::LIMIT]
      len = RawOut.append(buf.to_unsafe, 0, "gcry: ")
      len = RawOut.append(buf.to_unsafe, len, name)
      len = RawOut.append(buf.to_unsafe, len, " is not supported by gcry: ")
      len = RawOut.append(buf.to_unsafe, len, why)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
      LibC.abort
    end

    # Boehm's `GC_base`: the start of the live block containing *pointer*, or
    # null. Interior pointers resolve, as in Boehm.
    def self.base(pointer : Void*) : Void*
      return Pointer(Void).null if pointer.null?
      heap = Gcry.default_heap?
      return Pointer(Void).null unless heap
      found = heap.find_object_with_chunk(pointer)
      return Pointer(Void).null unless found
      header, chunk = found
      heap.user_of(chunk, header)
    end

    # Boehm's `GC_register_finalizer` and `_ignore_self`: one finalizer per
    # object, replaced by a second registration and removed by a null *fn*,
    # the previous function and client data written to *old_fn* / *old_data*
    # (nulls when there was none). A pointer that is not the start of a live
    # gcry block registers nothing and reports nothing, as Boehm does for one
    # outside its heap. *order* is the call's ordering (`Finalizers::Order`).
    #
    # `GC_register_finalizer_no_order` and `_unreachable` are not defined:
    # stdlib's `gc/boehm.cr` binds neither, and both are Java-style unordered
    # finalization that gcry's ordering pass does not implement — a program
    # that calls them fails to link rather than getting ordered finalization.
    #
    # Until 2026-10-06 a second registration was caught by reading
    # `BlockHeader.finalizer?`, which under headerless is a bit of the
    # object's own bytes 4..7 — and was never set there, so a real second
    # registration ran both finalizers
    # (`process_spec/regression/25_boehm_finalizer_registration_spec.cr`).
    def self.register_finalizer(object : Void*, fn : LibGC::Finalizer, data : Void*,
                                old_fn : LibGC::Finalizer*, old_data : Void**,
                                order : Finalizers::Order) : Nil
      previous = {Pointer(Void).null, Pointer(Void).null}
      heap = Gcry.default_heap?
      if heap && (found = heap.find_object_with_chunk(object))
        header, chunk = found
        if heap.user_of(chunk, header) == object
          previous = heap.replace_c_finalizer(object, fn.pointer, data, order)
        end
      end
      # The slot is a C function pointer, one word, not a Crystal `Proc`.
      old_fn.as(Void**).value = previous[0] unless old_fn.null?
      old_data.value = previous[1] unless old_data.null?
    end

    def self.add_roots(low : Void*, high : Void*) : Nil
      return unless low.address < high.address
      lo = low.address
      hi = high.address
      # The hook that scans these is in from `GC.init` (`install_roots_hook`).
      lock_ranges
      begin
        table = @@ranges.get(:acquire)
        count = table.null? ? 0_u64 : table[0]
        free_entry = Pointer(UInt64).null
        i = 0_u64
        while i < count
          entry = table + (2 &+ 2 &* i)
          # One with the same start extends it — a removed one too, which
          # takes its start back with the single store of its end.
          if entry[0] == lo
            Atomic::Ops.store(entry + 1, hi, LLVM::AtomicOrdering::Release, false) if entry[1] < hi
            return
          end
          if entry[0] < entry[1]
            return if entry[0] <= lo && hi <= entry[1]
          elsif free_entry.null?
            free_entry = entry
          end
          i &+= 1
        end
        unless free_entry.null?
          # A removed entry is taken over in place, so add/remove churn reuses
          # the table instead of copying it: a copy cannot free the one it
          # replaces, and 2M add/remove pairs over distinct ranges left 45 MB
          # of such copies behind when a full table with removed entries was
          # compacted into a new one. End to 0 first, then the start, then the
          # end: the hook reads end, start, end and takes the range only when
          # both ends agree, so it never pairs one range's start with
          # another's end (`install_roots_hook`).
          Atomic::Ops.store(free_entry + 1, 0_u64, LLVM::AtomicOrdering::Release, false)
          Atomic::Ops.store(free_entry, lo, LLVM::AtomicOrdering::Release, false)
          Atomic::Ops.store(free_entry + 1, hi, LLVM::AtomicOrdering::Release, false)
          return
        end
        if table.null? || count == table[1]
          capacity = table.null? ? 8_u64 : table[1] &* 2
          fresh = LibC.malloc(LibC::SizeT.new((2 &+ 2 &* capacity) &* 8)).as(UInt64*)
          unsupported("GC_add_roots", "out of memory for the root table") if fresh.null?
          fresh[0] = count
          fresh[1] = capacity
          (table + 2).copy_to(fresh + 2, 2 &* count) unless table.null?
          @@ranges.set(fresh, :release)
          @@root_table_copies += 1
          table = fresh
        end
        Atomic::Ops.store(table + (2 &+ 2 &* count), lo, LLVM::AtomicOrdering::Release, false)
        Atomic::Ops.store(table + (3 &+ 2 &* count), hi, LLVM::AtomicOrdering::Release, false)
        Atomic::Ops.store(table, count &+ 1, LLVM::AtomicOrdering::Release, false)
      ensure
        unlock_ranges
      end
    end

    # Boehm's `GC_remove_roots`: every registered range wholly inside
    # `[low, high)` stops being a root (`GC_remove_roots_inner`, mark_rts.c).
    # Until 2026-10-08 gcry had no way to take one back, so a range whose
    # memory was then freed stayed scanned. A removed entry keeps its start
    # and has its end stored down to it, one word the hook reads with
    # acquire: the hook sees the range whole or empty, never a mix. The next
    # `add_roots` of another range takes the entry over in place.
    def self.remove_roots(low : Void*, high : Void*) : Nil
      return unless low.address < high.address
      lo = low.address
      hi = high.address
      lock_ranges
      begin
        table = @@ranges.get(:acquire)
        return if table.null?
        count = table[0]
        i = 0_u64
        while i < count
          entry = table + (2 &+ 2 &* i)
          if entry[0] < entry[1] && lo <= entry[0] && entry[1] <= hi
            Atomic::Ops.store(entry + 1, entry[0], LLVM::AtomicOrdering::Release, false)
          end
          i &+= 1
        end
      ensure
        unlock_ranges
      end
    end

    # Ranges in the `GC_add_roots` table, removed ones not counted.
    def self.root_range_count : Int32
      table = @@ranges.get(:acquire)
      return 0 if table.null?
      count = Atomic::Ops.load(table, LLVM::AtomicOrdering::Acquire, false)
      live = 0
      i = 0_u64
      while i < count
        entry = table + (2 &+ 2 &* i)
        live += 1 if entry[0] < Atomic::Ops.load(entry + 1, LLVM::AtomicOrdering::Acquire, false)
        i &+= 1
      end
      live
    end

    # Copies of the `GC_add_roots` table made so far. Each one leaves the
    # table it replaces allocated, so add/remove churn must not keep making
    # them.
    def self.root_table_copies : Int32
      @@root_table_copies
    end

    private def self.lock_ranges : Nil
      until Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Xchg, pointerof(@@ranges_lock), 1, LLVM::AtomicOrdering::Acquire, false) == 0
        Intrinsics.pause
      end
    end

    private def self.unlock_ranges : Nil
      Atomic::Ops.store(pointerof(@@ranges_lock), 0, LLVM::AtomicOrdering::Release, false)
    end

    def self.push_other_roots=(proc : Proc(Nil)) : Nil
      @@push_other_roots = proc.pointer.null? ? nil : proc
    end

    # Never a null procedure: stdlib's `GC.before_collect` chains to whatever
    # this returned and calls it unconditionally.
    def self.push_other_roots : Proc(Nil)
      @@push_other_roots || -> { }
    end

    # Called at the start of every collection, before the world is stopped,
    # as Boehm calls it at the start of every full collection
    # (`GC_notify_full_gc`). Its one stdlib registrant (`gc/boehm.cr`
    # `GC.init`, so `crystal i`'s interpreted prelude) installs
    # `GC.lock_write`, which under the interpreter's `without_mt` is empty.
    def self.start_callback=(proc : Proc(Nil)) : Nil
      @@start_callback = proc.pointer.null? ? nil : proc
      hook_events
    end

    def self.start_callback : Void*
      @@start_callback.try(&.pointer) || Pointer(Void).null
    end

    def self.on_collection_event=(proc : LibGC::OnCollectionEventProc) : Nil
      @@on_collection_event = proc.pointer.null? ? nil : proc
      hook_events
    end

    def self.on_collection_event : LibGC::OnCollectionEventProc
      @@on_collection_event || LibGC::OnCollectionEventProc.new(Pointer(Void).null, Pointer(Void).null)
    end

    def self.on_thread_event=(proc : LibGC::OnThreadEventProc) : Nil
      @@on_thread_event = proc.pointer.null? ? nil : proc
      hook_events
    end

    def self.on_thread_event : LibGC::OnThreadEventProc
      @@on_thread_event || LibGC::OnThreadEventProc.new(Pointer(Void).null, Pointer(Void).null)
    end

    def self.on_heap_resize=(proc : LibGC::OnHeapResizeProc) : Nil
      @@on_heap_resize = proc.pointer.null? ? nil : proc
      hook_events
    end

    def self.on_heap_resize : LibGC::OnHeapResizeProc
      @@on_heap_resize || LibGC::OnHeapResizeProc.new(Pointer(Void).null, Pointer(Void).null)
    end

    # The heap's hooks are set only while a C callback wants them, so a
    # program that sets none pays one nil test per event and nothing else.
    # No closure captures anything: creating them allocates nothing, and
    # neither does calling them from inside the stopped world.
    private def self.hook_events : Nil
      heap = Gcry.default_heap
      if @@start_callback || @@on_collection_event
        heap.collection_event_hook = ->(event : Heap::CollectionEvent) { CAbi.collection_event(event) }
      else
        heap.collection_event_hook = nil
      end
      if @@on_thread_event
        heap.thread_event_hook = ->(event : Heap::CollectionEvent, thread : Void*) { CAbi.thread_event(event, thread) }
      else
        heap.thread_event_hook = nil
      end
      if @@on_heap_resize
        heap.heap_resize_hook = ->(size : UInt64) { CAbi.heap_resize(size) }
      else
        heap.heap_resize_hook = nil
      end
    end

    # Boehm runs the start callback, then reports `GC_EVENT_START`.
    def self.collection_event(event : Heap::CollectionEvent) : Nil
      if event.start?
        @@start_callback.try &.call
      end
      @@on_collection_event.try &.call(LibGC::EventType.new(event.value))
    end

    def self.thread_event(event : Heap::CollectionEvent, thread : Void*) : Nil
      @@on_thread_event.try &.call(LibGC::EventType.new(event.value), thread)
    end

    def self.heap_resize(size : UInt64) : Nil
      @@on_heap_resize.try &.call(LibGC::Word.new!(size))
    end

    # Boehm asserts the procedure is not null; a null one here restores the
    # default, which prints the warning to stderr as Boehm's default does.
    def self.warn_proc=(proc : LibGC::WarnProc) : Nil
      @@warn_proc = proc.pointer.null? ? nil : proc
    end

    # Boehm's warning for the one condition the two collectors share and
    # Boehm warns about: an allocation the heap cannot satisfy. Boehm warns
    # through its warn procedure and its `GC_malloc` returns null
    # (`GC_collect_or_expand`); gcry's allocator raises `OutOfMemoryError`
    # instead, which cannot unwind through a C caller, so the C entry points
    # catch it and answer as Boehm does. The text is Boehm's, a printf format
    # with one `%lu` for the heap size in MiB, as a warn procedure expects.
    def self.warn_out_of_memory : Nil
      mib = (Gcry.default_heap?.try(&.heap_size) || 0_u64) >> 20
      if proc = @@warn_proc
        proc.call("GC Warning: Out of Memory! Heap size: %lu MiB. Returning NULL!\n".to_unsafe, LibGC::Word.new!(mib))
      else
        buf = uninitialized UInt8[RawOut::LIMIT]
        len = RawOut.append(buf.to_unsafe, 0, "GC Warning: Out of Memory! Heap size: ")
        len = RawOut.append_u64(buf.to_unsafe, len, mib)
        len = RawOut.append(buf.to_unsafe, len, " MiB. Returning NULL!\n")
        RawOut.flush(buf.to_unsafe, len)
      end
    end

    # Boehm's result codes (`gc.h`).
    GC_SUCCESS       = 0
    GC_DUPLICATE     = 1
    GC_UNIMPLEMENTED = 3

    # A thread C created is registered by putting it on Crystal's thread list,
    # which is the set gcry stops and scans on every platform. Linux, Darwin
    # and Windows: OpenBSD/Android keep `Thread.current` in a pthread key
    # rather than the thread-local cleared below.
    {% if (flag?(:linux) || flag?(:darwin) || flag?(:win32)) && !flag?(:android) %}
      # Bit 0: this thread was adopted by `register_my_thread`, so it is the
      # one to take off the list again — a Crystal thread leaves it in its own
      # `Thread#start`, and deleting a node twice corrupts the list. Bit 1: the
      # suspend signal was blocked when it registered. A literal initialiser,
      # so reading it runs no `__crystal_once` (which would make a `Thread`).
      @[ThreadLocal]
      @@adopted : UInt8 = 0_u8

      # The key whose destructor takes a thread that exits still registered
      # back off the lists — `pthread_exit` out of a `GC_pthread_create`
      # routine passes over the trampoline's own unregister, and a C thread
      # can end without its `GC_unregister_my_thread` — since a thread listed
      # after it is gone is one every later stop signals and waits for. Its
      # value is the adopted `Thread`, so the destructor needs no thread-local
      # to find it: Darwin frees those in a key destructor of its own, which
      # may run first. 0: not made, 1: being made, 2: made, 3: refused
      # (registration goes on without one).
      #
      # On Windows the key is an FLS slot whose callback runs on the exiting
      # thread, before its TLS goes (`Gcry::OS.pthread_key_create`). Without
      # it a stop skips such a thread only if `SuspendThread` refuses it and
      # `WaitForSingleObject` shows it gone (windows_stw.cr), and the list
      # keeps its `Thread`, its main fiber over a freed stack, and its handle.
      # A thread ended by `TerminateThread`, or by `ExitProcess` from another,
      # runs no callback and is left to that skip.
      @@exit_key_state = 0
      @@exit_key = uninitialized Gcry::OS::GcryPthreadKeyT

      private def self.exit_key? : Bool
        loop do
          case Atomic::Ops.load(pointerof(@@exit_key_state), LLVM::AtomicOrdering::Acquire, false)
          when 2 then return true
          when 3 then return false
          when 0
            _, won = Atomic::Ops.cmpxchg(pointerof(@@exit_key_state), 0, 1,
              LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::Monotonic)
            if won
              made = Gcry::OS.pthread_key_create(pointerof(@@exit_key), ->(thread : Void*) { CAbi.drop_adopted(thread.as(::Thread)) }) == 0
              Atomic::Ops.store(pointerof(@@exit_key_state), made ? 2 : 3, LLVM::AtomicOrdering::Release, false)
            end
          else
            Intrinsics.pause
          end
        end
      end

      # Fiber first, then the thread, then the thread-locals: the reverse of
      # `Thread#start`'s exit. From `unregister_my_thread`, and from the exit
      # key's destructor on the dying thread, which can still be stopped.
      def self.drop_adopted(thread : ::Thread) : Nil
        if fiber = thread.@main_fiber
          Fiber.inactive(fiber)
        end
        ::Thread.gcry_unlist(thread)
        {% if flag?(:win32) %}
          # The handle `Thread.new` duplicated, which only a stop read, and a
          # stop walks the list under the lock `gcry_unlist` just took: as
          # `Thread#start` ends with `system_close`, without the join no C
          # caller would make.
          LibC.CloseHandle(thread.to_unsafe)
        {% end %}
        Crystal::System::Thread.gcry_clear_current_thread
        @@adopted = 0_u8
      end

      # Windows has no `GC_pthread_create`; its `GC_beginthreadex` stays
      # unsupported (below).
      {% unless flag?(:win32) %}
        # `GC_pthread_create`'s routine and argument, carried to the new thread
        # in libc memory.
        private record PthreadStart, start : Void* -> Void*, arg : Void*

        # Boehm's `GC_pthread_create` registers the thread before the routine
        # runs and unregisters it after (`GC_pthread_start`). Until 2026-10-07
        # gcry's ran the routine directly: the thread was never on Crystal's
        # list, so no stop suspended it or scanned its stack, and what it held
        # there alone was swept under it
        # (`process_spec/regression/40_gc_pthread_create_registers_spec.cr`).
        # *arg* is rooted for the thread's life as before (`GC.pthread_create`),
        # and held by this frame until it is.
        def self.pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start : Void* -> Void*, arg : Void*) : LibC::Int
          data = LibC.malloc(sizeof(PthreadStart)).as(PthreadStart*)
          return LibC::EAGAIN if data.null?
          data.value = PthreadStart.new(start, arg)
          ret = GC.pthread_create(thread, attr, ->(raw : Void*) { CAbi.pthread_start(raw) }, data.as(Void*), arg)
          LibC.free(data.as(Void*)) unless ret == 0
          ret
        end

        # On the new thread, its own pthread stack the base. A registration
        # refused (no stop-the-world collector) runs the routine unregistered.
        def self.pthread_start(raw : Void*) : Void*
          data = raw.as(PthreadStart*)
          start = data.value.start
          arg = data.value.arg
          LibC.free(raw)
          registered = register_my_thread(Pointer(LibGC::StackBase).null) == GC_SUCCESS
          result = start.call(arg)
          unregister_my_thread if registered
          result
        end
      {% end %}
    {% end %}

    def self.register_my_thread(sb : LibGC::StackBase*) : LibGC::Int
      {% if (flag?(:linux) || flag?(:darwin) || flag?(:win32)) && !flag?(:android) %}
        heap = Gcry.default_heap?
        return GC_UNIMPLEMENTED unless heap && heap.stop_the_world
        return GC_DUPLICATE if ::Thread.current?
        bounds = Platform.current_pthread_stack_bounds
        return GC_UNIMPLEMENTED unless bounds
        # gcry scans a thread's pthread stack, from its stack pointer up to
        # the top. A base outside it — a coroutine's or an alternate stack —
        # names memory gcry would not scan, so it is refused, not accepted.
        base = sb.null? ? bounds[1] : sb.value.mem_base
        return GC_UNIMPLEMENTED unless bounds[0].address < base.address && base.address <= bounds[1].address
        flags = 1_u8
        {% if flag?(:linux) %}
          # The stop is a signal on Linux, and a C thread may have it
          # blocked; a thread that never takes it is never stopped, and the
          # collector would wait on it for good.
          mask = uninitialized LibC::SigsetT
          LibC.pthread_sigmask(LibC::SIG_SETMASK, nil, pointerof(mask))
          if LibC.sigismember(pointerof(mask), Platform::STW_SIG_SUSPEND) == 1
            flags |= 2_u8
            LibC.sigdelset(pointerof(mask), Platform::STW_SIG_SUSPEND)
            LibC.pthread_sigmask(LibC::SIG_SETMASK, pointerof(mask), nil)
          end
        {% end %}
        # A second mutator from here on, as `GC.pthread_create` arranges.
        heap.heap_counters_atomic = true unless heap.heap_counters_atomic_pinned
        # Crystal's constructor for a thread that already exists: its `Thread`
        # and main fiber over the thread's stack, pushed onto the lists. On
        # Windows the `Thread` holds a duplicate of the thread's handle, which
        # is what a stop suspends, and `drop_adopted` closes.
        thread = heap.registering_thread { ::Thread.new }
        Crystal::System::Thread.current_thread = thread
        @@adopted = flags
        Gcry::OS.pthread_setspecific(@@exit_key, thread.as(Void*)) if exit_key?
        GC_SUCCESS
      {% else %}
        GC_UNIMPLEMENTED
      {% end %}
    end

    # While the thread is still listed it is stopped and scanned (its pthread
    # stack, once its fiber is gone), and after the list lets go of it nothing
    # reads the `Thread` again — so unlike a Crystal thread's exit there is no
    # window to cover with a birth root.
    def self.unregister_my_thread : LibGC::Int
      {% if (flag?(:linux) || flag?(:darwin) || flag?(:win32)) && !flag?(:android) %}
        flags = @@adopted
        return GC_SUCCESS unless flags & 1_u8 != 0
        thread = ::Thread.current?
        return GC_SUCCESS unless thread
        Gcry::OS.pthread_setspecific(@@exit_key, Pointer(Void).null) if exit_key?
        drop_adopted(thread)
        {% if flag?(:linux) %}
          if flags & 2_u8 != 0
            mask = uninitialized LibC::SigsetT
            LibC.pthread_sigmask(LibC::SIG_SETMASK, nil, pointerof(mask))
            LibC.sigaddset(pointerof(mask), Platform::STW_SIG_SUSPEND)
            LibC.pthread_sigmask(LibC::SIG_SETMASK, pointerof(mask), nil)
          end
        {% end %}
      {% end %}
      GC_SUCCESS
    end

    # The calling thread's stack bottom, from the OS, never the main thread's
    # (`GC.current_thread_stack_bottom` falls back to that).
    def self.get_stack_base(sb : LibGC::StackBase*) : LibGC::Int
      bounds = Platform.current_pthread_stack_bounds
      return GC_UNIMPLEMENTED unless bounds
      sb.value.mem_base = bounds[1]
      GC_SUCCESS
    end

    # The thread `GC.init` ran on: Boehm's main thread, whose stack bottom
    # `GC_stackbottom` holds.
    @@main_thread = 0_u64

    # Boehm sets `GC_stackbottom` when the collector starts.
    def self.init_stackbottom(bottom : Void*) : Nil
      {% if flag?(:linux) || flag?(:darwin) %}
        @@main_thread = Platform.current_thread_id
        LibGC.stackbottom = bottom
      {% end %}
    end

    # Boehm's `GC_set_stackbottom` moves `GC_stackbottom` when the stack is the
    # main thread's. gcry itself never reads the variable back.
    def self.note_stackbottom(bottom : Void*) : Nil
      {% if flag?(:linux) || flag?(:darwin) %}
        LibGC.stackbottom = bottom if Platform.current_thread_id == @@main_thread
      {% end %}
    end

    # One `before_collect` hook serves both root sources; it runs in the root
    # phase of every collection, world stopped, where `push_stack` is valid —
    # which is where Boehm calls its push-other-roots procedure too. Installed
    # once by `GC.init`, before any user code: installed by the first
    # `GC_add_roots` instead, it allocated mid-call, and a collection that
    # allocation started could run a finalizer that added a range before the
    # hook existed, or left the install half done if it raised.
    def self.install_roots_hook : Nil
      GC.before_collect do
        table = @@ranges.get(:acquire)
        unless table.null?
          i = 0_u64
          n = Atomic::Ops.load(table, LLVM::AtomicOrdering::Acquire, false)
          while i < n
            entry = table + (2 &+ 2 &* i)
            # End, start, end: an entry `add_roots` is taking over in place
            # (end 0, start, end) is skipped unless both ends agree, so a
            # start is never paired with another range's end; a removed
            # range reads as empty (`remove_roots`).
            hi = Atomic::Ops.load(entry + 1, LLVM::AtomicOrdering::Acquire, false)
            lo = Atomic::Ops.load(entry, LLVM::AtomicOrdering::Acquire, false)
            again = Atomic::Ops.load(entry + 1, LLVM::AtomicOrdering::Acquire, false)
            Gcry.default_heap.push_stack(Pointer(Void).new(lo), Pointer(Void).new(hi)) if hi == again && lo < hi
            i &+= 1
          end
        end
        @@push_other_roots.try &.call
      end
    end
  end
end

{% if (flag?(:linux) || flag?(:darwin) || flag?(:win32)) && !flag?(:android) %}
  class Thread
    # :nodoc:
    # Takes a thread `GC_register_my_thread` adopted off the list again; the
    # list is protected, and a Crystal thread leaves it in `#start`.
    def self.gcry_unlist(thread : Thread) : Nil
      threads.delete(thread)
    end
  end

  module Crystal::System::Thread
    # :nodoc:
    # `current_thread=` takes no nil. A thread that unregistered must not
    # keep naming a `Thread` the collector may since have swept.
    def self.gcry_clear_current_thread : Nil
      {% if flag?(:win32) && flag?(:gnu) %}
        # MinGW keeps it in a TLS slot rather than a thread-local.
        LibC.TlsSetValue(@@current_key, Pointer(Void).null)
      {% else %}
        @@current_thread = nil
      {% end %}
    end
  end
{% end %}

# The process GC is initialised by Crystal's `main` before any code that could
# call this runs, and that set `GC_stackbottom`; Boehm's own `GC_init` is
# likewise idempotent.
fun gcry_c_init = GC_init : Nil
end

# `GC_stackbottom`, the one Boehm variable a gcry program defines. Crystal
# cannot define a data symbol with a C name, so this function's inline
# assembly emits it into the data section. `crystal i` needs it: it interprets
# the program with stdlib's `gc/boehm.cr`, which under the interpreter's
# `without_mt` flag (and no `pkg-config` version for its `@[Link("gc")]`)
# binds `$stackbottom = GC_stackbottom` and reads it for the main fiber's
# stack, resolving it from the compiler binary like every `GC_*` call. Without
# it, every `crystal i` run stopped at "undefined reference to
# `GC_stackbottom'". Windows keeps that failure: no symbol is defined there.
{% if flag?(:darwin) %}
  fun gcry_c_stackbottom_storage : Nil
    asm(".pushsection __DATA,__data
         .p2align 3
         .globl _GC_stackbottom
         _GC_stackbottom:
         .quad 0
         .popsection" :::: "volatile")
  end
{% elsif flag?(:linux) %}
  fun gcry_c_stackbottom_storage : Nil
    asm(".pushsection .data
         .p2align 3
         .globl GC_stackbottom
         .type GC_stackbottom, @object
         .size GC_stackbottom, 8
         GC_stackbottom:
         .quad 0
         .popsection" :::: "volatile")
  end
{% end %}

# Out of memory, Boehm warns and returns null (`Gcry::CAbi.warn_out_of_memory`).
# gcry raised `OutOfMemoryError` here until 2026-10-06, and an exception
# cannot leave a `fun`: the caller's `rescue` never saw it and the process died
# with "Unhandled exception" (`process_spec/regression/28_boehm_callbacks_spec.cr`).
fun gcry_c_malloc = GC_malloc(size : LibGC::SizeT) : Void*
  GC.malloc(size)
    rescue Gcry::OutOfMemoryError
      Gcry::CAbi.warn_out_of_memory
      Pointer(Void).null
end

fun gcry_c_malloc_atomic = GC_malloc_atomic(size : LibGC::SizeT) : Void*
  GC.malloc_atomic(size)
    rescue Gcry::OutOfMemoryError
      Gcry::CAbi.warn_out_of_memory
      Pointer(Void).null
end

# Null with the old block left as it was, as Boehm's `GC_realloc` fails.
fun gcry_c_realloc = GC_realloc(ptr : Void*, size : LibGC::SizeT) : Void*
  GC.realloc(ptr, size)
    rescue Gcry::OutOfMemoryError
      Gcry::CAbi.warn_out_of_memory
      Pointer(Void).null
end

fun gcry_c_free = GC_free(ptr : Void*) : Nil
  GC.free(ptr)
end

# Boehm's meaning: 1 while an incremental collection is in progress, 0 once
# there is nothing left to do, and 0 while disabled (`GC.collect_a_little`).
fun gcry_c_collect_a_little = GC_collect_a_little : LibGC::Int
  GC.collect_a_little
end

# Nothing while collection is disabled, as in Boehm (`GC.collect`).
fun gcry_c_gcollect = GC_gcollect : Nil
  GC.collect
end

fun gcry_c_add_roots = GC_add_roots(low : Void*, high : Void*) : Nil
  Gcry::CAbi.add_roots(low, high)
end

fun gcry_c_remove_roots = GC_remove_roots(low : Void*, high : Void*) : Nil
  Gcry::CAbi.remove_roots(low, high)
end

# Boehm counts: `GC_disable` twice needs `GC_enable` twice. `Heap#enable` /
# `#disable` nest the same way, and an unmatched `GC_enable` is a no-op in both.
fun gcry_c_enable = GC_enable : Nil
  Gcry.default_heap.enable
  nil
end

fun gcry_c_disable = GC_disable : Nil
  Gcry.default_heap.disable
end

fun gcry_c_is_disabled = GC_is_disabled : LibGC::Int
  Gcry.default_heap.enabled? ? 0 : 1
end

# gcry re-initialises its own state in a forked child (`pthread_atfork`,
# `GC.note_fork_child`) whatever this says; Boehm's default is the same.
fun gcry_c_set_handle_fork = GC_set_handle_fork(value : LibGC::Int) : Nil
end

fun gcry_c_base = GC_base(displaced_pointer : Void*) : Void*
  Gcry::CAbi.base(displaced_pointer)
end

fun gcry_c_is_heap_ptr = GC_is_heap_ptr(pointer : Void*) : LibGC::Int
  GC.is_heap_ptr(pointer) ? 1 : 0
end

# Boehm's `GC_SUCCESS` (0) for a new registration, `GC_DUPLICATE` (1) when
# *link* was registered already — its registration then follows *obj*, as in
# Boehm (`GC_register_disappearing_link_inner`).
fun gcry_c_general_register_disappearing_link = GC_general_register_disappearing_link(link : Void**, obj : Void*) : LibGC::Int
  Gcry.default_heap.register_disappearing_link(link, obj) ? 0 : 1
end

# Boehm's short form: the object is the one `*link` points into, `GC_base(*link)`.
fun gcry_c_register_disappearing_link = GC_register_disappearing_link(link : Void**) : LibGC::Int
  Gcry.default_heap.register_disappearing_link(link) ? 0 : 1
end

# 1 when *link* was registered and is not any more, 0 when it was not
# (Boehm's `GC_unregister_disappearing_link`). The word at *link* is left as
# it is.
fun gcry_c_unregister_disappearing_link = GC_unregister_disappearing_link(link : Void**) : LibGC::Int
  Gcry.default_heap.unregister_disappearing_link(link) ? 1 : 0
end

fun gcry_c_register_finalizer = GC_register_finalizer(obj : Void*, fn : LibGC::Finalizer, cd : Void*,
                                                      ofn : LibGC::Finalizer*, ocd : Void**) : Nil
  Gcry::CAbi.register_finalizer(obj, fn, cd, ofn, ocd, Gcry::Finalizers::Order::Normal)
end

fun gcry_c_register_finalizer_ignore_self = GC_register_finalizer_ignore_self(obj : Void*, fn : LibGC::Finalizer, cd : Void*,
                                                                              ofn : LibGC::Finalizer*, ocd : Void**) : Nil
  Gcry::CAbi.register_finalizer(obj, fn, cd, ofn, ocd, Gcry::Finalizers::Order::IgnoreSelf)
end

# gcry runs finalizers itself at the end of each collection — Boehm's default
# (`GC_finalize_on_demand` 0), under which this call also has nothing to run.
fun gcry_c_invoke_finalizers = GC_invoke_finalizers : LibGC::Int
  0
end

fun gcry_c_get_heap_usage_safe = GC_get_heap_usage_safe(heap_size : LibGC::Word*, free_bytes : LibGC::Word*,
                                                        unmapped_bytes : LibGC::Word*, bytes_since_gc : LibGC::Word*,
                                                        total_bytes : LibGC::Word*) : Nil
  stats = GC.stats
  heap_size.value = LibGC::Word.new!(stats.heap_size) unless heap_size.null?
  free_bytes.value = LibGC::Word.new!(stats.free_bytes) unless free_bytes.null?
  unmapped_bytes.value = LibGC::Word.new!(stats.unmapped_bytes) unless unmapped_bytes.null?
  bytes_since_gc.value = LibGC::Word.new!(stats.bytes_since_gc) unless bytes_since_gc.null?
  total_bytes.value = LibGC::Word.new!(stats.total_bytes) unless total_bytes.null?
end

fun gcry_c_set_max_heap_size = GC_set_max_heap_size(size : LibGC::Word) : Nil
  Gcry::CAbi.unsupported("GC_set_max_heap_size", "gcry has no heap size limit")
end

# Fills at most *size* bytes of *stats*.
fun gcry_c_get_prof_stats = GC_get_prof_stats(stats : LibGC::ProfStats*, size : LibGC::SizeT) : Nil
  s = GC.prof_stats
  out = LibGC::ProfStats.new
  out.heap_size = LibGC::Word.new!(s.heap_size)
  out.free_bytes = LibGC::Word.new!(s.free_bytes)
  out.unmapped_bytes = LibGC::Word.new!(s.unmapped_bytes)
  out.bytes_since_gc = LibGC::Word.new!(s.bytes_since_gc)
  out.bytes_before_gc = LibGC::Word.new!(s.bytes_before_gc)
  out.non_gc_bytes = LibGC::Word.new!(s.non_gc_bytes)
  out.gc_no = LibGC::Word.new!(s.gc_no)
  out.markers_m1 = LibGC::Word.new!(s.markers_m1)
  out.bytes_reclaimed_since_gc = LibGC::Word.new!(s.bytes_reclaimed_since_gc)
  out.reclaimed_bytes_before_gc = LibGC::Word.new!(s.reclaimed_bytes_before_gc)
  out.expl_freed_bytes_since_gc = LibGC::Word.new!(s.expl_freed_bytes_since_gc)
  out.obtained_from_os_bytes = LibGC::Word.new!(s.obtained_from_os_bytes)
  n = Math.min(size, LibGC::SizeT.new(sizeof(LibGC::ProfStats)))
  pointerof(out).as(UInt8*).copy_to(stats.as(UInt8*), n) unless stats.null?
end

# Called on the collecting thread at the start of every collection, before
# the world is stopped and before `GC_EVENT_START` (`Gcry::CAbi.collection_event`).
# Until 2026-10-06 it was recorded and never called. Boehm's rule is that it
# must not allocate; `crystal i`'s registrant runs interpreted code, which
# does (an `Interpreter` per callback), and that is survivable here because
# the call comes before the world is stopped or the collector's write lock
# taken, with the collection flag already up so no allocation in it can
# start a second collection.
fun gcry_c_get_start_callback = GC_get_start_callback : Void*
  Gcry::CAbi.start_callback
end

fun gcry_c_set_start_callback = GC_set_start_callback(callback : ->) : Nil
  Gcry::CAbi.start_callback = callback
end

# Called in the root phase of every collection, world stopped; it may call
# `GC_push_all_eager`.
fun gcry_c_set_push_other_roots = GC_set_push_other_roots(proc : ->) : Nil
  Gcry::CAbi.push_other_roots = proc
end

fun gcry_c_get_push_other_roots = GC_get_push_other_roots : ->
  Gcry::CAbi.push_other_roots
end

fun gcry_c_push_all_eager = GC_push_all_eager(bottom : Void*, top : Void*) : Nil
  Gcry.default_heap.push_stack(bottom, top)
end

# gcry's handle is always null (`GC.current_thread_stack_bottom`), and its
# stack bottom is per process, not per handle — `GC.set_stackbottom` ignores
# the thread in compiled code too.
fun gcry_c_get_my_stackbottom = GC_get_my_stackbottom(sb : LibGC::StackBase*) : LibGC::ThreadHandle
  handle, bottom = GC.current_thread_stack_bottom
  sb.value.mem_base = bottom
  handle
end

fun gcry_c_set_stackbottom = GC_set_stackbottom(th : LibGC::ThreadHandle, sb : LibGC::StackBase*) : LibGC::ThreadHandle
  bottom = sb.value.mem_base
  Gcry.default_heap?.try &.set_stackbottom(bottom)
  Gcry::CAbi.note_stackbottom(bottom)
  th
end

# Boehm's registration of a thread it did not create (`GC_register_my_thread`
# and company), until 2026-10-06 absent. The thread goes on Crystal's thread
# list, which is how gcry stops and scans every thread
# (`Gcry::CAbi.register_my_thread`); it must unregister before it exits, as
# Boehm requires, and must not touch the heap after. Linux, Darwin and
# Windows; the others answer `GC_UNIMPLEMENTED` (3). Registration is always
# allowed, so `GC_allow_register_threads` has nothing to do.
fun gcry_c_register_my_thread = GC_register_my_thread(sb : LibGC::StackBase*) : LibGC::Int
  Gcry::CAbi.register_my_thread(sb)
end

fun gcry_c_unregister_my_thread = GC_unregister_my_thread : LibGC::Int
  Gcry::CAbi.unregister_my_thread
end

fun gcry_c_allow_register_threads = GC_allow_register_threads : Nil
end

# Every Crystal thread is registered, and a C thread once it has called
# `GC_register_my_thread`.
fun gcry_c_thread_is_registered = GC_thread_is_registered : LibGC::Int
  Thread.current? ? 1 : 0
end

fun gcry_c_get_stack_base = GC_get_stack_base(sb : LibGC::StackBase*) : LibGC::Int
  Gcry::CAbi.get_stack_base(sb)
end

# Boehm's event hooks, which stdlib's `-Dtracing` (`CRYSTAL_TRACE=gc`) feeds
# on. Until 2026-10-06 setting one aborted. Each is called where Boehm calls
# it, from inside the collector, and must not allocate:
#
# - heap resize: each time the heap maps a chunk, with the new heap size
#   (`Heap#heap_resize_hook`).
# - collection events: `START`, `PRE_STOP_WORLD`, `POST_STOP_WORLD`,
#   `MARK_START`, `MARK_END`, `RECLAIM_START`, `RECLAIM_END`,
#   `PRE_START_WORLD`, `POST_START_WORLD`, `END` (`Heap#collection_event_hook`).
#   gcry sweeps inside the stop unless the sweep is deferred past it, so the
#   reclaim pair usually comes before the start-world pair, where Boehm's
#   comes after.
# - thread events: `THREAD_SUSPENDED` / `THREAD_UNSUSPENDED` with the thread's
#   `pthread_t`, once per thread each stop suspends and resumes
#   (`Heap#thread_event_hook`).
fun gcry_c_set_on_heap_resize = GC_set_on_heap_resize(proc : LibGC::OnHeapResizeProc) : Nil
  Gcry::CAbi.on_heap_resize = proc
end

fun gcry_c_get_on_heap_resize = GC_get_on_heap_resize : LibGC::OnHeapResizeProc
  Gcry::CAbi.on_heap_resize
end

fun gcry_c_set_on_collection_event = GC_set_on_collection_event(cb : LibGC::OnCollectionEventProc) : Nil
  Gcry::CAbi.on_collection_event = cb
end

fun gcry_c_get_on_collection_event = GC_get_on_collection_event : LibGC::OnCollectionEventProc
  Gcry::CAbi.on_collection_event
end

fun gcry_c_set_on_thread_event = GC_set_on_thread_event(cb : LibGC::OnThreadEventProc) : Nil
  Gcry::CAbi.on_thread_event = cb
end

fun gcry_c_get_on_thread_event = GC_get_on_thread_event : LibGC::OnThreadEventProc
  Gcry::CAbi.on_thread_event
end

fun gcry_c_size = GC_size(addr : Void*) : LibC::SizeT
  LibC::SizeT.new!(Gcry.usable_size(addr))
end

{% if flag?(:win32) %}
  # `GC.beginthreadex` writes the new handle into *arglist* as a Crystal
  # `Thread` — true of Crystal's own caller, not of a foreign one.
  fun gcry_c_beginthreadex = GC_beginthreadex(security : Void*, stack_size : LibC::UInt, start_address : Void* -> LibC::UInt,
                                              arglist : Void*, initflag : LibC::UInt, thrdaddr : LibC::UInt*) : Void*
    Gcry::CAbi.unsupported("GC_beginthreadex", "gcry's thread start assumes the argument is a Crystal Thread")
  end
{% elsif !flag?(:wasm32) %}
  # The new thread is staged and its argument rooted for its life
  # (`GC.pthread_create`); a non-`Thread` argument is rooted as a plain pointer.
  # On Linux and Darwin the routine runs registered, as in Boehm
  # (`Gcry::CAbi.pthread_create`); elsewhere gcry cannot register a C thread,
  # and it runs unregistered.
  fun gcry_c_pthread_create = GC_pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start : Void* -> Void*, arg : Void*) : LibC::Int
    {% if (flag?(:linux) || flag?(:darwin)) && !flag?(:android) %}
      Gcry::CAbi.pthread_create(thread, attr, start, arg)
    {% else %}
      GC.pthread_create(thread, attr, start, arg)
    {% end %}
  end

  # `GC.pthread_join`'s bookkeeping, keeping the thread's result, which
  # `GC.pthread_join` discards.
  fun gcry_c_pthread_join = GC_pthread_join(thread : LibC::PthreadT, value : Void**) : LibC::Int
    if value.null?
      GC.pthread_join(thread)
    else
      Gcry::Platform.unstage_thread(thread.unsafe_as(UInt64))
      Gcry::ThreadBirthRoot.joining(thread.unsafe_as(UInt64)) { LibC.pthread_join(thread, value) }
    end
  end

  fun gcry_c_pthread_detach = GC_pthread_detach(thread : LibC::PthreadT) : LibC::Int
    GC.pthread_detach(thread)
  end
{% end %}

# Receives Boehm's out-of-memory warning, the one Boehm warning gcry has a
# matching condition for (`Gcry::CAbi.warn_out_of_memory`). Boehm's others
# describe its own machinery — blacklisted large blocks, heap sections, the
# mark stack — which gcry does not have. gcry's own diagnostics stay on
# stderr: they are not Boehm's, and a warn procedure written for Boehm's
# format string would misread them.
fun gcry_c_set_warn_proc = GC_set_warn_proc(proc : LibGC::WarnProc) : Nil
  Gcry::CAbi.warn_proc = proc
end

fun gcry_c_stop_world_external = GC_stop_world_external : Nil
  GC.stop_world
end

fun gcry_c_start_world_external = GC_start_world_external : Nil
  GC.start_world
end

{% if flag?(:unix) %}
  fun gcry_c_get_suspend_signal = GC_get_suspend_signal : LibGC::Int
    Crystal::System::Thread.sig_suspend.value
  end

  fun gcry_c_get_thr_restart_signal = GC_get_thr_restart_signal : LibGC::Int
    Crystal::System::Thread.sig_resume.value
  end
{% else %}
  fun gcry_c_get_suspend_signal = GC_get_suspend_signal : LibGC::Int
    Gcry::CAbi.unsupported("GC_get_suspend_signal", "this platform stops threads without signals")
  end

  fun gcry_c_get_thr_restart_signal = GC_get_thr_restart_signal : LibGC::Int
    Gcry::CAbi.unsupported("GC_get_thr_restart_signal", "this platform stops threads without signals")
  end
{% end %}
