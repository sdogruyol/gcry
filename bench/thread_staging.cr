# When gcry's staging table is full, which birth does it keep?
#
# `Platform.stage_thread` records a thread from the moment `pthread_create`
# returns, and `stop_world`'s pre-stop wait uses that record to wait for it to
# publish itself. A thread with no record is not waited for: the world stops
# with it unpublished, so it is neither suspended nor scanned, and anything
# reachable only from its stack has no root. `ThreadBirthRoot` covers the
# `Thread` object and nothing else that thread has touched.
#
# A slot is freed when the thread turns up in Crystal's list, and until
# 2026-08-22 the only thing that looked was the collection's own walk — so the
# table held every thread created **since the last collection**, not the ones
# being born. 65 `Thread.new`s with none in between filled it; at 200 only 73
# of 201 births were recorded at all. And the one it refused was the newest:
# the thread actually inside the window the table exists to see.
#
#   default    the birth handed to a full table is recorded. The full path
#              drains entries whose threads have published, and evicts the
#              oldest if that frees nothing.
#   --no-evict `GCRY_STAGED_NO_EVICT=1` — the old behaviour. The same birth must
#              be **absent**, or the arm above is passing for another reason.
#
# The table is filled with raw pthreads, which never join Crystal's list, so
# neither the drain nor anything else can release them: the full table is a
# fact of the harness rather than a race it hopes for.
#
#   crystal build -Dgc_none bench/thread_staging.cr -o bin/thread_staging
#   bin/thread_staging
#   GCRY_STAGED_NO_EVICT=1 bin/thread_staging --no-evict

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "thread_staging requires -Dgc_none (gcry as process GC)" %}
{% end %}

# Exits immediately. The record outlives the thread, and is deliberately never
# joined: glibc recycles a `pthread_t` once its thread is joined, and a recycled
# id could collide with a real Crystal thread's and let the collection's walk
# release one of these slots.
def staging_filler(arg : Void*) : Void*
  arg
end

def spawn_raw : LibC::PthreadT
  handle = uninitialized LibC::PthreadT
  rc = GC.pthread_create(
    thread: pointerof(handle),
    attr: Pointer(LibC::PthreadAttrT).null,
    start: ->staging_filler(Void*),
    arg: Pointer(Void).new(0x1000_u64),
  )
  raise "pthread_create failed: #{rc}" unless rc == 0
  handle
end

def staged?(id : UInt64) : Bool
  found = false
  Gcry::Platform.each_staged { |staged| found = true if staged == id }
  found
end

no_evict = ARGV.includes?("--no-evict")
mode = no_evict ? "no-evict (GCRY_STAGED_NO_EVICT=1, the old refusal)" : "default (drain, then evict the oldest)"

puts "=== thread staging table ==="
puts "mode: #{mode}"

slots = Gcry::Platform::STAGED_SLOTS
overflows_before = Gcry::Platform.staged_overflows

# Fill it. One per slot is enough on an idle program, and a few more make the
# arm independent of whatever Crystal has staged already.
(slots + 4).times { spawn_raw }

filled = Gcry::Platform.staged_count
overflowed = Gcry::Platform.staged_overflows > overflows_before

# The birth under test: the one handed to a table that is already full.
in_flight = spawn_raw.unsafe_as(UInt64)
recorded = staged?(in_flight)

puts "slots=#{slots} staged_count=#{filled} total=#{Gcry::Platform.staged_total} " \
     "overflows=#{Gcry::Platform.staged_overflows} evictions=#{Gcry::Platform.staged_evictions}"
puts "in-flight birth 0x#{in_flight.to_s(16)}: staged=#{recorded}"

failures = [] of String

failures << "the table never filled (#{filled} of #{slots}), so nothing was under test" if filled < slots
failures << "no birth found the table full, so this arm never reached the overflow path" unless overflowed

if no_evict
  failures << "the old behaviour recorded the birth anyway — the other arm's " \
              "success cannot be credited to the eviction" if recorded
  failures << "the old behaviour evicted something, which it is not supposed to do" if Gcry::Platform.staged_evictions > 0
else
  unless recorded
    failures << "the birth handed to a full table was refused — the thread in its birth window " \
                "is the one that will not be waited for"
  end
  failures << "nothing was evicted, so the record came from somewhere other than the eviction" if Gcry::Platform.staged_evictions == 0
end

if failures.empty?
  puts
  puts(no_evict ? "ok — a full table refuses the newest birth, which is what the eviction replaces" \
                   : "ok — the birth in flight is recorded even when the table is full")
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
