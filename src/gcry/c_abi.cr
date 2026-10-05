# Boehm's C entry points (`GC_*`), defined by every `-Dgc_none` gcry program,
# and stdlib's `lib LibGC` binding to them.
#
# Who calls them: code compiled against stdlib's `gc/boehm.cr` running inside
# a gcry process. That is the interpreter first of all — `crystal i` interprets
# the program with the Boehm prelude and resolves its `LibGC` calls from the
# compiler binary itself (`compiler/crystal/interpreter/context.cr`,
# `load_current_program_handle`) — and any shard or C library that binds
# `GC_*` itself (readiness M8; Crystal's own `spec/std` calls `LibGC.size`).
#
# The declarations are `gc/boehm.cr`'s, type for type: Crystal rejects a `fun`
# definition whose signature differs from a `lib` declaration of the same
# symbol, so a binding copied from stdlib compiles against these only if they
# match it. (`GC_get_prof_stats` therefore returns nothing, as stdlib declares
# it, where Boehm's C returns the bytes written.)
#
# Each function either does what Boehm documents, on gcry's heap, or — where
# gcry has no equivalent and pretending would change the caller's program —
# prints what is missing and aborts (`Gcry::CAbi.unsupported`). Boehm's three
# exported *variables* (`GC_gc_no`, `GC_bytes_found`, `GC_current_warn_proc`)
# cannot be defined from Crystal and are not declared: using them is a compile
# error rather than a wrong answer.
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
  fun enable = GC_enable
  fun disable = GC_disable
  fun is_disabled = GC_is_disabled : Int
  fun set_handle_fork = GC_set_handle_fork(value : Int)

  fun base = GC_base(displaced_pointer : Void*) : Void*
  fun is_heap_ptr = GC_is_heap_ptr(pointer : Void*) : Int
  fun general_register_disappearing_link = GC_general_register_disappearing_link(link : Void**, obj : Void*) : Int

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
end

