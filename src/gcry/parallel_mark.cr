# Parallel mark.
#
# Library heaps (`stop_the_world == false`): Crystal::Thread helpers steal grey
# work under `@mark_lock`.
#
# Process GC (`stop_the_world`): Crystal::Thread would freeze in `stop_world`, so
# helpers are raw `LibC.pthread_create` threads (not registered with Crystal).
# They only touch mark state / heap headers — no Fiber, no managed alloc.
#
# Fields (@parallel_mark_workers, …) are declared/initialized in heap.cr.

require "c/pthread"

lib LibC
  fun pthread_create(thread : PthreadT*, attr : PthreadAttrT*, start : Void* -> Void*, arg : Void*) : Int
  fun pthread_join(thread : PthreadT, retval : Void**) : Int
end

# C ABI entry — must not be a Crystal::Thread so STW will not suspend it.
fun gcry_mark_worker_main(arg : Void*) : Void*
  Gcry::Heap.run_mark_worker(arg)
  Pointer(Void).null
end

module Gcry
  class Heap
    MAX_MARK_PTHREADS = 15

    def parallel_mark_workers : Int32
      @parallel_mark_workers
    end

    def parallel_mark_workers=(value : Int32) : Int32
      @parallel_mark_workers = value.clamp(1, 16)
    end

    def parallel_mark_runs : UInt64
      @parallel_mark_runs
    end

    def parallel_mark_stolen : UInt64
      @parallel_mark_stolen
    end

    # Entry for `gcry_mark_worker_main` (raw pthread).
    def self.run_mark_worker(arg : Void*) : Nil
      arg.as(Heap).mark_worker_loop
    end

    protected def ensure_mark_worker_pool : Nil
      return if @parallel_mark_workers <= 1

      need = @parallel_mark_workers - 1
      if @stop_the_world
        ensure_mark_pthreads(need)
      else
        ensure_mark_crystal_threads(need)
      end
    end

    private def ensure_mark_crystal_threads(need : Int32) : Nil
      while @mark_worker_threads.size < need
        heap = self
        @mark_worker_threads << Thread.new do
          heap.mark_worker_loop
        end
      end
      @mark_pthread_mode = false
    end

    private def ensure_mark_pthreads(need : Int32) : Nil
      return if @mark_pthread_count >= need

      @mark_pthread_mode = true
      while @mark_pthread_count < need && @mark_pthread_count < MAX_MARK_PTHREADS
        tid = uninitialized LibC::PthreadT
        rc = LibC.pthread_create(
          pointerof(tid),
          Pointer(LibC::PthreadAttrT).null,
          ->gcry_mark_worker_main(Void*),
          self.as(Void*),
        )
        break if rc != 0
        @mark_pthreads[@mark_pthread_count] = tid
        @mark_pthread_count += 1
      end
    end

    protected def shutdown_mark_workers : Nil
      @mark_shutdown.set(1)
      @mark_epoch.add(1)

      if @mark_pthread_mode || @mark_pthread_count > 0
        @mark_pthread_count.times do |i|
          LibC.pthread_join(@mark_pthreads[i], Pointer(Void*).null)
        end
        @mark_pthread_count = 0
        @mark_pthread_mode = false
      end

      unless @mark_worker_threads.empty?
        @mark_worker_threads.each &.join
        @mark_worker_threads.clear
      end

      @mark_shutdown.set(0)
      @mark_workers_busy.set(0)
      @mark_parallel = false
    end

    # Abandon helpers after fork (only the forking thread survives).
    protected def reset_mark_workers_after_fork : Nil
      @mark_worker_threads.clear
      @mark_pthread_count = 0
      @mark_pthread_mode = false
      @mark_parallel = false
      @mark_shutdown.set(0)
      @mark_workers_busy.set(0)
      @mark_lock = Crystal::SpinLock.new
      @mark_epoch = Atomic(UInt64).new(0_u64)
    end

    # Helper loop (Crystal::Thread or raw pthread). No managed-heap alloc.
    protected def mark_worker_loop : Nil
      local_epoch = 0_u64
      while @mark_shutdown.get == 0
        epoch = @mark_epoch.get
        if epoch == local_epoch
          Intrinsics.pause
          next
        end
        local_epoch = epoch
        next if @mark_shutdown.get != 0

        @mark_workers_busy.add(1)
        begin
          while @mark_parallel && @mark_shutdown.get == 0
            header = pop_mark_header(steal: true)
            break unless header
            scan_object(header)
          end
        ensure
          @mark_workers_busy.add(-1)
        end
      end
    end

    private def pop_mark_header(*, steal : Bool) : BlockHeader*?
      @mark_lock.lock
      begin
        return nil if @mark_stack.empty?
        header = @mark_stack.pop
        @parallel_mark_stolen += 1 if steal
        header
      ensure
        @mark_lock.unlock
      end
    end

    private def mark_loop : Nil
      if @parallel_mark_workers > 1
        @parallel_mark_runs += 1
      end

      if @parallel_mark_workers <= 1
        until @mark_stack.empty?
          header = @mark_stack.pop
          scan_object(header)
        end
        return
      end

      ensure_mark_worker_pool
      # No helpers available (pthread_create failed) → serial.
      helpers = @mark_pthread_mode ? @mark_pthread_count : @mark_worker_threads.size
      if helpers == 0
        until @mark_stack.empty?
          header = @mark_stack.pop
          scan_object(header)
        end
        return
      end

      @mark_parallel = true
      @mark_epoch.add(1)
      begin
        loop do
          progressed = false
          while (header = pop_mark_header(steal: false))
            progressed = true
            scan_object(header)
          end
          busy = @mark_workers_busy.get
          empty = begin
            @mark_lock.lock
            begin
              @mark_stack.empty?
            ensure
              @mark_lock.unlock
            end
          end
          break if empty && busy == 0 && !progressed
          Intrinsics.pause unless progressed
        end
      ensure
        @mark_parallel = false
        @mark_epoch.add(1)
        until @mark_workers_busy.get == 0
          Intrinsics.pause
        end
      end
    end
  end
end
