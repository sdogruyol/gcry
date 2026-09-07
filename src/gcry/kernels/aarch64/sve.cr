struct Gcry::Kernels::SVE < Gcry::Kernels::Base
  def tier : UInt8
    TIER_SVE
  end

  Gcry::Kernels.define_sve_methods("+sve")
end
