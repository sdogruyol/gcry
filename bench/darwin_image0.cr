# Is the image gcry reads as "the executable" on Darwin the executable?
#
# `GC.init` resolves the static roots from one Mach-O image and takes its
# slide as `exe_bias` and its `__TEXT` as `exe_text?`. Run under
# `DYLD_INSERT_LIBRARIES` or with extra dylibs linked, and compared with
# `_NSGetMachExecuteHeader()`:
#
#   identity   the slide gcry took is the executable's, and the code of this
#              program is inside the `__TEXT` gcry took.
#   root       with library roots off, the executable's writable data is
#              scanned only if gcry found the right image. An array whose only
#              reference is a class variable must survive collections and
#              the reuse churn after them.
#
# Prints `OK` and exits 0, or names the failed check and exits 1.
#
#   crystal build -Dgc_none bench/darwin_image0.cr -o bin/darwin_image0
#   DYLD_INSERT_LIBRARIES=libinject.dylib bin/darwin_image0

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "darwin_image0 requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% if flag?(:darwin) %}
  lib LibImage0
    fun _NSGetMachExecuteHeader : Gcry::Platform::LibDyld::MachHeader64*
    fun _dyld_get_image_name(image_index : UInt32) : UInt8*
  end

  module Image0
    MH_EXECUTE = 2_u32
    WORDS      = 4096

    @@keep : Array(UInt64)? = nil

    def self.exe_slide : UInt64?
      exe = LibImage0._NSGetMachExecuteHeader
      n = Gcry::Platform::LibDyld._dyld_image_count
      i = 0_u32
      while i < n
        if Gcry::Platform::LibDyld._dyld_get_image_header(i) == exe
          return Gcry::Platform::LibDyld._dyld_get_image_vmaddr_slide(i).to_u64!
        end
        i += 1
      end
      nil
    end

    @[NoInline]
    def self.plant : Nil
      @@keep = Array(UInt64).new(WORDS) { |i| 0x5eed_0000_0000_u64 | i }
    end

    @[NoInline]
    def self.churn : Nil
      64.times do
        a = Array(UInt64).new(WORDS, 0xdead_dead_dead_dead_u64)
        a[0] = 1_u64
      end
    end

    def self.intact? : Bool
      keep = @@keep
      return false unless keep && keep.size == WORDS
      WORDS.times { |i| return false unless keep.unsafe_fetch(i) == (0x5eed_0000_0000_u64 | i) }
      true
    end

    def self.run : Int32
      h0 = Gcry::Platform::LibDyld._dyld_get_image_header(0_u32)
      exe = LibImage0._NSGetMachExecuteHeader
      STDERR.puts "[crystal-main] image0=#{String.new(LibImage0._dyld_get_image_name(0_u32))} " \
                  "filetype=#{h0.null? ? 0 : h0.value.filetype} image0_is_exe=#{h0 == exe ? 1 : 0}"

      failed = [] of String
      slide = exe_slide
      if slide.nil? || Gcry::Platform.exe_bias != slide
        failed << "identity: exe_bias=0x#{Gcry::Platform.exe_bias.to_s(16)} executable slide=#{slide.try(&.to_s(16))}"
      end
      code = (->Image0.churn).pointer.address
      failed << "identity: own code 0x#{code.to_s(16)} not in gcry's exe __TEXT" unless Gcry::Platform.exe_text?(code)

      Gcry::Platform.shared_lib_roots = false
      plant
      3.times do
        GC.collect
        churn
      end
      GC.collect
      churn
      failed << "root: class-variable array collected" unless intact?
      Gcry::Platform.shared_lib_roots = true

      if failed.empty?
        puts "OK"
        0
      else
        failed.each { |f| puts "FAIL #{f}" }
        1
      end
    end
  end

  exit Image0.run
{% else %}
  puts "OK (not darwin)"
{% end %}
