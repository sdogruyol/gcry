{% skip_file unless flag?(:linux) %}

require "../../src/gcry"
require "spec"

# A library `dlopen`ed since the last collection is taken into the root
# table by the next one, which walks the loader's `r_debug` list. Until
# 2026-10-07 the walk took a new entry only while `r_state` read
# `RT_CONSISTENT`: a collection that stopped the world while another thread
# was inside `dlopen` or `dlclose` skipped every library loaded since the
# last collection, so a GC pointer already stored in one of their globals
# was not a root and its object was swept. Boehm re-walks
# `dl_iterate_phdr` under the loader lock each collection and never misses
# a fully loaded object. Here the base namespace is held in `RT_ADD` across
# the collections, as a concurrent `dlopen` would hold it, with nothing else
# loading meanwhile.
module LibrarySyncDuringDlopenSpec
  C_SOURCE = <<-C
    static void *slot;
    void gcry_sync_keep(void *p) { slot = p; }
    void *gcry_sync_get(void) { return slot; }
    C

  RT_ADD = 1

  class Held
    TAG   = 0x0dd5_eed5_c0de_f00d_u64
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

  # Builds the library; nil when there is no C compiler. Its own name, so
  # no other spec in the binary has loaded it, and the table has not.
  def self.library : String?
    return nil unless Process.find_executable("cc")
    dir = File.tempname("gcry_sync_roots")
    Dir.mkdir(dir)
    src = File.join(dir, "sync_root.c")
    File.write(src, C_SOURCE)
    out = File.join(dir, "libgcry_sync_root.so")
    status = Process.run("cc", ["-shared", "-fPIC", "-O0", "-o", out, src],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    raise "cc failed: #{status}" unless status.success?
    out
  end

  # In a frame of its own that has returned before the first collection, so
  # the library's global is the only copy the collector could find.
  @[NoInline]
  def self.plant(keep : Void*) : Nil
    Proc(Void*, Nil).new(keep, Pointer(Void).null).call(Held.new.as(Void*))
  end

  # `r_debug.r_state`: `int r_version; link_map* r_map; addr r_brk; int r_state`.
  def self.r_state(rd : Void*) : Int32*
    Pointer(Int32).new(rd.address &+ 24)
  end
end

describe "a library loaded since the last collection" do
  it "is a root when the collection finds the loader mid-dlopen" do
    so_path = LibrarySyncDuringDlopenSpec.library
    pending! "no C compiler (cc) on PATH" unless so_path
    # glibc exports the base namespace's `r_debug` under this name; it is the
    # one `DT_DEBUG` points at, which the collector reads.
    rd = LibC.dlsym(Pointer(Void).null, "_r_debug")
    pending! "loader exports no _r_debug" if rd.null?
    state = LibrarySyncDuringDlopenSpec.r_state(rd)
    state.value.should eq 0
    heap = Gcry.default_heap
    poison = heap.poison_freed
    heap.poison_freed = true
    handle = LibC.dlopen(so_path, LibC::RTLD_NOW)
    raise "dlopen failed" if handle.null?
    keep = LibC.dlsym(handle, "gcry_sync_keep")
    get = LibC.dlsym(handle, "gcry_sync_get")
    raise "symbol not resolved" if keep.null? || get.null?
    # Nothing allocates between `dlopen` and here, so no collection has
    # taken the library while the list was consistent.
    state.value = LibrarySyncDuringDlopenSpec::RT_ADD
    held = Pointer(Void).null
    before = LibrarySyncDuringDlopenSpec::Held.finalized
    begin
      LibrarySyncDuringDlopenSpec.plant(keep)
      sink = [] of Array(UInt64)
      5.times do
        # Churn the object's size class so a freed block is handed back out
        # and overwritten even if poisoning were off.
        20_000.times { sink << Array(UInt64).new(LibrarySyncDuringDlopenSpec::Held::WORDS, 0_u64) }
        sink.clear
        GC.collect
      end
      held = Proc(Void*).new(get, Pointer(Void).null).call
    ensure
      state.value = 0
      heap.poison_freed = poison
    end
    held.null?.should be_false
    LibrarySyncDuringDlopenSpec::Held.finalized.should eq before
    held.as(LibrarySyncDuringDlopenSpec::Held).intact?.should be_true
    LibC.dlclose(handle)
  end
end
