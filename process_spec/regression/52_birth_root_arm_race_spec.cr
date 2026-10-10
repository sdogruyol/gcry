require "../../src/gcry"
require "spec"

# A thread that ends before its creator has armed its birth root (review of
# master, 2026-10-10). The real `pthread_create` returned, the creator had not
# reached `ThreadBirthRoot.arm` yet, and nothing stopped the new thread from
# running to its end: its `note_death` found no slot and it detached, so glibc
# could hand its `pthread_t` to the next thread created. That thread's creator
# armed the handle for it, and when the first creator reached `arm`, it took
# that slot as a recycled handle's and un-rooted a thread that was still
# running — swept in its death window 6 runs of 6. The late `arm` also
# recorded a thread that was already gone, a root nothing would release
# (src/gcry/thread_birth_root.cr, "A birth that ends first").
#
# The creator is parked between `pthread_create` and `arm` by the research
# hold, since nothing else can put it there on demand. The first thread runs
# to its end and exits meanwhile, and the second is handed its handle. Before
# the fix the first thread's death is unmatched and the second thread's
# `Thread` is swept; after it, the first thread stamps its own claim, and the
# held `arm` sees that and takes back only a record whose death is stamped.

BIRTH_ARM_RACE_KEY = 0x3C3C_C3C3_3C3C_C3C3_u64

module BirthArmRaceSpec
  @@go = Atomic(Int32).new(0)
  @@handle = Atomic(UInt64).new(0_u64)

  def self.go? : Bool
    @@go.get != 0
  end

  def self.go! : Nil
    @@go.set(1)
  end

  def self.handle : UInt64
    @@handle.get
  end

  # The second birth: parked alive until `go!`, its address kept only masked.
  @[NoInline]
  def self.spawn_parked : UInt64
    thread = Thread.new do
      @@handle.set(Thread.current.to_unsafe.unsafe_as(UInt64))
      until go?
        Thread.yield
      end
    end
    thread.object_id ^ BIRTH_ARM_RACE_KEY
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

  def self.listed?(hidden : UInt64) : Bool
    found = false
    Thread.each { |thread| found = true if (thread.object_id ^ BIRTH_ARM_RACE_KEY) == hidden }
    found
  end
end

