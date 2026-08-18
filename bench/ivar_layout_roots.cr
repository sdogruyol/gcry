# Does a precise layout cover every ivar of the type it claims to describe?
#
# `Layout.register` walks `T.instance_vars` and sorts each one into three
# buckets: emit a scan offset, emit a noscan offset, or give up on precision for
# the whole type and install a conservative `scan_cap`. Ivars that are neither
# `Reference`, `Pointer`, a pointer-safe union, a `Value`-with-ivars nor a
# `StaticArray` land in none of them — they get no offset *and* do not force the
# fallback, so the type stays precise and the slot is never scanned. Whatever
# lives only behind such an ivar has no root.
#
# Two shapes ship in the stdlib and both are tested here:
#
#   module   `@dispatcher : Log::Dispatcher`, `@wrapped : Socket::Server`,
#            `@spawn_context : Fiber::ExecutionContext` — one pointer word.
#   proc     `Fiber#proc : Proc(Nil)`, `Thread#func` — two words, of which the
#            second points at the closure's heap-allocated environment.
#
# The question came out of the v0.20.0 scheduler-root audit
# (`bench/scheduler_roots.cr`), which could not settle it: the explicit pins in
# `scan_thread_roots` cover the scheduler graph whether or not the layout drops
# an ivar, so that harness is green either way. This one holds the object behind
# nothing else. (What that audit named as the instance — `@event_loop :
# Crystal::EventLoop` — turned out not to be one: on Crystal 1.21.0 EventLoop is
# an abstract *class*, so it is `< Reference` and its offset is emitted.)
#
# Three arms, and the first is the gate:
#
#   mechanism   the installed entry must cover the ivar's word — by a precise
#               offset, or by not being a precise entry at all, since a
#               `scan_cap` entry scans the whole body conservatively. A precise
#               entry whose offsets skip the ivar is the defect. **This is the
#               gate**, and it is a static property of the registration: no
#               allocation, no codegen luck.
#
#   end-to-end  an object reachable *only* through that ivar must survive a
#               collection. Unlike the second arm in `greg_roots` this one does
#               fail for the right reason — measured, both shapes were swept
#               before the fix — but it could still pass for the wrong one, since
#               a stale word in a dead frame roots the object conservatively.
#               The stack is wiped first; the arm above is what decides.
#
#   --control   the same shape with the ivar typed as the class instead. That
#               offset *is* emitted, so the object must survive. It separates
#               "the ivar is dropped" from "this harness never rooted the holder
#               to begin with" — if the control dies, the arm above proves
#               nothing.
#
#   crystal build -Dgc_none bench/ivar_layout_roots.cr -o bin/ivar_layout_roots
#   bin/ivar_layout_roots            # module-typed ivar
#   bin/ivar_layout_roots --proc     # Proc-typed ivar (the closure environment)
#   bin/ivar_layout_roots --control  # Reference-typed ivar; must survive
#
# Run each a second time with GCRY_AUTO_LAYOUTS=1: that is the shipping route
# into the same macro (`register_all_from_reference_subclasses` → `register`),
# and it registers these probe types on its own, without the explicit call below.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "ivar_layout_roots requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

FILL       = 0x5A_u8
LEAF_BYTES =      64
# `addr ^ KEY` is not itself a heap pointer, so the address this harness keeps
# for the liveness check cannot be what roots the object it is testing.
KEY = 0x9E3779B97F4A7C15_u64

module Probe
  # Included by exactly one class. What matters is the *static* type of the ivar
  # below: Crystal stores one pointer word for it, and the layout walk has no
  # bucket for it.
  module Payload
    abstract def stamp : UInt8
  end

  class Leaf
    include Payload

    def initialize
      @bytes = Bytes.new(LEAF_BYTES, FILL)
    end

    def stamp : UInt8
      @bytes[0]
    end
  end

  # The subject. `@name` is a Reference ivar, so the walk emits an offset and the
  # entry is *precise* — which is what makes a dropped `@payload` fatal rather
  # than harmless. A class whose only ivar were module-typed would emit no
  # offsets at all, fall back to a conservative body scan, and hide the defect.
  class Holder
    getter name : String

    def initialize(@name : String, @payload : Payload)
    end

    # Read the slot as the word it is: Crystal stores a module-typed ivar as one
    # pointer, and it is that word the layout walk decides whether to mark.
    def payload_id : UInt64
      pointerof(@payload).as(UInt64*).value
    end
  end

  # The second shape. `Proc` is a `Value` with zero `instance_vars`, so it fell
  # through the same hole — and it is two words, the second of which is the only
  # pointer to the closure's environment.
  class ProcHolder
    getter name : String

    def initialize(@name : String, @job : Proc(UInt64))
    end

    def call : UInt64
      @job.call
    end
  end

  # The control. Identical to Holder but for the ivar's declared type.
  class RefHolder
    getter name : String

    def initialize(@name : String, @payload : Leaf)
    end

    def payload_id : UInt64
      @payload.object_id
    end
  end
end

# Rooted from a global, i.e. through the conservative static-root scan. The
# holder itself is never in question; what is, is whether marking it reaches
# what its ivar points at.
ROOT = [] of Probe::Holder | Probe::ProcHolder | Probe::RefHolder

