# Probe main for every arm of this log: crystal-metric with the parallel
# mark's counters and the mark stack's mapped size printed at exit, so one
# build per arm gives both the timings and the steal shares. The hook runs
# after the bench's own timer stops.
require "gcry"

at_exit do
  h = Gcry.default_heap
  STDERR.puts "PROBE workers=#{h.parallel_mark_workers} runs=#{h.parallel_mark_runs} " \
              "stolen=#{h.parallel_mark_stolen} wakes=#{h.parallel_mark_wakes} " \
              "markstack=#{h.@mark_stack.@mapped_bytes} gcs=#{h.collections}"
end

require "./metric"
