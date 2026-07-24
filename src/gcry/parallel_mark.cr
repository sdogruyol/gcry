# Parallel mark API.
#
# True multi-threaded mark under Crystal STW is blocked by the runtime: helper
# threads are suspended with the world. Until Crystal exposes STW-exempt GC
# workers, N>1 still marks serially and increments `parallel_mark_runs`.
# Alloc-side parallelism: TLAB (`GCRY_TLAB=1`).
#
# Fields (@parallel_mark_workers, …) are declared/initialized in heap.cr.

module Gcry
  class Heap
    def parallel_mark_workers : Int32
      @parallel_mark_workers
    end

    def parallel_mark_workers=(value : Int32) : Int32
      @parallel_mark_workers = value
    end

    def parallel_mark_runs : UInt64
      @parallel_mark_runs
    end

    def parallel_mark_stolen : UInt64
      @parallel_mark_stolen
    end

    protected def ensure_mark_worker_pool : Nil
    end

    private def mark_loop : Nil
      if @parallel_mark_workers > 1
        @parallel_mark_runs += 1
      end
      until @mark_stack.empty?
        header = @mark_stack.pop
        scan_object(header)
      end
    end
  end
end
