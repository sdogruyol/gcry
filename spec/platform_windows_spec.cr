require "./spec_helper"

{% if flag?(:win32) %}
  module WindowsPlatformSpec
    class_property root : Void* = Pointer(Void).null
    @@destructors = Atomic(Int32).new(0)

    def self.destructors : Int32
      @@destructors.get
    end

    def self.destroy(value : Void*) : Nil
      @@destructors.add(1)
    end
  end

  describe "Windows platform" do
    it "retains a class-variable root from the main PE image without scanning stacks" do
      heap = Gcry::Heap.new
      begin
        heap.scan_static_roots = true
        WindowsPlatformSpec.root = heap.malloc(32)
        heap.collect(scan_stack: false)
        heap.live?(WindowsPlatformSpec.root).should be_true
        Gcry::Platform.static_root_bytes.should be > 0
        Gcry::Platform.static_root_overflow.should eq 0
        Gcry::Platform.static_root_bss_lost.should eq 0
      ensure
        WindowsPlatformSpec.root = Pointer(Void).null
        heap.destroy
      end
    end

    it "recommits zeroed pages without releasing the reservation or adjacent live pages" do
      page = Gcry::Platform.host_page_size
      memory = Gcry::OS.mmap(nil, page * 3, Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
        Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, 0).as(UInt8*)
      memory.null?.should be_false
      begin
        memory.to_slice((page * 3).to_i).fill(0xAB_u8)
        Gcry::Platform.release_physical_pages(memory.address + page, page).should be_true
        memory[0].should eq 0xAB_u8
        memory[page * 2].should eq 0xAB_u8
        (memory + page).to_slice(page.to_i).all?(&.zero?).should be_true
        Gcry::Platform.release_physical_pages(memory.address + 1, page).should be_false
      ensure
        Gcry::OS.munmap(memory, page * 3).should eq 0
      end
    end

    it "skips a guard page in the middle of a root range without consuming the guard" do
      page = Gcry::Platform.host_page_size
      memory = Gcry::OS.mmap(nil, page * 3, Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
        Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, 0).as(UInt8*)
      memory.null?.should be_false
      begin
        memory.as(UInt64*).value = 0x12345678_u64
        (memory + page * 2).as(UInt64*).value = 0x87654321_u64
        LibC.VirtualProtect(memory + page, page, LibC::PAGE_READWRITE | LibC::PAGE_GUARD, out old).should_not eq 0
        first = false
        last = false
        Gcry::Roots.scan_range(memory.as(Void*), (memory + page * 3).as(Void*), safe: true) do |candidate|
          first ||= candidate.address == 0x12345678_u64
          last ||= candidate.address == 0x87654321_u64
        end
        first.should be_true
        last.should be_true
        LibC.VirtualQuery(memory + page, out info, sizeof(LibC::MEMORY_BASIC_INFORMATION)).should_not eq 0
        (info.protect & LibC::PAGE_GUARD).should_not eq 0
      ensure
        Gcry::OS.munmap(memory, page * 3)
      end
    end

    it "runs TLS destructors on thread exit, but not when deleting the key" do
      key = uninitialized Gcry::OS::GcryPthreadKeyT
      Gcry::OS.pthread_key_create(pointerof(key), ->WindowsPlatformSpec.destroy(Void*)).should eq 0
      before = WindowsPlatformSpec.destructors
      begin
        thread = Thread.new do
          Gcry::OS.pthread_setspecific(key, Pointer(Void).new(1_u64)).should eq 0
        end
        thread.join
        WindowsPlatformSpec.destructors.should eq before + 1
        Gcry::OS.pthread_setspecific(key, Pointer(Void).new(2_u64)).should eq 0
      ensure
        Gcry::OS.pthread_key_delete(key).should eq 0
      end
      WindowsPlatformSpec.destructors.should eq before + 1
    end

    it "uses distinct thread IDs instead of the current-thread pseudo handle" do
      current = Gcry::Platform.current_thread_id
      other = 0_u64
      Thread.new { other = Gcry::Platform.current_thread_id }.join
      other.should_not eq current
      other.should_not eq 0
    end

    it "resumes threads and releases collector locks when suspension capacity is exceeded" do
      heap = Gcry::Heap.new
      ready = Atomic(Int32).new(0)
      finish = Atomic(Int32).new(0)
      workers = [] of Thread
      begin
        heap.stop_the_world = true
        65.times do
          workers << Thread.new do
            ready.add(1)
            while finish.get == 0
              LibC.Sleep(1)
            end
          end
        end
        until ready.get == workers.size
          Thread.yield
        end
        expect_raises(Exception, /Windows thread suspension/) { heap.stop_world }
      ensure
        finish.set(1)
        workers.each(&.join)
      end
      begin
        # A second suspension proves the failed attempt released Thread.lock
        # and reset ownership, rather than leaving the collector half stopped.
        heap.stop_world
        heap.start_world
        heap.malloc(16).null?.should be_false
      ensure
        heap.start_world
        heap.destroy
      end
    end

    it "captures suspended integer and nonvolatile XMM registers" do
      ready = Atomic(Int32).new(0)
      finish = Atomic(Int32).new(0)
      worker = Thread.new do
        asm("movabsq $$0x12345678ABCDEF01, %r12
             movabsq $$0x23456789ABCDEF02, %rax
             movq %rax, %xmm15
             xorq %rax, %rax
             movl $$1, ($0)
             1:
             pause
             cmpl $$0, ($1)
             je 1b"
                :: "r"(pointerof(ready)), "r"(pointerof(finish))
                : "rax", "r12", "xmm15", "memory", "cc"
                : "volatile")
      end
      begin
        until ready.get == 1
          Thread.yield
        end
        integer_root = false
        xmm_root = false
        captured_sp = false
        Gcry::Platform.stop_world_threads(Thread.current)
        begin
          captured_sp = !Gcry::Platform.thread_sp(worker.to_unsafe).nil?
          Gcry::Platform.each_thread_greg(worker.to_unsafe) do |candidate|
            integer_root ||= candidate.address == 0x1234_5678_ABCD_EF01_u64
            xmm_root ||= candidate.address == 0x2345_6789_ABCD_EF02_u64
          end
        ensure
          Gcry::Platform.start_world_threads(Thread.current)
          Gcry::Platform.clear_thread_sps
        end
        captured_sp.should be_true
        integer_root.should be_true
        xmm_root.should be_true
        # Saved contexts reside in the PE image. They must disappear from
        # that root source after resume, even if this worker later exits.
        stale = false
        Gcry::Platform.scan_static_roots do |low, high|
          Gcry::Roots.scan_range_chunked(low, high, safe: true) do |candidate|
            stale ||= candidate.address == 0x2345_6789_ABCD_EF02_u64
          end
        end
        stale.should be_false
      ensure
        finish.set(1)
        worker.join
      end
    end
  end
{% end %}
