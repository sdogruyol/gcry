require "../../src/gcry"
require "spec"

# The runtime's SYSMON thread allocates: `Thread#start` builds its main
# `Fiber` on that thread, and the monitor spawns threads from its loop. A
# process-wide "single mutator" regime once exempted it from ending the
# lock-free path, and two threads popped the same freelist head:
# `make scheduler-roots` hung under load with SYSMON's main fiber pushed
# twice onto `Fiber.fibers` — its `next` pointing at itself, the root scan
# iterating it forever. Allocation is now lock-free per thread through its
# own cursor set, so this drives the same shape on purpose — a thread that
# carries SYSMON's name allocates alongside the main thread, both on the hit
# path — and no block may be handed out twice.
{% if flag?(:linux) %}
  describe "two threads on the unlocked allocation path" do
    it "never hands the same block to both threads" do
      per = 200_000
      other = Array(Void*).new(per, Pointer(Void).null)
      done = Atomic(Int32).new(0)
      go = Atomic(Int32).new(0)
      worker = Thread.new(name: "SYSMON") do
        while go.get == 0
          Thread.yield
        end
        i = 0
        while i < per
          p = GC.malloc(48)
          p.as(UInt64*).value = 0xBBBB_BBBB_BBBB_BBBB_u64
          other[i] = p
          i += 1
        end
        done.set(1)
      end
      mine = Array(Void*).new(per, Pointer(Void).null)
      go.set(1)
      i = 0
      while i < per
        p = GC.malloc(48)
        p.as(UInt64*).value = 0xAAAA_AAAA_AAAA_AAAA_u64
        mine[i] = p
        i += 1
      end
      while done.get == 0
        Thread.yield
      end
      worker.join

      # Every address handed to one thread is absent from the other's list,
      # and every stamp is still the one its owner wrote.
      seen = Set(UInt64).new(per)
      mine.each { |p| seen << p.address }
      shared = other.count { |p| seen.includes?(p.address) }
      shared.should eq(0)
      mine.count { |p| p.as(UInt64*).value != 0xAAAA_AAAA_AAAA_AAAA_u64 }.should eq(0)
      other.count { |p| p.as(UInt64*).value != 0xBBBB_BBBB_BBBB_BBBB_u64 }.should eq(0)
    end
  end
{% end %}
