# Is the runtime's thread list still readable when `stop_world` reaches it?
#
# The oldest open crash in this tree is a fault at address `0x18` inside
# `stop_world`:
#
#     pthread_mutex_lock <- Thread::Mutex#lock <- Thread::lock
#     <- Gcry::Heap#stop_world
#
# `Thread::Mutex#lock` is a real frame, so the receiver was fetched and then
# `pointerof(@mutex)` came out at `0x18` — a null reference, not a stray
# pointer. The reference lives in `Thread::LinkedList`'s `@mutex`, a field of a
# heap object written once during boot and only ever read afterwards. A field of
# a live object reading zero is what a released page leaves behind.
#
# Every instrument aimed at this so far has gone quiet, and gone quiet for the
# same reason: it watched objects the *harness* owns, and the victim here is one
# the runtime allocated before any harness existed
# (`bench/log/linux/2026-08-23-threads-null-0x18/FINDINGS.md`).
#
# This one watches the victim. If the list object's memory has been zeroed then
# `@head` is zero along with `@mutex`, so a walk that yields nothing is the same
# damage the fault is about — reported one instruction *before* the fault, with
# the collection number, instead of as an unexplained signal afterwards.
#
# The walk is unlocked on purpose: `Thread.lock` is the call being protected, so
# taking it first would defeat the point. That is safe here in the only sense
# that matters — a concurrent `push` can make the walk miss a node, and missing
# a node cannot turn a non-empty list into an empty one, because a push writes
# `@head` last.
#
# `GCRY_THREAD_LIST_TRIPWIRE=1`, and off by default, because the walk is not
# free of hazards of its own: a worker thread that has exited has removed
# itself from the list and its `Thread` object is ordinary garbage, so an
# unlocked walk that reads a stale `next` can follow it into a chunk gcry has
# legitimately released. A fault raised *by the instrument* under those rules
# says nothing about the defect it was built for, and it looks identical in a
# log. Default-off keeps the two apart: every arm can be run with the walk and
# without it.
#
# Silence is not an answer on its own, so the walk also records the largest
# count it has seen. A tripwire that reports zero threads on a run whose maximum
# was also zero never saw the list at all.
module Gcry
  class Heap
    # Threads the last pre-lock walk found, and the most any walk has found.
    getter thread_list_seen_max : UInt32 = 0_u32
    # Walks that found an empty list after a non-empty one. This is the defect.
    getter thread_list_empty : UInt64 = 0_u64

    # `GCRY_THREAD_LIST_TRIPWIRE=1`.
    property thread_list_tripwire : Bool = false

    protected def check_thread_list_before_lock : Nil
      return unless @thread_list_tripwire
      n = 0_u32
      Thread.unsafe_each { n &+= 1 }

      if n > @thread_list_seen_max
        @thread_list_seen_max = n
        return
      end
      return unless n == 0 && @thread_list_seen_max > 0

      @thread_list_empty &+= 1
      return unless @thread_list_empty == 1

      buf = uninitialized UInt8[256]
      len = 0
      len = RawOut.append(buf.to_unsafe, len,
        "gcry: the runtime thread list reads empty before Thread.lock — it held ")
      len = RawOut.append_u64(buf.to_unsafe, len, @thread_list_seen_max.to_u64)
      len = RawOut.append(buf.to_unsafe, len,
        " threads, so the list object's memory has been zeroed under it. collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end
  end
end