module Gcry
  # :nodoc:
  module CAbi
    @@push_other_roots : Proc(Nil)? = nil
    @@start_callback : Proc(Nil)? = nil
    @@warn_proc : LibGC::WarnProc? = nil
    @@roots_hooked = false

    # `GC_add_roots` ranges: an immutable `[count, lo0, hi0, lo1, hi1, ...]`
    # array of words in libc memory, replaced whole on every add. A mutator
    # stopped half-way through `add_roots` must not leave the collector reading
    # a torn table, and a lock the stopped thread might hold cannot be taken
    # inside the stop — so the collector reads whichever table was last
    # published, complete. A replaced table is not freed: the hook may be
    # reading it, and `add_roots` is a once-per-library call (Boehm caps the
    # count at a few thousand).
    @@ranges = Atomic(UInt64*).new(Pointer(UInt64).null)

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

    # Boehm *replaces* an object's finalizer, and a null *fn* removes it;
    # gcry's table only adds. Replacing or removing therefore aborts rather
    # than leaving two finalizers, or one the caller believes is gone. A
    # pointer that is not the start of a live gcry block is ignored, as Boehm
    # ignores one outside its heap. Both of Boehm's entry points register
    # through `Heap#add_finalizer`, the path `GC.add_finalizer` takes.
    def self.register_finalizer(name : String, object : Void*, fn : LibGC::Finalizer, data : Void*,
                                old_fn : LibGC::Finalizer*, old_data : Void**) : Nil
      # Never a previous finalizer to report: a second registration aborts.
      # The slot is a C function pointer, one word, not a Crystal `Proc`.
      old_fn.as(Void**).value = Pointer(Void).null unless old_fn.null?
      old_data.value = Pointer(Void).null unless old_data.null?
      heap = Gcry.default_heap?
      return unless heap
      found = heap.find_object_with_chunk(object)
      return unless found
      header, chunk = found
      return unless heap.user_of(chunk, header) == object
      if BlockHeader.finalizer?(header)
        unsupported(name, "the object already has a finalizer, and gcry cannot replace or remove one")
      end
      return if fn.pointer.null?
      heap.add_finalizer(object, ->(o : Void*) { fn.call(o, data) })
    end

    def self.add_roots(low : Void*, high : Void*) : Nil
      return unless low.address < high.address
      old = @@ranges.get(:acquire)
      count = old.null? ? 0_u64 : old[0]
      fresh = LibC.malloc(LibC::SizeT.new((2 &* (count &+ 1) &+ 1) &* 8)).as(UInt64*)
      unsupported("GC_add_roots", "out of memory for the root table") if fresh.null?
      fresh[0] = count &+ 1
      (old + 1).copy_to(fresh + 1, 2 &* count) unless old.null?
      fresh[1 &+ 2 &* count] = low.address
      fresh[2 &+ 2 &* count] = high.address
      # Publish only a complete table (see `@@ranges`).
      @@ranges.set(fresh, :release)
      hook_roots
    end

    def self.push_other_roots=(proc : Proc(Nil)) : Nil
      @@push_other_roots = proc.pointer.null? ? nil : proc
      hook_roots
    end

    # Never a null procedure: stdlib's `GC.before_collect` chains to whatever
    # this returned and calls it unconditionally.
    def self.push_other_roots : Proc(Nil)
      @@push_other_roots || -> { }
    end

    def self.start_callback=(proc : Proc(Nil)) : Nil
      @@start_callback = proc.pointer.null? ? nil : proc
    end

    def self.start_callback : Void*
      @@start_callback.try(&.pointer) || Pointer(Void).null
    end

    def self.warn_proc=(proc : LibGC::WarnProc) : Nil
      @@warn_proc = proc
    end

    # One `before_collect` hook serves both root sources; it runs in the root
    # phase of every collection, world stopped, where `push_stack` is valid —
    # which is where Boehm calls its push-other-roots procedure too.
    private def self.hook_roots : Nil
      return if @@roots_hooked
      @@roots_hooked = true
      GC.before_collect do
        ranges = @@ranges.get(:acquire)
        unless ranges.null?
          i = 0_u64
          n = ranges[0]
          while i < n
            Gcry.default_heap.push_stack(Pointer(Void).new(ranges[1 &+ 2 &* i]), Pointer(Void).new(ranges[2 &+ 2 &* i]))
            i &+= 1
          end
        end
        @@push_other_roots.try &.call
      end
    end
  end
end

# The process GC is initialised by Crystal's `main` before any code that could
# call this runs; Boehm's own `GC_init` is likewise idempotent.
fun gcry_c_init = GC_init : Nil
end

fun gcry_c_malloc = GC_malloc(size : LibGC::SizeT) : Void*
  GC.malloc(size)
end

fun gcry_c_malloc_atomic = GC_malloc_atomic(size : LibGC::SizeT) : Void*
  GC.malloc_atomic(size)
end

fun gcry_c_realloc = GC_realloc(ptr : Void*, size : LibGC::SizeT) : Void*
  GC.realloc(ptr, size)
end

fun gcry_c_free = GC_free(ptr : Void*) : Nil
  GC.free(ptr)
end

fun gcry_c_collect_a_little = GC_collect_a_little : LibGC::Int
  GC.collect_a_little
end

fun gcry_c_gcollect = GC_gcollect : Nil
  GC.collect
end

fun gcry_c_add_roots = GC_add_roots(low : Void*, high : Void*) : Nil
  Gcry::CAbi.add_roots(low, high)
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

# 0 is `GC_SUCCESS`. gcry has no duplicate (`GC_DUPLICATE`) report: a second
# registration of the same link clears it once, like the first.
fun gcry_c_general_register_disappearing_link = GC_general_register_disappearing_link(link : Void**, obj : Void*) : LibGC::Int
  Gcry.default_heap.register_disappearing_link(link, obj)
  0
end

