# How many threads does the OS say this process has?
#
# gcry learns about threads from Crystal's list — `stop_world` suspends what
# `Thread.unsafe_each` yields, and the stack scans walk the same set. A thread
# that exists at the OS level but has not yet pushed itself onto
# `Thread.threads` is therefore neither stopped nor scanned: it runs through the
# stopped world, and anything reachable only from it is unrooted.
#
# That window is argued for from Crystal's source in
# `bench/log/linux/2026-08-17-thread-birth-window/FINDINGS.md`, and an argument
# is not a measurement. This is the measurement: at `stop_world`, count what the
# list yields and ask the kernel what the process actually has. A difference is
# a thread outside the stopped world, and its size is the size of the window.
#
# A count is where this stopped until 2026-09-19, and a count cannot be acted
# on. `test (aarch64 native)` reports a gap of exactly one on **every**
# collection of `scheduler_roots --control` — an arm that starts no workers and
# no execution context — in 40 of 40 green runs, while the same binary on an
# x86_64 box reports none. "One thread is outside Crystal's list" has been true
# and useless for a month. So the walk below names them: kernel thread id and
# `comm` for every task, which is what tells a birth window apart from a thread
# that was never going to be on Crystal's list at all.
#
# Raw syscalls into stack buffers — no allocation, callable with the world
# stopped. Linux only; `/proc/self/status` has no portable equivalent, and
# `darwin_thread_census.cr` answers `nil` rather than a number nobody measured.
{% skip_file unless flag?(:linux) %}

require "c/sys/uio"

lib LibC
  # glibc ≥ 2.30 and musl both export this; the alternative is a raw
  # `syscall(SYS_getdents64, …)` with a per-architecture number, and a wrong
  # constant there is a silent misread rather than a link error.
  fun getdents64(fd : Int, dirp : Void*, count : UInt) : Int
  fun gettid : Int
  fun pthread_setname_np(thread : PthreadT, name : Char*) : Int

  # Reading another thread's stack means reading memory that thread can be
  # unmapping. A plain load there is the shape that has already crashed this
  # collector once — `pthread_kill(id, 0)` dereferencing a freed
  # `struct pthread`, 3 of 3. `process_vm_readv` against our own pid answers
  # **EFAULT** instead of signalling, so however wrong the address is the
  # question cannot fault. glibc ≥ 2.15.
  fun process_vm_readv(pid : PidT, local_iov : Iovec*, liovcnt : ULong,
                       remote_iov : Iovec*, riovcnt : ULong, flags : ULong) : SSizeT
end

