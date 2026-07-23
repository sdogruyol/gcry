module Gcry
  # Finalizers and disappearing links (WeakRef support).
  #
  # Long-lived entries stay in Crystal Arrays (reachable from Heap → marked).
  # After mark, Heap walks the registry once via index APIs (no Crystal Proc —
  # allocating a closure mid-collect re-enters malloc and crashes).
  # Pending work is LibC-queued and drained after collect.
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

      def entry_count : Int32
        @entries.size
      end

      def link_count : Int32
        @links.size
      end

      def entry_object_at(i : Int32) : Void*
        @entries[i].object
      end

      def link_object_at(i : Int32) : Void*
        @links[i].object
      end

      # Queue finalizer at *i* and swap-remove (does not allocate on GC heap).
      def queue_and_remove_entry_at(i : Int32) : Nil
        queue_pending(@entries[i])
        swap_remove_entry(i)
      end

      # Clear disappearing link at *i* and swap-remove.
      def clear_and_remove_link_at(i : Int32) : Nil
        @links[i].link.value = Pointer(Void).null
        swap_remove_link(i)
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

      def entry_closure_data_at(i : Int32) : Void*
        @entries[i].callback.closure_data
      end

      def entries_buffer : Void*
        @entries.to_unsafe.as(Void*)
      end

      def links_buffer : Void*
        @links.to_unsafe.as(Void*)
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
