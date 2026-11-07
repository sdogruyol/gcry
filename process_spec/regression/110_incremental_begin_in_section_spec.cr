require "../../src/gcry"
require "spec"

# `collect_a_little` began a cycle (`begin_incremental`: `@collecting` set,
# a stop, the marks cleared, the roots marked, the barrier armed) before it
# queued for the collection section, on nothing but its entry checks, one of
# which reads `@collecting` false. A full collection sets `@collecting` only
# once it holds the section and is past its prelude, so a slicing thread
# that read it false while a full collection queued or prepared went on to
# begin; the begin's `lock_write` waited behind the collection's stop and
# took the world as soon as that stop let it go — in the collection's
# post-stop passes, ahead of its sweep after the world (the default lazy
# sweep), with the collection still holding the section. The begin cleared
# the marks that sweep reads and marked the roots alone, and the sweep then
# freed every object a root does not point at directly; the sweep's re-arm
# took the new cycle's mprotect barrier down again, and the begin's
# `@collecting = false` ended the collection's flag while it still ran. Now
# the cycle is begun holding the section (`collect_a_little`): it waits for
# the collection and begins after it. Boehm starts an incremental cycle
# under the allocation lock (`GC_collect_a_little_inner`).
#
# The construction, deterministic: automatic collection and the idle thread
# off, a chain of 20 000 blocks whose head is an explicit root
# (`Heap#add_root`), the stack below scrubbed. A second thread calls
# `collect_a_little`; `Heap.inc_begin_hook` holds it after its entry checks
# (`@collecting` false) and releases the main thread into `collect`, then
# waits until that collection's `post_stw_hook` (`:after_start_world`, the
# world running again, the section held, the lazy sweep not run yet) says
# it is there. The post-stop hook waits until the second thread holds a
# ticket for the section, and records whether a cycle is open and whether
# `@collecting` still says the collection runs. Fixed: the second thread
# queues before any begin, no cycle is open at the hook, and the
# collection's sweep keeps the chain; the collection it queued behind paid
# the debt, so the slice returns true without beginning a cycle (no
# locked hook, no cycle open after), and the main thread's next slice
# begins one under the section on the mprotect barrier. Control
# (`Heap.inc_begins_in_section = false`, the code before): the cycle is
# open at the hook (checked), `@collecting` already false (checked), the
# lazy sweep pending (checked); after the collection the chain is gone
# behind its head (checked), and the open cycle has no barrier (checked).
# The control's sweep took the runtime's own objects with the chain, so it
# reports with no allocation, from a stack buffer, and leaves through
# `_exit` while the slice is still held in its locked hook. Each arm in a
# process of its own. Linux only (the mprotect barrier, as regressions 99,
# 100, 102 and 108 use); elsewhere, and when no cycle can begin on it, the
# child prints the skip mark.
#
# *raise*: the begin runs holding the section, so a raise inside it — a
# before-collect callback, the event hook, the stop — must release the
# section, as every other holder does on a raise. The event hook raises at
# the begin's `PreStopWorld`; then another thread's `collect` must return.
# Fixed: it does, and the half-begun cycle is dropped. Control
# (`Heap.inc_begin_raise_releases_section = false`, this fix's first
# version): the cycle stays open and the `collect` still waits after 5 s;
# the child leaves through `_exit` around it.
# `bench/log/linux/2026-11-07-incremental-begin/FINDINGS.md`.

private INC110_SKIP_MARK          = "inc110: this heap cannot reach the window, skipped"
private INC110_FIXED_MARK         = "inc110: the chain a root holds lived through the collection and the cycle"
private INC110_CONTROL_MARK       = "inc110: control began a cycle inside the collection and its sweep freed the chain"
private INC110_RAISE_FIXED_MARK   = "inc110 raise: the section was released and another thread's collect returned"
private INC110_RAISE_CONTROL_MARK = "inc110 raise: control kept the section and another thread's collect waited"
private INC110_CHAIN              = 20_000

private class Inc110Roots
  class_property head = Pointer(Void).null
  class_property sink = 0_u64
end

