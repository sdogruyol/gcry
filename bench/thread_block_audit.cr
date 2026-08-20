# Does the dying-type audit name a block of the watched type that is about to be
# swept — and does it stay quiet when nothing of that type dies?
#
# The arm it gates (`GCRY_THREAD_BLOCK_AUDIT=1`, src/gcry/thread_block_audit.cr)
# exists for one CI question: the `Thread` use-after-free is only ever observed
# on CI, so the instrument aimed at it has to be trusted before it is read
# there. An audit that has never been shown to report anything is worth nothing
# when it reports nothing, and this defect has already produced two readings
# that were wrong in exactly that way — a cleared flag read as "explicit free",
# a zero mark generation read as "never marked".
#
# Four arms, and the type is the knob that makes them possible: `GCRY_DYING_TYPE_ID`
# points the same walk at a type whose life and death this harness controls.
#
#   dies      200 `Probe` objects allocated, dropped, and their frames buried.
#             The audit must name at least one as unmarked-and-about-to-be-swept,
#             and the address-space walk it triggers must have run — that walk
#             is the half the CI job is being wired for.
#   lives     the same 200, held in a rooted array. The audit must find them
#             *marked* (a non-zero `live` count is what says the walk can see
#             this type at all) and report **no** deaths.
#   thread    the shipped default: no id given, so the arm watches `Thread`.
#             Four spinning threads, and the walk must find their blocks live.
#             This is the arm that checks the default is aimed at something real
#             — a `Thread.crystal_instance_type_id` that matched nothing in the
#             heap would make the CI arm silent for a reason that has nothing to
#             do with the defect.
#   --control the knob off, with `dying_type_id` still set by hand: nothing may
#             be walked, so the other arms' counts are attributable to the knob
#             and not to the property.
#
#   crystal build -Dgc_none bench/thread_block_audit.cr -o bin/thread_block_audit
#   bin/thread_block_audit
#   bin/thread_block_audit --control
#
# `--child=<arm>` is the half that runs under the collector; the parent reads its
# stderr, because the audit reports through `RawOut` from inside the pause.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "thread_block_audit requires -Dgc_none (gcry as process GC)" %}
{% end %}

class Probe
  @a : Pointer(Void) = Pointer(Void).null
  @b : Pointer(Void) = Pointer(Void).null
end

class Gate
  @flag = Atomic(Int32).new(0)

  def set : Nil
    @flag.set(1)
  end

  def get : Int32
    @flag.get
  end
end

PROBES = 200

# Allocated and never stored. The only thing that can keep one of these alive is
# a dead slot in this frame, which is what `bury_stack` is for.
@[NoInline]
def drop_probes : Nil
  i = 0
  while i < PROBES
    Probe.new
    i += 1
  end
end

# Overwrite the frames `drop_probes` wrote the addresses into. Without it a
# conservative scan of this thread's stack can hold every probe alive and the
# `dies` arm fails for a reason that is not the audit's.
@[NoInline]
def bury_stack : Nil
  buf = uninitialized UInt8[16384]
  i = 0
  while i < 16384
    buf.to_unsafe[i] = 0xA5_u8
    i += 1
  end
  Gcry::Trace.enabled? && puts(buf.to_unsafe[0])
end

@[NoInline]
def spin_until(go : Gate) : Nil
  while go.get == 0
  end
end

def run_child(arm : String) : NoReturn
  heap = Gcry.default_heap
  # Set in every arm, including the control: the property alone must not turn
  # anything on, or the control proves nothing about the knob.
  heap.dying_type_id = Probe.crystal_instance_type_id.to_u32! unless arm == "thread"

  keeper = [] of Probe
  go = Gate.new
  workers = [] of Thread

  case arm
  when "lives"
    PROBES.times { keeper << Probe.new }
  when "thread"
    4.times { workers << Thread.new { spin_until(go) } }
  else
    drop_probes
    bury_stack
  end

  3.times { GC.collect }

  STDERR.puts "walked=#{heap.dying_type_walked} live=#{heap.dying_type_live} " \
              "deaths=#{heap.dying_type_deaths} audits=#{heap.address_space_audits} " \
              "pop=#{heap.thread_pop_collections} gaps=#{heap.thread_pop_gap_collections} " \
              "staged=#{heap.thread_pop_staged_collections}"

  go.set
  workers.each(&.join)
  # Keep the keeper alive across the collections above.
  Gcry::Roots.keep_alive(keeper.as(Void*))
  exit 0