module Gcry
  module Platform
    # The kernel's thread count for this process, or `nil` when `/proc` cannot
    # answer. Nil rather than 0: a caller comparing counts must be able to tell
    # "no threads" from "no answer" — the distinction the Darwin RSS reader did
    # not make, and passed a gate by measuring nothing for three releases.
    def self.os_thread_count : Int32?
      fd = LibC.open("/proc/self/status".to_unsafe.as(LibC::Char*), 0) # O_RDONLY
      return nil if fd < 0
      buf = uninitialized UInt8[2048]
      n = LibC.read(fd, buf.to_unsafe.as(Void*), 2047.to_u64)
      LibC.close(fd)
      return nil if n <= 0
      parse_threads_line(buf.to_unsafe, n.to_i32)
    end

    # The `comm` gcry gives the raw pthreads it creates for parallel mark.
    # 15 bytes is the kernel's limit for a thread name and this fits.
    #
    # Naming them is what lets the census tell its own helpers apart from a
    # mutator it has never heard of. They are raw `pthread_create` threads on
    # purpose (`parallel_mark.cr`: a Crystal::Thread would freeze in
    # `stop_world`), so they are outside Crystal's list *by construction* and
    # the census counted every one of them as a thread "running through this
    # stopped world, unscanned" — measured 2026-09-19 at `GCRY_PARALLEL_MARK=4`:
    # `gap=3`, which is the three helpers and nothing else.
    #
    # The classification is by name, and the report prints the name it used, so
    # a reader can audit it. A mutator that calls itself `gcry-mark` would be
    # miscounted; nothing in Crystal does, and the alternative — a tid table the
    # helpers register into — has to be read from inside the stop while they
    # write it.
    OWN_THREAD_COMM = "gcry-mark"

    # Called by the **creating** thread on the handle `pthread_create` just
    # returned, not by the helper on itself. The same placement, and the same
    # reason, as `thread_staging.cr`: a thread naming itself leaves a window
    # between `pthread_create` returning and the name landing, and the census
    # lands in it. Measured on `test (aarch64 native)`, run `35448782491`, with
    # the helper naming itself —
    #
    #   OS tasks: … 7743:gcry-mark 7744:gcry-mark 7745:thread_census_n
    #             — 2 are gcry's own mark helpers, leaving 2 unexplained
    #
    # then `3 … leaving 1` on the next collection: the third helper existed,
    # still wearing its creator's inherited `comm`, and was counted as a
    # mutator gcry had never heard of. From the creating side the window
    # cannot be observed, because the creator is the collector and it cannot
    # be inside `ensure_mark_pthreads` and inside a stop at the same time.
    def self.name_own_thread(handle : Gcry::OS::PthreadT) : Nil
      LibC.pthread_setname_np(handle, OWN_THREAD_COMM.to_unsafe.as(LibC::Char*))
    end

    def self.own_thread_comm?(name : UInt8*, len : Int32) : Bool
      return false unless len == OWN_THREAD_COMM.bytesize
      matches?(name, OWN_THREAD_COMM, len)
    end

    # This thread's kernel id. Used to keep the report honest about itself:
    # a thread reading `/proc/self/task/<own tid>/syscall` is inside `read`
    # while it reads, so it reports itself parked in the very call that is
    # asking. Measured — the collector came out as "parked in syscall 0".
    def self.current_tid : Int32
      LibC.gettid
    end

    # The mapping a program counter lands in, as `name, name_len, offset`.
    # Returns false when no mapping holds it, which is a different answer from
    # an anonymous one (`name_len == 0`) and is reported as such — the rule
    # `segv_region_report` already follows.
    #
    # The offset is from the file's **load base**, not from the mapping the pc
    # happens to be in. That distinction is the difference between a number
    # `addr2line` resolves and one it does not: a PIE has several LOAD
    # segments and the executable one does not start at the base, so
    # `pc - text_start` names nothing. The lowest mapping of the same
    # pathname is the base, which is how `dladdr` and `perf` reach it too.
    def self.pc_mapping(pc : UInt64, & : UInt8*, Int32, UInt64 ->) : Bool
      hold = uninitialized UInt8[192]
      hold_len = 0
      base = 0_u64
      found = false
      each_map_region do |lo, hi, _perms, name, name_len|
        if !found && pc >= lo && pc < hi
          found = true
          base = lo
          hold_len = name_len < 192 ? name_len : 192
          i = 0
          while i < hold_len
            hold[i] = name[i]
            i += 1
          end
        end
      end
      return false unless found

      if hold_len > 0
        each_map_region do |lo, _hi, _perms, name, name_len|
          if name_len == hold_len && lo < base && same_bytes?(name, hold.to_unsafe, hold_len)
            base = lo
          end
        end
      end
      # `hold` rather than the walk's buffer: that one is reused per line, and
      # the second walk has already overwritten the name by now.
      yield hold.to_unsafe, hold_len, pc - base
      true
    end

    private def self.same_bytes?(a : UInt8*, b : UInt8*, len : Int32) : Bool
      i = 0
      while i < len
        return false if a[i] != b[i]
        i += 1
      end
      true
    end

    # Fault-safe read of this process's own memory. Returns bytes read, 0 on
    # any refusal — see the `process_vm_readv` note above for why a plain load
    # is not an option here.
    def self.read_self_memory(remote : UInt64, dst : Void*, bytes : Int32) : Int32
      return 0 if bytes <= 0 || remote == 0
      local = LibC::Iovec.new(iov_base: dst, iov_len: LibC::SizeT.new(bytes))
      far = LibC::Iovec.new(iov_base: Pointer(Void).new(remote), iov_len: LibC::SizeT.new(bytes))
      n = LibC.process_vm_readv(LibC.getpid, pointerof(local), 1_u64, pointerof(far), 1_u64, 0_u64)
      n <= 0 ? 0 : n.to_i32
    end

    # Executable mappings this process has. More than this many and the tail
    # is dropped, which can only lose a candidate, never invent one.
    MAX_CODE_RANGES = 48

    # Words of a thread's stack to look at, from its SP upward.
    STACK_SCAN_WORDS = 512

    # Yields each word at or above `sp` that lands in an executable mapping,
    # up to `max_hits`. A return address is such a word; so is any stale copy
    # of one, which is why this is a *conservative* read and is reported as a
    # set of frames the thread returns through rather than a backtrace.
    #
    # The pc from `/proc/self/task/<tid>/syscall` names the libc wrapper a
    # thread is sleeping in and nothing above it. These words are the callers,
    # and the one that lands in the main binary is the thing that created the
    # frame.
    #
    # Bounded by the stack mapping the SP is in, so the scan cannot wander
    # into an unrelated region, and every read is fault-safe regardless.
    def self.each_stack_code_address(sp : UInt64, max_hits : Int32, & : UInt64 ->) : Bool
      return false if sp == 0

      code_lo = uninitialized UInt64[MAX_CODE_RANGES]
      code_hi = uninitialized UInt64[MAX_CODE_RANGES]
      ranges = 0
      stack_end = 0_u64
      walked = each_map_region do |lo, hi, perms, _name, _name_len|
        stack_end = hi if sp >= lo && sp < hi
        if perms[2] == 'x'.ord.to_u8 && ranges < MAX_CODE_RANGES
          code_lo[ranges] = lo
          code_hi[ranges] = hi
          ranges += 1
        end
      end
      return false unless walked && ranges > 0 && stack_end > sp

      words = uninitialized UInt64[64]
      addr = sp
      seen = 0
      hits = 0
      while seen < STACK_SCAN_WORDS && hits < max_hits && addr < stack_end
        want = 64
        left = ((stack_end - addr) // 8).to_i32
        want = left if left < want
        budget = STACK_SCAN_WORDS - seen
        want = budget if budget < want
        break if want <= 0

        got = read_self_memory(addr, words.to_unsafe.as(Void*), want * 8)
        break if got < 8

        i = 0
        while i < got // 8 && hits < max_hits
          word = words[i]
          j = 0
          while j < ranges
            if word >= code_lo[j] && word < code_hi[j]
              hits += 1
              yield word
              break
            end
            j += 1
          end
          i += 1
        end
        addr &+= got.to_u64
        seen += got // 8
      end
      true
    end

    # Yields `tid, comm, comm_len` for every task in this process. `comm` points
    # into a buffer this method reuses, so it is valid only inside the block.
    #
    # Returns false when `/proc/self/task` could not be walked, so "named
    # nothing" and "could not look" stay distinguishable — the same rule
    # `os_thread_count` follows.
    def self.each_os_thread(& : Int32, UInt8*, Int32 ->) : Bool
      fd = LibC.open("/proc/self/task".to_unsafe.as(LibC::Char*), 0) # O_RDONLY
      return false if fd < 0

      begin
        dirents = uninitialized UInt8[4096]
        comm = uninitialized UInt8[64]
        loop do
          n = LibC.getdents64(fd, dirents.to_unsafe.as(Void*), 4096_u32)
          break if n <= 0

          off = 0
          while off < n
            entry = dirents.to_unsafe + off
            # struct linux_dirent64: d_ino(8) d_off(8) d_reclen(2) d_type(1)
            # d_name[] — so the record length is at +16 and the name at +19.
            reclen = (entry + 16).as(UInt16*).value.to_i32
            break if reclen <= 0
            off += reclen

            tid = parse_tid(entry + 19, reclen - 19)
            next unless tid
            len = read_comm(tid, comm.to_unsafe, 64)
            yield tid, comm.to_unsafe, len
          end
        end
      ensure
        LibC.close(fd)
      end
      true
    end

    # `/proc/self/task/<tid>/comm` without its trailing newline, or 0 bytes when
    # the task exited between the walk and this read — which is not an error:
    # a task list sampled from /proc is a snapshot of a moving set.
    private def self.read_comm(tid : Int32, dst : UInt8*, cap : Int32) : Int32
      path = uninitialized UInt8[64]
      len = build_comm_path(path.to_unsafe, tid)
      return 0 if len == 0
      fd = LibC.open(path.to_unsafe.as(LibC::Char*), 0)
      return 0 if fd < 0
      n = LibC.read(fd, dst.as(Void*), LibC::SizeT.new(cap))
      LibC.close(fd)
      return 0 if n <= 0
      size = n.to_i32
      while size > 0 && (dst[size - 1] == '\n'.ord.to_u8 || dst[size - 1] == 0_u8)
        size -= 1
      end
      size
    end

    # "/proc/self/task/<tid>/comm\0", built by hand: interpolation allocates.
    private def self.build_comm_path(dst : UInt8*, tid : Int32) : Int32
      prefix = "/proc/self/task/"
      suffix = "/comm"
      i = 0
      while i < prefix.bytesize
        dst[i] = prefix.to_unsafe[i]
        i += 1
      end
      digits = uninitialized UInt8[12]
      d = 0
      value = tid
      return 0 if value <= 0
      while value > 0
        digits[d] = ('0'.ord + (value % 10)).to_u8
        d += 1
        value //= 10
      end
      while d > 0
        d -= 1
        dst[i] = digits[d]
        i += 1
      end
      j = 0
      while j < suffix.bytesize
        dst[i] = suffix.to_unsafe[j]
        i += 1
        j += 1
      end
      dst[i] = 0_u8
      i
    end

    # A task directory name is all digits; `.` and `..` are not.
    private def self.parse_tid(name : UInt8*, cap : Int32) : Int32?
      value = 0
      i = 0
      while i < cap && name[i] != 0_u8
        c = name[i]
        return nil if c < '0'.ord.to_u8 || c > '9'.ord.to_u8
        value = value * 10 + (c - '0'.ord.to_u8).to_i32
        i += 1
      end
      i > 0 ? value : nil
    end

    # Finds `Threads:\t<n>` in a `/proc/self/status` body. Hand-rolled because
    # `String#lines` allocates and this runs inside the pause.
    private def self.parse_threads_line(buf : UInt8*, len : Int32) : Int32?
      key = "Threads:"
      klen = key.bytesize
      i = 0
      while i + klen < len
        # Only at a line start, so a "Threads:" appearing inside another value
        # cannot be matched.
        if (i == 0 || buf[i - 1] == '\n'.ord.to_u8) && matches?(buf + i, key, klen)
          j = i + klen
          while j < len && (buf[j] == ' '.ord.to_u8 || buf[j] == '\t'.ord.to_u8)
            j += 1
          end
          value = 0
          digits = 0
          while j < len && buf[j] >= '0'.ord.to_u8 && buf[j] <= '9'.ord.to_u8
            value = value * 10 + (buf[j] - '0'.ord.to_u8).to_i32
            digits += 1
            j += 1
          end
          return digits > 0 ? value : nil
        end
        i += 1
      end
      nil
    end

    private def self.matches?(at : UInt8*, key : String, klen : Int32) : Bool
      src = key.to_unsafe
      i = 0
      while i < klen
        return false if at[i] != src[i]
        i += 1
      end
      true
    end
  end
end
