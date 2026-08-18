# Does a freed block read as poison, and does the collector still hand out zeros?
#
# The 2026-08-10 soak died in `Parallel::Scheduler#quick_dequeue?` on
# `0x7f1700000149`. Three sessions have argued about what that value was — a
# partially overwritten pointer, a reissued object's first two Int32s, a valid
# pointer into an unmapped chunk — and the argument is unresolvable because the
# value is *plausible*. `GCRY_POISON_FREED=1` overwrites a freed block's payload
# with `0xdeadf2eedeadf2ee`, which is not plausible: it is not a pointer, it is
# not zero, it is not anyone's data, and dereferencing it faults at an address
# that says use-after-free and nothing else.
#
# The knob is only sound because of a pairing, and both halves are gated here:
#
#   poison    a freed payload must read the pattern. Without this the knob does
#             nothing and every other arm passes vacuously.
#
#   zeroing   a `malloc` that asks to be cleared must still get zeros. This is
#             the half that could break the collector rather than debug it:
#             gcry skips the clearing memset when a size class's freelist is
#             known clean (a freshly carved chunk is zero), so poisoning a block
#             on a "clean" list would hand poison to a caller expecting zeros.
#             Every path into `push_size_class_free` sets that flag false; this
#             arm is what proves it, over the size classes the poison touches.
#             **This is the gate.**
#
#   use-after-free
#             a pointer read out of a block *after* it was freed must read
#             poison rather than what was written there — the property that
#             turns the next soak crash into a sentence.
#
#   --control the same run with the knob off: freed payloads keep their old
#             bytes, so the arms above are attributable to the knob and not to
#             something else zeroing memory.
#
#   crystal build -Dgc_none bench/poison_freed.cr -o bin/poison_freed
#   GCRY_POISON_FREED=1 bin/poison_freed
#   bin/poison_freed --control

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "poison_freed requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP   = Gcry.default_heap.not_nil!
POISON = 0xDEADF2EEDEADF2EE_u64
MARKER = 0x0123456789ABCDEF_u64

# Sizes across several size classes. All small (the threshold is 32 KiB): a
# freed *large* block can be munmapped outright, so reading one back is not
# defined and the first version of this harness SEGV'd on its own probe. The
# large path is poisoned too — `poisoned_blocks` counts it — but it cannot be
# read back from here.
SIZES = [32, 64, 200, 1024, 4096]

def run(control : Bool) : Int32
  failures = [] of String
  on = HEAP.poison_freed
  puts "poison_freed: #{on}"

  # ── Arm 1: a freed payload reads the pattern ────────────────────────────────
  poisoned = 0
  intact = 0
  SIZES.each do |size|
    ptr = GC.malloc(size)
    words = ptr.as(UInt64*)
    n = size // 8
    n.times { |i| words[i] = MARKER }
    GC.free(ptr)
    # Reading a freed block is exactly what this knob exists to make legible;
    # the block is still mapped, so the read itself is defined.
    first = words[0]
    last = words[n - 1]
    if first == POISON && last == POISON
      poisoned += 1
    elsif first == MARKER
      intact += 1
    end
  end
  puts "freed payloads: #{poisoned}/#{SIZES.size} poisoned, #{intact} still holding their old bytes"

  before = HEAP.poisoned_blocks
  if on
    failures << "#{SIZES.size - poisoned} of #{SIZES.size} freed payloads did not read as poison" if poisoned != SIZES.size
    failures << "poisoned_blocks is 0 — the counter cannot see the work" if before == 0
  else
    failures << "the knob is off but #{poisoned} payloads read as poison" if poisoned > 0
    failures << "the knob is off but poisoned_blocks is #{before}" if before > 0
  end

  # ── Arm 2: cleared allocations still get zeros ──────────────────────────────
  # The dangerous direction. Free a run of blocks in a class, then allocate the
  # same class back and require every word to be zero.
  dirty = 0
  checked = 0
  [32, 64, 200, 1024].each do |size|
    freed = [] of Void*
    64.times do
      p = GC.malloc(size)
      w = p.as(UInt64*)
      (size // 8).times { |i| w[i] = MARKER }
      freed << p
    end
    freed.each { |p| GC.free(p) }

    64.times do
      p = GC.malloc(size)
      w = p.as(UInt64*)
      (size // 8).times do |i|
        checked += 1
        dirty += 1 if w[i] != 0
      end
    end
  end
  puts "cleared allocations: #{dirty} non-zero words of #{checked}"
  if dirty > 0
    failures << "#{dirty} of #{checked} words came back non-zero from a cleared malloc — the " \
                "freelist-clean fast path handed out a poisoned block, which is a correctness " \
                "regression and not a debugging aid"
  end

  # ── Arm 3: use after free reads poison, not the old value ───────────────────
  victim = GC.malloc(64)
  vwords = victim.as(UInt64*)
  8.times { |i| vwords[i] = MARKER }
  GC.free(victim)
  stale = vwords[3]
  puts "stale read after free: 0x#{stale.to_s(16)}"
  if on
    unless stale == POISON
      failures << "a word read out of a freed block still returned 0x#{stale.to_s(16)} — a " \
                  "use-after-free would look like live data, which is the situation the " \
                  "2026-08-10 crash left us in"
    end
  else
    unless stale == MARKER
      failures << "with the knob off a freed block's word changed to 0x#{stale.to_s(16)}, so the " \
                  "control does not isolate the knob"
    end
  end

  puts "poisoned blocks: #{HEAP.poisoned_blocks}"

  if failures.empty?
    puts
    if control
      puts "ok — with the knob off freed payloads keep their bytes, so the poison arms are " \
           "attributable to the knob"
    else
      puts "ok — freed payloads read 0x#{POISON.to_s(16)}, cleared allocations still come back " \
           "zeroed, and a use-after-free reads poison rather than plausible data"
    end
    return 0
  else
    puts
    failures.each { |f| STDERR.puts "FAIL: #{f}" }
    return 1
  end
end

control = ARGV.includes?("--control")
puts "=== poison on free ==="
puts "mode: #{control ? "control (knob off; freed payloads must keep their bytes)" : "hold (knob on)"}"
exit run(control)
