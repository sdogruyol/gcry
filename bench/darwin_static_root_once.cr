# Can `GC.init`'s eager static-root resolve reach `__crystal_once`?
#
# `Crystal.main` calls `GC.init` and *then* `init_runtime`, which is where
# `Thread.init`, `Fiber.init` and `Crystal::Once.init` happen. Crystal says so
# itself, in a comment above `init_runtime`: "`__crystal_once` directly or
# indirectly depends on `Fiber` and `Thread`". So anything reached from
# `GC.init` that compiles to a `once`-guarded lazy initialiser is a crash
# before `main`, and the crash is a null deref in
# `Fiber.@@fibers.push` — a `Thread::LinkedList` that `Fiber.init` has not
# created yet — reached via `Fiber.current` from `Once.exec`.
#
# That is what stopped Darwin from moving the resolve into `GC.init` on
# 2026-08-2x (CI run 33900305015: "Process terminated because of an invalid
# memory access", macOS runner only). Two class variables in
# `platform/darwin_roots.cr` were the cause:
#
#   @@ranges : RootRange* = Pointer(RootRange).null   # initialiser is a *call*
#   @@cached_generation = UInt32::MAX                 # initialiser is a *path*
#
# Neither needed a guard — the compiler had already folded both values into
# the LLVM global's own initialiser (`ptr null`, `i32 -1`), so the guarded
# store changed nothing — but the `~var:read` accessor calls `__crystal_once`
# on every read regardless, and the accessor for `cached_generation` was the
# first instruction of `ensure_static_root_cache`. A *simple literal*
# initialiser gets no accessor, which is why the neighbouring
# `@@range_count = 0` was always fine and why Linux's file, written with
# `uninitialized` and literals throughout, never hit this.
#
# A runtime arm ("the binary still starts") is not enough to keep that fixed:
# it passes for whichever reason, including a `once` that happens to be
# initialised earlier by something else. So this gate reads the *emitted IR*
# and walks the call graph.
#
# The invariant, stated exactly: **no `__crystal_once` is reachable from
# `ensure_static_root_cache` along any path that can return.** Paths through a
# panic door are excluded — `__crystal_raise*`, `__crystal_malloc*` and every
# `:NoReturn` function — because every Crystal `+` on an `Int32` and every
# `StaticArray#[]` compiles to one, and a process that has reached `raise
# IndexError` inside `GC.init` is already over. Excluding them is what makes
# the invariant satisfiable rather than aspirational; not excluding anything
# else is what gives it teeth.
#
# Arms:
#
#   ir-green   the shipped build: no `once` on a returning path. **The gate.**
#   ir-red     `-Dgcry_static_root_once` restores the `@@cached_generation`
#              initialiser — the accessor that was the resolve's first
#              instruction. `@@ranges` has no arm because the pointer table it
#              guarded is a fixed `StaticArray` now. The same walk must *find*
#              the edge; without this arm the green one could pass by the walk
#              being broken.
#   run-green  the shipped binary must start and exit 0.
#   run-red    the `-Dgcry_static_root_once` binary must die by signal. This
#              is what says the IR edge is fatal rather than cosmetic.
#
#   crystal build bench/darwin_static_root_once.cr -o bin/darwin_static_root_once
#   bin/darwin_static_root_once

require "file_utils"

CRYSTAL = ENV["CRYSTAL"]? || "crystal"
SOURCE  = "samples/min.cr"
START   = "*Gcry::Platform::ensure_static_root_cache:Nil"
ONCE    = "__crystal_once"

DEFINE_RE = /^define\s+.*?@(?:"([^"]+)"|([\w.$]+))\s*\(/
CALL_RE   = /\b(?:call|invoke)\b.*?@(?:"([^"]+)"|([A-Za-z_$][\w.$]*))\s*\(/

# The panic doors. A callee that cannot return is not on a path the resolve
# takes when it succeeds.
def door?(sym : String) : Bool
  return true if sym.starts_with?("__crystal_raise")
  return true if sym.starts_with?("__crystal_malloc")
  return true if sym.starts_with?("__crystal_realloc")
  sym.ends_with?(":NoReturn")
end

# `Process::Status#exit_code` raises on an abnormal exit, and the red arm's
# whole point is that it dies by signal.
def outcome(status : Process::Status) : String
  status.normal_exit? ? "exit=#{status.exit_code}" : "signal=#{status.exit_signal}"
end

def call_graph(path : String) : Hash(String, Set(String))
  graph = Hash(String, Set(String)).new
  current = nil.as(String?)
  File.each_line(path) do |line|
    if line.starts_with?("define ")
      if m = DEFINE_RE.match(line)
        current = m[1]? || m[2]?
        graph[current.not_nil!] ||= Set(String).new
      end
      next
    end
    if line.starts_with?("}")
      current = nil
      next
    end
    cur = current
    next unless cur
    next unless line.includes?("call ") || line.includes?("invoke ")
    if m = CALL_RE.match(line)
      callee = m[1]? || m[2]?
      graph[cur] << callee if callee
    end
  end
  graph
