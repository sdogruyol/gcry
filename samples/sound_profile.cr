# Prove the root-completeness profile survives GC.init → apply_env_config.
#
# Build: crystal build -Dgc_none samples/sound_profile.cr -o sound_profile
# Run:   ./sound_profile              # expects "tuned" (process defaults)
#        GCRY_SOUND=1 ./sound_profile # expects "sound"
#
# Exits non-zero when the observed heap state disagrees with GCRY_SOUND, so CI
# catches a knob that is added later but forgotten in apply_sound_profile.
#
# See docs/SOUND-DEFAULTS.md.

require "../src/gcry"

heap = Gcry.default_heap
want_sound = ENV["GCRY_SOUND"]? == "1"
got = Gcry.root_soundness(heap)

puts "root_soundness=#{got}"
puts "  allow_interior_pointers   = #{heap.allow_interior_pointers}"
puts "  scan_unaligned_candidates = #{heap.scan_unaligned_candidates}"
puts "  type_id_gate              = #{heap.type_id_gate}"
puts "  type_id_gate_stacks       = #{heap.type_id_gate_stacks}"
puts "  stw_multi_stack_lag       = #{heap.stw_multi_stack_lag}"
puts "  stw_multi_pthread_lag     = #{heap.stw_multi_pthread_lag}"
puts "  scrub_fibers_enabled      = #{heap.scrub_fibers_enabled}"
puts "  blacklist_enabled         = #{heap.blacklist_enabled}"
puts "  layout_precise            = #{heap.layout_precise} (separate axis)"

# Exercise the collector in whichever mode we booted into — the profile must
# not just be reported, it must survive a real collect.
1000.times { |i| ("x" * (i % 97 + 1)).bytesize }
GC.collect
puts "collections=#{heap.collections} live_objects=#{heap.live_objects}"

# An explicit knob must still override the profile: apply_sound_profile runs
# first, individual GCRY_* run after. Checked before the label assert because
# a successful override necessarily demotes the label back to "tuned".
if ENV["GCRY_SCRUB_FIBERS"]? == "1"
  unless heap.scrub_fibers_enabled
    STDERR.puts "FAIL: GCRY_SCRUB_FIBERS=1 did not override GCRY_SOUND"
    exit 1
  end
  puts "ok (scrub override honoured)"
  exit 0
end

expected = want_sound ? "sound" : "tuned"
if got != expected
  STDERR.puts "FAIL: GCRY_SOUND=#{want_sound} but root_soundness=#{got} (expected #{expected})"
  exit 1
end

puts "ok"