class Gcry::Heap
  def inc110_barrier_possible? : Bool
    incremental_barrier_possible?
  end
end

private module Inc110
  @@begin_armed = Atomic(Int32).new(0)
  @@stop_armed = Atomic(Int32).new(0)
  @@locked_armed = Atomic(Int32).new(0)
  @@go = Atomic(Int32).new(0)
  @@collect_go = Atomic(Int32).new(0)
  @@in_post_stop = Atomic(Int32).new(0)
  # 1 when the post-stop hook saw the second thread's ticket.
  @@queued = Atomic(Int32).new(0)
  # At the post-stop hook, once the ticket was seen: a cycle open (1) or
  # not (2); `@collecting` true (1) or false (2); the lazy sweep pending (1)
  # or not (2).
  @@open = Atomic(Int32).new(0)
  @@collecting = Atomic(Int32).new(0)
  @@lazy = Atomic(Int32).new(0)
  # In the slice, holding the section: the cycle's backend mprotect (1) or
  # not (2).
  @@slice_backend = Atomic(Int32).new(0)
  # The control parks the slice here; the child exits around it.
  @@park = Atomic(Int32).new(0)
  @@slice_result = Atomic(Int32).new(0)
  # How far the slicing thread got: 1 running, 2 released, 3 at its begin.
  @@stage = Atomic(Int32).new(0)

  def self.arm(park : Bool) : Nil
    @@park.set(park ? 1 : 0)
    @@begin_armed.set(1)
    @@stop_armed.set(1)
    @@locked_armed.set(1)
  end

  def self.queued? : Bool
    @@queued.get == 1
  end

  def self.open : Int32
    @@open.get
  end

  def self.collecting : Int32
    @@collecting.get
  end

  def self.lazy : Int32
    @@lazy.get
  end

  def self.slice_backend : Int32
    @@slice_backend.get
  end

  def self.slice_result : Int32
    @@slice_result.get
  end

  # Polls the block for up to 10 s. The flags are read in the block, by
  # name: `pointerof` on one of these class variables runs its initializer
  # again (Crystal 1.21's code for it calls the initializer directly), which
  # reset a flag the other thread had just set — a first version that
  # waited through a pointer lost the slicing thread's `collect_go` in 3 of
  # 1 000 control children on headers, 4 of 1 000 under CPU load.
  def self.wait_until(& : -> Bool) : Bool
    deadline = Gcry::Clock.monotonic_ns &+ 10_000_000_000_u64
    until yield
      return false if Gcry::Clock.monotonic_ns > deadline
      Intrinsics.pause
    end
    true
  end

  # On the second thread, after `collect_a_little`'s entry checks. Allocates
  # nothing.
  def self.before_begin : Nil
    return unless @@begin_armed.swap(0) == 1
    @@stage.set(3)
    @@collect_go.set(1)
    wait_until { @@in_post_stop.get == 1 }
  end

  # On the collecting thread, the world running, the section held, before
  # the sweep after the world. Allocates nothing.
  def self.after_stop(phase : Symbol) : Nil
    return unless phase == :after_start_world
    return unless @@stop_armed.swap(0) == 1
    heap = Gcry.default_heap
    @@lazy.set(heap.@lazy_sweep_pending ? 1 : 2)
    queued = heap.@post_stw_next
    @@in_post_stop.set(1)
    deadline = Gcry::Clock.monotonic_ns &+ 10_000_000_000_u64
    loop do
      Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, false)
      if heap.@post_stw_next != queued
        @@queued.set(1)
        break
      end
      break if Gcry::Clock.monotonic_ns > deadline
      Intrinsics.pause
    end
    Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, false)
    @@open.set(heap.@inc_active ? 1 : 2)
    @@collecting.set(heap.@collecting ? 1 : 2)
  end

  # In the slice, holding the section. Allocates nothing.
  def self.locked : Nil
    return unless @@locked_armed.swap(0) == 1
    heap = Gcry.default_heap
    @@slice_backend.set(heap.@barrier_backend.mprotect? ? 1 : 2)
    if @@park.get == 1
      loop { Intrinsics.pause }
    end
  end

  def self.stage : Int32
    @@stage.get
  end

  def self.slicer : Nil
    @@stage.set(1)
    until @@go.get == 1
      Intrinsics.pause
    end
    @@stage.set(2)
    finished = Gcry.default_heap.collect_a_little(Int32::MAX)
    @@slice_result.set(finished ? 1 : 2)
  end

  def self.go : Nil
    @@go.set(1)
  end

  def self.wait_collect_go : Bool
    wait_until { @@collect_go.get == 1 }
  end
