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
# Raw syscalls into stack buffers — no allocation, callable with the world
# stopped. Linux only; `/proc/self/status` has no portable equivalent, and
# `darwin_thread_census.cr` answers `nil` rather than a number nobody measured.
{% skip_file unless flag?(:linux) %}

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
