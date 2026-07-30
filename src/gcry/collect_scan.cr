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

    # Mark Thread objects and their current_fiber (TLS alone is not scanned).
    private def scan_thread_roots : Nil
      Thread.unsafe_each do |thread|
        mark_root_candidate(Pointer(Void).new(thread.object_id), source: RootSource::Thread)
        # Parallel EC can briefly have nil current_fiber while a worker OS
        # thread is between fibers / during shutdown — skip rather than raise.
        fiber = thread.@current_fiber
        next unless fiber
        mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Thread)
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
        # Running fiber: @context.stack_top is stale (last yield). Full scan.
        # Parked fiber: clamp reported top below the guard page.
        top = if fiber.running?
                guard
              else
                t = fiber.@context.stack_top.address
                t < guard ? guard : t
              end
        Roots.scan_range(Pointer(Void).new(top), stack.bottom, safe: true) do |candidate|
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

        if fiber.nil?
          # Between fibers / shutdown: scan the OS thread stack if we can.
          if pthread_bounds
            low = pthread_bounds[0]
            high = pthread_bounds[1]
            if sp && sp.address >= low.address && sp.address < high.address
              low = sp
              @sp_clamp_hits += 1
            else
              @sp_clamp_fallbacks += 1
            end
            Roots.scan_range(low, high, safe: true) do |candidate|
              mark_root_candidate(candidate, source: RootSource::Thread)
            end
          end
          next
        end

        # Boehm sets per-thread stackbottom to fiber.@stack.bottom so the OS
        # thread scan covers the *fiber* stack. Every Thread main fiber is
        # named "main" and lives on the pthread stack — but under Parallel EC
        # current_fiber is usually a pool fiber. Always scan the fiber stack;
        # also scan the pthread stack when SP lies there (scheduler / main).
        mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Thread)
        stack = fiber.@stack
        guard = stack.pointer.address + Roots::PAGE_SIZE
        bottom = stack.bottom
        if guard < bottom.address
          if fiber.running?
            # Full scan: @context.stack_top is stale while running.
            @sp_clamp_fallbacks += 1
            Roots.scan_range(Pointer(Void).new(guard), bottom, safe: true) do |candidate|
              mark_root_candidate(candidate, source: RootSource::Thread)
            end
          else
            top = fiber.@context.stack_top.address
            top = guard if top < guard
            if top < bottom.address
              Roots.scan_range(Pointer(Void).new(top), bottom, safe: true) do |candidate|
                mark_root_candidate(candidate, source: RootSource::Thread)
              end
            end
          end
        end

        if pthread_bounds && sp
          plo = pthread_bounds[0].address
          phi = pthread_bounds[1].address
          spa = sp.address
          on_pthread = spa >= plo && spa < phi
          on_fiber = spa >= stack.pointer.address && spa < bottom.address
          if on_pthread && !on_fiber
            @sp_clamp_hits += 1
            Roots.scan_range(sp, pthread_bounds[1], safe: true) do |candidate|
              mark_root_candidate(candidate, source: RootSource::Thread)
            end
          end
        end
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
