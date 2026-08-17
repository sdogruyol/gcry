# A use-after-free in fiber creation, in seconds instead of an hour and a half.
#
# The open 2026-08-10 soak SEGV is read as a block freed while the Parallel
# scheduler still pointed at it. It took 1h24m to arrive, once, which is why
# ROADMAP's "make the soak reproducible enough to bisect" exists: at that rate a
# candidate fix and a quiet run are the same observation.
#
# This reproduces a use-after-free of the same family in **seconds**, and it was
# not found by looking for it. `make ec-queue-audit` crashed three times on
# 2026-08-15 — aarch64, Darwin, then x86_64 — and every time the output stopped
# before its first arm line, i.e. inside the churn that arm 1 runs *before* the
# harness plants anything. With `GCRY_POISON_FREED=1` on, the crash named itself:
#
#     gcry: SIGSEGV at 0x0 — gcry's freed-block poison (GCRY_POISON_FREED) is in
#     the faulting context. Something followed a pointer read out of a block that
#     had already been freed: a use-after-free, not a wild pointer
#     … Fiber#makecontext … Fiber#initialize<Nil, Fiber::Stack, Parallel, Proc>
#
# Stripped to just that churn, measured on an idle WSL2 x86_64 host:
#
#     gcry  (-Dgc_none)   16 crashes in 25 runs
#     Boehm (control)      0 crashes in 25 runs
#
# Same program, same compiler, same workload — so the collector is the subject,
# not Crystal's execution context. And it does not need parallelism:
#
#     WORKERS=1  7 crashes in 12 runs
#     WORKERS=2  7 crashes in 12 runs
#     WORKERS=4  5 crashes in 12 runs
#
# One worker is enough, which rules out a race between workers and leaves the
# collector's view of a fiber being created while a collection runs.
#
# **Not wired into CI.** It fails most of the time on purpose — that is the
# finding — and a gate that is always red gates nothing. Wire it up as the
# regression test when the defect is fixed.
#
#   crystal build -Dgc_none bench/nested_spawn_uaf.cr -o bin/nested_spawn_uaf
#   GCRY_POISON_FREED=1 GCRY_SEGV_REPORT=1 bin/nested_spawn_uaf
#
# Knobs: FIBERS (64), ROUNDS (200), WORKERS (4), COLLECTS (8).

require "../src/gcry"

{% unless flag?(:gc_none) %}
  # Deliberately allowed: the Boehm build is the control arm above, and it has to
  # be buildable from this same file for the comparison to mean anything.
{% end %}

HEAP = Gcry.default_heap.not_nil!

FIBERS   = (ENV["FIBERS"]? || "64").to_i
ROUNDS   = (ENV["ROUNDS"]? || "200").to_i
WORKERS  = (ENV["WORKERS"]? || "4").to_i
COLLECTS = (ENV["COLLECTS"]? || "8").to_i
NEST     = (ENV["NEST"]? || "1") != "0"

# One context for the whole run. A fresh context per round exhausts threads
# instead, which is a different failure and would hide this one.
ec = Fiber::ExecutionContext::Parallel.new("nested-spawn-uaf", WORKERS)

# `GCRY_POISON_HOLDERS=1` reports a holder by `type_id`, because a signal
# handler cannot look a name up: Crystal's type ids are assigned per program and
# gcry ships no table of them. This prints the ids of the types the hunt is
# about, from *this* binary, so the number in the crash report can be read.
# It adds no type to the program — every one of these is already instantiated by
# `Fiber::StackPool` — so the ids it prints are the ids a crashing run has.
if ENV["PRINT_TYPE_IDS"]? == "1"
  {% for t in [Deque(Fiber::Stack), Fiber::StackPool, Fiber, Fiber::ExecutionContext::Parallel,
               Fiber::ExecutionContext::Parallel::Scheduler, Array(Fiber::Stack), Thread] %}
    puts "type_id {{t}} = #{ {{t}}.crystal_instance_type_id } (instance_sizeof #{instance_sizeof({{t}})})"
  {% end %}
  # And the offsets, because the holder report dumps raw payload words and
  # decoding them by guessing the ivar order is how a coherent deque gets read
  # as a mid-resize one. `offsetof` is the compiler's answer, not an assumption.
  {% for iv in %w[start size capacity buffer] %}
    puts "offsetof Deque(Fiber::Stack).@{{iv.id}} = #{offsetof(Deque(Fiber::Stack), @{{iv.id}})}"
  {% end %}
  {% for iv in %w[protect reuse_dead_fiber_stack deque] %}
    puts "offsetof Fiber::StackPool.@{{iv.id}} = #{offsetof(Fiber::StackPool, @{{iv.id}})}"
  {% end %}
