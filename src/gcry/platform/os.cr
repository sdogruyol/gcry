# Allocation-free operating-system primitives used by the collector.
# POSIX keeps its native ABI; Windows implements the small subset gcry uses.
{% if flag?(:win32) %}
  {% unless flag?(:x86_64) || flag?(:aarch64) %}
    {% raise "gcry Windows support requires x86_64 or aarch64" %}
  {% end %}
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