end

private def inc110_say(text : String) : Nil
  STDOUT.puts text
  STDOUT.flush
end

# For the control, after its sweep took the runtime's objects: no
# allocation, a stack buffer and `write(2)`.
private def inc110_raw(text : String, value : Int32 = -1) : Nil
  buf = uninitialized StaticArray(UInt8, 256)
  n = 0
  text.to_slice.each do |byte|
    break if n >= 200
    buf[n] = byte
    n += 1
  end
  if value >= 0
    buf[n] = ' '.ord.to_u8
    n += 1
    digits = uninitialized StaticArray(UInt8, 12)
    d = 0
    v = value
    loop do
      digits[d] = ('0'.ord + v % 10).to_u8
      d += 1
      v //= 10
      break if v == 0
    end
    while d > 0
      d -= 1
      buf[n] = digits[d]
      n += 1
    end
  end
  buf[n] = '\n'.ord.to_u8
  n += 1
  LibC.write(1, buf.to_unsafe, n)
end

@[NoInline]
private def inc110_build(heap : Gcry::Heap) : Nil
  head = Pointer(Void).null
  INC110_CHAIN.times do
    node = GC.malloc(16).as(Void**)
    node[0] = head
    head = node.as(Void*)
  end
  Inc110Roots.head = head
  heap.add_root(head)
end

# The stops scan this thread's stack; what `inc110_build`'s frames left
# there is zeroed first.
@[NoInline]
private def inc110_scrub_stack : Nil
  buf = uninitialized StaticArray(UInt64, 8192)
  words = buf.to_unsafe
  8192.times { |i| words[i] = 0_u64 }
  Inc110Roots.sink = words[0] &+ words[8191]
end

# Chain blocks from the head on, up to the first that is no allocated block.
private def inc110_alive(heap : Gcry::Heap) : Int32
  node = Inc110Roots.head
  count = 0
  while count < INC110_CHAIN && !node.null? && heap.find_object(node)
    count += 1
    node = node.as(Void**)[0]
  end
  count
end

