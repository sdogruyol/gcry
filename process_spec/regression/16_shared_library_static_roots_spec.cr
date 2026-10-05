{% skip_file unless flag?(:linux) %}

require "../../src/gcry"
require "spec"

# A shared object's writable data is a root. Boehm scans every loaded
# object's data (`GC_register_dynamic_libraries`); gcry scanned only the
# executable's until 2026-10-05, so a C library — or Crystal code in a `.so` —
# whose only copy of a GC pointer sat in one of its own globals had that
# object swept under it. Two ways in, two code paths in
# `platform/linux_roots.cr`: a library the loader mapped before `GC.init`
# (here `LD_PRELOAD`), taken by the init-time `dl_iterate_phdr` walk, and one
# `dlopen`ed afterwards, found by the per-collection walk of the loader's
# `r_debug` list.
module SharedLibRootSpec
  C_SOURCE = <<-C
    static void *slot;
    void gcry_so_keep(void *p) { slot = p; }
    void *gcry_so_get(void) { return slot; }
    C

  class Held
    TAG   = 0x5eed_c0de_0bad_f00d_u64
    WORDS =                        32

    @@finalized = Atomic(Int32).new(0)

    def self.finalized : Int32
      @@finalized.get
    end

    @tag : UInt64
    @words : StaticArray(UInt64, WORDS)

    def initialize
      @tag = TAG
      @words = StaticArray(UInt64, WORDS).new { |i| TAG &+ i }
    end

    def intact? : Bool
      return false unless @tag == TAG
      WORDS.times { |i| return false unless @words[i] == TAG &+ i }
      true
    end

    def finalize
      @@finalized.add(1)
    end
  end

  @@library : String? = nil

  # Builds the library once per process; nil when there is no C compiler.
  def self.library : String?
    @@library ||= begin
      return nil unless Process.find_executable("cc")
      dir = File.tempname("gcry_so_roots")
      Dir.mkdir(dir)
      src = File.join(dir, "so_root.c")
      File.write(src, C_SOURCE)
      out = File.join(dir, "libgcry_so_root.so")
      status = Process.run("cc", ["-shared", "-fPIC", "-O0", "-o", out, src],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      raise "cc failed: #{status}" unless status.success?
      out
    end
  end

  # In a frame of its own that has returned before the first collection, so
  # the library's global is the only copy the collector could find. Not in
  # a spawned fiber: a finished fiber's stack went on being found holding the
  # object, which made the red arm (library roots off) pass.
  @[NoInline]
  def self.plant(keep : Void*) : Nil
    Proc(Void*, Nil).new(keep, Pointer(Void).null).call(Held.new.as(Void*))
  end

  # True when the object the library holds survived intact: no finalizer
  # ran for it and, with freed payloads poisoned, every word reads back.
  def self.survives?(keep : Void*, get : Void*) : Bool
    raise "symbol not resolved" if keep.null? || get.null?
    heap = Gcry.default_heap
    poison = heap.poison_freed
    heap.poison_freed = true
    begin
      before = Held.finalized
      plant(keep)
      sink = [] of Array(UInt64)
      5.times do
        # Churn the size class the object came from, so a freed block is
        # handed back out and overwritten even if poisoning were off.
        20_000.times { sink << Array(UInt64).new(Held::WORDS, 0_u64) }
        sink.clear
        GC.collect
      end
      held = Proc(Void*).new(get, Pointer(Void).null).call
      return false if held.null?
      Held.finalized == before && held.as(Held).intact?
    ensure
      heap.poison_freed = poison
    end
  end
end

# Child mode: the spec re-runs its own binary with the library preloaded,
# because a library mapped before `GC.init` cannot be produced from inside an
# already-running process.
if ENV["GCRY_SO_ROOT_CHILD"]?
  ok = SharedLibRootSpec.survives?(LibC.dlsym(Pointer(Void).null, "gcry_so_keep"),
    LibC.dlsym(Pointer(Void).null, "gcry_so_get"))
  STDOUT.puts(ok ? "intact" : "lost")
  STDOUT.flush
  LibC._exit(ok ? 0 : 1)
end

describe "a GC pointer held only in a shared library's global" do
  it "survives when the library is dlopen'ed after GC.init" do
    so_path = SharedLibRootSpec.library
    pending! "no C compiler (cc) on PATH" unless so_path
    handle = LibC.dlopen(so_path, LibC::RTLD_NOW)
    handle.null?.should be_false
    SharedLibRootSpec.survives?(LibC.dlsym(handle, "gcry_so_keep"),
      LibC.dlsym(handle, "gcry_so_get")).should be_true
  end

  it "survives when the library is loaded before GC.init" do
    so_path = SharedLibRootSpec.library
    pending! "no C compiler (cc) on PATH" unless so_path
    output = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!,
      env: {"LD_PRELOAD" => so_path, "GCRY_SO_ROOT_CHILD" => "1"},
      output: output, error: Process::Redirect::Inherit)
    output.to_s.strip.should eq("intact")
    status.success?.should be_true
  end
end
