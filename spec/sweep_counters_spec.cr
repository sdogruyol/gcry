require "./spec_helper"

class Gcry::Heap
  def prepare_sweep_counters_for_spec : Nil
    @collecting = true
    @world_stopped = false
    @free_bytes.set(1_000_000_u64)
    @live_objects.set(1_000_000_u64)
  end

  def end_sweep_counters_for_spec : Nil
    @collecting = false
  end

  def sweep_credit_for_spec : Nil
    free_bytes_add(1_u64)
    live_objects_sub(1_u64)
  end

  def mutator_debit_for_spec : Nil
    free_bytes_sub(1_u64)
    @live_objects.add(1_u64)
  end
end

describe "counters while lazy sweep runs beside mutators" do
  [false, true].each do |bitmap|
    {% if flag?(:gcry_headerless) %}
      next unless bitmap
    {% end %}
    it "keeps increments and decrements whole (bitmap=#{bitmap})" do
      heap = Gcry::Heap.new
      begin
        heap.bitmap_alloc = bitmap
        # Bitmap allocation must imply atomicity even with the explicit flag off.
        heap.heap_counters_atomic = !bitmap
        heap.prepare_sweep_counters_for_spec
        ready = Atomic(Int32).new(0)
        workers = [false, true].map do |sweeper|
          Thread.new do
            ready.add(1)
            while ready.get < 2
              Thread.yield
            end
            100_000.times do
              sweeper ? heap.sweep_credit_for_spec : heap.mutator_debit_for_spec
            end
          end
        end
        workers.each(&.join)
        heap.free_bytes.should eq(1_000_000_u64)
        heap.live_objects.should eq(1_000_000_u64)
      ensure
        heap.end_sweep_counters_for_spec
        heap.destroy
      end
    end
  end
end