private def inc110_child(fixed : Bool) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.disable
    heap.prefer_mprotect_barrier = true
    Gcry::Heap.inc_begins_in_section = fixed
    unless heap.inc110_barrier_possible? && !heap.incremental_in_progress?
      inc110_say("#{INC110_SKIP_MARK}: no incremental cycle can begin on a barrier")
      return
    end
    second = Thread.new { Inc110.slicer }
    inc110_build(heap)
    inc110_scrub_stack
    Gcry::Heap.inc_begin_hook = -> { Inc110.before_begin }
    Gcry::Heap.inc_slice_locked_hook = -> { Inc110.locked }
    heap.post_stw_hook = ->(phase : Symbol) { Inc110.after_stop(phase) }
    Inc110.arm(park: !fixed)
    Inc110.go
    unless Inc110.wait_collect_go
      fail "the slicing thread never reached its begin (stage #{Inc110.stage}, slice result #{Inc110.slice_result})"
    end
    heap.collect
    if fixed
      second.join
      # The collection the slice queued behind paid its debt: it returned
      # true, began nothing and never reached its locked hook.
      queued_slice_backend = Inc110.slice_backend
      open_after = heap.incremental_in_progress?
      alive = inc110_alive(heap)
      # A slice with no collection ahead of it begins the cycle under the
      # section and runs on the barrier (the locked hook is still armed).
      heap.collect_a_little(0)
      own_open = heap.incremental_in_progress?
      own_backend = Inc110.slice_backend
      Gcry::Heap.inc_begin_hook = nil
      Gcry::Heap.inc_slice_locked_hook = nil
      heap.post_stw_hook = nil
      inc110_say("inc110: at the post-stop hook the cycle was #{Inc110.open == 1 ? "open" : "not open"}, " \
                 "@collecting #{Inc110.collecting == 1}, lazy sweep pending #{Inc110.lazy == 1}; " \
                 "the queued slice returned #{Inc110.slice_result == 1}, reached its locked hook " \
                 "#{queued_slice_backend != 0}, left a cycle open #{open_after}; " \
                 "#{alive} of #{INC110_CHAIN} chain blocks alive; the next slice's cycle open #{own_open}, " \
                 "on #{own_backend == 1 ? "mprotect" : "no mprotect barrier"}")
      Inc110.queued?.should be_true
      Inc110.open.should eq(2)
      Inc110.collecting.should eq(1)
      Inc110.slice_result.should eq(1)
      queued_slice_backend.should eq(0)
      open_after.should be_false
      alive.should eq(INC110_CHAIN)
      own_open.should be_true
      own_backend.should eq(1)
      inc110_say(INC110_FIXED_MARK)
    else
      # The slice is parked in its locked hook, holding the section; nothing
      # here allocates.
      alive = inc110_alive(heap)
      barrier_less = heap.incremental_in_progress? && heap.@barrier_backend.none?
      inc110_raw("inc110: control ticket seen (1 yes)", Inc110.queued? ? 1 : 0)
      inc110_raw("inc110: control cycle at the post-stop hook (1 open, 2 not)", Inc110.open)
      inc110_raw("inc110: control @collecting at the post-stop hook (1 true, 2 false)", Inc110.collecting)
      inc110_raw("inc110: control lazy sweep pending (1 yes, 2 no)", Inc110.lazy)
      inc110_raw("inc110: control open cycle with no barrier after the collection (1 yes)", barrier_less ? 1 : 0)
      inc110_raw("inc110: control chain blocks alive of 20000:", alive)
      ok = Inc110.queued? && Inc110.open == 1 && Inc110.collecting == 2 && Inc110.lazy == 1 &&
           barrier_less && alive < INC110_CHAIN
      inc110_raw(ok ? INC110_CONTROL_MARK : "inc110: control did not reach the state it names")
      LibC._exit(ok ? 0 : 1)
    end
  {% else %}
    inc110_say("#{INC110_SKIP_MARK}: Linux only")
  {% end %}
end

private class Inc110RaiseError < Exception
end

private module Inc110Raise
  @@armed = Atomic(Int32).new(0)
  @@done = Atomic(Int32).new(0)

  def self.arm : Nil
    @@armed.set(1)
  end

  # The begin's `PreStopWorld`: `lock_write` held, the world not stopped yet.
  def self.event(event : Gcry::Heap::CollectionEvent) : Nil
    return unless event.pre_stop_world?
    return unless @@armed.swap(0) == 1
    raise Inc110RaiseError.new("inc110: the collection event hook raised in the begin")
  end

  def self.collector : Nil
    Gcry.default_heap.collect
    @@done.set(1)
  end

  # Up to *seconds* for the other thread's `collect` to return.
  def self.wait_done(seconds : Int32) : Bool
    deadline = Gcry::Clock.monotonic_ns &+ seconds.to_u64 * 1_000_000_000_u64
    until @@done.get == 1
      return false if Gcry::Clock.monotonic_ns > deadline
      sleep 10.milliseconds
    end
    true
  end
end

