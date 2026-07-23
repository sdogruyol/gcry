require "./block"

module Gcry
  # Growable mark stack backed by mmap (not the managed heap).
  class MarkStack
    INITIAL_BYTES = 65536_u64 # 64 KiB

    @base : Void* = Pointer(Void).null
    @capacity : Int32 = 0
    @size : Int32 = 0
    @mapped_bytes : UInt64 = 0

    def initialize
      grow(INITIAL_BYTES)
    end

    def finalize
      destroy
    end

    def destroy : Nil
      return if @base.null?
      LibC.munmap(@base, LibC::SizeT.new(@mapped_bytes))
      @base = Pointer(Void).null
      @capacity = 0
      @size = 0
      @mapped_bytes = 0
    end

    def clear : Nil
      @size = 0
    end

    def empty? : Bool
      @size == 0
    end

    def push(header : BlockHeader*) : Nil
      if @size >= @capacity
        grow(@mapped_bytes * 2)
      end
      entries[@size] = header.as(Void*)
      @size += 1
    end

    def pop : BlockHeader*
      raise "mark stack underflow" if @size == 0
      @size -= 1
      entries[@size].as(BlockHeader*)
    end

    private def entries : Void**
      @base.as(Void**)
    end

    private def grow(bytes : UInt64) : Nil
      ptr = LibC.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(bytes),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS,
        -1,
        0
      )
      raise OutOfMemoryError.new("mark stack mmap failed") if Gcry.mmap_failed?(ptr)

      new_capacity = (bytes // sizeof(Void*)).to_i32
      unless @base.null?
        @base.as(Void**).copy_to(ptr.as(Void**), @size)
        LibC.munmap(@base, LibC::SizeT.new(@mapped_bytes))
      end

      @base = ptr
      @mapped_bytes = bytes
      @capacity = new_capacity
    end
  end
end
