# ping_nogc.cr plus a record of who each Parallel worker is resuming. On a
# stall a plain watchdog thread prints, per worker thread: the fiber it is
# running (the one that suspended) and the fiber `resume` is spinning on.
# The circular-wait hypothesis predicts w-0's target == w-1's current and
# w-1's target == w-0's current.
SLOTS = 4

# A class, not `StaticArray(Atomic)`: indexing a StaticArray of structs
# returns a copy, and the first version of this recorded into copies.
class Slot
  property current = 0_u64
  property target = 0_u64
  property resumable_at_entry = true
end

SLOT     = Array.new(SLOTS) { Slot.new }
PROGRESS = Atomic(UInt64).new(0_u64)

def slot_of_thread : Int32
  name = Thread.current.name || ""
  if name.starts_with?("w-")
    name[2..].to_i? || -1
  else
    -1
  end
end

FIX       = ENV["FIX"]? == "1"
MAX_SPINS = 1000
GAVE_UP   = Atomic(Int32).new(0)

class Fiber::ExecutionContext::Parallel::Scheduler
  protected def resume(fiber : Fiber) : Nil
    s = slot_of_thread
    if 0 <= s < SLOTS
      SLOT[s].current = Fiber.current.object_id
      SLOT[s].target = fiber.object_id
      SLOT[s].resumable_at_entry = fiber.resumable?
    end
    attempts = 0
    # `Thread.delay` returns a backoff that wraps to 0 after 7, not a count:
    # the first version compared it to MAX_SPINS and never gave up.
    spins = 0
    until fiber.resumable?
      raise "BUG: tried to resume dead fiber #{fiber}" if fiber.dead?
      # The candidate: stop waiting on a fiber whose context another thread has
      # not saved yet; requeue it and go back to this scheduler's main loop,
      # which saves *our* current fiber and so ends any spin waiting on it.
      # Never from the main loop fiber itself: it has nowhere to go, and no
      # cycle can pass through it (its thread runs no fiber while it spins).
      if FIX && spins >= MAX_SPINS && !thread.current_fiber.same?(main_fiber)
        GAVE_UP.add(1)
        SLOT[s].target = 0_u64 if 0 <= s < SLOTS
        enqueue(fiber)
        swapcontext(main_fiber)
        return
      end
      attempts = Thread.delay(attempts)
      spins += 1
    end
    SLOT[s].target = 0_u64 if 0 <= s < SLOTS
    swapcontext(fiber)
  end
end

workers = (ARGV[0]? || "2").to_i
rounds = (ARGV[1]? || "4000").to_i
out_ch = Channel(Int32).new
ack_ch = Channel(Nil).new
ctx = Fiber::ExecutionContext::Parallel.new("w", workers)
names = {} of UInt64 => String
names_lock = Thread::Mutex.new
workers.times do |w|
  f = ctx.spawn(name: "worker-fiber-#{w}") do
    rng = Random.new(w)
    begin
      loop do
        out_ch.send w
        ack_ch.receive
        Fiber.yield if rng.rand(0..15) == 0
      end
    rescue Channel::ClosedError
    end
  end
  names_lock.synchronize { names[f.object_id] = "worker-fiber-#{w}" }
end
names[Fiber.current.object_id] = "main-fiber"

Thread.new(name: "watch") do
  last = 0_u64
  still = 0
  loop do
    ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 500_000_000)
    LibC.nanosleep(pointerof(ts), nil)
    now = PROGRESS.get
    if now == last
      still += 1
    else
      still = 0
      last = now
    end
    if still >= 6
      msg = String.build do |io|
        io << "STALL after " << now << " round trips\n"
        workers.times do |i|
          cur = SLOT[i].current
          tgt = SLOT[i].target
          io << "  w-" << i << ": running " << (names[cur]? || cur.to_s(16)) << ", resuming " << (tgt == 0 ? "-" : (names[tgt]? || tgt.to_s(16))) \
            << " (target resumable at entry: " << SLOT[i].resumable_at_entry << ")\n"
        end
        circular = workers == 2 && SLOT[0].target == SLOT[1].current && SLOT[1].target == SLOT[0].current && SLOT[0].target != 0
        io << "  circular wait: " << circular << "\n"
      end
      LibC.write(2, msg.to_unsafe, msg.bytesize)
      LibC._exit(3)
    end
  end
end

rounds.times do
  out_ch.receive
  ack_ch.send nil
  PROGRESS.add(1)
end
out_ch.close
ack_ch.close
puts "ok gave_up=#{GAVE_UP.get}"