# A begin under the section raises (the event hook, at `PreStopWorld`);
# then another thread's `collect` must get the section.
private def inc110_raise_child(fixed : Bool) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.disable
    heap.prefer_mprotect_barrier = true
    Gcry::Heap.inc_begin_raise_releases_section = fixed
    unless heap.inc110_barrier_possible? && !heap.incremental_in_progress?
      inc110_say("#{INC110_SKIP_MARK}: no incremental cycle can begin on a barrier")
      return
    end
    Inc110Raise.arm
    heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) { Inc110Raise.event(event) }
    raised = false
    begin
      heap.collect_a_little(0)
    rescue Inc110RaiseError
      raised = true
    end
    heap.collection_event_hook = nil
    open_after = heap.incremental_in_progress?
    other = Thread.new { Inc110Raise.collector }
    done = Inc110Raise.wait_done(fixed ? 30 : 5)
    inc110_say("inc110 raise: the begin raised #{raised}; a cycle open after it #{open_after}; " \
               "another thread's collect returned #{done}")
    if fixed
      other.join
      raised.should be_true
      open_after.should be_false
      done.should be_true
      inc110_say(INC110_RAISE_FIXED_MARK)
    else
      # The other thread waits for the section for ever; leave around it.
      ok = raised && open_after && !done
      inc110_say(ok ? INC110_RAISE_CONTROL_MARK : "inc110 raise: control did not reach the state it names")
      LibC._exit(ok ? 0 : 1)
    end
  {% else %}
    inc110_say("#{INC110_SKIP_MARK}: Linux only")
  {% end %}
end

# Runs one child; kills it past *seconds*. Returns its status and output.
private def inc110_run(arm : String, seconds : Int32 = 90) : {Process::Status, String}
  captured = IO::Memory.new
  env = {"GCRY_INC110_CHILD" => arm, "GCRY_IDLE_RELEASE_MS" => "0"} of String => String?
  # The control's sweep frees blocks a root still reaches.
  env["GCRY_DEBUG_INVARIANTS"] = nil if arm == "control"
  child = Process.new(Process.executable_path.not_nil!, ["-e", "inc110 child #{arm}"],
    env: env, output: captured, error: captured)
  deadline = Time.instant + seconds.seconds
  until child.terminated? || Time.instant >= deadline
    sleep 100.milliseconds
  end
  child.terminate(graceful: false) unless child.terminated?
  status = child.wait
  {status, captured.to_s}
end

describe "Regression: an incremental cycle begins inside the collection section" do
  it "fixed arm in a process of its own" do
    status, text = inc110_run("fixed")
    fail "child fixed #{status.inspect}:\n#{text}" unless status.success?
    text.should contain("1 examples, 0 failures")
    text.should contain(INC110_FIXED_MARK) unless text.includes?(INC110_SKIP_MARK)
  end

  # The control leaves through `_exit` before the spec runner reports.
  it "control arm in a process of its own" do
    status, text = inc110_run("control")
    fail "child control #{status.inspect}:\n#{text}" unless status.success?
    if text.includes?(INC110_SKIP_MARK)
      text.should contain("1 examples, 0 failures")
    else
      text.should contain(INC110_CONTROL_MARK)
    end
  end

  it "raise: fixed arm in a process of its own" do
    status, text = inc110_run("raise-fixed")
    fail "child raise-fixed #{status.inspect}:\n#{text}" unless status.success?
    text.should contain("1 examples, 0 failures")
    text.should contain(INC110_RAISE_FIXED_MARK) unless text.includes?(INC110_SKIP_MARK)
  end

  # The control leaves through `_exit` with the other thread still waiting.
  it "raise: control arm keeps the section held" do
    status, text = inc110_run("raise-control")
    fail "child raise-control #{status.inspect}:\n#{text}" unless status.success?
    if text.includes?(INC110_SKIP_MARK)
      text.should contain("1 examples, 0 failures")
    else
      text.should contain(INC110_RAISE_CONTROL_MARK)
    end
  end

  it "inc110 child fixed" do
    next unless ENV["GCRY_INC110_CHILD"]? == "fixed"
    inc110_child(fixed: true)
  end

  it "inc110 child control" do
    next unless ENV["GCRY_INC110_CHILD"]? == "control"
    inc110_child(fixed: false)
  end

  it "inc110 child raise-fixed" do
    next unless ENV["GCRY_INC110_CHILD"]? == "raise-fixed"
    inc110_raise_child(fixed: true)
  end

  it "inc110 child raise-control" do
    next unless ENV["GCRY_INC110_CHILD"]? == "raise-control"
    inc110_raise_child(fixed: false)
  end
end
