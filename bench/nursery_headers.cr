# Nursery + old HTTP::Headers Hash regression (Phase 4 / process GC).
#
# OverflowError/SEGV in HTTP keep-alive Hash lookup when minor GC swept nursery
# String keys that lived only inside an old Hash.@entries blob. The minor's
# old→young scan (`scan_old_for_nursery_pointers`: dirty pages, then a walk of
# every old block) is what reaches them; soft-dirty alone has missed the page
# under WSL.
#
# Until 2026-09-20 this was a hollow CI step on the compile default:
# `Heap#nursery_enabled=` is a no-op without `-Dgcry_block_headers`, so
# `minor_collect` returned immediately and the keys were string literals
# sitting on the stack. It was hollow a second way until 2026-10-04: a major
# does not promote, so the Hash and its `@entries` were still young when the
# key was planted, and the minor reached the key from the class-var pin
# without any old→young scan. The red arm only went red through the major
# after it, with a `Gcry::Layout` map that skipped keys — and the mark no
# longer reads layouts (`bench/log/linux/2026-10-04-layout-union-collision/`).
#
# Now a minor promotes the Hash before the key is planted, and both are
# checked: the Hash and `@entries` old, the key young. The green arm requires
# the key to survive a minor that skips the stack; `--disabled` turns the
# minor's old→young scan off (`Heap#nursery_old_scan`) and requires the key to
# be swept. Liveness is asked of the heap by address, so the red arm never
# reads freed memory.
#
# Build: crystal build -Dgc_none -Dgcry_block_headers bench/nursery_headers.cr -o bin/nursery_headers
# Run:   ./bin/nursery_headers
#        ./bin/nursery_headers --disabled
#
# Dropping `-Dgcry_block_headers`: exit 64 (nursery never on). Dropping the
# promoting minor: exit 64 (the Hash is young). Either way the gate goes red
# rather than hiding.

{% unless flag?(:gc_none) %}
  {% raise "nursery_headers requires -Dgc_none (gcry as process GC)" %}
{% end %}

require "http"
require "../src/gcry"

HEAP     = Gcry.default_heap.not_nil!
DISABLED = ARGV.includes?("--disabled")

# Stack residue kept the young name alive on CI. A class var is a static root,
# so the minor can skip the stack.
class Pin
  class_property headers : HTTP::Headers?
end

# The key's address, as an integer: the minor below does not scan the stack,
# so holding it here roots nothing.
@[NoInline]
def plant_young_header(headers : HTTP::Headers) : UInt64
  name = String.build { |io| io << "X-Nurs-" << Random.rand(1_000_000) }
  val = String.build { |io| io << "young-" << Random.rand(1_000_000) }
  headers[name] = val
  name.as(Void*).address
end

def nursery?(pointer : Void*) : Bool?
  header = HEAP.find_object(pointer)
  header ? Gcry::BlockHeader.nursery?(header) : nil
end

def header_names(headers : HTTP::Headers) : Array(String)
  names = [] of String
  headers.each { |k, _| names << k }
  names
end

old_soft = HEAP.soft_dirty_max_pct
old_nursery = HEAP.nursery_enabled

begin
  HEAP.nursery_enabled = true
  HEAP.soft_dirty_max_pct = 0 # force scan_object_for_nursery fallback

  unless HEAP.nursery_enabled
    STDERR.puts "nursery_headers: nursery did not enable (headerless compile default, or GCRY_DISABLE_NURSERY). Build with -Dgcry_block_headers."
    exit 64
  end

  headers = HTTP::Headers.new
  Pin.headers = headers
  headers["Connection"] = "keep-alive"
  GC.collect
  # A major does not promote; a minor does.
  HEAP.minor_collect
  hash = headers.@hash
  unless nursery?(hash.as(Void*)) == false && nursery?(hash.@entries.as(Void*)) == false
    STDERR.puts "nursery_headers: the Hash or its @entries is still young, so the key would be " \
                "reached without any old→young scan"
    exit 64
  end

  key = plant_young_header(headers)
  unless nursery?(Pointer(Void).new(key)) == true
    STDERR.puts "nursery_headers: the planted key is not young"
    exit 64
  end
  HEAP.clear_stack(1_u64 << 20)
  # Stack off: the pin is a static root, the Hash is old, the young name
  # lives only in @entries. A leftover word on this frame is not a root.
  HEAP.nursery_old_scan = !DISABLED
  HEAP.minor_collect(scan_stack: false)
  HEAP.nursery_old_scan = true

  if DISABLED
    if HEAP.live?(Pointer(Void).new(key))
      STDERR.puts "nursery_headers --disabled: the young key survived a minor with no old→young scan"
      exit 1
    end
  else
    unless HEAP.live?(Pointer(Void).new(key))
      STDERR.puts "nursery_headers: X-Nurs-* swept by the minor"
      exit 1
    end
    GC.collect
    begin
      unless headers["Connection"] == "keep-alive"
        STDERR.puts "nursery_headers: Connection lost"
        exit 1
      end
      unless header_names(headers).any?(&.starts_with?("X-Nurs-"))
        STDERR.puts "nursery_headers: X-Nurs-* lost after minor"
        exit 1
      end
      unless HTTP.keep_alive?(HTTP::Request.new("GET", "/", headers))
        STDERR.puts "nursery_headers: keep_alive? false"
        exit 1
      end
    rescue ex
      STDERR.puts "nursery_headers: #{ex.class}: #{ex.message}"
      exit 1
    end
  end
ensure
  HEAP.soft_dirty_max_pct = old_soft
  HEAP.nursery_enabled = old_nursery
end

puts DISABLED ? "nursery_headers disabled ok" : "nursery_headers ok"
