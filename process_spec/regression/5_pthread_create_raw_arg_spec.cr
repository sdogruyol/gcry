require "../../src/gcry"
require "spec"

# The allocation fast path ends when a second mutator thread is created, and
# the runtime's SYSMON thread is exempt by name. The exemption first read
# `pthread_create`'s `arg` as a `Thread` outright; Crystal's `Thread` passes
# itself, but a raw caller passes anything, and `make thread-birth-root`
# passes an obfuscated integer — SIGSEGV at address 0 on x86_64 CI, at
# 0xc7c7…cb on aarch64 (run 33930621625). The regime and its exemption are
# gone (per-thread cursor sets; see 7_sysmon_alloc_race_spec.cr) and `arg`
# is never read.
{% if flag?(:linux) %}
  describe "GC.pthread_create with an argument that is not a Thread" do
    it "does not read it, and still ends the single-mutator regime" do
      handle = uninitialized LibC::PthreadT
      # Non-canonical on x86_64 and unmapped everywhere: any read faults.
      arg = Pointer(Void).new(0xc7c7c7c7c7c7c7c8_u64)
      rc = GC.pthread_create(
        thread: pointerof(handle),
        attr: Pointer(LibC::PthreadAttrT).null,
        start: ->(_x : Void*) { Pointer(Void).null },
        arg: arg,
      )
      rc.should eq(0)
      LibC.pthread_join(handle, nil)
      Gcry.default_heap.not_nil!.heap_counters_atomic.should be_true
    end

    it "does not read a heap pointer that is not a Thread either" do
      block = GC.malloc(64)
      handle = uninitialized LibC::PthreadT
      rc = GC.pthread_create(
        thread: pointerof(handle),
        attr: Pointer(LibC::PthreadAttrT).null,
        start: ->(_x : Void*) { Pointer(Void).null },
        arg: block,
      )
      rc.should eq(0)
      LibC.pthread_join(handle, nil)
      Gcry.default_heap.not_nil!.heap_counters_atomic.should be_true
    end
  end
{% end %}
