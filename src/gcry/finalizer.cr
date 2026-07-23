module Gcry
  # Finalizers and disappearing links (WeakRef support).
  #
  # Long-lived entries stay in Crystal Arrays (reachable from Heap → marked).
  # After mark, `enqueue_unreachable` walks the registry once (O(finalizers)),
  # not once per reclaimed heap object (that was O(reclaimed × finalizers) and
  # multi-second under HTTP + WeakRef). Pending work is LibC-queued and drained
  # after collect (nested auto-collect suppressed).
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
      @entries = [] of Entry
      @links = [] of Link
      @pending : PendingNode* = Pointer(PendingNode).null
      @pending_count = 0

      def clear : Nil
        @entries.clear
        @links.clear
        free_pending
      end

      def add(object : Void*, callback : Callback) : Nil
        return if object.null?
        @entries << Entry.new(object, callback)
      end

      def register_disappearing_link(link : Void**, object : Void*) : Nil
        return if link.null? || object.null?
        @links << Link.new(link, object)
      end

      # After mark, before sweep: O(entries + links). *is_dead* is true when the
      # referent is an unmarked (still-mapped) heap object.
      def enqueue_unreachable(&is_dead : Void* -> Bool) : Nil
        return if @entries.empty? && @links.empty?

        i = 0
        while i < @entries.size
          entry = @entries[i]
          if is_dead.call(entry.object)
            queue_pending(entry)
            swap_remove_entry(i)
          else
            i += 1
          end
        end

        i = 0
        while i < @links.size
          link = @links[i]
          if is_dead.call(link.object)
            link.link.value = Pointer(Void).null
            swap_remove_link(i)
          else
            i += 1
          end
        end
      end

      # Explicit free path (rare): drop registry rows for one object.
      def notice_reclaim(object : Void*) : Nil
        return if object.null?
        return if @entries.empty? && @links.empty?

        i = 0
        while i < @entries.size
          if @entries[i].object == object
            queue_pending(@entries[i])
            swap_remove_entry(i)
          else
            i += 1
          end
        end

        i = 0
        while i < @links.size
          if @links[i].object == object
            @links[i].link.value = Pointer(Void).null
            swap_remove_link(i)
          else
            i += 1
          end
        end
      end

      def run_pending : Nil
        node = @pending
        @pending = Pointer(PendingNode).null
        @pending_count = 0
        while node
          nxt = node.value.next
          callback = node.value.callback
          object = node.value.object
          LibC.free(node.as(Void*))
          callback.call(object)
          node = nxt
        end
      end

      def pending_count : Int32
        @pending_count
      end

      def entry_count : Int32
        @entries.size
      end

      def link_count : Int32
        @links.size
      end

      # Heap metadata (Registry/Array) may live on LibC bootstrap malloc while
      # Array buffers sit on the gcry heap. Pin those buffers (and finalizer
      # Proc closures) so empty-chunk munmap cannot reclaim them.
      # Do **not** mark entry/link `object` fields — those must stay collectible.
      def each_mark_root(& : Void* ->) : Nil
        unless @entries.empty?
          yield @entries.to_unsafe.as(Void*)
          @entries.each do |entry|
            data = entry.callback.closure_data
            yield data unless data.null?
          end
        end
        yield @links.to_unsafe.as(Void*) unless @links.empty?
      end

      private def swap_remove_entry(i : Int32) : Nil
        last = @entries.size - 1
        @entries.swap(i, last) if i != last
        @entries.pop
      end

      private def swap_remove_link(i : Int32) : Nil
        last = @links.size - 1
        @links.swap(i, last) if i != last
        @links.pop
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
