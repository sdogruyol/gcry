require "../../src/gcry"
require "spec"

# Readiness B4 / M8: code compiled against Boehm's C API inside a gcry process.
# `crystal i` runs its program with the Boehm prelude and resolves `LibGC` from
# the compiler binary; a shard or C library that binds `GC_*` resolves them from
# the program, and Crystal's own `spec/std` calls `LibGC.size`. Until
# 2026-10-05 a gcry program defined none of them and had no `LibGC`, so this
# file did not build. It uses stdlib's binding, as such code does
# (src/gcry/c_abi.cr).

private BLOCK_BYTES =     256
private PATTERN     = 0xC3_u8
# Addresses the spec keeps for checking are XORed with this, so the kept word
# is not itself a conservative root for the block it names.
private MASK = 0x5555_5555_5555_5555_u64

private def hide(p : Void*) : UInt64
  p.address ^ MASK
end

private def unhide(word : UInt64) : Void*
  Pointer(Void).new(word ^ MASK)
end

# A block nothing on any stack holds: built on a fiber that has finished and
# scrubbed its frames, its address kept only masked (and wherever *store*
# puts it).
@[NoInline]
private def fresh_block(&store : Void* ->) : UInt64
  hidden = 0_u64
  done = Channel(Nil).new
  spawn do
    p = LibGC.malloc_atomic(BLOCK_BYTES)
    p.as(UInt8*).fill(BLOCK_BYTES) { PATTERN }
    store.call(p)
    hidden = hide(p)
    p = Pointer(Void).null
    scrub_frames
    done.send(nil)
  end
  done.receive
  Fiber.yield
  hidden
end

@[NoInline]
private def scrub_frames : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

private def live_and_intact?(hidden : UInt64) : Bool
  p = unhide(hidden)
  return false unless LibGC.base(p) == p
  BLOCK_BYTES.times { |i| return false unless p.as(UInt8*)[i] == PATTERN }
  true
end

private def collect(n = 3) : Nil
  n.times { LibGC.collect }
end

# libc memory: never scanned, so a pointer stored here roots nothing by itself.
private def libc_word : Void**
  word = LibC.malloc(sizeof(Void*)).as(Void**)
  word.value = Pointer(Void).null
  word
end

class BoehmAbiLog
  # (masked object, client data) per finalizer run, in libc memory so the log
  # roots nothing.
  class_property finalized_log : UInt64* = Pointer(UInt64).null
  class_property finalized_count = 0
  class_property other_root : Void** = Pointer(Void*).null
  class_property initial_stackbottom = Pointer(Void).null
end

# Read before any example runs: examples (18's `GC.set_stackbottom` among
# them) move it, as Boehm's would move.
{% if flag?(:linux) || flag?(:darwin) %}
  BoehmAbiLog.initial_stackbottom = LibGC.stackbottom
{% end %}

