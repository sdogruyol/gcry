# Nursery + old HTTP::Headers Hash regression (Phase 4 / process GC).
#
# OverflowError/SEGV in HTTP keep-alive Hash lookup when minor GC swept nursery
# String keys that lived only inside an old Hash.@entries blob. The minor's
# walk of every old block (`scan_old_for_nursery_pointers`) is what reaches
# them: soft-dirty alone has missed the page under WSL.
#
# Until 2026-09-20 this was a hollow CI step on the compile default:
# `Heap#nursery_enabled=` is a no-op without `-Dgcry_block_headers`, so
# `minor_collect` returned immediately and the keys were string literals
# sitting on the stack. Both arms would have stayed green through a broken
# walk. The green arm requires a live nursery and a nursery-allocated name
# reachable only through the Hash (class-var pin, minor without a stack scan).
#
# Until 2026-10-04 a `--disabled` arm installed a `Gcry::Layout` Hash map that
# skipped keys and required the name to vanish. The mark no longer reads
# layouts (`bench/log/linux/2026-10-04-layout-union-collision/`), and with the
# minor's whole old→young scan switched off by hand the name still survived,
# poisoned frees included — something else roots it, and until that is known
# this gate has no red arm (ROADMAP).
#
# Build: crystal build -Dgc_none -Dgcry_block_headers bench/nursery_headers.cr -o bin/nursery_headers
# Run:   ./bin/nursery_headers
#
# Dropping `-Dgcry_block_headers`: exit 64 (nursery never on).

{% unless flag?(:gc_none) %}
  {% raise "nursery_headers requires -Dgc_none (gcry as process GC)" %}
{% end %}

require "http"
require "../src/gcry"

HEAP = Gcry.default_heap.not_nil!

# Stack residue kept the young name alive on CI. A class var is a static root,
# so the minor can skip the stack.
class Pin
  class_property headers : HTTP::Headers?
end

@[NoInline]
def plant_young_header(headers : HTTP::Headers) : Nil
  name = String.build { |io| io << "X-Nurs-" << Random.rand(1_000_000) }
  val = String.build { |io| io << "young-" << Random.rand(1_000_000) }
  headers[name] = val
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
  plant_young_header(headers)
  HEAP.clear_stack(1_u64 << 20)
  # Stack off: the pin is a static root, the Hash is old, the young name
  # lives only in @entries. A leftover word on this frame is not a root.
  HEAP.minor_collect(scan_stack: false)
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
ensure
  HEAP.soft_dirty_max_pct = old_soft
  HEAP.nursery_enabled = old_nursery
end

puts "nursery_headers ok"
