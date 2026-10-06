# A gcry program that also links libgc, as `make boehm-abi-optout` builds it.
#
# gcry defines Boehm's `GC_*` entry points (src/gcry/c_abi.cr) for `crystal i`
# and for code bound to `gc/boehm.cr`'s `LibGC`. A program that links libgc as
# well gets two definitions of each; with Crystal's own `libgc.a` — or any
# static libgc — the link fails with "multiple definition of `GC_malloc'",
# which is what this file does built with `-Dgc_none` alone. master linked
# it, because master defined none of them; `-Dgcry_no_boehm_abi` leaves them
# out again, and then this program links and runs with both collectors.
#
# Linking is not all of it. libgc's `GC_init` installs its thread-suspend
# handlers on `SIGPWR` and `SIGXCPU`, and on Linux those are Crystal's
# stop-the-world pair — gcry's — too. Boehm's handler then answers gcry's
# stops on threads Boehm never registered, and the process faults at the first
# multi-threaded collection (SIGSEGV at 0x18, 3 of 3 runs, 2026-10-06). So
# Boehm's pair is moved before `GC_init`, as libgc allows; `BOEHM_SIGNALS=crystal`
# skips the move and is the gate's last, failing arm.
#
#   crystal build -Dgc_none -Dgcry_no_boehm_abi bench/boehm_abi_optout.cr -o bin/boehm_abi_optout
#   bin/boehm_abi_optout                            # exit 0
#   BOEHM_SIGNALS=crystal bin/boehm_abi_optout      # faults in gcry's stop
{% unless flag?(:gc_none) %}
  {% raise "boehm_abi_optout requires -Dgc_none (gcry as process GC)" %}
{% end %}

require "../src/gcry"

# Static on purpose: `-l:libgc.a` takes Crystal's bundled archive (through
# CRYSTAL_LIBRARY_PATH) or the distribution's, never a shared libgc, so the
# collision without the flag is a link error on every host rather than a
# silent split between the two collectors.
@[Link(ldflags: "-l:libgc.a -lpthread")]
lib LibBoehm
  fun init = GC_init
  fun malloc = GC_malloc(size : LibC::SizeT) : Void*
  fun size = GC_size(addr : Void*) : LibC::SizeT
  fun gcollect = GC_gcollect
  fun get_version = GC_get_version : LibC::UInt
  fun get_gc_no = GC_get_gc_no : LibC::ULong
  fun set_suspend_signal = GC_set_suspend_signal(sig : LibC::Int) : LibC::Int
  fun set_thr_restart_signal = GC_set_thr_restart_signal(sig : LibC::Int) : LibC::Int
  fun get_suspend_signal = GC_get_suspend_signal : LibC::Int
end

{% if flag?(:linux) %}
  lib LibSigRt
    fun current_sigrtmin = __libc_current_sigrtmin : LibC::Int
  end
{% end %}

failures = [] of String

{% if flag?(:linux) %}
  unless ENV["BOEHM_SIGNALS"]? == "crystal"
    # Real-time signals Crystal does not use; it takes SIGPWR and SIGXCPU.
    rtmin = LibSigRt.current_sigrtmin
    LibBoehm.set_suspend_signal(rtmin + 8)
    LibBoehm.set_thr_restart_signal(rtmin + 9)
  end
{% end %}
LibBoehm.init
v = LibBoehm.get_version
puts "libgc #{v >> 16}.#{(v >> 8) & 0xff}.#{v & 0xff}, suspend signal #{LibBoehm.get_suspend_signal}; gcry's #{GC.sig_suspend.value}"

# `GC_malloc` is libgc's now: its block is not gcry's, and libgc collects.
boehm_block = LibBoehm.malloc(64)
failures << "libgc's GC_malloc returned null" if boehm_block.null?
failures << "GC_malloc returned a gcry block: gcry's export is still in the program" if GC.is_heap_ptr(boehm_block)
failures << "libgc's GC_size says #{LibBoehm.size(boehm_block)} for a 64-byte block" if LibBoehm.size(boehm_block) < 64
gc_no = LibBoehm.get_gc_no
LibBoehm.gcollect
failures << "libgc's GC_gcollect did not collect" unless LibBoehm.get_gc_no > gc_no

# gcry is the program's collector: several threads allocate through it while
# it stops the world repeatedly.
heap = Gcry.default_heap
stop = Atomic(Int32).new(0)
threads = Array.new(3) do
  Thread.new do
    until stop.get != 0
      Bytes.new(128)
    end
  end
end
kept = Array.new(1000) { |i| "s#{i}" }
before = heap.collections
20.times { GC.collect }
stop.set(1)
threads.each(&.join)
collected = heap.collections - before
failures << "gcry ran #{collected} of 20 collections" if collected < 20
kept.each_with_index { |s, i| failures << "kept string #{i} reads #{s.inspect}" unless s == "s#{i}" }

puts "gcry collections #{collected}, libgc collections #{LibBoehm.get_gc_no}"
if failures.empty?
  puts "ok"
else
  failures.each { |f| puts "FAIL: #{f}" }
  exit 1
end
