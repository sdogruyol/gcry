{% skip_file unless flag?(:win32) %}

require "../../src/gcry"
require "spec"

# A loaded DLL's writable data is a root on Windows, as under Boehm: since
# 2026-10-05 `platform/windows_roots.cr` walks every writable `MEM_IMAGE`
# region again whenever a DLL notification moves the module generation. Until
# 2026-10-06 nothing ran that walk: `16_shared_library_static_roots_spec` and
# `34_dlclose_static_roots_spec` are Linux-only, and no gate loads a library.
# This builds a DLL whose global is the only copy of a GC pointer, loads it
# after `GC.init`, and checks the object survives; with library roots off
# (`Gcry::Platform.shared_lib_roots = false`) the same object must be swept,
# or the first example could pass on a collector that keeps everything.
module DllRootSpec
  C_SOURCE = <<-C
    static void *slot;
    __declspec(dllexport) void gcry_dll_keep(void *p) { slot = p; }
    __declspec(dllexport) void *gcry_dll_get(void) { return slot; }
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

  # Builds the DLL once per process; nil when there is no C compiler.
  def self.library : String?
    @@library ||= begin
      dir = File.tempname("gcry_dll_roots")
      Dir.mkdir(dir)
      File.write(File.join(dir, "dll_root.c"), C_SOURCE)
      dll = File.join(dir, "gcry_dll_root.dll")
      return nil unless compile(dir, "dll_root.c", dll)
      dll
    end
  end

  # MSVC: `cl` found through vswhere, as Crystal finds its linker, so no
  # developer shell is needed. The DLL has no entry point and links no CRT,
  # so `cl` needs neither INCLUDE nor LIB. GNU (MinGW): `cc` or `clang`.
  private def self.compile(dir : String, src : String, dll : String) : Bool
    return false unless command = compiler_command(src, dll)
    log = IO::Memory.new
    status = Process.run(command[0], command[1], chdir: dir, output: log, error: log)
    raise "C compiler failed (#{status}):\n#{log}" unless status.success?
    true
  end

  private def self.compiler_command(src : String, dll : String) : {String, Array(String)}?
    {% if flag?(:msvc) %}
      return nil unless cl = msvc_cl
      {cl, ["/nologo", "/LD", "/GS-", "/O1", src, "/Fe:#{dll}", "/link", "/NOENTRY", "/NODEFAULTLIB"]}
    {% else %}
      return nil unless cc = Process.find_executable("cc") || Process.find_executable("clang")
      {cc, ["-shared", "-O0", "-o", dll, src]}
    {% end %}
  end

  private def self.msvc_cl : String?
    root = ENV["ProgramFiles(x86)"]? || return nil
    vswhere = File.join(root, "Microsoft Visual Studio", "Installer", "vswhere.exe")
    return nil unless File.exists?(vswhere)
    host = {% if flag?(:aarch64) %} "Hostarm64\\arm64" {% else %} "Hostx64\\x64" {% end %}
    found = IO::Memory.new
    Process.run(vswhere, ["-latest", "-products", "*", "-find", "VC\\Tools\\MSVC\\**\\bin\\#{host}\\cl.exe"],
      output: found, error: Process::Redirect::Close)
    found.to_s.lines.map(&.strip).reject(&.empty?).last?
  end

  def self.open : {Void*, Void*}
    dll = library
    pending! "no C compiler (MSVC via vswhere, or cc/clang) found" unless dll
    handle = LibC.LoadLibraryExW(dll.to_utf16, nil, 0)
    raise "LoadLibraryExW failed: #{WinError.value}" if handle.null?
    keep = LibC.GetProcAddress(handle, "gcry_dll_keep")
    get = LibC.GetProcAddress(handle, "gcry_dll_get")
    raise "export not found" if keep.null? || get.null?
    {keep, get}
  end

  # On a thread that has exited before the first collection, so the DLL's
  # global is the only copy the collector could find. Planted from the main
  # thread, a stale stack copy kept the object with library roots off and the
  # control passed for the wrong reason.
  def self.plant(keep : Void*) : Nil
    Thread.new { Proc(Void*, Nil).new(keep, Pointer(Void).null).call(Held.new.as(Void*)) }.join
  end

  # Plants an object in the DLL and collects over it with library roots on or
  # off. Returns how many `Held` were finalized meanwhile and what the DLL
  # still holds.
  def self.collect_over(keep : Void*, get : Void*, roots : Bool) : {Int32, Void*}
    # Whatever an earlier example left in the slot goes first, so the count
    # below is this object's alone.
    Proc(Void*, Nil).new(keep, Pointer(Void).null).call(Pointer(Void).null)
    2.times { GC.collect }
    heap = Gcry.default_heap
    poison = heap.poison_freed
    saved_roots = Gcry::Platform.shared_lib_roots?
    heap.poison_freed = true
    # Off, this also prints gcry's "static roots collapsed" diagnostic: the
    # loaded libraries' ranges leave the scan while they stay loaded.
    Gcry::Platform.shared_lib_roots = roots
    begin
      before = Held.finalized
      plant(keep)
      sink = [] of Array(UInt64)
      5.times do
        # Churn the object's size class, so a freed block is handed back out
        # and overwritten even if poisoning were off.
        20_000.times { sink << Array(UInt64).new(Held::WORDS, 0_u64) }
        sink.clear
        GC.collect
      end
      {Held.finalized - before, Proc(Void*).new(get, Pointer(Void).null).call}
    ensure
      heap.poison_freed = poison
      Gcry::Platform.shared_lib_roots = saved_roots
    end
  end
end

describe "a GC pointer held only in a loaded DLL's global" do
  it "survives when the DLL is loaded after GC.init" do
    keep, get = DllRootSpec.open
    finalized, held = DllRootSpec.collect_over(keep, get, roots: true)
    finalized.should eq(0)
    held.null?.should be_false
    held.as(DllRootSpec::Held).intact?.should be_true
  end

  # The control. The object is not read back: its block may be gone.
  it "is collected with library roots off" do
    keep, get = DllRootSpec.open
    finalized, _ = DllRootSpec.collect_over(keep, get, roots: false)
    finalized.should eq(1)
  end
end
