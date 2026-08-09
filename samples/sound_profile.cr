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
got = Gcry.soundness(heap)

puts "soundness=#{got} (roots=#{Gcry.root_soundness(heap)} barriers=#{Gcry.barrier_soundness(heap)})"
puts "  allow_interior_pointers   = #{heap.allow_interior_pointers}"
puts "  scan_unaligned_candidates = #{heap.scan_unaligned_candidates}"
puts "  scan_static_roots         = #{heap.scan_static_roots}"
puts "  type_id_gate              = #{heap.type_id_gate}"
puts "  type_id_gate_stacks       = #{heap.type_id_gate_stacks}"
puts "  stw_multi_stack_lag       = #{heap.stw_multi_stack_lag}"
puts "  stw_multi_pthread_lag     = #{heap.stw_multi_pthread_lag}"
puts "  scrub_fibers_enabled      = #{heap.scrub_fibers_enabled}"
puts "  blacklist_enabled         = #{heap.blacklist_enabled}"
puts "  nursery_enabled           = #{heap.nursery_enabled}"
puts "  incremental_auto          = #{heap.incremental_auto}"
puts "  layout_precise            = #{heap.layout_precise} (separate axis)"

# Exercise the collector in whichever mode we booted into — the profile must
# not just be reported, it must survive a real collect.
1000.times { |i| ("x" * (i % 97 + 1)).bytesize }
GC.collect
puts "collections=#{heap.collections} live_objects=#{heap.live_objects}"

# An explicit knob must still override the profile: apply_sound_profile runs
# first, individual GCRY_* run after. Checked before the label assert because
# a successful override necessarily demotes the label.
if ENV["GCRY_SCRUB_FIBERS"]? == "1"
  unless heap.scrub_fibers_enabled
    STDERR.puts "FAIL: GCRY_SCRUB_FIBERS=1 did not override GCRY_SOUND"
    exit 1
  end
  puts "ok (scrub override honoured)"
  exit 0
end

# The parked-fiber scrub is opt-in, and nothing else here would notice if that
# regressed: it is *off* under GCRY_SOUND too, so flipping the process default
# back on still leaves the default run reading "tuned" and this sample green.
# Assert the default itself. Only when no knob asked for it — GCRY_SCRUB_FIBERS=1
# already returned above, and GCRY_DISABLE_SCRUB_FIBERS=1 agrees with the default.
if ENV["GCRY_SCRUB_FIBERS"]?.nil? && heap.scrub_fibers_enabled
  STDERR.puts "FAIL: scrub_fibers_enabled is on by default — it is opt-in " \
              "(GCRY_SCRUB_FIBERS=1). See docs/SOUND-DEFAULTS.md."
  exit 1
end

# Barrier axis: sound roots plus a page-dirty barrier must NOT read as "sound".
# Only meaningful together with GCRY_SOUND — without it the roots axis already
# reads tuned and the aggregate says so.
if want_sound && ENV["GCRY_NURSERY"]?
  unless got == "sound-roots-only"
    STDERR.puts "FAIL: GCRY_NURSERY set but soundness=#{got} (expected sound-roots-only)"
    exit 1
  end
  puts "ok (nursery demotes the label)"
  exit 0
end

expected = want_sound ? "sound" : "tuned"
if got != expected
  STDERR.puts "FAIL: GCRY_SOUND=#{want_sound} but soundness=#{got} (expected #{expected})"
  exit 1
end

puts "ok"