# Build the graph and hand back only the obfuscated address of the leaf. NoInline
# so the plaintext pointer dies with this frame instead of living on in the
# caller's, where a conservative scan would find it and root the leaf for a
# reason that has nothing to do with the layout.
@[NoInline]
def build_hidden(shape : Symbol) : UInt64
  leaf = Probe::Leaf.new
  case shape
  when :proc
    # The leaf is captured, so it lives in the closure's environment — reachable
    # only through the second word of `@job`.
    ROOT << Probe::ProcHolder.new("proc", -> { leaf.object_id ^ KEY })
  when :control
    ROOT << Probe::RefHolder.new("control", leaf)
  else
    ROOT << Probe::Holder.new("module", leaf)
  end
  leaf.object_id ^ KEY
end

# `build_hidden` returned, but the words it used are still on the stack and the
# root scan is conservative.
@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[65536]
  i = 0
  while i < 65536
    buf.to_unsafe[i] = 0_u8
    i += 1
  end
  # Keep the writes: without a use LLVM may drop the loop.
  Gcry::Trace.enabled? && puts(buf.to_unsafe[0])
end

# What the registration actually installed for `type_id`. `covered` is the
# question the gate asks: is the word at `offset` reached at mark time at all —
# by a precise offset, or by the conservative body scan a non-precise entry
# falls back to?
record EntryReport, registered : Bool, precise : Bool, covered : Bool,
  scan : Array(UInt16), noscan : Array(UInt16)

def entry_report(type_id : Int32, offset : UInt16) : EntryReport
  entry = Gcry::Layout.entry_for(type_id)
  # No entry at all: every word of the object is scanned conservatively, which
  # covers the ivar. Nothing to answer for.
  return EntryReport.new(false, false, true, [] of UInt16, [] of UInt16) unless entry
  scan = entry.scan_offsets.to_a
  noscan = entry.noscan_offsets.to_a
  precise = entry.precise_fields?
  covered = !precise || scan.includes?(offset) || noscan.includes?(offset)
  EntryReport.new(true, precise, covered, scan, noscan)
end

shape = if ARGV.includes?("--control")
          :control
        elsif ARGV.includes?("--proc")
          :proc
        else
          :module
        end

description = case shape
              when :control then "control (@payload : Probe::Leaf — a Reference; its offset is emitted)"
              when :proc    then "proc (@job : Proc(UInt64) — the leaf lives in the closure environment)"
              else               "module (@payload : Probe::Payload — a module)"
              end

puts "=== unclassified ivar roots ==="
puts "mode: #{description}"
puts "auto layouts: #{ENV["GCRY_AUTO_LAYOUTS"]? == "1" ? "on (registered by the whole-program walk)" : "off (registered explicitly below)"}"

# Explicit registration is the same macro the auto walk calls. Under
# GCRY_AUTO_LAYOUTS=1 these types are already registered and this rewrites the
# same entry.
Gcry.register_layout(Probe::Holder)
Gcry.register_layout(Probe::ProcHolder)
Gcry.register_layout(Probe::RefHolder)
Gcry.register_layout(Probe::Leaf)

subject, ivar_off, type_id = case shape
                             when :control
                               {"Probe::RefHolder.@payload", offsetof(Probe::RefHolder, @payload).to_u16,
                                Probe::RefHolder.crystal_instance_type_id}
                             when :proc
                               {"Probe::ProcHolder.@job", offsetof(Probe::ProcHolder, @job).to_u16,
                                Probe::ProcHolder.crystal_instance_type_id}
                             else
                               {"Probe::Holder.@payload", offsetof(Probe::Holder, @payload).to_u16,
                                Probe::Holder.crystal_instance_type_id}
                             end

report = entry_report(type_id, ivar_off)
puts "#{subject} at byte #{ivar_off}"
puts "entry: registered?=#{report.registered} precise?=#{report.precise} " \
     "scan=#{report.scan} noscan=#{report.noscan}"

hidden = build_hidden(shape)
wipe_stack

GC.collect

leaf = Pointer(Void).new(hidden ^ KEY)
alive = HEAP.live?(leaf)
puts "objects scanned precisely this collection: #{HEAP.layout_precise_scans}"
puts "leaf 0x#{(hidden ^ KEY).to_s(16)}: live?=#{alive}"

# Read the ivar back through the holder the global still points at. Done after
# the collection, where knowing the address can no longer keep it alive.
holder = ROOT[0]
still = case holder
        in Probe::ProcHolder then holder.call ^ KEY # the closure hands it back obfuscated too
        in Probe::Holder     then holder.payload_id
        in Probe::RefHolder  then holder.payload_id
        end
intact = still == (hidden ^ KEY)
puts "holder still points at it: #{intact}"

failures = [] of String

# ── Arm 1: the mechanism ─────────────────────────────────────────────────────
unless report.covered
  failures << "the entry for #{subject.split('.').first} is precise but neither offset list " \
              "contains #{subject.split('.').last} at byte #{ivar_off} — the layout walk dropped " \
              "the ivar without falling back to a conservative body scan, so anything reachable " \
              "only through it has no root"
end

# ── Arm 2: end to end (and its control) ──────────────────────────────────────
unless alive
  failures << "the leaf was swept while #{subject} still pointed at it"
end
unless intact
  failures << "#{subject} no longer points at the leaf after collection"
end

if failures.empty?
  puts
  case shape
  when :control
    puts "ok — a Reference-typed ivar is emitted and its object survives, so the harness does " \
         "root the holder and the other arms are attributable to the ivar's type"
  else
    puts "ok — the ivar is covered (offset emitted, or the type fell back to a conservative " \
         "body scan) and the object behind it survived"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