end

# The holder search names the crashing `Fiber::StackPool` and its `Deque` by
# address. These are the addresses of the *live* pools, printed before anything
# can go wrong, so a crash can be read as "the context's own pool" or "some
# other pool" without inferring it. There are two: the context this file
# creates, and the default one Crystal sets up for plain `spawn`.
ec_pool = ec.stack_pool
default_pool = Fiber::ExecutionContext.default.stack_pool
puts "live ec pool 0x#{ec_pool.object_id.to_s(16)} deque 0x#{ec_pool.@deque.object_id.to_s(16)}"
puts "live default pool 0x#{default_pool.object_id.to_s(16)} deque 0x#{default_pool.@deque.object_id.to_s(16)}"

puts "fibers=#{FIBERS} rounds=#{ROUNDS} workers=#{WORKERS} collects=#{COLLECTS} nest=#{NEST}"

# Which edge of `ec → @stack_pool → @deque → @buffer` does the mark fail to
# follow? Rooting one link explicitly and measuring the crash rate answers it,
# and the arms are nested rather than independent: an explicit root marks the
# object *and* everything the mark then reaches from it. So if `ROOT=pool` takes
# the rate to zero the break is at `ec → @stack_pool`; if `pool` does not but
# `deque` does, it is the pool's own payload scan; if only `buffer` does, it is
# the deque's. `none` is the control, and the same binary runs all four.
ROOT = ENV["ROOT"]? || "none"

def root_link(pool : Fiber::StackPool) : Nil
  heap = Gcry.default_heap
  case ROOT
  when "pool"
    heap.add_root(Pointer(Void).new(pool.object_id))
  when "deque"
    heap.add_root(Pointer(Void).new(pool.@deque.object_id))
  when "buffer"
    # The buffer moves on every resize, so re-root the current one each round.
    # Roots are a set of raw addresses with no ownership, so leaving the old
    # ones in costs a few dozen entries over a run and nothing else.
    buf = pool.@deque.@buffer
    heap.add_root(buf.as(Void*)) unless buf.null?
  end
end

ROUNDS.times do
  root_link(ec_pool)
  done = Channel(Nil).new(FIBERS)
  FIBERS.times do
    if NEST
      # The nesting is the shape: a fiber that spawns a fiber and then yields, so
      # a new Fiber is being built on one stack while the collection walks another.
      ec.spawn do
        ec.spawn { done.send(nil) }
        Fiber.yield
      end
    else
      # NEST=0 — the same fiber count and the same collections, but every spawn
      # is issued from the main thread. If this arm is clean the defect is in the
      # spawning *fiber's* stack, not in spawning as such.
      ec.spawn { done.send(nil) }
      ec.spawn { Fiber.yield }
    end
  end
  COLLECTS.times { GC.collect }
  FIBERS.times { done.receive }
end

heap = Gcry.default_heap
puts "mark audit: #{heap.mark_audit_edges} base edges checked, #{heap.mark_audit_misses} missed"
puts "birth grace: #{heap.birth_grace_rooted} rooted, #{heap.birth_grace_saved} saved from the sweep, #{heap.birth_grace_overflows} overflowed"
puts "birth grace follow-up: #{heap.birth_grace_live_later} were live next collection, #{heap.birth_grace_garbage_later} were garbage"
puts "unowned stacks: pooled #{heap.pooled_stacks_walked} walked / #{heap.pooled_stack_words} words, " \
     "in-flight #{heap.inflight_stacks_walked} walked / #{heap.inflight_stack_words} words"
# Retention, because an arm that takes a crash rate to zero by keeping
# everything alive is not a fix, and the two look identical from the outside.
puts "retention: heap_size #{GC.stats.heap_size} live_objects #{heap.live_objects} collections #{heap.collections}"
puts "ok — no fault this run (it is intermittent; see the rates in the header)"
