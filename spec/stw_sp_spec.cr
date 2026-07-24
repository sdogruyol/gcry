require "./spec_helper"

it "Platform SP table records and looks up by pthread id" do
  id = LibC.pthread_self
  sp = 0x7fff00001234_u64
  Gcry::Platform.record_thread_sp(id, sp)
  begin
    got = Gcry::Platform.thread_sp(id)
    got.should_not be_nil
    got.not_nil!.address.should eq sp

    Gcry::Platform.clear_thread_sps
    Gcry::Platform.thread_sp(id).should be_nil
  ensure
    Gcry::Platform.clear_thread_sps
  end
end

it "sp_from_ucontext reads saved SP at glibc offset" do
  {% if flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
    buf = StaticArray(UInt8, 512).new(0_u8)
    expected = 0x00007fffffffdc00_u64
    (buf.to_unsafe + Gcry::Platform::UCONTEXT_SP_OFFSET).as(UInt64*).value = expected
    Gcry::Platform.sp_from_ucontext(buf.to_unsafe.as(Void*)).should eq expected
    Gcry::Platform.rsp_from_ucontext(buf.to_unsafe.as(Void*)).should eq expected
    Gcry::Platform.sp_from_ucontext(Pointer(Void).null).should eq 0_u64
  {% end %}
end
