# Reopens Crystal's `GC` module under `-Dgc_none`, forwarding to Gcry.

{% if flag?(:linux) && flag?(:gnu) %}
  lib LibC
    $__libc_stack_end : Void*
  end
{% end %}

module GC
  @@gcry_ready = false
  @@gcry_enabled = true
  # Set via GC.note_fork_child; malloc/collect refuse to run (no atfork reinit yet).
  @@after_fork_child = false

  def self.init : Nil
    Crystal::System::Thread.init_suspend_resume

    # Build the heap while still on LibC malloc (@@gcry_ready == false).
    heap = Gcry.default_heap
    heap.scan_static_roots = true
    # Process GC: majors only by default. Nursery without write barriers must
    # scan all old objects each minor — that dominates pause time under HTTP.
    heap.nursery_enabled = false
    heap.nursery_threshold = UInt64::MAX
    # Full STW majors by default (v0.4+). Incremental without write barriers is
    # unsound under heavy pointer mutation (e.g. Kemal /json).
    heap.incremental_auto = false
    # Empty-chunk munmap stays opt-in: default-on regresses Kemal wrk ~35–40%.
    # GCRY_RELEASE_CHUNKS=1 enables; finalizer buffer pinning (unreleased) makes it safe.
    heap.release_empty_chunks = false
    # Avoid mid-boot collections until env config runs.
    heap.gc_threshold = UInt64::MAX

    {% if flag?(:linux) && flag?(:gnu) %}
      heap.set_stackbottom(LibC.__libc_stack_end)
    {% end %}

    # Suspended fibers: push their stacks before marking (Boehm-compatible hooks).
    # Crystal 1.21+ defaults to Fiber::ExecutionContext, which does not call
    # GC.set_stackbottom on fiber swap — refresh from Fiber.current here.
    heap.before_collect do
      Fiber.unsafe_each do |fiber|
        fiber.push_gc_roots unless fiber.running?
      end
      heap.set_stackbottom(Fiber.current.@stack.bottom)
    end

    @@gcry_ready = true
    apply_env_config(heap)
  end

  # Skeleton: refuse GC in a forked child. Full Boehm-style reinit is future work.
  # :nodoc:
  def self.note_fork_child : Nil
    @@after_fork_child = true
  end

  private def self.check_fork_poison! : Nil
    if @@after_fork_child
      raise "gcry: GC after fork is unsupported (exec or stay on Boehm); see docs/POLICY.md"
    end
  end

  # Use LibC.getenv — Crystal's ENV uses `once` + Fiber, unavailable in GC.init.
  private def self.apply_env_config(heap : Gcry::Heap) : Nil
    if env_flag_one?("GCRY_DISABLE_AUTO")
      heap.gc_threshold = UInt64::MAX
    elsif thr = env_u64("GCRY_THRESHOLD")
      heap.gc_threshold = thr unless thr == 0
    else
      heap.gc_threshold = Gcry::Heap::PROCESS_GC_THRESHOLD
    end

    if env_flag_one?("GCRY_DISABLE_NURSERY")
      heap.nursery_enabled = false
      heap.nursery_threshold = UInt64::MAX
    elsif nursery = env_u64("GCRY_NURSERY")
      # Opt-in: nursery without barriers is expensive (old→young full scan).
      heap.nursery_enabled = true
      heap.nursery_threshold = nursery unless nursery == 0
      heap.nursery_threshold = Gcry::Heap::DEFAULT_NURSERY_THRESHOLD if heap.nursery_threshold == UInt64::MAX
    end

    if env_flag_one?("GCRY_INCREMENTAL")
      # Experimental: sliced majors. Unsafe without write barriers if the mutator
      # stores pointers into already-scanned objects (typical JSON/Hash workloads).
      heap.incremental_auto = true
    end

    if env_flag_one?("GCRY_DISABLE_INCREMENTAL")
      heap.incremental_auto = false
    end

    if work = env_u64("GCRY_INCREMENTAL_WORK")
      heap.incremental_work = work.to_i32 if work > 0 && work <= Int32::MAX
    end

    # Empty-chunk release remains opt-in (default-on hurts Kemal throughput).
    # GCRY_RELEASE_CHUNKS=1 enables; GCRY_KEEP_CHUNKS=1 forces off.
    if env_flag_one?("GCRY_KEEP_CHUNKS")
      heap.release_empty_chunks = false
    elsif env_flag_one?("GCRY_RELEASE_CHUNKS")
      heap.release_empty_chunks = true
    end
  end

  private def self.env_flag_one?(name : String) : Bool
    flag = LibC.getenv(name)
    return false if flag.null?
    flag.value == '1'.ord.to_u8 && (flag + 1).value == 0
  end

  private def self.env_u64(name : String) : UInt64?
    ptr = LibC.getenv(name)
    return nil if ptr.null?
    parse_u64_cstr(ptr)
  end

  private def self.parse_u64_cstr(ptr : UInt8*) : UInt64
    value = 0_u64
    while (c = ptr.value) != 0
      break if c < '0'.ord.to_u8 || c > '9'.ord.to_u8
      value = value * 10_u64 + (c - '0'.ord.to_u8).to_u64
      ptr += 1
    end
    value
  end

  # :nodoc:
  def self.malloc(size : LibC::SizeT) : Void*
    check_fork_poison!
    if @@gcry_ready
      Gcry.default_heap.malloc(size)
    else
      bootstrap_malloc(size, clear: true)
    end
  end

  # :nodoc:
  def self.malloc_atomic(size : LibC::SizeT) : Void*
    check_fork_poison!
    if @@gcry_ready
      Gcry.default_heap.malloc_atomic(size)
    else
      bootstrap_malloc(size, clear: false)
    end
  end

  # :nodoc:
  def self.realloc(pointer : Void*, size : LibC::SizeT) : Void*
    check_fork_poison!
    if @@gcry_ready
      # Pointers from the LibC bootstrap era are not on the gcry heap.
      if !pointer.null? && !Gcry.default_heap.is_heap_ptr(pointer)
        return bootstrap_realloc(pointer, size)
      end
      Gcry.default_heap.realloc(pointer, size)
    else
      bootstrap_realloc(pointer, size)
    end
  end

  def self.collect
    return unless @@gcry_ready
    check_fork_poison!
    Gcry.default_heap.collect
  end

  def self.collect_a_little : Int
    return 0 unless @@gcry_ready
    Gcry.default_heap.collect_a_little ? 1 : 0
  end

  def self.enable
    raise "GC is not disabled" unless !@@gcry_enabled
    @@gcry_enabled = true
    Gcry.default_heap.enable if @@gcry_ready
  end

  def self.disable
    @@gcry_enabled = false
    Gcry.default_heap.disable if @@gcry_ready
  end

  def self.free(pointer : Void*) : Nil
    return if pointer.null?
    if @@gcry_ready && Gcry.default_heap.is_heap_ptr(pointer)
      Gcry.default_heap.free(pointer)
    else
      LibC.free(pointer)
    end
  end

  def self.is_heap_ptr(pointer : Void*) : Bool
    return false unless @@gcry_ready
    Gcry.default_heap.is_heap_ptr(pointer)
  end

  def self.add_finalizer(object : Reference) : Nil
    add_finalizer_impl(object)
  end

  def self.add_finalizer(object)
  end

  private def self.add_finalizer_impl(object : T) forall T
    return unless @@gcry_ready
    Gcry.default_heap.add_finalizer(object.as(Void*)) do |ptr|
      ptr.as(T).finalize
    end
  end

  def self.add_root(object : Reference)
    return unless @@gcry_ready
    Gcry.default_heap.add_root(Pointer(Void).new(object.object_id))
  end

  def self.register_disappearing_link(pointer : Void**)
    return unless @@gcry_ready
    Gcry.default_heap.register_disappearing_link(pointer)
  end

  def self.stats : GC::Stats
    if @@gcry_ready
      h = Gcry.default_heap
      Stats.new(
        heap_size: h.heap_size,
        free_bytes: h.free_bytes,
        unmapped_bytes: h.unmapped_bytes,
        bytes_since_gc: h.bytes_since_gc,
        total_bytes: h.total_bytes,
      )
    else
      Stats.new(0, 0, 0, 0, 0)
    end
  end

  def self.prof_stats
    if @@gcry_ready
      h = Gcry.default_heap
      ProfStats.new(
        heap_size: h.heap_size,
        free_bytes: h.free_bytes,
        unmapped_bytes: h.unmapped_bytes,
        bytes_since_gc: h.bytes_since_gc,
        bytes_before_gc: h.bytes_before_gc,
        non_gc_bytes: 0_u64,
        gc_no: h.collections,
        markers_m1: 0_u64,
        bytes_reclaimed_since_gc: h.bytes_reclaimed_since_gc,
        reclaimed_bytes_before_gc: h.reclaimed_bytes_before_gc,
        expl_freed_bytes_since_gc: h.expl_freed_bytes_since_gc,
        obtained_from_os_bytes: h.heap_size + h.unmapped_bytes,
      )
    else
      ProfStats.new(
        heap_size: 0_u64,
        free_bytes: 0_u64,
        unmapped_bytes: 0_u64,
        bytes_since_gc: 0_u64,
        bytes_before_gc: 0_u64,
        non_gc_bytes: 0_u64,
        gc_no: 0_u64,
        markers_m1: 0_u64,
        bytes_reclaimed_since_gc: 0_u64,
        reclaimed_bytes_before_gc: 0_u64,
        expl_freed_bytes_since_gc: 0_u64,
        obtained_from_os_bytes: 0_u64,
      )
    end
  end

  {% if flag?(:win32) %}
    # :nodoc:
    def self.beginthreadex(security : Void*, stack_size : LibC::UInt, start_address : Void* -> LibC::UInt, arglist : Void*, initflag : LibC::UInt, thrdaddr : LibC::UInt*) : LibC::HANDLE
      ret = LibC._beginthreadex(security, stack_size, start_address, arglist, initflag, thrdaddr)
      raise RuntimeError.from_errno("_beginthreadex") if ret.null?
      ret.as(LibC::HANDLE)
    end
  {% elsif !flag?(:wasm32) %}
    # :nodoc:
    def self.pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start : Void* -> Void*, arg : Void*)
      LibC.pthread_create(thread, attr, start, arg)
    end

    # :nodoc:
    def self.pthread_join(thread : LibC::PthreadT)
      LibC.pthread_join(thread, nil)
    end

    # :nodoc:
    def self.pthread_detach(thread : LibC::PthreadT)
      LibC.pthread_detach(thread)
    end
  {% end %}

  # :nodoc:
  def self.current_thread_stack_bottom : {Void*, Void*}
    if @@gcry_ready
      Gcry.default_heap.current_thread_stack_bottom
    else
      {Pointer(Void).null, Pointer(Void).null}
    end
  end

  # :nodoc:
  # Crystal 1.21+: default is ExecutionContext (`!without_mt`). Only the legacy
  # `-Dwithout_mt` scheduler uses the single-argument form. ExecutionContext
  # itself does not call this on fiber swap — see `before_collect` above.
  {% if !flag?(:without_mt) %}
    def self.set_stackbottom(thread : Thread, stack_bottom : Void*)
      Gcry.default_heap.set_stackbottom(stack_bottom) if @@gcry_ready
    end
  {% else %}
    def self.set_stackbottom(stack_bottom : Void*)
      Gcry.default_heap.set_stackbottom(stack_bottom) if @@gcry_ready
    end
  {% end %}
  # :nodoc:
  def self.lock_read
    Gcry.default_heap.lock_read if @@gcry_ready
  end

  # :nodoc:
  def self.unlock_read
    Gcry.default_heap.unlock_read if @@gcry_ready
  end

  # :nodoc:
  def self.lock_write
    Gcry.default_heap.lock_write if @@gcry_ready
  end

  # :nodoc:
  def self.unlock_write
    Gcry.default_heap.unlock_write if @@gcry_ready
  end

  # :nodoc:
  def self.push_stack(stack_top, stack_bottom) : Nil
    return unless @@gcry_ready
    Gcry.default_heap.push_stack(stack_top, stack_bottom)
  end

  # :nodoc:
  def self.before_collect(&block) : Nil
    Gcry.default_heap.before_collect(&block)
  end

  # :nodoc:
  # Parallel ExecutionContext STW is not implemented yet (v0.4 skeleton).
  # Under parallelism 1 these remain no-ops — same as Crystal's gc/none.
  def self.stop_world : Nil
    Gcry.default_heap.stop_world if @@gcry_ready
  end

  # :nodoc:
  def self.start_world : Nil
    Gcry.default_heap.start_world if @@gcry_ready
  end

  private def self.bootstrap_malloc(size : LibC::SizeT, clear : Bool) : Void*
    ptr = LibC.malloc(size)
    raise Gcry::OutOfMemoryError.new("bootstrap malloc failed") if ptr.null?
    ptr.as(UInt8*).clear(size) if clear
    ptr
  end

  private def self.bootstrap_realloc(pointer : Void*, size : LibC::SizeT) : Void*
    ptr = LibC.realloc(pointer, size)
    raise Gcry::OutOfMemoryError.new("bootstrap realloc failed") if ptr.null? && size != 0
    ptr
  end
end
