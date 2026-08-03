module Gcry
  # Finalizers and disappearing links (WeakRef support).
  #
  # Entry/link tables live in LibC malloc — NOT on the gcry heap. If they were
  # Crystal Arrays, marking the Heap → Registry → Array buffer would keep every
  # finalizable object alive forever (acik: ~1500 TCPSocket + OpenSSL::Digest
  # + 32 KiB IO buffers; finalizers never ran). Boehm-style: registry is
  # invisible to the marker for Entry.object; after mark we enqueue unmarked
  # finalizables, resurrect them through sweep, then run_pending. Callback
  # closure_data is marked explicitly in collect.
  module Finalizers
    alias Callback = Void* -> Nil

    struct Entry
      property object : Void*
      property callback : Callback

      def initialize(@object : Void*, @callback : Callback)
      end
    end

    struct Link
      property link : Void**
      property object : Void*

      def initialize(@link : Void**, @object : Void*)
      end
    end

    struct PendingNode
      property next : PendingNode*
      property object : Void*
      property callback : Callback

      def initialize(@object : Void*, @callback : Callback, @next : PendingNode* = Pointer(PendingNode).null)
      end
    end

    class Registry
      @entries : Entry* = Pointer(Entry).null
      @entries_size = 0
      @entries_cap = 0
      @links : Link* = Pointer(Link).null
      @links_size = 0
      @links_cap = 0
      @pending : PendingNode* = Pointer(PendingNode).null
      @pending_count = 0
      # LibC table mutate vs MT allocators (preview_mt / EC).
      @lock = Crystal::SpinLock.new

      def clear : Nil
        @lock.lock
        begin
          LibC.free(@entries.as(Void*)) unless @entries.null?
          LibC.free(@links.as(Void*)) unless @links.null?
          @entries = Pointer(Entry).null
          @links = Pointer(Link).null
          @entries_size = 0
          @entries_cap = 0
          @links_size = 0
          @links_cap = 0
          free_pending
        ensure
          @lock.unlock
        end
      end

      def add(object : Void*, callback : Callback) : Nil
        return if object.null?
        @lock.lock
        begin
          ensure_entries_cap(@entries_size + 1)
          @entries[@entries_size] = Entry.new(object, callback)
          @entries_size += 1
        ensure
          @lock.unlock
        end
      end

      def register_disappearing_link(link : Void**, object : Void*) : Nil
        return if link.null? || object.null?
        @lock.lock
        begin
          ensure_links_cap(@links_size + 1)
          @links[@links_size] = Link.new(link, object)
          @links_size += 1
        ensure
          @lock.unlock
        end
      end

      def entry_count : Int32
        @entries_size
      end

      def link_count : Int32
        @links_size
      end

      def entry_object_at(i : Int32) : Void*
        @entries[i].object
      end

      def link_object_at(i : Int32) : Void*
        @links[i].object
      end

      # Queue finalizer at *i* and swap-remove (does not allocate on GC heap).
      # STW collect only — mutators quiesced via lock_for_stw (see collect_stw).
      def queue_and_remove_entry_at(i : Int32) : Nil
        queue_pending(@entries[i])
        swap_remove_entry(i)
      end

      # Clear disappearing link at *i* and swap-remove. STW collect only.
      def clear_and_remove_link_at(i : Int32) : Nil
        @links[i].link.value = Pointer(Void).null
        swap_remove_link(i)
      end

      # Held across stop_world so no mutator is frozen mid-add/notice_reclaim.
      def lock_for_stw : Nil
        @lock.lock
      end

      def unlock_for_stw : Nil
        @lock.unlock
      end

      # Explicit free path: drop registry rows for one object.
      # Common realloc/free of ordinary objects must not scan thousands of
      # unrelated finalizer entries (perf: ~15%+ CPU on HTTP apps).
      def notice_reclaim(object : Void*) : Nil
        return if object.null?
        @lock.lock
        begin
          return if @entries_size == 0 && @links_size == 0

          header = BlockHeader.from_user(object)
          flags = header.value.flags
          scan_entries = @entries_size > 0 && (flags & BlockHeader::Flags::FINALIZER) != 0
          scan_links = @links_size > 0 && (flags & BlockHeader::Flags::DISAPPEARING) != 0
          return unless scan_entries || scan_links

          if scan_entries
            i = 0
            while i < @entries_size
              if @entries[i].object == object
                queue_pending(@entries[i])
                swap_remove_entry(i)
              else
                i += 1
              end
            end
          end

          if scan_links
            i = 0
            while i < @links_size
              if @links[i].object == object
                @links[i].link.value = Pointer(Void).null
                swap_remove_link(i)
              else
                i += 1
              end
            end
          end
        ensure
          @lock.unlock
        end
      end

      def run_pending : Nil
        @lock.lock
        node = @pending
        @pending = Pointer(PendingNode).null
        @pending_count = 0
        @lock.unlock
        # Callbacks outside the lock (may re-enter add / allocate).
        while node
          nxt = node.value.next
          callback = node.value.callback
          object = node.value.object
          LibC.free(node.as(Void*))
          Trace.finalizer("run", object)
          callback.call(object)
          node = nxt
        end
      end

      def pending_count : Int32
        @pending_count
      end

      def entry_closure_data_at(i : Int32) : Void*
        @entries[i].callback.closure_data
      end

      # LibC storage — not a GC object; kept for API compat / diagnostics.
      def entries_buffer : Void*
        @entries.as(Void*)
      end

      def links_buffer : Void*
        @links.as(Void*)
      end

      private def ensure_entries_cap(need : Int32) : Nil
        return if need <= @entries_cap
        new_cap = @entries_cap == 0 ? 16 : @entries_cap * 2
        new_cap = need if new_cap < need
        bytes = (new_cap * sizeof(Entry)).to_u64
        ptr = if @entries.null?
                LibC.malloc(LibC::SizeT.new(bytes))
              else
                LibC.realloc(@entries.as(Void*), LibC::SizeT.new(bytes))
              end
        raise OutOfMemoryError.new("finalizer entries realloc failed") if ptr.null?
        @entries = ptr.as(Entry*)
        @entries_cap = new_cap
      end

      private def ensure_links_cap(need : Int32) : Nil
        return if need <= @links_cap
        new_cap = @links_cap == 0 ? 16 : @links_cap * 2
        new_cap = need if new_cap < need
        bytes = (new_cap * sizeof(Link)).to_u64
        ptr = if @links.null?
                LibC.malloc(LibC::SizeT.new(bytes))
              else
                LibC.realloc(@links.as(Void*), LibC::SizeT.new(bytes))
              end
        raise OutOfMemoryError.new("finalizer links realloc failed") if ptr.null?
        @links = ptr.as(Link*)
        @links_cap = new_cap
      end

      private def swap_remove_entry(i : Int32) : Nil
        last = @entries_size - 1
        @entries[i] = @entries[last] if i != last
        @entries_size = last
      end

      private def swap_remove_link(i : Int32) : Nil
        last = @links_size - 1
        @links[i] = @links[last] if i != last
        @links_size = last
      end

      private def queue_pending(entry : Entry) : Nil
        node = LibC.malloc(sizeof(PendingNode)).as(PendingNode*)
        raise OutOfMemoryError.new("finalizer pending malloc failed") if node.null?
        node.value = PendingNode.new(entry.object, entry.callback, @pending)
        @pending = node
        @pending_count += 1
      end

      private def free_pending : Nil
        node = @pending
        @pending = Pointer(PendingNode).null
        @pending_count = 0
        while node
          nxt = node.value.next
          LibC.free(node.as(Void*))
          node = nxt
        end
      end
    end
  end
end
