struct Gcry::Kernels::SVE2 < Gcry::Kernels::Base
  def tier : UInt8
    TIER_SVE2
  end

  Gcry::Kernels.define_sve_methods("+sve,+sve2")
end
