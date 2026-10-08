require "gcry"

at_exit do
  h = Gcry.default_heap
  STDERR.puts "SHADOW checks=#{h.shadow_checks} bad=#{h.shadow_bad} radix_fast=#{h.radix_fast_hits} gcs=#{h.collections}"
end

require "../../../crystal_metric/metric"