end

ARGV.each do |arg|
  if arg =~ /--child=(.+)/
    run_child($1)
  end
end

control = ARGV.includes?("--control")
puts "=== dying-type audit ==="
puts "mode: #{control ? "control (GCRY_THREAD_BLOCK_AUDIT unset; nothing may be walked)" : "audit on"}"

exe = Process.executable_path.not_nil!
failures = [] of String

["dies", "lives", "thread"].each do |arm|
  env = {"GCRY_THREAD_BLOCK_AUDIT" => control ? "0" : "1"}
  captured = IO::Memory.new
  Process.run(exe, ["--child=#{arm}"], env: env, output: captured, error: captured)
  text = captured.to_s
  line = text.lines.find(&.starts_with?("walked="))
  unless line
    failures << "#{arm}: the child did not report its counters. What it said:\n#{text.lines.first(8).join("\n")}"
    next
  end
  fields = line.split(' ').to_h { |f| {f.split('=')[0], f.split('=')[1].to_u64} }
  walked = fields["walked"]
  live = fields["live"]
  deaths = fields["deaths"]
  audits = fields["audits"]
  pop = fields["pop"]
  gaps = fields["gaps"]
  staged = fields["staged"]
  puts "#{arm}: #{walked} blocks walked, #{live} live, #{deaths} dying, #{audits} address-space audits, " \
       "#{pop} collections walked for the precondition (#{gaps} with an unbounded thread, #{staged} with a staged one)"

  if control
    if walked > 0 || live > 0 || deaths > 0 || audits > 0 || pop > 0
      failures << "#{arm}: the knob is off and the arm still ran (walked #{walked}, live #{live}, " \
                  "deaths #{deaths}, audits #{audits}, precondition walks #{pop})"
    end
    next
  end

  # The precondition walk runs every collection, crash or not — it is what makes
  # a green CI run say something. A zero here means its counts are not evidence.
  if pop == 0
    failures << "#{arm}: the precondition was never walked, so a zero gap and a zero staged count " \
                "say nothing about this run"
  end

  if walked == 0
    failures << "#{arm}: the audit walked no blocks at all, so its live and death counts mean nothing"
    next
  end

  case arm
  when "dies"
    if deaths == 0
      failures << "dies: #{PROBES} objects of the watched type were dropped and the audit named none " \
                  "of them as dying — it cannot detect the death it exists to detect"
    end
    if audits == 0
      failures << "dies: the audit named a dying block and never asked where its address lives. " \
                  "The address-space walk is the half the CI arm is for"
    end
  when "lives"
    if live == 0
      failures << "lives: #{PROBES} objects of the watched type are held alive and the audit found " \
                  "none of them marked — it is not seeing this type, so its silence is not evidence"
    end
    if deaths > 0
      failures << "lives: #{deaths} block(s) of the watched type reported dying while every one of " \
                  "them is rooted. Either the mark is dropping them or the audit reports deaths that " \
                  "are not real"
    end
  when "thread"
    if live == 0
      failures << "thread: the shipped default watches Thread.crystal_instance_type_id and found no " \
                  "live Thread block with four threads running. The default is aimed at nothing, and " \
                  "a silent CI arm would say nothing about the defect"
    end
  end
end

if failures.empty?
  puts
  if control
    puts "ok — with the knob off nothing is walked, so the other run's counts are attributable to it"
  else
    puts "ok — the audit names a dropped block of the watched type and asks where it lives, stays " \
         "silent while the same objects are held, and finds live Thread blocks under its default"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