describe "Boehm's GC_* C ABI in a gcry program (B4/M8)" do
  it "allocates, and answers GC_base / GC_size / GC_is_heap_ptr for interior pointers" do
    p = LibGC.malloc(100)
    LibGC.is_heap_ptr(p).should eq(1)
    LibGC.base(p + 40).should eq(p)
    LibGC.size(p).should be >= 100
    foreign = LibC.malloc(16)
    LibGC.base(foreign).should eq(Pointer(Void).null)
    LibGC.is_heap_ptr(foreign).should eq(0)
    LibC.free(foreign)
  end

  it "nests GC_disable / GC_enable and reports it through GC_is_disabled" do
    LibGC.disable
    LibGC.disable
    LibGC.enable
    LibGC.is_disabled.should eq(1)
    LibGC.enable
    LibGC.is_disabled.should eq(0)
  end

  it "keeps a block alive from a GC_add_roots range, and only then" do
    unrooted = libc_word
    control = fresh_block { |p| unrooted.value = p }
    rooted = libc_word
    kept = fresh_block { |p| rooted.value = p }
    LibGC.add_roots(rooted.as(Void*), (rooted + 1).as(Void*))
    collect
    live_and_intact?(control).should be_false
    live_and_intact?(kept).should be_true
  end

  it "keeps a block alive from GC_push_all_eager in a GC_set_push_other_roots callback" do
    BoehmAbiLog.other_root = libc_word
    LibGC.set_push_other_roots(-> {
      root = BoehmAbiLog.other_root
      LibGC.push_all_eager(root.as(Void*), (root + 1).as(Void*))
    })
    kept = fresh_block { |p| BoehmAbiLog.other_root.value = p }
    collect
    live_and_intact?(kept).should be_true
  end

  # A single object can stay reachable through a stale word in the collect
  # call chain — conservative scanning, under Boehm as much as here. On macOS
  # arm64 one such block was held through twelve collections once an unrelated
  # change moved the collector's frames (2026-10-05: no heap block, explicit
  # root or fiber stack held it; flipped by codegen alone). So eight blocks,
  # each with its own client data: at least seven must be finalized, each once,
  # each with the data registered for that very block.
  it "runs a GC_register_finalizer_ignore_self callback with its client data" do
    blocks = 8
    BoehmAbiLog.finalized_log = LibC.malloc(LibC::SizeT.new(blocks * 2 * sizeof(UInt64))).as(UInt64*)
    BoehmAbiLog.finalized_count = 0
    hidden = Array(UInt64).new(blocks) do |i|
      fresh_block do |p|
        LibGC.register_finalizer_ignore_self(p, ->(obj : Void*, cd : Void*) {
          k = BoehmAbiLog.finalized_count
          if k < 8
            BoehmAbiLog.finalized_log[2 * k] = obj.address ^ MASK
            BoehmAbiLog.finalized_log[2 * k + 1] = cd.address
          end
          BoehmAbiLog.finalized_count = k + 1
        }, Pointer(Void).new(0x1234_u64 + i), nil, nil)
      end
    end
    6.times do
      break if BoehmAbiLog.finalized_count == blocks
      collect(1)
    end
    ran = BoehmAbiLog.finalized_count
    ran.should be >= blocks - 1
    ran.should be <= blocks
    finalized = Array(UInt64).new(ran) { |k| BoehmAbiLog.finalized_log[2 * k] }
    finalized.uniq.size.should eq(ran)
    ran.times do |k|
      index = hidden.index(finalized[k])
      index.should_not be_nil
      BoehmAbiLog.finalized_log[2 * k + 1].should eq(0x1234_u64 + index.not_nil!)
    end
    LibC.free(BoehmAbiLog.finalized_log.as(Void*))
  end

  it "clears a GC_general_register_disappearing_link when its object dies" do
    link = libc_word
    fresh_block do |p|
      link.value = p
      LibGC.general_register_disappearing_link(link, p)
    end
    collect
    link.value.should eq(Pointer(Void).null)
  end

  it "fills GC_get_prof_stats and counts collections in it" do
    stats = uninitialized LibGC::ProfStats
    LibGC.get_prof_stats(pointerof(stats), sizeof(LibGC::ProfStats))
    before = stats.gc_no
    collect(1)
    LibGC.get_prof_stats(pointerof(stats), sizeof(LibGC::ProfStats))
    stats.gc_no.should be > before
    stats.heap_size.should be > 0
  end

  {% if flag?(:linux) || flag?(:darwin) %}
    # `crystal i` interprets the program with `gc/boehm.cr`, whose prelude, under
    # the interpreter's `without_mt`, reads `$stackbottom = GC_stackbottom` for
    # the main fiber's stack and resolves it from the compiler binary's own
    # handle (`Crystal::Loader#load_current_program_handle`). Without the symbol
    # every `crystal i` run failed with "undefined reference to `GC_stackbottom'".
    it "defines GC_stackbottom where crystal i looks for it, tracking the main thread's stack bottom" do
      symbol = LibC.dlsym(LibC.dlopen(nil, LibC::RTLD_LAZY), "GC_stackbottom")
      symbol.should eq(pointerof(LibGC.stackbottom).as(Void*))

      # Set when the collector starts: the main thread's stack bottom.
      _, high = Gcry::Platform.current_pthread_stack_bounds.not_nil!
      marker = 0
      initial = BoehmAbiLog.initial_stackbottom
      initial.address.should be > pointerof(marker).address
      initial.address.should be <= high.address

      # A stack bottom set on the main thread moves it, as in Boehm — through
      # `GC_set_stackbottom` and through `GC.set_stackbottom` — and one set on
      # another thread does not.
      moved = LibGC::StackBase.new(mem_base: high - 64)
      LibGC.set_stackbottom(nil, pointerof(moved))
      LibGC.stackbottom.should eq(high - 64)
      Thread.new do
        LibGC.get_my_stackbottom(out own)
        LibGC.set_stackbottom(nil, pointerof(own))
        {% unless flag?(:without_mt) %} GC.set_stackbottom(Thread.current, own.mem_base) {% end %}
      end.join
      LibGC.stackbottom.should eq(high - 64)
      {% unless flag?(:without_mt) %}
        GC.set_stackbottom(Thread.current, high)
        LibGC.stackbottom.should eq(high)
      {% end %}

      main = LibGC::StackBase.new(mem_base: high)
      LibGC.set_stackbottom(nil, pointerof(main))
      LibGC.stackbottom.should eq(high)
    end
  {% end %}
end
