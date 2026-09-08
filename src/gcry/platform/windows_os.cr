require "c/process"
require "c/fcntl"
require "c/io"
require "c/memoryapi"
require "c/processthreadsapi"
require "c/sysinfoapi"
require "c/synchapi"
require "c/profileapi"

@[Link("kernel32")]
lib LibGcryWindows
  fun GetEnvironmentVariableA(name : UInt8*, buffer : UInt8*, size : UInt32) : UInt32
  fun RtlCaptureStackBackTrace(skip : UInt32, count : UInt32, frames : Void**, hash : UInt32*) : UInt16
  fun FlsAlloc(callback : Void* ->) : UInt32
  fun FlsFree(index : UInt32) : Int32
  fun FlsGetValue(index : UInt32) : Void*
  fun FlsSetValue(index : UInt32, value : Void*) : Int32
  fun InitializeSRWLock(lock : Void**)
  fun AcquireSRWLockExclusive(lock : Void**)
  fun TryAcquireSRWLockExclusive(lock : Void**) : UInt8
  fun ReleaseSRWLockExclusive(lock : Void**)
end

module Gcry::OS
  # Clear only committed dead stack, without calling memset on the range its
  # own call frames may occupy. Windows grows stacks through PAGE_GUARD.
  def self.clear_dead_stack(bytes : UInt64) : UInt64
    sp = 0_u64
    {% if flag?(:aarch64) %}
      asm("mov $0, sp" : "=r"(sp) :: "memory" : "volatile")
    {% else %}
      asm("movq %rsp, $0" : "=r"(sp) :: "memory" : "volatile")
    {% end %}
    return 0_u64 if LibC.VirtualQuery(Pointer(Void).new(sp), out info, sizeof(LibC::MEMORY_BASIC_INFORMATION)) == 0
    base = info.baseAddress.address
    cleared = 0_u64
    {% if flag?(:aarch64) %}
      # Windows reserves [SP-16, SP) for instrumentation. Use byte stores so
      # an arbitrary wipe budget never rounds down into the guard page.
      asm("sub x9, sp, #16
           sub x10, x9, $1
           cmp x10, $2
           csel x10, x10, $2, hs
           mov $0, xzr
           cmp x10, x9
           b.hs 2f
           sub $0, x9, x10
           1:
           strb wzr, [x10], #1
           cmp x10, x9
           b.lo 1b
           2:"
              : "=&r"(cleared)
              : "r"(bytes), "r"(base)
              : "x9", "x10", "memory", "cc"
              : "volatile")
    {% else %}
      asm("movq %rsp, %rdi
         subq $1, %rdi
         cmpq $2, %rdi
         cmovbq $2, %rdi
         movq %rsp, %rcx
         subq %rdi, %rcx
         movq %rcx, $0
         xorl %eax, %eax
         rep stosb"
              : "=&r"(cleared)
              : "r"(bytes), "r"(base)
              : "rax", "rcx", "rdi", "memory", "cc"
              : "volatile")
    {% end %}
    cleared
  end

  alias PthreadT = LibC::HANDLE
  alias PthreadAttrT = UInt8
  alias PthreadMutexT = Void*
  alias PthreadMutexattrT = UInt8
  alias GcryPthreadKeyT = FlsKey*
  PROT_NONE     =  0
  PROT_READ     =  1
  PROT_WRITE    =  2
  MAP_PRIVATE   =  2
  MAP_ANONYMOUS = 32
  SC_PAGESIZE   =  1

  struct Timespec
    property tv_sec : Int64 = 0_i64
    property tv_nsec : Int64 = 0_i64
  end

  def self.sysconf(name) : Int64
    LibC.GetNativeSystemInfo(out info)
    info.dwPageSize.to_i64
  end

  def self.mmap(address, size, protection, flags, fd, offset) : Void*
    LibC.VirtualAlloc(address, size, LibC::MEM_RESERVE | LibC::MEM_COMMIT,
      protection == PROT_NONE ? 1_u32 : LibC::PAGE_READWRITE.to_u32)
  end

  # Only whole reservations may be released. Callers must not coalesce them.
  def self.munmap(address, size) : Int32
    LibC.VirtualFree(address, 0, LibC::MEM_RELEASE) != 0 ? 0 : -1
  end

  def self.mprotect(address, size, protection) : Int32
    protect = protection == PROT_NONE ? 1_u32 : LibC::PAGE_READWRITE.to_u32
    LibC.VirtualProtect(address, size, protect, out old) != 0 ? 0 : -1
  end

  def self.pthread_self : PthreadT
    LibC.GetCurrentThread
  end

  def self.pthread_mutex_init(lock, attributes) : Int32
    LibGcryWindows.InitializeSRWLock(lock)
    0
  end

  def self.pthread_mutex_lock(lock) : Int32
    LibGcryWindows.AcquireSRWLockExclusive(lock)
    0
  end

  def self.pthread_mutex_trylock(lock) : Int32
    LibGcryWindows.TryAcquireSRWLockExclusive(lock) != 0 ? 0 : 1
  end

  def self.pthread_mutex_unlock(lock) : Int32
    LibGcryWindows.ReleaseSRWLockExclusive(lock)
    0
  end

  struct FlsKey
    property index : UInt32
    property destructor : Void* ->
    property active : Bool

    def initialize(@index, @destructor, @active = true)
    end
  end

  struct FlsValue
    property key : FlsKey*
    property value : Void*

    def initialize(@key, @value)
    end
  end

  def self.pthread_key_create(key, destructor : Void* ->) : Int32
    entry = LibC.malloc(sizeof(FlsKey)).as(FlsKey*)
    return -1 if entry.null?
    index = LibGcryWindows.FlsAlloc(->(raw : Void*) {
      slot = raw.as(FlsValue*)
      owner = slot.value.key
      value = slot.value.value
      if owner.value.active && !value.null?
        owner.value.destructor.call(value)
      end
      LibC.free(raw)
    })
    if index == UInt32::MAX
      LibC.free(entry)
      return -1
    end
    entry.value = FlsKey.new(index, destructor)
    key.value = entry
    0
  end

  def self.pthread_setspecific(key, value) : Int32
    slot = LibGcryWindows.FlsGetValue(key.value.index).as(FlsValue*)
    if slot.null?
      slot = LibC.malloc(sizeof(FlsValue)).as(FlsValue*)
      return -1 if slot.null?
      slot.value = FlsValue.new(key, value)
      if LibGcryWindows.FlsSetValue(key.value.index, slot) == 0
        LibC.free(slot)
        return -1
      end
    else
      slot.value.value = value
    end
    0
  end

  def self.pthread_key_delete(key) : Int32
    # FlsFree calls every destructor, unlike pthread_key_delete. Suppress
    # the user callback on deletion, but still release our per-thread wrappers.
    key.value.active = false
    return -1 if LibGcryWindows.FlsFree(key.value.index) == 0
    LibC.free(key)
    0
  end

  # Raw helpers never enter Crystal's Thread list and never allocate GC memory.
  struct Start
    property callback : Void* -> Void*
    property argument : Void*

    def initialize(@callback, @argument)
    end
  end

  def self.pthread_create(thread, attributes, callback : Void* -> Void*, argument) : Int32
    data = LibC.malloc(sizeof(Start)).as(Start*)
    return -1 if data.null?
    data.value = Start.new(callback, argument)
    handle = LibC._beginthreadex(nil, 0, ->(raw : Void*) {
      entry_data = raw.as(Start*)
      start = entry_data.value
      LibC.free(raw)
      start.callback.call(start.argument)
      0_u32
    }, data, 0, nil)
    if handle.null?
      LibC.free(data)
      return -1
    end
    thread.value = handle
    0
  end

  def self.pthread_join(thread, result) : Int32
    return -1 unless LibC.WaitForSingleObject(thread, LibC::INFINITE) == LibC::WAIT_OBJECT_0
    LibC.CloseHandle(thread) != 0 ? 0 : -1
  end

  def self.pthread_detach(thread) : Int32
    LibC.CloseHandle(thread) != 0 ? 0 : -1
  end

  def self.nanosleep(request, remaining) : Int32
    time = request.value
    LibC.Sleep((time.tv_sec * 1000 + (time.tv_nsec + 999_999) // 1_000_000).to_u32)
    0
  end
end

module Gcry::OS
  def self.write(fd : Int32, buffer, count) : Int32
    LibC._write(fd, buffer.as(UInt8*), count.to_u32)
  end

  def self.close(fd : Int32) : Int32
    LibC._close(fd)
  end
end

module Gcry::OS
  def self.open(path : String, flags : Int32, mode : Int32) : Int32
    LibC._wopen(path.to_utf16, flags | LibC::O_BINARY | LibC::O_NOINHERIT, 0o600)
  end
end

lib LibC
  fun abort : NoReturn
end

module Gcry::OS
  @[ThreadLocal]
  @@env_buffer = uninitialized UInt8[32768]

  # The CRT keeps a separate environment snapshot; Crystal's ENV updates the
  # Win32 environment. Read the latter so runtime knob changes are observed.
  def self.getenv(name : String) : UInt8*
    getenv(name.to_unsafe)
  end

  def self.getenv(name : UInt8*) : UInt8*
    buffer = @@env_buffer.to_unsafe
    size = LibGcryWindows.GetEnvironmentVariableA(name, buffer, 32768)
    size > 0 && size < 32768 ? buffer : Pointer(UInt8).null
  end

  def self.write(fd : Int32, buffer : String, count) : Int32
    write(fd, buffer.to_unsafe, count)
  end
end
