require "gcry"

at_exit do
  h = Gcry.default_heap
  {% if flag?(:gcry_markprof) %}
    STDERR.puts "MP words=#{h.mp_words} objs=#{h.mp_objs} cands=#{h.mp_cands} nochunk=#{h.mp_nochunk} large=#{h.mp_large} notalloc=#{h.mp_notalloc} marked=#{h.mp_marked} new_atomic=#{h.mp_new_atomic} new_push=#{h.mp_new_push} radix_fast=#{h.radix_fast_hits} radix_slow=#{h.radix_slow_lookups} gcs=#{h.collections}"
  {% end %}
end

require "../../../crystal_metric/metric"
