require "../../src/gcry"
require "spec"

# A pointer held only in a callee-saved register of a frame above
# `GC.collect` is a root. The collecting thread finds such a register in one
# of two places: a frame between it and the capture saved the register in its
# prologue (scanned stack), or nothing did and the register still holds the
# value when `Roots.capture_registers` runs `setjmp`. The second case is the
# one this spec forces: inline asm puts the only copy of the pointer in one
# register and calls the collector straight from the asm, with no Crystal
# frame of its own in between.
#
# x86_64 glibc `setjmp` stores rbx and r12-r15 as they are but PTR_MANGLEs
# rbp (XOR with a TLS guard, then rotate), so a jmp_buf scan cannot see rbp.
# Crystal does not keep frame pointers on Linux (`--frame-pointers auto`), so
# rbp is an ordinary callee-saved register there. Before `capture_registers`
# stored rbp itself, the `captures rbp` example failed on Crystal 1.21.0
# x86_64, debug and `--release` alike (2026-10-05); the `keeps … rbp` one
# passed only because the collector's own chain happened to push rbp. glibc
# aarch64 mangles only sp and x30; Darwin arm64 also munges x29.

# The XOR keeps the plain pointer out of every Crystal frame: the asm undoes
# it in the target register itself.
private KEY   = 0x5a5a_5a5a_5a5a_5a5a_u64
private MAGIC = 0x0bad_c0de_0000_0000_u64 # not pointer-shaped, block is atomic
private WORDS =                         8

# Called from the asm by symbol: no Crystal caller frame, so nothing but the
# collector's own call chain can save the register before `setjmp`.
fun gcry_spec_regroot_collect : Nil
  GC.collect
end

# Whether the collector's chain saves a register is the compiler's choice, and
# on 1.21.0 every build tried did save rbp somewhere above `setjmp`. So the
# capture primitive is also asked directly, from a frame with almost nothing
# in it, the way `scan_mutator` uses it: is the value in the buffer, or in a
# frame at or above the SP the capture ran at? Either is scanned; anywhere
# else is not.
private module CaptureBuffer
  @@words = uninitialized StaticArray(UInt64, 32) # REGISTER_BUFFER_SIZE bytes
  class_property top = 0_u64
  class_property? in_frames = false

  def self.to_unsafe : UInt64*
    pointerof(@@words).as(UInt64*)
  end
end

# The frame check runs here, before returning: the example's own calls after
# the asm reuse exactly the stack this frame occupied.
fun gcry_spec_regroot_capture : Nil
  Gcry::Roots.capture_registers(CaptureBuffer.to_unsafe.as(UInt8*))
  sp = Gcry::Roots.hardware_stack_pointer.address
  CaptureBuffer.in_frames = (sp...CaptureBuffer.top).step(8).any? do |a|
    Pointer(UInt64).new(a).value == MAGIC
  end
end

@[NoInline]
private def hidden_block : UInt64
  ptr = GC.malloc_atomic(WORDS * 8).as(UInt64*)
  WORDS.times { |i| ptr[i] = MAGIC | i }
  ptr.address ^ KEY
end

# The allocation path leaves copies of the pointer in frames that are dead
# but lie inside the collector's scan window; zero them.
@[NoInline]
private def scrub_dead_stack : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

private macro hold_only_in(reg, target)
  {% if flag?(:x86_64) %}
    # rax keeps the entry rsp; the red zone is skipped and the stack aligned
    # for the call. Operands are pinned to r13-r15 so they never share *reg*.
    asm(
      "movq %rsp, %rax
       subq $$128, %rsp
       andq $$-16, %rsp
       pushq %rax
       pushq %{{reg.id}}
       movq $1, %{{reg.id}}
       xorq $2, %{{reg.id}}
       call {{target.id}}
       xorq $2, %{{reg.id}}
       movq %{{reg.id}}, $0
       popq %{{reg.id}}
       popq %rsp"
            : "={r13}"(back)
            : "{r14}"(hidden), "{r15}"(KEY)
            : "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11",
              "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7",
              "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15",
              "memory", "cc"
            : "volatile")
  {% else %}
    # x29/x30 are saved because `bl` overwrites x30 and *reg* may be x29.
    asm(
      "stp x29, x30, [sp, #-16]!
       stp {{reg.id}}, xzr, [sp, #-16]!
       mov {{reg.id}}, $1
       eor {{reg.id}}, {{reg.id}}, $2
       bl {{target.id}}
       eor {{reg.id}}, {{reg.id}}, $2
       mov $0, {{reg.id}}
       ldp {{reg.id}}, x9, [sp], #16
       ldp x29, x30, [sp], #16"
            : "={x22}"(back)
            : "{x20}"(hidden), "{x21}"(KEY)
            : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9",
              "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x18", "x30",
              "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v16", "v17",
              "v18", "v19", "v20", "v21", "v22", "v23", "v24", "v25", "v26",
              "v27", "v28", "v29", "v30", "v31", "memory", "cc"
            : "volatile")
  {% end %}
end

private macro register_root_example(reg)
  it "keeps an object whose only pointer is in {{reg.id}}" do
    heap = Gcry.default_heap
    poison = heap.poison_freed
    heap.poison_freed = true
    begin
      hidden = hidden_block
      scrub_dead_stack
      back = 0_u64
      hold_only_in({{reg}}, gcry_spec_regroot_collect)
      back.should eq(hidden) # the asm handed the register back intact
      ptr = Pointer(UInt64).new(back ^ KEY)
      heap.live?(ptr.as(Void*)).should be_true
      WORDS.times { |i| ptr[i].should eq(MAGIC | i) }
    ensure
      heap.poison_freed = poison
    end
  end
end

private macro register_capture_example(reg)
  it "captures {{reg.id}} where the collector scans" do
    Gcry::Roots::REGISTER_BUFFER_SIZE.should eq(sizeof(StaticArray(UInt64, 32)))
    words = CaptureBuffer.to_unsafe
    words.clear(32)
    hidden = MAGIC ^ KEY
    back = 0_u64
    anchor = 0_u64 # above everything the asm and its callee push
    CaptureBuffer.top = pointerof(anchor).address
    scrub_dead_stack # no MAGIC left below from an earlier example
    hold_only_in({{reg}}, gcry_spec_regroot_capture)
    back.should eq(hidden)
    in_buffer = (0...32).any? { |i| words[i] == MAGIC }
    (in_buffer || CaptureBuffer.in_frames?).should be_true
  end
end

{% if flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
  describe "Regression: pointer held only in a callee-saved register across GC.collect" do
    {% if flag?(:x86_64) %}
      register_root_example(rbx)
      register_root_example(r12)
      register_root_example(rbp)
      register_capture_example(rbx)
      register_capture_example(r12)
      register_capture_example(rbp)
    {% else %}
      register_root_example(x19)
      register_root_example(x28)
      register_root_example(x29)
      register_capture_example(x19)
      register_capture_example(x28)
      register_capture_example(x29)
    {% end %}
  end
{% end %}
