# Audit-only: read foreign thread stack pointers from /proc, without a signal.
#
# `Platform.thread_sp` only knows about threads the STW suspend handler ran on.
# The EC Monitor (SYSMON) is signal-exempt (`stw_signal_exempt?`), so its SP is
# never recorded — and SYSMON is precisely the thread the EC1 scrub exemption is
# about. That made the parked-fiber audit structurally blind to the one shape it
# exists to test: it could only ever report "0 foreign-SP scrubs", which is not
# evidence of safety.
#
# `/proc/self/task/<tid>/syscall` reports a blocked thread's user SP as its
# second-to-last field, for every thread, with no signal and no cooperation.
#
# Two rules make this safe to call from inside STW:
#
#   * **No allocation.** The tid list is refreshed outside STW by the audit
#     harness (`audit_refresh_tids`); the read path uses raw open/read/close
#     into stack buffers. Allocating while the world is stopped can deadlock on
#     a lock a suspended thread holds.
#   * **Read-only.** Nothing here perturbs the threads being measured.
#
# Conservative in the right direction: a signal-suspended thread's /proc SP is
# its *handler* frame, which sits below the interrupted SP, so the live-frame
# region [sp, bottom) comes out larger than reality. An audit that errs toward
# reporting overlap is the one you want.
{% skip_file unless flag?(:linux) %}

lib LibC
  fun open(path : Char*, oflag : Int, ...) : Int
  fun read(fd : Int, buf : Void*, count : SizeT) : SSizeT
  fun close(fd : Int) : Int
end

module Gcry
  module Platform
    MAX_AUDIT_TIDS = 128

    @@audit_tids = uninitialized StaticArray(Int32, MAX_AUDIT_TIDS)
    @@audit_tid_count = 0
    @@audit_sps = uninitialized StaticArray(UInt64, MAX_AUDIT_TIDS)
    @@audit_sp_count = 0

    # Refresh the thread-id list. **Call outside STW** — this allocates.
    # The thread set is stable across a run, so once before the collect loop is
    # enough; call again after spawning threads.
    def self.audit_refresh_tids : Int32
      n = 0
      begin
        Dir.each_child("/proc/self/task") do |name|
          next if n >= MAX_AUDIT_TIDS
          if tid = name.to_i?
            @@audit_tids[n] = tid
            n += 1
          end
        end
      rescue
        n = 0
      end
      @@audit_tid_count = n
      n
    end

    # Snapshot every known thread's SP. Safe inside STW: no allocation.
    # Returns how many were read.
    #
    # The collector's own tid is deliberately *not* excluded — its SP lies on
    # the current fiber's stack, and the scrub loop already skips that fiber, so
    # it can never match another fiber's range.
    def self.audit_snapshot_sps : Int32
      n = 0
      i = 0
      while i < @@audit_tid_count
        tid = @@audit_tids[i]
        i += 1
        if sp = read_thread_sp_from_proc(tid)
          @@audit_sps[n] = sp
          n += 1
        end
      end
      @@audit_sp_count = n
      n
    end

    def self.audit_sp_count : Int32
      @@audit_sp_count
    end

    def self.audit_sp_at(index : Int32) : UInt64
      return 0_u64 if index < 0 || index >= @@audit_sp_count
      @@audit_sps[index]
    end

    # True when any snapshotted SP lies in [low, high).
    def self.audit_sp_within(low : UInt64, high : UInt64) : UInt64?
      i = 0
      while i < @@audit_sp_count
        sp = @@audit_sps[i]
        return sp if sp >= low && sp < high
        i += 1
      end
      nil
    end

    # /proc/self/task/<tid>/syscall → "nr arg0 .. arg5 sp pc", or "running".
    # Raw syscalls into stack buffers: no allocation, callable under STW.
    private def self.read_thread_sp_from_proc(tid : Int32) : UInt64?
      path = uninitialized UInt8[64]
      len = build_syscall_path(path.to_unsafe, tid)
      return nil if len == 0

      fd = LibC.open(path.to_unsafe.as(LibC::Char*), 0) # O_RDONLY
      return nil if fd < 0
      buf = uninitialized UInt8[256]
      n = LibC.read(fd, buf.to_unsafe.as(Void*), 255.to_u64)
      LibC.close(fd)
      return nil if n <= 0

      parse_syscall_sp(buf.to_unsafe, n.to_i32)
    end

    # "/proc/self/task/<tid>/syscall\0" without String#% or interpolation.
    private def self.build_syscall_path(dst : UInt8*, tid : Int32) : Int32
      prefix = "/proc/self/task/"
      suffix = "/syscall"
      i = 0
      prefix.each_byte { |b| dst[i] = b; i += 1 }

      return 0 if tid <= 0
      digits = uninitialized UInt8[12]
      d = 0
      v = tid
      while v > 0
        digits[d] = ('0'.ord + (v % 10)).to_u8
        d += 1
        v //= 10
      end
      while d > 0
        d -= 1
        dst[i] = digits[d]
        i += 1
      end

      suffix.each_byte { |b| dst[i] = b; i += 1 }
      dst[i] = 0_u8
      i
    end

    # Second-to-last whitespace-separated field, parsed as 0x-prefixed hex.
    # "running" (a thread on-CPU) has no SP to report and yields nil.
    private def self.parse_syscall_sp(buf : UInt8*, len : Int32) : UInt64?
      # Trim trailing whitespace/newline.
      last = len - 1
      while last >= 0 && (buf[last] == '\n'.ord || buf[last] == ' '.ord)
        last -= 1
      end
      return nil if last < 0

      # Walk back over the final field (pc), then over the one before it (sp).
      fields = 0
      i = last
      sp_start = -1
      sp_end = -1
      while i >= 0 && fields < 2
        # skip this field's characters
        while i >= 0 && buf[i] != ' '.ord
          i -= 1
        end
        fields += 1
        if fields == 2
          sp_start = i + 1
          break
        end
        sp_end = i # position of the space before pc
        # skip the separating space(s)
        while i >= 0 && buf[i] == ' '.ord
          i -= 1
        end
        sp_end = i + 1
      end
      return nil if sp_start < 0 || sp_end <= sp_start

      parse_hex(buf, sp_start, sp_end)
    end

    private def self.parse_hex(buf : UInt8*, start : Int32, stop : Int32) : UInt64?
      i = start
      # optional 0x
      if stop - i >= 2 && buf[i] == '0'.ord && (buf[i + 1] == 'x'.ord || buf[i + 1] == 'X'.ord)
        i += 2
      end
      return nil if i >= stop
      value = 0_u64
      while i < stop
        c = buf[i]
        digit =
          if c >= '0'.ord && c <= '9'.ord
            c - '0'.ord
          elsif c >= 'a'.ord && c <= 'f'.ord
            c - 'a'.ord + 10
          elsif c >= 'A'.ord && c <= 'F'.ord
            c - 'A'.ord + 10
          else
            return nil
          end
        value = (value << 4) | digit.to_u64
        i += 1
      end
      value
    end
  end
end
