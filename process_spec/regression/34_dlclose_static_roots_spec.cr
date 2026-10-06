{% skip_file unless flag?(:linux) %}

require "../../src/gcry"
require "spec"

# A library that is `dlclose`d takes its writable ranges out of the static
# scan. Until 2026-10-06 the collapse diagnostic, which compares each
# collection's scanned bytes against the most any collection scanned, read
# that as globals going missing: "gcry: static roots collapsed to … — globals
# are not roots this collection" on stderr and `static_scanned_drops` + 1,
# for nothing but a library leaving. The baseline now drops by what the
# library table lost; ranges that vanish while their object stays loaded
# still count, which the second example holds.
module DlcloseStaticRootsSpec
  # Big enough that losing it halves the scan of any spec binary: the
  # diagnostic fires below half the maximum.
  C_SOURCE = <<-C
    char gcry_dlclose_bss[64 << 20];
    void *gcry_dlclose_bss_addr(void) { return gcry_dlclose_bss; }
    C

  BSS_BYTES = 64_u64 << 20

  @@library : String? = nil

  # Builds the library once per process; nil when there is no C compiler.
  def self.library : String?
    @@library ||= begin
      return nil unless Process.find_executable("cc")
      dir = File.tempname("gcry_dlclose_roots")
      Dir.mkdir(dir)
      src = File.join(dir, "bss.c")
      File.write(src, C_SOURCE)
      out = File.join(dir, "libgcry_dlclose_bss.so")
      status = Process.run("cc", ["-shared", "-fPIC", "-O0", "-o", out, src],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      raise "cc failed: #{status}" unless status.success?
      out
    end
  end

  def self.open : Void*
    so_path = library
    pending! "no C compiler (cc) on PATH" unless so_path
    handle = LibC.dlopen(so_path, LibC::RTLD_NOW)
    raise "dlopen failed" if handle.null?
    handle
  end
end

describe "static roots across dlclose" do
  it "does not count an unloaded library's ranges as a collapse" do
    heap = Gcry.default_heap
    handle = DlcloseStaticRootsSpec.open
    GC.collect
    loaded = heap.static_scanned_last
    # The library's `.bss` was scanned, or there is nothing to lose.
    loaded.should be >= DlcloseStaticRootsSpec::BSS_BYTES
    drops = heap.static_scanned_drops
    LibC.dlclose(handle).should eq 0
    GC.collect
    # And it really left the scan, by more than the diagnostic's half.
    (heap.static_scanned_last * 2 < loaded).should be_true
    heap.static_scanned_drops.should eq drops
  end

  it "still counts ranges that vanish while their library stays loaded" do
    heap = Gcry.default_heap
    handle = DlcloseStaticRootsSpec.open
    begin
      GC.collect
      heap.static_scanned_last.should be >= DlcloseStaticRootsSpec::BSS_BYTES
      drops = heap.static_scanned_drops
      # Same bytes gone from the scan, but the loader still has the library:
      # what a lost range looks like, and what the diagnostic is for.
      Gcry::Platform.shared_lib_roots = false
      GC.collect
      heap.static_scanned_drops.should eq drops + 1
    ensure
      Gcry::Platform.shared_lib_roots = true
      LibC.dlclose(handle)
    end
  end
end
