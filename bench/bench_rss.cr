# Process resident-set size, on both platforms the collector supports.
#
# Three bench harnesses each carried their own `/proc/self/status` reader with a
# `rescue 0_u64`. On Darwin that is not a fallback, it is a silent zero: the file
# does not exist, every sample reads 0, and an RSS ceiling compares 0 against a
# start of 0 and passes. A gate that passes because it measured nothing is the
# failure mode this repo spends most of its CI on, so this reader has no such
# path — `available?` answers the question up front and the callers refuse rather
# than gate on zeros.
#
# Darwin reads `task_info(MACH_TASK_BASIC_INFO)`, not `ps`: the samplers run
# inside a GC soak, and forking a process per sample would be both noise and a
# hazard.

{% if flag?(:darwin) %}
  lib LibMachTask
    alias Port = UInt32
    alias KernReturn = Int32
    alias MachMsgTypeNumber = UInt32

    # `mach_task_self()` is a macro over this global in <mach/mach_init.h>.
    $mach_task_self_ : Port

    fun task_info(
      target : Port,
      flavor : Int32,
      info_out : UInt32*,
      count : MachMsgTypeNumber*,
    ) : KernReturn
  end
{% end %}

module BenchRss
  {% if flag?(:darwin) %}
    KERN_SUCCESS = 0
    # MACH_TASK_BASIC_INFO. `mach_task_basic_info` is
    #   virtual_size, resident_size, resident_size_max (8 each),
    #   user_time, system_time (time_value_t, 8 each),
    #   policy, suspend_count (4 each)
    # = 48 bytes = 12 natural_t, and resident_size is the second 64-bit word.
    MACH_TASK_BASIC_INFO       =     20
    MACH_TASK_BASIC_INFO_COUNT = 12_u32
    RESIDENT_SIZE_WORD         =      1
  {% end %}

  # kB, or nil when this platform cannot answer. Never 0-as-a-fallback: the
  # caller has to decide what to do about not knowing.
  def self.read_kb? : UInt64?
    {% if flag?(:linux) %}
      File.open("/proc/self/status") do |f|
        f.each_line do |line|
          if line.starts_with?("VmRSS:")
            parts = line.split
            return parts[1].to_u64 if parts.size >= 2
          end
        end
      end
      nil
    {% elsif flag?(:darwin) %}
      info = uninitialized UInt64[6]
      count = MACH_TASK_BASIC_INFO_COUNT
      kr = LibMachTask.task_info(
        LibMachTask.mach_task_self_,
        MACH_TASK_BASIC_INFO,
        info.to_unsafe.as(UInt32*),
        pointerof(count),
      )
      return nil unless kr == KERN_SUCCESS
      resident = info[RESIDENT_SIZE_WORD]
      resident_max = info[RESIDENT_SIZE_WORD + 1]
      # The flavor, the count and the word index come from the C struct, and a
      # wrong offset would return a plausible-looking number rather than an
      # error. These two hold for any correct read and break for most incorrect
      # ones — a shifted window reads a time_value_t or a policy word — so a
      # mistake surfaces as "this platform cannot answer", which the callers
      # refuse on, instead of as a quiet wrong RSS.
      return nil if resident == 0 || resident > 1_u64 << 40
      return nil if resident_max < resident
      resident // 1024
    {% else %}
      nil
    {% end %}
  rescue
    nil
  end

  def self.available? : Bool
    !read_kb?.nil?
  end

  # For callers that only report the number and do not gate on it.
  def self.read_kb : UInt64
    read_kb? || 0_u64
  end
end
