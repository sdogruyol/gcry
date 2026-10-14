require "../../src/gcry"
require "spec"

# The invariant checker compares a walk of the heap with `live_objects`, and
# declines while another thread could be allocating (`concurrent_mutators?`).
# It let the Monitor and the idle thread through as non-mutators, which they
# are once in their loops — but each allocates in its birth: `Thread#start`
# pushes the thread onto Crystal's list and then allocates its main `Fiber`.
# A walk taken while one sat between setting an occupancy bit and crediting
# the counter read one block more than the counter for as long as that thread
# was off the CPU, and three readings in a row made it a "lost increment":
# the one `make counter-loss` failure on macos-15-intel, 1 in 983 361
# comparisons and never seen again after it. On Linux under CPU contention 11
# of 3 840 runs of the old harness counted such mismatches, all in the
# Monitor's or the idle thread's birth, none of them persistent.
#
# The idle thread is held in its birth (`IdleRelease.test_birth_hold`), past
# the point where `IdleRelease.thread?` names it, and the checker must count
# it as a mutator until it has stored itself as exempt. A process of its own:
# the idle thread is born once per process, and `GCRY_IDLE_RELEASE_MS=0` keeps
# the collections before the hold is armed from starting it.

describe "Regression: a runtime thread in its birth is a mutator to the checker" do
  it "in a process of its own" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "runtime-birth child"],
      env: {"GCRY_RUNTIME_BIRTH_CHILD" => "1", "GCRY_IDLE_RELEASE_MS" => "0"},
      output: captured, error: captured)
    fail "child #{status.inspect}:\n#{captured}" unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  it "runtime-birth child" do
    next unless ENV["GCRY_RUNTIME_BIRTH_CHILD"]? == "1"
    heap = Gcry.default_heap
    fail "the idle thread is armed already; it may have been born before the hold" if Gcry::IdleRelease.armed?
    Gcry::IdleRelease.test_birth_hold = true
    Gcry::IdleRelease.idle_ms = 3_600_000_u64
    # Ends by starting the idle thread, which stops at the hold.
    GC.collect
    deadline = Time.instant + 10.seconds
    until Gcry::IdleRelease.birth_spins > 0
      fail "the idle thread never reached its birth hold" if Time.instant > deadline
      sleep 1.millisecond
    end
    idle = nil
    Thread.each { |t| idle = t if t.name == "gc-idle" }
    idle = idle.not_nil!
    Gcry::IdleRelease.thread?(idle).should be_true

    heap.concurrent_mutators?.should be_true

    # Once it has exempted itself it only reads, and the checker walks again.
    Gcry::IdleRelease.release_birth_hold
    deadline = Time.instant + 10.seconds
    until Gcry::IdleRelease.signal_exempt?(idle)
      fail "the idle thread never became exempt" if Time.instant > deadline
      sleep 1.millisecond
    end
    heap.concurrent_mutators?.should be_false
  end
end