{% unless flag?(:win32) %}
  lib LibBirthArmRace
    fun pthread_attr_init(attr : LibC::PthreadAttrT*) : LibC::Int
    fun pthread_attr_setdetachstate(attr : LibC::PthreadAttrT*, state : LibC::Int) : LibC::Int
    fun pthread_attr_destroy(attr : LibC::PthreadAttrT*) : LibC::Int
  end

  {% if flag?(:darwin) %}
    BIRTH_ARM_RACE_DETACHED = 2
  {% else %}
    BIRTH_ARM_RACE_DETACHED = 1
  {% end %}

  # A thread created detached through `GC.pthread_create` never says it is
  # over, so its birth record stays live and unstamped under its handle after
  # it has gone (src/gcry/thread_birth_root.cr, `stamp_own`). *flag* is its
  # argument and libc memory; the routine only stores to it.
  def birth_arm_race_stale_record : Nil
    flag = LibC.malloc(8).as(Int64*)
    flag.value = 0
    attr = uninitialized LibC::PthreadAttrT
    LibBirthArmRace.pthread_attr_init(pointerof(attr)).should eq(0)
    LibBirthArmRace.pthread_attr_setdetachstate(pointerof(attr), BIRTH_ARM_RACE_DETACHED).should eq(0)
    tid = uninitialized LibC::PthreadT
    GC.pthread_create(pointerof(tid), pointerof(attr),
      ->(arg : Void*) { Atomic::Ops.store(arg.as(Int64*), 1_i64, :sequentially_consistent, true); Pointer(Void).null },
      flag.as(Void*)).should eq(0)
    LibBirthArmRace.pthread_attr_destroy(pointerof(attr))
    until Atomic::Ops.load(flag, :sequentially_consistent, true) != 0
      Thread.yield
    end
    # Gone, and its handle free for the next birth.
    Thread.sleep(50.milliseconds)
  end

  # Windows arms before the thread is resumed, so there is no such window.
  describe "Regression: a thread that ends before its creator arms its birth root" do
    # In a process of its own: before the fix the second thread reads its
    # swept `Thread` once let go, and the hold must not touch the suite's
    # other births.
    it "keeps the root of the thread handed the dead thread's handle" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "birth-arm-race child"],
        env: {"GCRY_BIRTH_ARM_RACE_CHILD" => "1"}, output: captured, error: captured)
      fail captured.to_s unless status.success?
      captured.to_s.should contain("1 examples, 0 failures")
    end

    # The same, with a stale record under the handle first: a detached
    # thread's, which the first thread's death must not take for its own.
    it "keeps it when a detached thread left a record under the same handle" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "birth-arm-race child"],
        env: {"GCRY_BIRTH_ARM_RACE_CHILD" => "detached"}, output: captured, error: captured)
      fail captured.to_s unless status.success?
      captured.to_s.should contain("1 examples, 0 failures")
    end

    # The run, by the examples above in a fresh process; a no-op anywhere else.
    it "birth-arm-race child" do
      next unless mode = ENV["GCRY_BIRTH_ARM_RACE_CHILD"]?
      heap = Gcry.default_heap
      # The hold takes the next birth, whoever makes it. A first collection
      # starts the idle thread (`IdleRelease.ensure_started`) from whichever
      # thread collected; let that birth happen now, not inside the hold.
      GC.collect
      creator_go = Atomic(Int32).new(0)
      first_handle = Atomic(UInt64).new(0_u64)
      first_done = Atomic(Int32).new(0)
      creator = Thread.new do
        until creator_go.get != 0
          Thread.yield
        end
        Thread.new do
          first_handle.set(Thread.current.to_unsafe.unsafe_as(UInt64))
          first_done.set(1)
        end
      end
      birth_arm_race_stale_record if mode == "detached"
      unmatched0 = Gcry::ThreadBirthRoot.deaths_unmatched
      seen0 = Gcry::ThreadBirthRoot.deaths_seen
      Gcry::ThreadBirthRoot.test_hold_birth
      creator_go.set(1)
      deadline = Time.instant + 10.seconds
      until Gcry::ThreadBirthRoot.test_birth_held?
        fail "the creator never reached the hold" if Time.instant > deadline
        Thread.yield
      end

      # The first thread runs to its end while its creator is held: its death
      # is counted, unmatched before the fix and matched against its claim
      # after it, and it exits.
      until first_done.get != 0
        fail "the first thread never ran" if Time.instant > deadline
        Thread.yield
      end
      until Gcry::ThreadBirthRoot.deaths_unmatched != unmatched0 || Gcry::ThreadBirthRoot.deaths_seen != seen0
        fail "the first thread's death was never counted" if Time.instant > deadline
        Thread.sleep(1.millisecond)
      end
      # Long enough for it to finish exiting, so libc can hand its handle to
      # the next birth.
      Thread.sleep(50.milliseconds)

      hidden = BirthArmRaceSpec.spawn_parked
      until BirthArmRaceSpec.handle != 0
        fail "the second thread never ran" if Time.instant > deadline
        Thread.yield
      end
      Gcry::ThreadBirthRoot.test_release_birth
      creator.join
      unmatched = Gcry::ThreadBirthRoot.deaths_unmatched - unmatched0
      same_handle = BirthArmRaceSpec.handle == first_handle.get

      # The second thread in its death window, as in spec 23: off Crystal's
      # list, waiting on the fiber list's mutex, held by its birth root alone.
      BirthArmRaceSpec.wipe_stack
      Fiber.gcry_lock_list
      BirthArmRaceSpec.go!
      while BirthArmRaceSpec.listed?(hidden)
        fail "the second thread never left the list" if Time.instant > deadline
        Thread.yield
      end
      heap.fiber_list_unlocked = true
      lost = false
      begin
        3.times do
          BirthArmRaceSpec.wipe_stack
          GC.collect
          BirthArmRaceSpec.churn_garbage(instance_sizeof(Thread))
        end
        object = Pointer(Void).new(hidden ^ BIRTH_ARM_RACE_KEY)
        lost = !(heap.live?(object) && object.as(Thread).to_unsafe.unsafe_as(UInt64) == BirthArmRaceSpec.handle)
      ensure
        heap.fiber_list_unlocked = false
      end
      # The thread reads its `Thread` once let go, so a loss must not be.
      if lost
        STDERR.puts "second thread's Thread swept in its death window " \
                    "(handle reused: #{same_handle}, unmatched deaths: #{unmatched})"
        LibC._exit(1)
      end
      Fiber.gcry_unlock_list
      # The first thread's death found its own record.
      unmatched.should eq(0)
    end
  end
{% end %}
