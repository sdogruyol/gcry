struct Gcry::Kernels::Scalar < Gcry::Kernels::Base
  def tier : UInt8
    TIER_SCALAR
  end

  def sweep_words(occ : UInt64*, mark : UInt64*, n : Int32) : {UInt64, UInt64}
    freed = 0_u64
    live = 0_u64
    i = 0
    while i < n
      o = occ[i]
      m = mark[i]
      freed &+= (o & ~m).popcount.to_u64
      live &+= m.popcount.to_u64
      occ[i] = m
      mark[i] = 0_u64
      i += 1
    end
    {freed, live}
  end

  def popcount_words(words : UInt64*, n : Int32) : UInt64
    acc = 0_u64
    i = 0
    while i < n
      acc &+= words[i].popcount.to_u64
      i += 1
    end
    acc
  end

  def all_zero?(words : UInt64*, n : Int32) : Bool
    acc = 0_u64
    i = 0
    while i < n
      acc |= words[i]
      i += 1
    end
    acc == 0_u64
  end

  def range_any?(ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64) : Bool
    acc = 0_u64
    i = 0
    while i < n
      acc |= ((ptr[i] &- lo) < span) ? 1_u64 : 0_u64
      i += 1
    end
    acc != 0_u64
  end
end
