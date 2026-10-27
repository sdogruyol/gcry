# Probe main: crystal-metric with mark counters printed at exit.
require "gcry"

at_exit do
  h = Gcry.default_heap
  STDERR.puts "PROBE gcs=#{h.collections} fast=#{h.radix_fast_hits} slow=#{h.radix_slow_lookups} runs=#{h.parallel_mark_runs}"
end

require "./metric"
