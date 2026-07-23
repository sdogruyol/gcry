# Reopens Crystal's `GC` module under `-Dgc_none`, forwarding to Gcry.
# Same integration pattern as ysbaddaden/gc (immix).

{% if flag?(:linux) && flag?(:gnu) %}
  lib LibC
    $__libc_stack_end : Void*
  end
{% end %}

module GC
  @@gcry_ready = false
  @@gcry_enabled = true

  def self.init : Nil
    Crystal::System::Thread.init_suspend_resume

    # Build the heap while still on LibC malloc (@@gcry_ready == false).
    heap = Gcry.default_heap
    heap.scan_static_roots = true
    heap.nursery_threshold = Gcry::Heap::DEFAULT_NURSERY_THRESHOLD
    # Avoid mid-boot collections until env config runs.
    heap.gc_threshold = UInt64::MAX

    {% if flag?(:linux) && flag?(:gnu) %}
      heap.set_stackbottom(LibC.__libc_stack_end)
    {% end %}

    # Suspended fibers: push their stacks before marking (Boehm / immix pattern).
    heap.before_collect do
      Fiber.unsafe_each do |fiber|
        fiber.push_gc_roots unless fiber.running?
      end
    end

    @@gcry_ready = true
    apply_env_config(heap)
  end

  # Use LibC.getenv — Crystal's ENV uses `once` + Fiber, unavailable in GC.init.
  private def self.apply_env_config(heap : Gcry::Heap) : Nil
    if flag = LibC.getenv("GCRY_DISABLE_AUTO")
      unless flag.null?
        if flag.value == '1'.ord.to_u8 && (flag + 1).value == 0
          heap.gc_threshold = UInt64::MAX
          return
        end
      end
    end

    if thr = LibC.getenv("GCRY_THRESHOLD")
      unless thr.null?
        value = parse_u64_cstr(thr)
        heap.gc_threshold = value unless value == 0
        return
      end
    end

    heap.gc_threshold = Gcry::Heap::DEFAULT_GC_THRESHOLD
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
    if @@gcry_ready
      Gcry.default_heap.malloc(size)
    else
      bootstrap_malloc(size, clear: true)
    end
  end

  # :nodoc:
  def self.malloc_atomic(size : LibC::SizeT) : Void*
    if @@gcry_ready
      Gcry.default_heap.malloc_atomic(size)
    else
      bootstrap_malloc(size, clear: false)
    end
  end

  # :nodoc:
  def self.realloc(pointer : Void*, size : LibC::SizeT) : Void*
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
        unmapped_bytes: 0_u64,
        bytes_since_gc: h.bytes_since_gc,
        total_bytes: h.total_bytes,
      )
    else
      Stats.new(0, 0, 0, 0, 0)
    end
  end

  def self.prof_stats
    ProfStats.new(
      heap_size: stats.heap_size,
      free_bytes: stats.free_bytes,
      unmapped_bytes: 0_u64,
      bytes_since_gc: stats.bytes_since_gc,
      bytes_before_gc: 0_u64,
      non_gc_bytes: 0_u64,
      gc_no: @@gcry_ready ? Gcry.default_heap.collections : 0_u64,
      markers_m1: 0_u64,
      bytes_reclaimed_since_gc: 0_u64,
      reclaimed_bytes_before_gc: 0_u64,
      expl_freed_bytes_since_gc: 0_u64,
      obtained_from_os_bytes: @@gcry_ready ? Gcry.default_heap.heap_size : 0_u64,
    )
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
  {% if flag?(:preview_mt) %}
    def self.set_stackbottom(thread : Thread, stack_bottom : Void*)
      Gcry.default_heap.set_stackbottom(stack_bottom) if @@gcry_ready
    end

    # :nodoc:
    def self.set_stackbottom(thread_handle : Void*, stack_bottom : Void*)
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
