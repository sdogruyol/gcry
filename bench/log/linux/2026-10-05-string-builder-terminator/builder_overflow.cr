# `String::Builder#to_s` stores the terminator one byte past its buffer.
# Stock Crystal, no gcry:
#
#   crystal run -Dgc_none builder_overflow.cr           # SIGSEGV at 116 bytes
#   crystal run -Dgc_none -Dfixed builder_overflow.cr   # every length passes
#
# Every GC allocation here ends exactly at a PROT_NONE page, so a store past
# the requested size faults instead of landing in allocator slack: Boehm adds
# a byte to each request and glibc rounds up, which is what hides the bug.
# `-Dfixed` applies `crystal-string-builder-terminator.patch`.
require "c/sys/mman"

module GC
  PAGE = 4096_u64

  def self.malloc(size : LibC::SizeT) : Void*
    guarded(size)
  end

  def self.malloc_atomic(size : LibC::SizeT) : Void*
    guarded(size)
  end

  def self.realloc(pointer : Void*, size : LibC::SizeT) : Void*
    fresh = guarded(size)
    unless pointer.null?
      old = (pointer.as(UInt64*) - 1).value
      fresh.as(UInt8*).copy_from(pointer.as(UInt8*), Math.min(old, size.to_u64))
    end
    fresh
  end

  def self.free(pointer : Void*) : Nil
  end

  # *size* bytes that end at a guard page; the size is kept in the word before.
  private def self.guarded(size) : Void*
    pages = (size.to_u64 + 8 + PAGE - 1) // PAGE
    base = LibC.mmap(nil, (pages + 1) * PAGE, LibC::PROT_READ | LibC::PROT_WRITE,
      LibC::MAP_PRIVATE | LibC::MAP_ANON, -1, 0).as(UInt8*)
    # `MAP_FAILED`, spelled out: a constant would initialise lazily, and this
    # runs before the runtime can.
    LibC._exit(70) if base.address == UInt64::MAX
    LibC.mprotect(base + pages * PAGE, PAGE, LibC::PROT_NONE)
    block = base + pages * PAGE - size.to_u64
    (block.as(UInt64*) - 1).value = size.to_u64
    block.as(Void*)
  end
end

{% if flag?(:fixed) %}
  class String::Builder
    private def increase_capacity_by(count)
      raise IO::EOFError.new if count >= Int32::MAX - real_bytesize

      # One more byte for the terminator `to_s` writes after the content.
      new_bytesize = real_bytesize + count + 1
      return if new_bytesize <= @capacity

      new_capacity = calculate_new_capacity(new_bytesize)
      resize_to_capacity(new_capacity)
    end
  end
{% end %}

# Header (12) + content filling a power of two after growth, and one either
# side; then content filling an initial `String.build(capacity)` buffer.
[115, 116, 117, 244, 500, 1012].each do |n|
  s = String.build { |io| io << "x" * n }
  puts "String.build, #{n} bytes: ok (#{s.bytesize})"
end
s = String.build(63) { |io| 64.times { io << 'y' } }
puts "String.build(63), 64 bytes: ok (#{s.bytesize})"
