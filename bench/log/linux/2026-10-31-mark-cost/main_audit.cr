# Audit main: crystal-metric with the mark audit's counters printed at exit
# (run with GCRY_MARK_AUDIT=1; the audit walks every marked block's payload
# after the mark and counts edges into used but unmarked blocks).
require "gcry"

at_exit do
  h = Gcry.default_heap
  STDERR.puts "AUDIT gcs=#{h.collections} edges=#{h.mark_audit_edges} misses=#{h.mark_audit_misses} pm_runs=#{h.parallel_mark_runs}"
end

require "./metric"
