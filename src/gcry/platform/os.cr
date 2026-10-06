# Allocation-free operating-system primitives used by the collector.
# POSIX keeps its native ABI; Windows implements the small subset gcry uses.
#
# Every target outside the ones below fails here, at compile time, with the
# reason, instead of building a collector that cannot work. The refusal holds
# for the library heap (`require "gcry"` without `-Dgc_none`) too, because the
# reasons are not the process GC's alone: there is no platform layer for the
# BSDs or Solaris, the bitmap allocator's per-thread cursor is a
# `@[ThreadLocal]`, which Crystal avoids on Android, and the mark reads every
# payload and root range as 8-byte words (`scan_payload`, `Roots.scan_range`
# step a `UInt64*` `size // sizeof(Void*)` times), so on a 32-bit target it
# would read twice each block's size and miss every 4-byte pointer that does
# not share its 8-byte word with a zero. Master compiled an i386 library heap
# (`crystal build --cross-compile --target i386-linux-gnu`, 2026-10-06); it
# would have been that one.
#
# The remedy depends on how gcry came in. As the process GC the program has
# to drop both `-Dgc_none` and the `require`: either alone leaves no working
# collector. As a library there is nothing to fall back to inside gcry, so the
# require has to go; the process GC was never gcry's and is unaffected.
{%
  reason = nil
  if !(flag?(:linux) || flag?(:darwin) || flag?(:win32))
    reason = "gcry supports Linux, macOS and Windows only"
  elsif flag?(:android)
    reason = "gcry does not support Android: its allocator keeps a per-thread cursor in thread-local storage, which Crystal avoids there"
  elsif !(flag?(:x86_64) || flag?(:aarch64))
    reason = "gcry requires a 64-bit x86_64 or aarch64 target: its mark reads 8-byte words and its stop-the-world captures registers for those two only"
  end
  if reason
    if flag?(:gc_none)
      raise "#{reason.id}; build without -Dgc_none and without `require \"gcry\"` to keep Crystal's default GC on this target"
    else
      raise "#{reason.id}; its library heap cannot run on this target either, so remove `require \"gcry\"` when building for it (Crystal's default GC is unaffected)"
    end
  end
%}
{% if flag?(:win32) %}
  require "./windows_os"
{% else %}
  require "c/sys/mman"
  require "c/pthread"
  require "c/unistd"
  require "c/fcntl"

  module Gcry
    alias OS = LibC
  end
{% end %}

module Gcry::Platform
  def self.current_thread_id : UInt64
    {% if flag?(:win32) %}
      LibC.GetCurrentThreadId.to_u64
    {% else %}
      LibC.pthread_self.unsafe_as(UInt64)
    {% end %}
  end
end
