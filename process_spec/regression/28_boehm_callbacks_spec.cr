require "../../src/gcry"
require "spec"

# Boehm's callbacks inside a gcry program (PR #44 review). Until 2026-10-06
# `GC_set_start_callback` and `GC_set_warn_proc` recorded their procedure and
# never called it, and `GC_set_on_collection_event`, `GC_set_on_thread_event`
# and `GC_set_on_heap_resize` aborted the process. And `GC_malloc` out of
# memory raised an `OutOfMemoryError` no C caller — nor a Crystal `rescue`
# around a `LibGC` call — could catch, where Boehm warns and returns null.

# Everything the callbacks record goes to libc memory through class
# variables: a callback runs inside the collector and must not allocate.
class BoehmCallbackLog
  START_CALLBACK =   -1
  CAP            = 4096

  class_property events : Int32* = Pointer(Int32).null
  class_property count = 0
  class_property threads : UInt64* = Pointer(UInt64).null
  class_property thread_count = 0
  class_property resize_count = 0
  class_property resize_last = 0_u64
  class_property warn_count = 0
  class_property warn_message : UInt8* = Pointer(UInt8).null
  class_property warn_arg = 0_u64
  class_property sink : Void* = Pointer(Void).null

  def self.reset : Nil
    @@events = LibC.malloc(CAP * sizeof(Int32)).as(Int32*) if @@events.null?
    @@threads = LibC.malloc(CAP * 2 * sizeof(UInt64)).as(UInt64*) if @@threads.null?
    @@count = 0
    @@thread_count = 0
    @@resize_count = 0
    @@resize_last = 0_u64
    @@warn_count = 0
    @@warn_message = Pointer(UInt8).null
    @@warn_arg = 0_u64
  end

  def self.record(event : Int32) : Nil
    if @@count < CAP
      @@events[@@count] = event
      @@count += 1
    end
  end

  def self.events_list : Array(Int32)
    Array(Int32).new(@@count) { |i| @@events[i] }
  end
end

private def no_collection_event : LibGC::OnCollectionEventProc
  LibGC::OnCollectionEventProc.new(Pointer(Void).null, Pointer(Void).null)
end

private def no_thread_event : LibGC::OnThreadEventProc
  LibGC::OnThreadEventProc.new(Pointer(Void).null, Pointer(Void).null)
end

private def ev(e : LibGC::EventType) : Int32
  e.value.to_i32
end

