require "../../src/gcry"
require "spec"

# A stack deeper than 64 MiB is still a root set. Until 2026-10-10 the
# collecting thread's own stack went to `Roots.scan_range` as one range, and
# `scan_range` refuses anything over `MAX_SCAN_BYTES` (64 MiB) — a valve
# against nonsense bounds. Under `ulimit -s unlimited` (or any RLIMIT_STACK
# that large) a program recursing deeper than that lost its whole stack from
# the root set: a block held only by a frame was swept at depth 20 000 with
# 2.4 KiB frames, `oversize_skips` 1. The window there is SP to the fiber's
# recorded stack bottom, real bounds, so it is now scanned chunked.
#
# Linux only: the main thread is the one stack the program can make this deep
# (fiber stacks are 8 MiB), macOS caps RLIMIT_STACK's hard limit at 64 MiB,
# and Windows fixes the main stack's reserve at link time.
{% skip_file unless flag?(:linux) %}

# How far below the holder's frame the collection runs. Measured from the
# stack pointer, not counted in frames, so the depth does not move with how
# big the compiler makes each frame.
private DEEP_STACK_BYTES = 96_u64 * 1024 * 1024
# What the raised RLIMIT_STACK must at least allow, with room for the spec
# runner's own frames above the holder.
private DEEP_STACK_LIMIT = 128_u64 * 1024 * 1024
# The block's address is passed down XORed with this, so no word below the
# holder's frame refers to it.
private DEEP_STACK_MASK = 0x5a5a_5a5a_5a5a_5a5a_u64

@[NoInline]
private def deep_stack_recurse(start : UInt64, hidden : UInt64) : Bool
  pad = uninitialized StaticArray(UInt8, 2048)
  pad[0] = 1_u8
  here = pad.to_unsafe.address
  survived = if start &- here >= DEEP_STACK_BYTES
               GC.collect
               Gcry.live?(Pointer(Void).new(hidden ^ DEEP_STACK_MASK))
             else
               deep_stack_recurse(start, hidden)
             end
  # Uses the frame after the call: neither the pad nor the recursion can be
  # turned into a loop.
  Gcry::Roots.keep_alive(pad.to_unsafe.as(Void*))
  survived
end

# The only reference to the block is this frame's (a slot or a callee-saved
# register some deeper frame spills): everything below it gets the address
# masked.
@[NoInline]
private def deep_stack_holder : Bool
  block = GC.malloc(64)
  marker = 0_u64
  survived = deep_stack_recurse(pointerof(marker).address, block.address ^ DEEP_STACK_MASK)
  Gcry::Roots.keep_alive(block)
  survived
end

describe "Regression: a stack deeper than 64 MiB stays in the root set" do
  # In a process of its own: RLIMIT_STACK is fixed for the main thread at exec.
  it "keeps a block held only by a frame 96 MiB above the collection" do
    LibC.getrlimit(LibC::RLIMIT_STACK, out limit).should eq(0)
    # RLIM_INFINITY is all ones on Linux.
    unlimited = limit.rlim_max.to_u64 == UInt64::MAX
    pending!("RLIMIT_STACK hard limit #{limit.rlim_max} is below #{DEEP_STACK_LIMIT}") unless unlimited || limit.rlim_max >= DEEP_STACK_LIMIT
    kib = unlimited ? "unlimited" : (limit.rlim_max // 1024).to_s
    captured = IO::Memory.new
    status = Process.run("/bin/sh", ["-c", "ulimit -s #{kib} && exec \"$0\" -e 'deep-stack child'", Process.executable_path.not_nil!],
      env: {"GCRY_DEEP_STACK_CHILD" => "1"}, output: captured, error: captured)
    fail "#{status}\n#{captured}" unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  # The run, by the example above in a fresh process; a no-op anywhere else.
  it "deep-stack child" do
    next unless ENV["GCRY_DEEP_STACK_CHILD"]? == "1"
    LibC.getrlimit(LibC::RLIMIT_STACK, out limit).should eq(0)
    (limit.rlim_cur.to_u64 == UInt64::MAX || limit.rlim_cur >= DEEP_STACK_LIMIT).should be_true
    skips = Gcry::Roots.oversize_skips
    deep_stack_holder.should be_true
    Gcry::Roots.oversize_skips.should eq(skips)
  end
end