fun gcry_c_register_finalizer = GC_register_finalizer(obj : Void*, fn : LibGC::Finalizer, cd : Void*,
                                                      ofn : LibGC::Finalizer*, ocd : Void**) : Nil
  Gcry::CAbi.register_finalizer("GC_register_finalizer", obj, fn, cd, ofn, ocd)
end

fun gcry_c_register_finalizer_ignore_self = GC_register_finalizer_ignore_self(obj : Void*, fn : LibGC::Finalizer, cd : Void*,
                                                                              ofn : LibGC::Finalizer*, ocd : Void**) : Nil
  Gcry::CAbi.register_finalizer("GC_register_finalizer_ignore_self", obj, fn, cd, ofn, ocd)
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

# Recorded, never called. Its one stdlib registrant (`gc/boehm.cr` `GC.init`)
# installs `GC.lock_write`, which pairs with the `GC.unlock_write` its
# `before_collect` does — fiber-swap exclusion that gcry's own stop provides.
# Calling it would mean running the registrant's code inside the collector
# (in `crystal i`, the interpreter), where allocating deadlocks.
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
  Gcry.default_heap?.try &.set_stackbottom(sb.value.mem_base)
  th
end

# Boehm's event hooks feed `-Dtracing` (`CRYSTAL_TRACE=gc`). gcry emits no
# Boehm events, and a caller that sets one would wait for events that never
# come; clearing one is fine.
fun gcry_c_set_on_heap_resize = GC_set_on_heap_resize(proc : LibGC::OnHeapResizeProc) : Nil
  Gcry::CAbi.unsupported("GC_set_on_heap_resize", "gcry emits no Boehm heap-resize events") unless proc.pointer.null?
end

fun gcry_c_get_on_heap_resize = GC_get_on_heap_resize : LibGC::OnHeapResizeProc
  LibGC::OnHeapResizeProc.new(Pointer(Void).null, Pointer(Void).null)
end

fun gcry_c_set_on_collection_event = GC_set_on_collection_event(cb : LibGC::OnCollectionEventProc) : Nil
  Gcry::CAbi.unsupported("GC_set_on_collection_event", "gcry emits no Boehm collection events") unless cb.pointer.null?
end

fun gcry_c_get_on_collection_event = GC_get_on_collection_event : LibGC::OnCollectionEventProc
  LibGC::OnCollectionEventProc.new(Pointer(Void).null, Pointer(Void).null)
end

fun gcry_c_set_on_thread_event = GC_set_on_thread_event(cb : LibGC::OnThreadEventProc) : Nil
  Gcry::CAbi.unsupported("GC_set_on_thread_event", "gcry emits no Boehm thread events") unless cb.pointer.null?
end

fun gcry_c_get_on_thread_event = GC_get_on_thread_event : LibGC::OnThreadEventProc
  LibGC::OnThreadEventProc.new(Pointer(Void).null, Pointer(Void).null)
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
  # The new thread is staged and its argument rooted until it publishes itself
  # (`GC.pthread_create`); a non-`Thread` argument is rooted as a plain pointer.
  fun gcry_c_pthread_create = GC_pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start : Void* -> Void*, arg : Void*) : LibC::Int
    GC.pthread_create(thread, attr, start, arg)
  end

  # `GC.pthread_join`'s bookkeeping, keeping the thread's result, which
  # `GC.pthread_join` discards.
  fun gcry_c_pthread_join = GC_pthread_join(thread : LibC::PthreadT, value : Void**) : LibC::Int
    if value.null?
      GC.pthread_join(thread)
    else
      Gcry::Platform.unstage_on_death(thread.unsafe_as(UInt64))
      Gcry::ThreadBirthRoot.note_death(thread.unsafe_as(UInt64))
      LibC.pthread_join(thread, value)
    end
  end

  fun gcry_c_pthread_detach = GC_pthread_detach(thread : LibC::PthreadT) : LibC::Int
    GC.pthread_detach(thread)
  end
{% end %}

# Recorded, never called: gcry has no Boehm warnings to report.
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
