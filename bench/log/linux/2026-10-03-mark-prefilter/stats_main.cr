{% if flag?(:gc_none) %}
  require "gcry"
  at_exit do
    m = Gcry.metrics
    STDERR.puts "GCSTATS collections=#{m.collections} majors=#{m.major_collections} pause_total_ms=#{m.pause_total_ns // 1_000_000} pause_max_ms=#{m.pause_max_ns // 1_000_000} mark_ms_last=#{m.phase_mark_ns // 1_000_000} heap_mib=#{m.heap_size >> 20} live_mib=#{m.size_class_live_bytes >> 20}"
  end
{% end %}
require "./metric"
