require "../../src/gcry"
require "spec"

# Every `Thread` is rooted from `pthread_create` until its thread is done with
# it (`src/gcry/thread_birth_root.cr`), and the root is released through the
# thread's slot in the birth table. The table was 256 slots until 2026-10-06:
# with more threads than that alive at once, every birth past the 256th found
# no slot, was rooted anyway, and could never be released — its `Thread`, the
# closure and the main `Fiber` it holds, pinned for the life of the process
# after the thread was long joined. Boehm's thread table is unbounded. The
# birth table now grows a segment at a time.
{% if flag?(:gc_none) %}
  describe "thread birth roots past 256 live threads" do
    it "releases every root once its thread is joined" do
      threads = 300
      # The first collection can start a collector thread of its own, which
      # keeps its root for as long as it lives: born before the baseline, so
      # it is part of it.
      GC.collect
      baseline = Gcry::ThreadBirthRoot.outstanding
      overflows = Gcry::ThreadBirthRoot.overflows
      ready = Atomic(Int32).new(0)
      go = Atomic(Int32).new(0)
      workers = [] of Thread
      begin
        threads.times do
          workers << Thread.new do
            ready.add(1)
            until go.get != 0
              Thread.yield
            end
          end
        end
        until ready.get == threads
          Thread.yield
        end
        # All of them alive at once: this is the moment the old table ran out.
        Gcry::ThreadBirthRoot.outstanding.should be >= baseline + threads
        Gcry::ThreadBirthRoot.capacity.should be >= baseline + threads
      ensure
        go.set(1)
        workers.each(&.join)
      end
      # A joined thread's root is stamped for the next collection and dropped
      # at the one after (`release_dead`), so at least three collections. On
      # Windows the root ends only once gcry's own handle on the thread
      # signals (`release_exited`), and `join` does not wait for that: a
      # thread that finished its block first detached itself in
      # `Thread#start`, and `Thread#join` of a detached thread returns
      # without `WaitForSingleObject`. Three collections straight after the
      # joins left 5-121 roots of threads still exiting, 11 runs in 20 on a
      # 12-vCPU Windows VM (2026-10-06). So collect until they are back, under
      # a deadline a table that never releases (the bug) still runs into.
      deadline = Time.instant + 5.seconds
      collected = 0
      loop do
        GC.collect
        collected += 1
        break if collected >= 3 && Gcry::ThreadBirthRoot.outstanding <= baseline
        break if Time.instant > deadline
        sleep 1.millisecond
      end
      Gcry::ThreadBirthRoot.overflows.should eq overflows
      Gcry::ThreadBirthRoot.outstanding.should be <= baseline
    end
  end
{% end %}
