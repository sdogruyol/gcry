require "spec"
require "../src/gcry"

# The thread this file was required on, which is the process's initial thread:
# nothing has waited yet. It is not where every example runs. Crystal 1.21's
# execution-context monitor hands a scheduler whose thread it catches inside
# `open(2)` (`Fiber.syscall`) to a pool thread, and the main fiber carries on
# there — measured on Darwin at one move per ~1 000–3 000 `File.open` calls
# from the main fiber. The moved fiber still reports `Thread.current.name` as
# `DEFAULT-0`, because the name belongs to the scheduler, so only the pthread
# id can say. An example that needs the initial thread itself — its stack
# bounds follow `RLIMIT_STACK`; a pool thread's are its mmap — has to check.
module SpecInitialThread
  class_property pthread : UInt64 = 0_u64

  def self.current? : Bool
    Gcry::Platform.current_thread_id == pthread
  end
end

SpecInitialThread.pthread = Gcry::Platform.current_thread_id

# `Invariant.check_live_objects` walks the heap and compares the result with
# `heap.live_objects`. On a heap another thread can allocate into, those are two
# different instants, so the walk is **skipped** — and counted as a
# `concurrent_skip` — whenever `concurrent_mutators?` says the process has more
# than one mutator thread. That predicate is `multi_mutator_threads?`, a count
# of Crystal's thread list against a small constant, so it answers a question
# about the *process* and not about the heap in front of it.
#
# An example that asserts the walk **ran** therefore depends on a thread count
# it does not own. `invariant_spec` has one example that starts two workers on
# purpose to force the skip, and `Thread#join` returning does not mean Crystal
# has unlinked that thread yet — so in a randomised order the next example can
# read three mutators, skip, and fail on `live_object_checks` having stayed
# where it was. That is the fifth spec of the aarch64 flake family: the other
# four were the empty-chunk release knobs
# (`bench/log/linux/2026-09-17-empty-chunk-release-flake/FINDINGS.md`), and this
# one has a different predicate, which is why pinning those knobs did not stop
# it. Observed twice in a row on the aarch64 runner, both times `Expected 0 to
# be GreaterThan 0`, while x86_64 stayed green.
#
# Waiting is the fix rather than a knob or an override: the threads in question
# are already joined, so the list does drain — what lags is the unlinking, not a
# live mutator. An example whose subject is the walk asserts its own
# precondition here, and says so if the precondition never arrives instead of
# failing on the counter.
module SpecSoleMutator
  DEFAULT_TIMEOUT = 5.seconds

  def self.wait(heap : Gcry::Heap, timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
    deadline = Time.instant + timeout
    while heap.concurrent_mutators?
      if Time.instant >= deadline
        n = 0
        Thread.unsafe_each { n += 1 }
        raise "#{n} threads are still on Crystal's list after #{timeout.total_seconds}s, so " \
              "check_live_objects will count a concurrent skip instead of walking. This " \
              "example asserts that the walk ran, so it would fail on the walk counter " \
              "rather than on what it tests (spec/spec_helper.cr)."
      end
      sleep 1.millisecond
    end
  end
end
