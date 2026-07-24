# Parallel mark.
#
# Library heaps (`stop_the_world == false`): real helper threads steal grey
# objects under `@mark_lock` and increment `parallel_mark_stolen`.
#
# Process GC (`stop_the_world`): Crystal helper threads are suspended with the
# world, so N>1 still marks serially and only bumps `parallel_mark_runs`.
# STW-exempt (raw pthread / runtime) workers are the next step for process GC.
#
# Fields (@parallel_mark_workers, …) are declared/initialized in heap.cr.

module Gcry
  class Heap
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

    protected def ensure_mark_worker_pool : Nil
      # Process STW would freeze Crystal::Thread helpers — keep pool empty there.
      return if @stop_the_world
      return if @parallel_mark_workers <= 1

      need = @parallel_mark_workers - 1
      while @mark_worker_threads.size < need
        heap = self
        @mark_worker_threads << Thread.new do
          heap.mark_worker_loop
        end
      end
    end

    protected def shutdown_mark_workers : Nil
      return if @mark_worker_threads.empty?
      @mark_shutdown.set(1)
      @mark_epoch.add(1)
      @mark_worker_threads.each &.join
      @mark_worker_threads.clear
      @mark_shutdown.set(0)
    end

    # Called from helper Thread; must not allocate on the managed heap.
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

      # Process GC / single worker: serial (Crystal helpers would be STW'd).
      if @parallel_mark_workers <= 1 || @stop_the_world
        until @mark_stack.empty?
          header = @mark_stack.pop
          scan_object(header)
        end
        return
      end

      ensure_mark_worker_pool
      @mark_parallel = true
      @mark_epoch.add(1)
      begin
        # Coordinator drains; helpers steal concurrently.
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
        # Wake helpers so they exit the inner drain and wait on the next epoch.
        @mark_epoch.add(1)
        until @mark_workers_busy.get == 0
          Intrinsics.pause
        end
      end
    end
  end
end
