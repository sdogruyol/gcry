# Thread-local allocation buffers (TLAB): each mutator OS thread takes a private
# freelist head per size-class so parallel ExecutionContexts can allocate without
# racing on the global freelist. Chunk refill still serializes on @alloc_lock.
#
# Fields (@alloc_lock, @tlab_enabled, …) are declared/initialized in heap.cr.

require "c/pthread"

module Gcry
  class Heap
    MAX_TLABS = 64

    struct Tlab
      property freelists : StaticArray(Void*, SIZE_CLASS_COUNT)
      property nursery_freelists : StaticArray(Void*, SIZE_CLASS_COUNT)
      property owner : UInt64
      property live : Bool

      def initialize
        @freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
        @nursery_freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
        @owner = 0_u64
        @live = false
      end
    end

    @tlabs = uninitialized StaticArray(Tlab, MAX_TLABS)

    def tlab_enabled? : Bool
      @tlab_enabled
    end

    def tlab_enabled=(value : Bool) : Bool
      @tlab_enabled = value
    end

    def tlab_refills : UInt64
      @tlab_refills
    end

    def tlab_steals : UInt64
      @tlab_steals
    end

    protected def ensure_tlabs : Nil
      return if @tlabs_booted
      MAX_TLABS.times do |i|
        @tlabs[i] = Tlab.new
      end
      @tlabs_booted = true
    end

    protected def with_alloc_lock(&)
      if @tlab_enabled
        @alloc_lock.sync { yield }
      else
        yield
      end
    end

    private def current_thread_key : UInt64
      {% if flag?(:win32) || flag?(:wasm32) %}
        1_u64
      {% else %}
        LibC.pthread_self.to_u64!
      {% end %}
    end

    protected def current_tlab : Tlab*
      ensure_tlabs
      key = current_thread_key
      i = 0
      while i < MAX_TLABS
        if @tlabs[i].live && @tlabs[i].owner == key
          return @tlabs.to_unsafe + i
        end
        i += 1
      end
      @alloc_lock.sync { current_tlab_under_lock(key) }
    end

    # Caller must hold @alloc_lock (or be single-threaded).
    protected def current_tlab_under_lock(key : UInt64 = current_thread_key) : Tlab*
      ensure_tlabs
      i = 0
      while i < MAX_TLABS
        if @tlabs[i].live && @tlabs[i].owner == key
          return @tlabs.to_unsafe + i
        end
        i += 1
      end
      i = 0
      while i < MAX_TLABS
        unless @tlabs[i].live
          @tlabs[i].owner = key
          @tlabs[i].live = true
          return @tlabs.to_unsafe + i
        end
        i += 1
      end
      @tlabs.to_unsafe
    end

    # Steal a batch from the global freelist into the calling thread's TLAB.
    protected def tlab_refill(class_index : Int32, payload : UInt32, nursery : Bool) : Void*
      head = Pointer(Void).null
      @alloc_lock.sync do
        if nursery
          if @nursery_freelists[class_index].null?
            refill_size_class(class_index, payload, nursery: true)
          end
        else
          if @freelists[class_index].null?
            refill_size_class(class_index, payload, nursery: false)
          end
        end

        src = nursery ? @nursery_freelists[class_index] : @freelists[class_index]
        unless src.null?
          head = src
          tail = src
          count = 1
          while count < 32
            h = BlockHeader.from_user(tail)
            nxt = h.value.next_free
            break if nxt.null?
            tail = nxt
            count += 1
          end
          last = BlockHeader.from_user(tail)
          rest = last.value.next_free
          lv = last.value
          lv.next_free = Pointer(Void).null
          last.value = lv
          if nursery
            @nursery_freelists[class_index] = rest
          else
            @freelists[class_index] = rest
          end

          tlab = current_tlab_under_lock
          if nursery
            tlab.value.nursery_freelists[class_index] = head
          else
            tlab.value.freelists[class_index] = head
          end
          @tlab_refills += 1
          @tlab_steals += count.to_u64
        end
      end
      head
    end

    protected def tlab_alloc_small(payload : UInt32, flags : UInt32, class_index : Int32, nursery : Bool) : Void*
      tlab = current_tlab
      user = if nursery
               tlab.value.nursery_freelists[class_index]
             else
               tlab.value.freelists[class_index]
             end

      if user.null?
        user = tlab_refill(class_index, payload, nursery)
        raise OutOfMemoryError.new("failed to refill TLAB size class #{payload}") if user.null?
      end

      header = BlockHeader.from_user(user)
      next_free = header.value.next_free
      if nursery
        tlab.value.nursery_freelists[class_index] = next_free
      else
        tlab.value.freelists[class_index] = next_free
      end
      BlockHeader.set_used(header, payload, flags)
      BlockHeader.set_mark(header) if @incremental_marking || @collecting

      with_alloc_lock do
        @free_bytes -= payload if @free_bytes >= payload
        @nursery_alloc_bytes += payload.to_u64 if nursery
      end
      user
    end

    # Return a small object to the current thread's TLAB (no global lock).
    protected def tlab_free_small(pointer : Void*, class_index : Int32, payload : UInt32, nursery : Bool) : Nil
      tlab = current_tlab
      header = BlockHeader.from_user(pointer)
      if nursery
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, tlab.value.nursery_freelists[class_index])
        tlab.value.nursery_freelists[class_index] = pointer
      else
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, tlab.value.freelists[class_index])
        tlab.value.freelists[class_index] = pointer
      end
      with_alloc_lock do
        @free_bytes += payload.to_u64
      end
    end

    # Flush TLAB freelists back to global (call under STW / before sweep / destroy).
    protected def flush_all_tlabs : Nil
      return unless @tlabs_booted && @tlab_enabled
      MAX_TLABS.times do |i|
        next unless @tlabs[i].live
        SIZE_CLASS_COUNT.times do |c|
          head = @tlabs[i].freelists[c]
          unless head.null?
            tail = head
            loop do
              h = BlockHeader.from_user(tail)
              nxt = h.value.next_free
              break if nxt.null?
              tail = nxt
            end
            th = BlockHeader.from_user(tail)
            tv = th.value
            tv.next_free = @freelists[c]
            th.value = tv
            @freelists[c] = head
            @tlabs[i].freelists[c] = Pointer(Void).null
          end

          head = @tlabs[i].nursery_freelists[c]
          unless head.null?
            tail = head
            loop do
              h = BlockHeader.from_user(tail)
              nxt = h.value.next_free
              break if nxt.null?
              tail = nxt
            end
            th = BlockHeader.from_user(tail)
            tv = th.value
            tv.next_free = @nursery_freelists[c]
            th.value = tv
            @nursery_freelists[c] = head
            @tlabs[i].nursery_freelists[c] = Pointer(Void).null
          end
        end
      end
    end
  end
end
