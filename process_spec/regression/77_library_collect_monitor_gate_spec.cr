require "../../src/gcry"
require "spec"

# A library heap's collection shut the runtime's Monitor out until the process
# heap's next collection. `stop_world_quiescing_roots` closed the Monitor gate
# for every heap, and the gate is opened again in `start_world` — which
# returns at once for a heap that never stopped the world, and a library heap
# never does. The Monitor then sat in `MonitorGate.enter` at the top of its
# next pass, in `transfer_schedulers_blocked_on_syscall`, and ran none of its
# three calls: no scheduler blocked on a syscall was handed to another
# thread, no parallel context grew, no fiber stack was collected.
#
# That is why spec 76 could not reach its hook on Windows (CI run
# 39028591028, all eight Windows jobs): `ci/windows.ps1` builds the process
# specs in sorted order, and 72's library-heap collection runs four files
# before 76 with no process collection in between. A probe there found the
# Monitor in `MonitorGate.wait_for_open` with the gate closed and no stop in
# progress, from the end of 72 to the end of the run (CI run 39058010270;
# `bench/log/windows/2026-10-18-monitor-hook/`). `crystal spec` takes the
# files in directory order, unsorted; on the Linux host it was read on, that
# put 71 — a process collection, which opens the gate — right before 76.
#
# Collection is off for the example, so no process collection can open the
# gate behind the library one's back.
{% if flag?(:gc_none) && @top_level.has_constant?("Fiber") && Fiber.has_constant?("ExecutionContext") && Fiber::ExecutionContext.has_constant?("Monitor") %}
  module LibraryCollectGate
    @@passes = Atomic(Int32).new(0)

    def self.pass : Nil
      @@passes.add(1)
    end

    def self.passes : Int32
      @@passes.get
    end
  end

  # Spec 77 only: the gate's state, which has no public reader.
  module Gcry::MonitorGate
    def self.closed_for_library_collect_spec? : Bool
      @@stopped.get != 0
    end
  end

  # Called on every pass of the Monitor's loop, after the other two calls, and
  # outside its gate.
  class Fiber::ExecutionContext::Monitor
    private def collect_stacks(now)
      LibraryCollectGate.pass
      previous_def
    end
  end

  describe "Regression: a library heap's collection" do
    it "does not shut the Monitor out" do
      gate_open = false
      passes = 0
      GC.disable
      begin
        heap = Gcry::Heap.new
        begin
          heap.collect
          # A process stop in flight closes the gate legitimately; one is over
          # in milliseconds.
          deadline = Time.instant + 100.milliseconds
          until (gate_open = !Gcry::MonitorGate.closed_for_library_collect_spec?) || Time.instant > deadline
            sleep 1.millisecond
          end
          before = LibraryCollectGate.passes
          deadline = Time.instant + 5.seconds
          until LibraryCollectGate.passes >= before + 2 || Time.instant > deadline
            sleep 1.millisecond
          end
          passes = LibraryCollectGate.passes - before
        ensure
          heap.destroy
        end
      ensure
        GC.enable
      end

      gate_open.should be_true, "the Monitor gate was still closed 100 ms after a library heap's collection"
      passes.should be >= 2, "the Monitor made #{passes} passes of its loop in 5 s after a library heap's collection"
    end
  end
{% end %}
