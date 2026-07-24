# Root scanning: stacks, fibers, threads, static ranges, metadata.

module Gcry
  class Heap
    def push_stack(stack_top : Void*, stack_bottom : Void*) : Nil
      raise "push_stack outside of collect" unless @collecting
      # stack_top may sit on the PROT_NONE guard; cheap safe skips leading
      # unreadable pages then bulk-scans (see Roots.scan_range_safe).
      Roots.scan_range(stack_top, stack_bottom, safe: true) do |candidate|
        mark_root_candidate(candidate)
      end
    end

    # Mark Thread objects and their current_fiber (TLS alone is not scanned).
    private def scan_thread_roots : Nil
      Thread.unsafe_each do |thread|
        mark_root_candidate(Pointer(Void).new(thread.object_id))
        mark_root_candidate(Pointer(Void).new(thread.current_fiber.object_id))
      end
    end

    # Spill GP registers, then scan approx SP→bottom for the running fiber.
    private def scan_mutator_stack : Nil
      bottom = Fiber.current.@stack.bottom
      @stack_bottom = bottom
      Roots.scan_mutator(bottom) do |candidate|
        mark_root_candidate(candidate)
      end
    end

    private def scan_all_fiber_roots : Nil
      current = Fiber.current
      Fiber.unsafe_each do |fiber|
        mark_root_candidate(Pointer(Void).new(fiber.object_id))
        next if fiber == current
        next if fiber.running?
        # Clamp below guard page (PROT_NONE); stack_top can sit there after overflow.
        # safe:true: reported ranges can still contain holes on some kernels.
        stack = fiber.@stack
        top = fiber.@context.stack_top.address
        guard = stack.pointer.address + Roots::PAGE_SIZE
        top = guard if top < guard
        Roots.scan_range(Pointer(Void).new(top), stack.bottom, safe: true) do |candidate|
          mark_root_candidate(candidate)
        end
      end
    end

    private def scan_other_thread_stacks : Nil
      return unless @stop_the_world

      current = Thread.current
      Thread.unsafe_each do |thread|
        next if thread == current
        fiber = thread.current_fiber
        stack = fiber.@stack
        pthread = thread.to_unsafe

        if fiber.name == "main"
          if bounds = Platform.pthread_stack_bounds(pthread)
            low = bounds[0]
            high = bounds[1]
            if (sp = Platform.thread_sp(pthread)) &&
               sp.address >= low.address && sp.address < high.address
              low = sp
              @sp_clamp_hits += 1
            else
              @sp_clamp_fallbacks += 1
            end
            Roots.scan_range(low, high, safe: true) do |candidate|
              mark_root_candidate(candidate)
            end
            next
          end
        end

        # Skip PROT_NONE guard; prefer saved stack_top (used portion) when it
        # sits above the guard — full 8 MiB scans kill STW under many fibers.
        # If suspend SP falls inside this fiber stack, clamp further.
        guard = stack.pointer.address + Roots::PAGE_SIZE
        top = fiber.@context.stack_top.address
        top = guard if top < guard
        if (sp = Platform.thread_sp(pthread)) &&
           sp.address >= stack.pointer.address && sp.address < stack.bottom.address
          top = sp.address if sp.address > top
          @sp_clamp_hits += 1
        end
        low = Pointer(Void).new(top)
        next if low.address >= stack.bottom.address
        Roots.scan_range(low, stack.bottom, safe: true) do |candidate|
          mark_root_candidate(candidate)
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
