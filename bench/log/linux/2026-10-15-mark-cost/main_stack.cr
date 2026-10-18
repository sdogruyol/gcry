# Probe main: crystal-metric with the mark stack's mapped size printed at exit.
# The stack never shrinks, so that is the deepest it grew.
require "gcry"

at_exit do
  h = Gcry.default_heap
  STDERR.puts "MARKSTACK mapped=#{h.@mark_stack.@mapped_bytes} gcs=#{h.collections}"
end

require "./metric"
