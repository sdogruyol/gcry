# The suspend/resume signal pair, read from Crystal's own private constants
# rather than restated.
#
# Both sides have to agree on them and neither can pick freely. gcry installs
# its suspend handler on Crystal's `SIG_SUSPEND` (`linux_stw.cr`) after
# `Crystal::System::Thread.init_suspend_resume` installed Crystal's, and
# resumes threads through Crystal's `Thread#resume`, which sends Crystal's
# `SIG_RESUME` to an empty resume handler — Crystal's, reinstalled by
# `linux_stw.cr` with `SA_RESTART` — the signal gcry's handler
# waits for in `sigsuspend`. Until 2026-10-05 gcry copied the two values with a
# "must match" comment: a stdlib change to either would have compiled cleanly
# and left the stop sending a signal no handler of gcry's waited for. Reading
# the constants makes a rename a compile error instead.
#
# Inlined at compile time — both are `LibC` literals — so the signal handler
# that reads them runs no `once`-guarded initialiser.
#
# `GC.sig_suspend` / `GC.sig_resume` (`gc_override.cr`) answer these, which is
# what `Crystal::System::Thread.sig_suspend` and `Process` spawn's signal
# unblocking consult.
{% unless flag?(:win32) %}
  module Crystal::System::Thread
    # :nodoc:
    GC_STW_SIG_SUSPEND = SIG_SUSPEND
    # :nodoc:
    GC_STW_SIG_RESUME = SIG_RESUME
  end
{% end %}
