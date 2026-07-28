# Regression test for stack-scan false root inside Crystal::System::Signal.
#
# Various Crystal runtime signal-handler internals store file descriptor
# numbers on the C stack. These fd values can look like heap pointers and
# cause the GC to conservatively retain garbage.
#
# Regression guard: just ensure GC doesn't crash during signal operations.

require "../../src/gcry"
require "spec"

{% if flag?(:linux) %}
describe "Regression: signal handler stack false roots" do
  it "survives signal trap during allocation" do
    handled = false
    Signal::USR1.trap do
      # Allocate inside handler (signal-safe GC.malloc)
      _p = GC.malloc_atomic(64)
      handled = true
    end

    Process.signal(Signal::USR1, Process.pid)
    sleep(0.01.seconds)

    Signal::USR1.reset
    handled.should be_true
  end
end
{% end %}
