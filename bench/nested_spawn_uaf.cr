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

# One context for the whole run. A fresh context per round exhausts threads
# instead, which is a different failure and would hide this one.
ec = Fiber::ExecutionContext::Parallel.new("nested-spawn-uaf", WORKERS)

puts "fibers=#{FIBERS} rounds=#{ROUNDS} workers=#{WORKERS} collects=#{COLLECTS}"

ROUNDS.times do
  done = Channel(Nil).new(FIBERS)
  FIBERS.times do
    # The nesting is the shape: a fiber that spawns a fiber and then yields, so
    # a new Fiber is being built on one stack while the collection walks another.
    ec.spawn do
      ec.spawn { done.send(nil) }
      Fiber.yield
    end
  end
  COLLECTS.times { GC.collect }
  FIBERS.times { done.receive }
end

puts "ok — no fault this run (it is intermittent; see the rates in the header)"