end

# Shortest path from `start` to `target` that never enters a panic door.
def returning_path(graph : Hash(String, Set(String)), start : String, target : String) : Array(String)?
  return nil unless graph.has_key?(start)
  seen = Set(String){start}
  queue = Deque(Tuple(String, Array(String))).new
  queue << {start, [start]}
  while entry = queue.shift?
    fn, trail = entry
    graph[fn]?.try &.each do |callee|
      return trail + [callee] if callee == target
      next if seen.includes?(callee) || door?(callee)
      seen << callee
      queue << {callee, trail + [callee]}
    end
  end
  nil
end

def emit_ir(dir : String, name : String, extra : Array(String)) : Tuple(String, String)
  bin = File.join(dir, name)
  args = ["build", "-Dgc_none", "--emit", "llvm-ir"] + extra + [SOURCE, "-o", bin]
  err = IO::Memory.new
  status = Process.run(CRYSTAL, args, output: Process::Redirect::Inherit, error: err)
  unless status.success?
    STDERR.puts "FAIL: #{CRYSTAL} #{args.join(' ')} exited #{status.exit_code}"
    STDERR.puts err.to_s
    exit 1
  end
  {bin, "#{bin}.ll"}
end

{% unless flag?(:darwin) %}
  # `-Dgcry_static_root_once` only reaches `platform/darwin_roots.cr`, so the
  # red arm cannot reproduce anywhere else and a green here would mean the
  # walk found nothing rather than that there is nothing to find. Linux's
  # equivalent file is written with `uninitialized` and simple literals
  # throughout and has never had this defect.
  puts "=== darwin static root once ==="
  puts "SKIP — Darwin only. -Dgcry_static_root_once is a knob on"
  puts "src/gcry/platform/darwin_roots.cr; there is no red arm on this platform."
  exit 0
{% end %}

puts "=== darwin static root once ==="
unless File.exists?(SOURCE)
  STDERR.puts "FAIL: #{SOURCE} not found — run from the repository root"
  exit 1
end

failures = [] of String
dir = File.tempname("gcry-once")
Dir.mkdir_p(dir)

begin
  green_bin, green_ll = emit_ir(dir, "green", [] of String)
  red_bin, red_ll = emit_ir(dir, "red", ["-Dgcry_static_root_once"])

  green = call_graph(green_ll)
  red = call_graph(red_ll)
  puts "  IR functions: green=#{green.size} red=#{red.size}"

  unless green.has_key?(START)
    failures << "ir: #{START} is not defined in the emitted IR. Either the eager " \
                "resolve was removed from GC.init, or the symbol was renamed — " \
                "either way this gate is no longer watching anything"
  end

  green_path = returning_path(green, START, ONCE)
  red_path = returning_path(red, START, ONCE)

  if green_path
    failures << "ir-green: __crystal_once is reachable from #{START} on a path that " \
                "can return, so GC.init runs a once-guarded initialiser before " \
                "init_runtime:\n    " + green_path.join("\n    -> ")
  else
    puts "  ir-green: no __crystal_once on any returning path from the resolve"
  end

  if red_path
    puts "  ir-red:   -Dgcry_static_root_once puts the edge back (#{red_path.size} hops): " \
         "#{red_path[1]}"
  else
    failures << "ir-red: -Dgcry_static_root_once did *not* reproduce a once edge. The " \
                "red arm is what proves the walk can find one at all, so the green " \
                "arm above is vacuous until this fails"
  end

  green_run = Process.run(green_bin, output: Process::Redirect::Close, error: Process::Redirect::Close)
  red_run = Process.run(red_bin, output: Process::Redirect::Close, error: Process::Redirect::Close)
  puts "  run-green: #{outcome(green_run)}"
  puts "  run-red:   #{outcome(red_run)}"

  unless green_run.normal_exit? && green_run.exit_code == 0
    failures << "run-green: the shipped build ended #{outcome(green_run)} — the eager " \
                "resolve is crashing for a reason this gate has not named"
  end
  if red_run.normal_exit? && red_run.exit_code == 0
    failures << "run-red: the -Dgcry_static_root_once build exited 0. The once edge is " \
                "present in its IR but no longer fatal, so nothing here shows why the " \
                "declarations must stay literal — re-attribute before trusting the " \
                "green arm"
  end
ensure
  FileUtils.rm_rf(dir)
end

puts
if failures.empty?
  puts "VERDICT: GC.init's static-root resolve reaches no once-guarded initialiser on " \
       "any returning path, and restoring the `cached_generation` initialiser both " \
       "reintroduces the edge and kills the process before main."
  exit 0
end

failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
