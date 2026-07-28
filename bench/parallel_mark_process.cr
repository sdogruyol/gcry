# Process-GC parallel mark (STW-exempt pthreads) — standalone (Phase 6 CI harden).
#
# Kept out of process_spec: Spec + parallel mark + GC.collect was flaky on CI
# (SEGV inside Spec::Result reporting after the example body succeeded).
#
# Build: crystal build -Dgc_none bench/parallel_mark_process.cr -o bin/parallel_mark_process
# Run:   ./bin/parallel_mark_process

{% unless flag?(:gc_none) %}
  raise "parallel_mark_process requires -Dgc_none (gcry as process GC)"
{% end %}

require "../src/gcry"

h = Gcry.default_heap
raise "no heap" unless h
raise "expected stop_the_world" unless h.stop_the_world

old = h.parallel_mark_workers
begin
  h.parallel_mark_workers = 4
  before_runs = h.parallel_mark_runs
  before_stolen = h.parallel_mark_stolen

  keep = Array(String).new(64) { |i| "pm-keep-#{i}-#{"y" * 32}" }
  8.times do
    nest = Array(String).new(16) { |j| "nest-#{j}-#{"z" * 24}" }
    keep << nest.join(",")
  end

  GC.collect
  GC.collect

  raise "parallel_mark_runs did not increase (#{before_runs} -> #{h.parallel_mark_runs})" unless h.parallel_mark_runs > before_runs
  raise "parallel_mark_stolen did not increase (#{before_stolen} -> #{h.parallel_mark_stolen})" unless h.parallel_mark_stolen > before_stolen
  raise "lost keep graph" unless keep.size > 60
ensure
  h.parallel_mark_workers = old
end

puts "parallel_mark_process ok"
