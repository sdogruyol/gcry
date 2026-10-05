# Allocation-free operating-system primitives used by the collector.
# POSIX keeps its native ABI; Windows implements the small subset gcry uses.
#
# Every target outside the ones below fails here, at compile time, with the
# reason, instead of building a collector that cannot work: there is no
# platform layer for the BSDs, Solaris or Android, the root scan reads 8-byte
# words, and STW captures registers only for x86_64 and aarch64. Such a
# program keeps Crystal's default collector by building without `-Dgc_none`.
{% unless flag?(:linux) || flag?(:darwin) || flag?(:win32) %}
  {% raise "gcry supports Linux, macOS and Windows only; build without -Dgc_none (and without `require \"gcry\"`) to keep Crystal's default GC on this target" %}
{% end %}
{% if flag?(:android) %}
  {% raise "gcry does not support Android: its allocation fast path relies on thread-local storage Crystal avoids there; build without -Dgc_none to keep Crystal's default GC" %}
{% end %}
{% unless flag?(:x86_64) || flag?(:aarch64) %}
  {% raise "gcry requires a 64-bit x86_64 or aarch64 target: its root scan reads 8-byte words and its stop-the-world captures registers for those two only; build without -Dgc_none to keep Crystal's default GC" %}
{% end %}
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
