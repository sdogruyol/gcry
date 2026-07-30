# Root scanning: stacks, fibers, threads, static ranges, metadata.

module Gcry
  class Heap
    def push_stack(stack_top : Void*, stack_bottom : Void*) : Nil
      raise "push_stack outside of collect" unless @collecting
      # stack_top may sit on the PROT_NONE guard; cheap safe skips leading
      # unreadable pages then bulk-scans (see Roots.scan_range_safe).
      Roots.scan_range(stack_top, stack_bottom, safe: true) do |candidate|
        mark_root_candidate(candidate, source: RootSource::Stack)
      end
    end

    # Module-typed Reference ivars (Scheduler, ExecutionContext) cannot
    # `.as(Reference)` / `unsafe_as(Reference)` yet — load the pointer bits.
    private def mark_ref_slot(slot_addr : UInt64) : Nil
      bits = Pointer(UInt64).new(slot_addr).value
      return if bits == 0
      mark_root_candidate(Pointer(Void).new(bits), source: RootSource::Thread)
    end

    # Mark Thread objects and Parallel EC roots (TLS alone is not scanned).
    private def scan_thread_roots : Nil
      Thread.unsafe_each do |thread|
        mark_root_candidate(Pointer(Void).new(thread.object_id), source: RootSource::Thread)
        # Parallel EC can briefly have nil current_fiber while a worker OS
        # thread is between fibers / during shutdown — skip rather than raise.
        if fiber = thread.@current_fiber
          mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Thread)
        end
        if main = thread.@main_fiber
          mark_root_candidate(Pointer(Void).new(main.object_id), source: RootSource::Thread)
        end
        # Scheduler + ExecutionContext hold run queues / event-loop state. Relying
        # only on conservative Thread body scan missed them when layout/scan_cap
        # truncated the object (Kemal EC4 SEGV @ …0008).
        mark_ref_slot(pointerof(thread.@scheduler).address)
        mark_ref_slot(pointerof(thread.@execution_context).address)
      end

      # Global EC list (not thread-local) — keeps contexts that temporarily have
      # no worker with them pinned via Thread.@execution_context.
      Fiber::ExecutionContext.unsafe_each do |ec|
        mark_ref_slot(pointerof(ec).address)
        # Parallel: also pin queues / event loop / schedulers explicitly. Body
        # scan alone still left residual EC4 SEGV @ …0008 under release Kemal.
        if ec.is_a?(Fiber::ExecutionContext::Parallel)
          mark_root_candidate(Pointer(Void).new(ec.@global_queue.object_id), source: RootSource::Thread)
          mark_root_candidate(Pointer(Void).new(ec.@event_loop.object_id), source: RootSource::Thread)
          mark_root_candidate(Pointer(Void).new(ec.@stack_pool.object_id), source: RootSource::Thread)
          mark_root_candidate(Pointer(Void).new(ec.@schedulers.object_id), source: RootSource::Thread)
          ec.@schedulers.each do |sched|
            mark_root_candidate(Pointer(Void).new(sched.object_id), source: RootSource::Thread)
            mark_root_candidate(Pointer(Void).new(sched.@runnables.object_id), source: RootSource::Thread)
            mark_root_candidate(Pointer(Void).new(sched.@main_fiber.object_id), source: RootSource::Thread)
          end
        end
      end
    end

    # Spill GP registers, then scan approx SP→bottom for the running fiber.
    private def scan_mutator_stack : Nil
      bottom = Fiber.current.@stack.bottom
      @stack_bottom = bottom
      Roots.scan_mutator(bottom) do |candidate|
        mark_root_candidate(candidate, source: RootSource::Stack)
      end
    end

    private def scan_all_fiber_roots : Nil
      current = Fiber.current
      Fiber.unsafe_each do |fiber|
        mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Stack)
        next if fiber == current

        # Without STW we must not touch another thread's live stack. With process
        # STW every other OS thread is frozen — scan running fibers here too.
        # Relying only on thread.@current_fiber missed stacks when that TLS was
        # briefly nil under Parallel EC (Kemal realloc "not a gcry allocation";
        # GCRY_KEEP_CHUNKS masked the subsequent empty-chunk munmap).
        if fiber.running? && !@world_stopped
          next
        end

        stack = fiber.@stack
        guard = stack.pointer.address + Roots::PAGE_SIZE
        bottom = stack.bottom.address
        next unless guard < bottom

        # Process STW: always full-scan. Parked `stack_top` and mid-swap
        # (current_fiber flipped before SP save) both under-scanned under
        # Parallel EC (Kemal EC4 SEGV). Library heaps keep the stack_top clamp.
        top = if @world_stopped || fiber.running?
                guard
              else
                t = fiber.@context.stack_top.address
                t < guard ? guard : t
              end
        next unless top < bottom

        Roots.scan_range(Pointer(Void).new(top), Pointer(Void).new(bottom), safe: true) do |candidate|
          mark_root_candidate(candidate, source: RootSource::Stack)
        end
      end
    end

    private def scan_other_thread_stacks : Nil
      return unless @stop_the_world

      current = Thread.current
      Thread.unsafe_each do |thread|
        next if thread == current
        pthread = thread.to_unsafe
        fiber = thread.@current_fiber

        # Always spill GP registers at suspend — may hold the only live copy.
        Platform.each_thread_greg(pthread) do |candidate|
          mark_root_candidate(candidate, source: RootSource::Thread)
        end

        sp = Platform.thread_sp(pthread)
        pthread_bounds = Platform.pthread_stack_bounds(pthread)

        if fiber
          mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Thread)
          scan_fiber_stack(fiber)
        end

        # Mid-swap: Scheduler sets current_fiber to the *next* fiber before
        # swapcontext saves the previous SP. If we only trust current_fiber +
        # stack_top, live frames below a stale top (still holding SP) are
        # swept → Kemal EC>1 SEGV @ 0x4. Always scan the stack that contains
        # the suspend SP (red zone included).
        scan_stack_containing_sp(sp)

        # Pthread mapping: scheduler/main frames remain here while SP sits on
        # a pool fiber (Boehm tracks per-thread stackbottom through swaps).
        scan_pthread_stack(pthread_bounds, sp)
      end
    end

    private def scan_fiber_stack(fiber : Fiber) : Nil
      stack = fiber.@stack
      guard = stack.pointer.address + Roots::PAGE_SIZE
      bottom = stack.bottom
      return unless guard < bottom.address

      # Always full-scan under process STW (caller). stack_top is stale for
      # running fibers and can lag mid-swap for "parked" ones.
      @sp_clamp_fallbacks += 1
      Roots.scan_range(Pointer(Void).new(guard), bottom, safe: true) do |candidate|
        mark_root_candidate(candidate, source: RootSource::Thread)
      end
    end

    # Scan [SP−red_zone, bottom) of whichever fiber stack holds *sp*.
    private def scan_stack_containing_sp(sp : Void*?) : Nil
      return unless sp

      spa = sp.address
      Fiber.unsafe_each do |fiber|
        stack = fiber.@stack
        base = stack.pointer.address
        bottom = stack.bottom.address
        next unless spa >= base && spa < bottom

        guard = base + Roots::PAGE_SIZE
        next unless guard < bottom

        low = stack_scan_low(spa, guard)
        @sp_clamp_hits += 1
        Roots.scan_range(Pointer(Void).new(low), Pointer(Void).new(bottom), safe: true) do |candidate|
          mark_root_candidate(candidate, source: RootSource::Thread)
        end
        return
      end
    end

    # SysV x86_64 red zone: callees may store below SP without adjusting it.
    {% if flag?(:x86_64) %}
      STACK_SCAN_RED_ZONE = 128_u64
    {% else %}
      STACK_SCAN_RED_ZONE = 0_u64
    {% end %}

    private def stack_scan_low(sp_addr : UInt64, floor : UInt64) : UInt64
      low = sp_addr > STACK_SCAN_RED_ZONE ? sp_addr - STACK_SCAN_RED_ZONE : 0_u64
      low < floor ? floor : low
    end

    # Scan [low, high) of the OS thread stack. When SP is inside the mapping,
    # clamp to SP−red_zone (still covers live frames). When SP is on a fiber
    # stack, scan the full pthread mapping — Parallel workers leave scheduler
    # frames there after switching onto a pool fiber.
    private def scan_pthread_stack(pthread_bounds : {Void*, Void*}?, sp : Void*?) : Nil
      return unless pthread_bounds

      low = pthread_bounds[0].address
      high = pthread_bounds[1].address
      return unless low < high

      if sp
        spa = sp.address
        if spa >= low && spa < high
          low = stack_scan_low(spa, low)
          @sp_clamp_hits += 1
        else
          @sp_clamp_fallbacks += 1
        end
      else
        @sp_clamp_fallbacks += 1
      end

      Roots.scan_range(Pointer(Void).new(low), Pointer(Void).new(high), safe: true) do |candidate|
        mark_root_candidate(candidate, source: RootSource::Thread)
      end
    end

    private def mark_metadata_roots : Nil
      # No Crystal Proc/closure — allocating mid-mark re-enters malloc.
      n = @finalizers.entry_count
      if n > 0
        mark_candidate(@finalizers.entries_buffer)
        i = 0
        while i < n
          data = @finalizers.entry_closure_data_at(i)
          mark_candidate(data) unless data.null?
          i += 1
        end
      end
      if @finalizers.link_count > 0
        mark_candidate(@finalizers.links_buffer)
      end
    end

    # Emit [low, high) minus each mapped heap chunk via sorted chunk index merge.
    private def each_static_range_excluding_heap(low : Void*, high : Void*, & : Void*, Void* ->) : Nil
      ensure_chunk_index
      lo = low.address
      hi = high.address
      return if hi <= lo

      cursor = lo
      i = 0
      n = @chunk_index_count
      while i < n && cursor < hi
        chunk = (@chunk_index + i).value
        c_lo = chunk.address
        c_hi = c_lo + chunk.value.mapped_bytes

        if c_hi <= cursor
          i += 1
          next
        end
        break if c_lo >= hi

        if c_lo > cursor
          gap_hi = c_lo < hi ? c_lo : hi
          yield Pointer(Void).new(cursor), Pointer(Void).new(gap_hi)
        end

        cursor = c_hi if c_hi > cursor
        i += 1
      end

      if cursor < hi
        yield Pointer(Void).new(cursor), Pointer(Void).new(hi)
      end
    end
  end
end
