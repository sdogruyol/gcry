require "../../src/gcry"
require "spec"

# A `Thread` nobody kept is held, once its thread has taken itself off
# Crystal's list, only by that thread's own stack — which gcry neither suspends
# nor scans. `Thread#start` still reads `@detached` and `@system_handle` after
# `Fiber.inactive`, and `Fiber.inactive` waits on the fiber list's mutex, which
# every stop holds for the whole collection. So the object has to be held on
# the thread's behalf until the thread is done with it: the birth root
# (src/gcry/thread_birth_root.cr).
#
# Two ways that root used to end early. Windows released it when a stop saw
# the thread on Crystal's list, so a collection while the thread ran followed
# by one inside its death window swept the object the dying thread then
# dereferenced. And on every platform the root table was claimed with a plain
# test-and-set, so concurrent `Thread.new`s lost or crossed records: 12% of
# 9 600 births armed eight at a time, and a crossed record releases a live
# thread's root on someone else's death.

DEATH_WINDOW_KEY = 0x5A5A_A5A5_5A5A_A5A5_u64

module DeathWindowSpec
  @@go = Atomic(Int32).new(0)
  @@started = Atomic(Int32).new(0)

  def self.go? : Bool
    @@go.get != 0
  end

  def self.go! : Nil
    @@go.set(1)
  end

  def self.started : Int32
    @@started.get
  end

  def self.started! : Nil
    @@started.add(1)
  end

  # The address exists only in this frame; the caller keeps the masked form.
  @[NoInline]
  def self.spawn_parked(handles : Pointer(UInt64), i : Int32) : UInt64
    thread = Thread.new do
      handles[i] = Thread.current.to_unsafe.unsafe_as(UInt64)
      started!
      until go?
        Thread.yield
      end
    end
    thread.object_id ^ DEATH_WINDOW_KEY
  end

  @[NoInline]
  def self.wipe_stack : Nil
    buf = uninitialized UInt8[16384]
    16384.times { |i| buf.to_unsafe[i] = 0x11_u8 }
    Gcry::Trace.enabled? && puts(buf.to_unsafe[0])
  end

  @[NoInline]
  def self.churn_garbage(size : Int32) : Nil
    512.times do
      block = GC.malloc(size).as(UInt64*)
      (size // 8).times { |j| block[j] = 0xEEEE_EEEE_EEEE_EEEE_u64 }
    end
  end

  def self.listed(hidden : Pointer(UInt64), n : Int32) : Int32
    count = 0
    Thread.each do |thread|
      masked = thread.object_id ^ DEATH_WINDOW_KEY
      n.times { |i| count += 1 if hidden[i] == masked }
    end
    count
  end
end

describe "a thread in its death window" do
  it "keeps a forgotten Thread while the dying thread still uses it" do
    n = 32
    heap = Gcry.default_heap
    hidden = Pointer(UInt64).malloc(n)
    handles = Pointer(UInt64).malloc(n)
    n.times { |i| hidden[i] = DeathWindowSpec.spawn_parked(handles, i) }
    DeathWindowSpec.wipe_stack
    until DeathWindowSpec.started == n
      Thread.yield
    end
    # Alive and on the list: a root released on sight is released here.
    GC.collect

    Fiber.gcry_lock_list
    DeathWindowSpec.go!
    until DeathWindowSpec.listed(hidden, n) == 0
      Thread.yield
    end
    # Every thread is now off Crystal's list and waiting in `Fiber.inactive`.
    # The collector must not relock the mutex this thread holds.
    heap.fiber_list_unlocked = true
    lost = 0
    begin
      3.times do
        DeathWindowSpec.wipe_stack
        GC.collect
        DeathWindowSpec.churn_garbage(instance_sizeof(Thread))
      end
      n.times do |i|
        object = Pointer(Void).new(hidden[i] ^ DEATH_WINDOW_KEY)
        lost += 1 unless heap.live?(object) && object.as(Thread).to_unsafe.unsafe_as(UInt64) == handles[i]
      end
    ensure
      heap.fiber_list_unlocked = false
    end
    # The threads read their `Thread` once let go, so a loss must not be.
    LibC._exit(1) if lost > 0
    Fiber.gcry_unlock_list
    lost.should eq(0)
  end

  {% unless flag?(:win32) %}
    it "records every concurrent birth against its own object" do
      creators = 8
      per = 16
      n = creators * per
      size = 64
      fill = 0xC3C3_C3C3_C3C3_C3C3_u64
      # Odd, so no id is ever a real `pthread_t`.
      ids = Pointer(UInt64).malloc(n)
      n.times { |i| ids[i] = 0x7E00_0000_0001_u64 + (i.to_u64 << 4) }
      hidden = Pointer(UInt64).malloc(n)

      gate = Atomic(Int32).new(0)
      ready = Atomic(Int32).new(0)
      makers = Array(Thread).new(creators) do |c|
        Thread.new do
          objects = Pointer(Void*).malloc(per)
          per.times do |k|
            block = GC.malloc(size).as(UInt64*)
            (size // 8).times { |j| block[j] = fill }
            objects[k] = block.as(Void*)
          end
          ready.add(1)
          until gate.get != 0
          end
          per.times { |k| Gcry::ThreadBirthRoot.arm(ids[c * per + k], objects[k]) }
          per.times do |k|
            hidden[c * per + k] = objects[k].address ^ DEATH_WINDOW_KEY
            objects[k] = Pointer(Void).null
          end
        end
      end
      until ready.get == creators
        Thread.yield
      end
      gate.set(1)
      makers.each(&.join)
      makers.clear
      # The makers were births too; let their roots go before counting.
      3.times { GC.collect }
      released0 = Gcry::ThreadBirthRoot.released_dead
      unmatched0 = Gcry::ThreadBirthRoot.deaths_unmatched

      # Half die. The other half must keep their roots: a crossed record
      # releases a survivor's object on one of these deaths.
      (0...n).step(2) { |i| Gcry::ThreadBirthRoot.note_death(ids[i]) }
      3.times do
        DeathWindowSpec.wipe_stack
        GC.collect
        DeathWindowSpec.churn_garbage(size)
      end
      torn = 0
      (1...n).step(2) do |i|
        block = Pointer(UInt64).new(hidden[i] ^ DEATH_WINDOW_KEY)
        torn += 1 unless Gcry.default_heap.live?(block.as(Void*)) && block.value == fill
      end
      (1...n).step(2) { |i| Gcry::ThreadBirthRoot.note_death(ids[i]) }
      3.times { GC.collect }

      torn.should eq(0)
      # A death that finds no record is a birth whose record was lost.
      (Gcry::ThreadBirthRoot.deaths_unmatched - unmatched0).should eq(0)
      (Gcry::ThreadBirthRoot.released_dead - released0).should be >= n
    end
  {% end %}
end
