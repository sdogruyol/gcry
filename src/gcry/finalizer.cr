module Gcry
  # Finalizers and disappearing links (WeakRef support).
  #
  # Metadata lives on the Heap Crystal object (must stay immortal when gcry is
  # the process GC). Callbacks may allocate after collection finishes.
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

    class Registry
      @entries = [] of Entry
      @pending = [] of Entry
      @links = [] of Link

      def clear : Nil
        @entries.clear
        @pending.clear
        @links.clear
      end

      def add(object : Void*, callback : Callback) : Nil
        return if object.null?
        @entries << Entry.new(object, callback)
      end

      def register_disappearing_link(link : Void**, object : Void*) : Nil
        return if link.null? || object.null?
        @links << Link.new(link, object)
      end

      # Called while reclaiming *object* (still before the block is reused).
      def on_reclaim(object : Void*) : Nil
        return if object.null?

        # Queue matching finalizers.
        kept = [] of Entry
        @entries.each do |entry|
          if entry.object == object
            @pending << entry
          else
            kept << entry
          end
        end
        @entries = kept

        # Clear weak links that watched this object.
        @links.reject! do |link|
          if link.object == object
            link.link.value = Pointer(Void).null
            true
          else
            false
          end
        end
      end

      def run_pending : Nil
        pending = @pending
        @pending = [] of Entry
        pending.each do |entry|
          entry.callback.call(entry.object)
        end
      end

      def pending_count : Int32
        @pending.size
      end

      def entry_count : Int32
        @entries.size
      end

      def link_count : Int32
        @links.size
      end
    end
  end
end