describe "Boehm's collection callbacks in a gcry program" do
  it "calls GC_set_start_callback's procedure once at the start of every collection" do
    BoehmCallbackLog.reset
    LibGC.set_start_callback(-> { BoehmCallbackLog.record(BoehmCallbackLog::START_CALLBACK) })
    begin
      3.times { LibGC.collect }
    ensure
      LibGC.set_start_callback(Proc(Nil).new(Pointer(Void).null, Pointer(Void).null))
    end
    BoehmCallbackLog.events_list.should eq([BoehmCallbackLog::START_CALLBACK] * 3)
  end

  it "calls the start callback, then reports every collection event in order" do
    BoehmCallbackLog.reset
    LibGC.set_start_callback(-> { BoehmCallbackLog.record(BoehmCallbackLog::START_CALLBACK) })
    LibGC.set_on_collection_event(->(e : LibGC::EventType) { BoehmCallbackLog.record(e.value.to_i32) })
    begin
      LibGC.get_start_callback.null?.should be_false
      LibGC.get_on_collection_event.pointer.null?.should be_false
      LibGC.collect
    ensure
      LibGC.set_start_callback(Proc(Nil).new(Pointer(Void).null, Pointer(Void).null))
      LibGC.set_on_collection_event(no_collection_event)
    end
    log = BoehmCallbackLog.events_list
    expected = [
      BoehmCallbackLog::START_CALLBACK,
      ev(LibGC::EventType::START), ev(LibGC::EventType::PRE_STOP_WORLD),
      ev(LibGC::EventType::POST_STOP_WORLD), ev(LibGC::EventType::MARK_START),
      ev(LibGC::EventType::MARK_END), ev(LibGC::EventType::RECLAIM_START),
      ev(LibGC::EventType::RECLAIM_END), ev(LibGC::EventType::PRE_START_WORLD),
      ev(LibGC::EventType::POST_START_WORLD), ev(LibGC::EventType::END),
    ]
    # One collection, every event once.
    log.sort.should eq(expected.sort)
    log.first.should eq(BoehmCallbackLog::START_CALLBACK)
    log[1].should eq(ev(LibGC::EventType::START))
    log.last.should eq(ev(LibGC::EventType::END))
    index = ->(e : LibGC::EventType) { log.index!(ev(e)) }
    index.call(LibGC::EventType::PRE_STOP_WORLD).should be < index.call(LibGC::EventType::POST_STOP_WORLD)
    index.call(LibGC::EventType::POST_STOP_WORLD).should be < index.call(LibGC::EventType::MARK_START)
    index.call(LibGC::EventType::MARK_START).should be < index.call(LibGC::EventType::MARK_END)
    index.call(LibGC::EventType::MARK_END).should be < index.call(LibGC::EventType::RECLAIM_START)
    index.call(LibGC::EventType::RECLAIM_START).should be < index.call(LibGC::EventType::RECLAIM_END)
    index.call(LibGC::EventType::MARK_END).should be < index.call(LibGC::EventType::PRE_START_WORLD)
    index.call(LibGC::EventType::PRE_START_WORLD).should be < index.call(LibGC::EventType::POST_START_WORLD)

    # Cleared, nothing more is reported.
    LibGC.get_start_callback.null?.should be_true
    LibGC.get_on_collection_event.pointer.null?.should be_true
    LibGC.collect
    BoehmCallbackLog.count.should eq(log.size)
  end

  it "reports each other thread suspended and resumed, with its pthread handle" do
    BoehmCallbackLog.reset
    parked = Atomic(Int32).new(0)
    release = Atomic(Int32).new(0)
    other = Thread.new do
      parked.set(1)
      until release.get != 0
        Thread.sleep(1.millisecond)
      end
    end
    until parked.get != 0
      Thread.yield
    end
    LibGC.set_on_thread_event(->(e : LibGC::EventType, thread : Void*) {
      k = BoehmCallbackLog.thread_count
      if k < BoehmCallbackLog::CAP
        BoehmCallbackLog.threads[2 * k] = e.value.to_u64
        BoehmCallbackLog.threads[2 * k + 1] = thread.address
        BoehmCallbackLog.thread_count = k + 1
      end
    })
    begin
      LibGC.get_on_thread_event.pointer.null?.should be_false
      LibGC.collect
    ensure
      LibGC.set_on_thread_event(no_thread_event)
      release.set(1)
      other.join
    end
    id = other.to_unsafe.unsafe_as(UInt64)
    seen = Array(UInt64).new
    BoehmCallbackLog.thread_count.times do |k|
      seen << BoehmCallbackLog.threads[2 * k] if BoehmCallbackLog.threads[2 * k + 1] == id
    end
    seen.should eq([LibGC::EventType::THREAD_SUSPENDED.value.to_u64, LibGC::EventType::THREAD_UNSUSPENDED.value.to_u64])
    # Never the collecting thread itself.
    own = Thread.current.to_unsafe.unsafe_as(UInt64)
    BoehmCallbackLog.thread_count.times { |k| BoehmCallbackLog.threads[2 * k + 1].should_not eq(own) }
  end

  it "reports the heap growing through GC_set_on_heap_resize" do
    BoehmCallbackLog.reset
    LibGC.set_on_heap_resize(->(size : LibGC::Word) {
      BoehmCallbackLog.resize_count += 1
      BoehmCallbackLog.resize_last = size.to_u64
    })
    held = [] of Void*
    begin
      LibGC.get_on_heap_resize.pointer.null?.should be_false
      # Live and large, so each one needs memory the heap does not have.
      4.times { held << LibGC.malloc_atomic(32 * 1024 * 1024) }
    ensure
      LibGC.set_on_heap_resize(LibGC::OnHeapResizeProc.new(Pointer(Void).null, Pointer(Void).null))
    end
    BoehmCallbackLog.resize_count.should be > 0
    BoehmCallbackLog.resize_last.should be >= 4_u64 * 32 * 1024 * 1024
    BoehmCallbackLog.resize_last.should be <= Gcry.default_heap.heap_size
    held.each { |p| LibGC.free(p) }
  end

  # `crystal i`'s registrant is interpreted code, and running it allocates.
  # Against Boehm's rule, but it is what the stdlib prelude installs, so a
  # collection must survive it rather than wedge.
  it "survives a start callback that allocates, as crystal i's interpreted one does" do
    heap = Gcry.default_heap
    LibGC.set_start_callback(-> { BoehmCallbackLog.sink = GC.malloc(256) })
    begin
      before = heap.collections
      LibGC.collect
      LibGC.collect
      heap.collections.should be >= before + 2
    ensure
      LibGC.set_start_callback(Proc(Nil).new(Pointer(Void).null, Pointer(Void).null))
      BoehmCallbackLog.sink = Pointer(Void).null
    end
  end
end

describe "GC_malloc out of memory (Boehm parity)" do
  it "warns through GC_set_warn_proc and returns null, leaving a failed GC_realloc's block intact" do
    BoehmCallbackLog.reset
    LibGC.set_warn_proc(->(msg : LibC::Char*, arg : LibGC::Word) {
      BoehmCallbackLog.warn_count += 1
      BoehmCallbackLog.warn_message = msg
      BoehmCallbackLog.warn_arg = arg.to_u64
    })
    # 64 TiB: no host maps it, so the heap's own mapping fails.
    huge = LibC::SizeT.new(1) << 46
    kept = LibGC.malloc_atomic(64)
    kept.as(UInt8*).fill(64) { 0x7E_u8 }
    before = Gcry.default_heap.heap_size
    begin
      LibGC.malloc(huge).null?.should be_true
      LibGC.malloc_atomic(huge).null?.should be_true
      LibGC.realloc(kept, huge).null?.should be_true
    ensure
      LibGC.set_warn_proc(LibGC::WarnProc.new(Pointer(Void).null, Pointer(Void).null))
    end
    BoehmCallbackLog.warn_count.should eq(3)
    String.new(BoehmCallbackLog.warn_message).should eq("GC Warning: Out of Memory! Heap size: %lu MiB. Returning NULL!\n")
    # The heap's size in MiB when it gave up, Boehm's `%lu`; an emergency
    # collection before the failure may have released chunks since `before`.
    BoehmCallbackLog.warn_arg.should be > 0
    BoehmCallbackLog.warn_arg.should be <= Math.max(before, Gcry.default_heap.heap_size) >> 20
    64.times { |i| kept.as(UInt8*)[i].should eq(0x7E_u8) }
    # And the heap still allocates.
    LibGC.malloc(64).null?.should be_false
  end
end
