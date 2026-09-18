require "../src/gcry"
require "./bounded_child"

# Can a thread walk the STW capture table while another thread grows it?
#
# `Gcry::StwSlots` publishes a new, bigger block with a single pointer store and
# **never frees the predecessor**. That is the whole reason the growth is safe:
# a reader — a suspend handler on Darwin, the stop loop on Windows — loads the
# table pointer once and then walks through it, and nothing stops a grow from
# landing in between. Freeing the old block there is a use-after-free in code
# that runs inside the stopped world, with no allocator and no way to report.
#
# No serial test can show that. `spec/stw_slots_spec.cr` covers the shape of the
# table — slots, claims, the 65th thread, pinning, preserved captures across a
# grow — and all of it passes with the predecessor freed, because nothing is
# reading it. The property needs a reader *inside* the old block at the moment it
# goes away, which means threads, a big enough block that the allocator unmaps it
# instead of recycling it, and a crash as the observable.
#
# So it lives here, as a gate with a deadline, and not in a spec suite: the first
# attempt put a four-reader busy loop in `crystal spec`, where it held the
# two-vCPU Windows runner for that job's whole 20-minute budget and was killed as
# an orphan process (run `35361339084`).
#
# Two arms, each a bounded child:
#
#   * **hold** — the shipped table. Every child must finish cleanly, and must
#     report that its readers ran across every growth step.
#   * **free** — `GCRY_STW_SLOTS_FREE_OLD=1`, which frees the predecessor. These
#     children must die. If they stop dying, this gate has stopped measuring the
#     thing it was built for.
module StwSlotsGrowRace
  READERS      =  4
  IDS          = 96
  DOUBLINGS    = 12
  ATTEMPTS     =  3
  MIN_FAULTS   =  2
  CHILD_BUDGET = 60.seconds

  def self.child : Int32
    Gcry::StwSlots.free_old = true if ENV["GCRY_STW_SLOTS_FREE_OLD"]? == "1"
    Gcry::StwSlots.reset_for_test
    Gcry::StwSlots.configure(8)

    base = 0xc000_u64
    IDS.times { |i| Gcry::StwSlots.slot_for(base + i) }

    stop = Atomic(Int32).new(0)
    passes = Atomic(Int64).new(0_i64)
    readers = Array(Thread).new(READERS) do
      Thread.new do
        # Flat out on purpose: the window between "loaded the table pointer" and
        # "read through it" is what this gate is trying to be inside of.
        while stop.get == 0
          IDS.times do |i|
            Gcry::StwSlots.sp(base + i)
            Gcry::StwSlots.each_greg(base + i) { |_| }
          end
          passes.add(1_i64)
        end
      end
    end

    want = Gcry::StwSlots::INITIAL_SLOTS
    grown = 0
    DOUBLINGS.times do
      want *= 2
      break unless Gcry::StwSlots.reserve(want)
      grown += 1
      # Long enough for every reader to be somewhere inside the block that the
      # next step replaces.
      Thread.sleep(2.milliseconds)
    end

    stop.set(1)
    readers.each(&.join)

    puts "child: grown=#{grown} capacity=#{Gcry::StwSlots.capacity} reader_passes=#{passes.get}"
    return 1 if grown < DOUBLINGS
    return 1 if passes.get <= 0
    0
  end

  def self.parent : Int32
    exe = Process.executable_path || PROGRAM_NAME
    failures = 0

    puts "stw-slots-grow-race: #{READERS} readers walking #{IDS} slots while the table doubles #{DOUBLINGS}x"
    puts

    survived = 0
    ATTEMPTS.times do |i|
      r = BoundedChild.run(exe, ["--child"], timeout: CHILD_BUDGET)
      survived += 1 if r.ok
      puts "  hold #{i + 1}/#{ATTEMPTS}: #{r.ok ? "ok" : "FAILED"} #{r.output.lines.last? || ""}"
    end
    puts "hold: #{survived}/#{ATTEMPTS} children finished cleanly"
    if survived != ATTEMPTS
      puts "FAIL: the shipped table must survive readers walking it during a grow"
      failures += 1
    end
    puts

    faulted = 0
    ATTEMPTS.times do |i|
      r = BoundedChild.run(exe, ["--child"],
        env: {"GCRY_STW_SLOTS_FREE_OLD" => "1"},
        timeout: CHILD_BUDGET)
      faulted += 1 unless r.ok
      puts "  free #{i + 1}/#{ATTEMPTS}: #{r.ok ? "survived" : "died"}"
    end
    puts "free: #{faulted}/#{ATTEMPTS} children died with the predecessor freed"
    if faulted < MIN_FAULTS
      puts "FAIL: freeing the predecessor must be observable here — #{faulted}/#{ATTEMPTS} is not"
      puts "      (either the readers stopped reaching the old block, or the"
      puts "      allocator started recycling it instead of unmapping it; this"
      puts "      gate is worthless until that is fixed, not passing)"
      failures += 1
    end
    puts

    if failures == 0
      puts "ok — the table carries readers across #{DOUBLINGS} growth steps, and freeing"
      puts "     the predecessor kills #{faulted}/#{ATTEMPTS} of them (src/gcry/stw_slots.cr)."
      0
    else
      1
    end
  end

  def self.main : Int32
    ARGV.includes?("--child") ? child : parent
  end
end

exit StwSlotsGrowRace.main
