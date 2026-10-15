# Probe main: crystal-metric with the radix-tag shadow check's counts at exit.
require "gcry"

at_exit do
  h = Gcry.default_heap
  STDERR.puts "SHADOW checks=#{h.shadow_checks} bad=#{h.shadow_bad} gcs=#{h.collections}"
end

require "./metric"
