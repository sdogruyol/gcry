module Gcry
  # Size-class helpers with no runtime constant initializers.
  # (Crystal `once` consts like Array literals / sizeof-based values deadlock
  # during GC.init because Fiber is not up yet.)
  module SizeClasses
    COUNT     = 32
    THRESHOLD = 8192_u32

    def self.payload(index : Int32) : UInt32
      case index
      when  0 then 16_u32
      when  1 then 32_u32
      when  2 then 48_u32
      when  3 then 64_u32
      when  4 then 80_u32
      when  5 then 96_u32
      when  6 then 112_u32
      when  7 then 128_u32
      when  8 then 160_u32
      when  9 then 192_u32
      when 10 then 224_u32
      when 11 then 256_u32
      when 12 then 320_u32
      when 13 then 384_u32
      when 14 then 448_u32
      when 15 then 512_u32
      when 16 then 640_u32
      when 17 then 768_u32
      when 18 then 896_u32
      when 19 then 1024_u32
      when 20 then 1280_u32
      when 21 then 1536_u32
      when 22 then 1792_u32
      when 23 then 2048_u32
      when 24 then 2560_u32
      when 25 then 3072_u32
      when 26 then 3584_u32
      when 27 then 4096_u32
      when 28 then 5120_u32
      when 29 then 6144_u32
      when 30 then 7168_u32
      when 31 then 8192_u32
      else
        raise ArgumentError.new("bad size class index: #{index}")
      end
    end

    def self.index_of(payload : UInt32) : Int32
      case payload
      when 16    then 0
      when 32    then 1
      when 48    then 2
      when 64    then 3
      when 80    then 4
      when 96    then 5
      when 112   then 6
      when 128   then 7
      when 160   then 8
      when 192   then 9
      when 224   then 10
      when 256   then 11
      when 320   then 12
      when 384   then 13
      when 448   then 14
      when 512   then 15
      when 640   then 16
      when 768   then 17
      when 896   then 18
      when 1024  then 19
      when 1280  then 20
      when 1536  then 21
      when 1792  then 22
      when 2048  then 23
      when 2560  then 24
      when 3072  then 25
      when 3584  then 26
      when 4096  then 27
      when 5120  then 28
      when 6144  then 29
      when 7168  then 30
      when 8192  then 31
      else
        raise ArgumentError.new("not a size-class payload: #{payload}")
      end
    end

    def self.round(size : UInt64) : UInt64
      return 16_u64 if size == 0

      word = sizeof(Void*).to_u64 # compile-time sizeof in expression
      aligned = (size + word - 1) & ~(word - 1)
      return aligned if aligned > THRESHOLD

      # Walk classes without touching a runtime Array constant.
      i = 0
      while i < COUNT
        klass = payload(i).to_u64
        return klass if aligned <= klass
        i += 1
      end
      aligned
    end
  end

  # Compatibility aliases (integer literals — safe during GC.init).
  SIZE_CLASS_COUNT = 32
  LARGE_THRESHOLD  = 8192_u32
end
