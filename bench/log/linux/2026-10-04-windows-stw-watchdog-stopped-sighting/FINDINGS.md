# Windows x86_64: the STW watchdog's `armed+stopped` arm stayed silent once

CI run 37226295143 (`078bcb2`, a ROADMAP-only commit), job 111506523760,
`test (windows x86_64, default)`, step "Native unit and process GC specs":

```
threshold 200 ms, stall 900 ms in the thread-stacks phase
quiet arm runs at 5000 ms (CI runners deschedule; see the comment)

  armed+stalled    gcry: STOP-THE-WORLD STALLED 212 ms in phase=thread-stacks — ...
  armed+presusp    gcry: STOP-THE-WORLD STALLED 250 ms in phase=suspend — ...
  armed+stopped    (silent)
  armed+quiet      (silent)
  unarmed+stalled  (silent)

FAIL a stall after PHASE_STOPPED did not name that phase — the span between
the suspend wait and the flush is still reported as `suspend`
```

The arm that stalls after `PHASE_STOPPED` printed nothing at all, not a report
under the wrong phase name. The re-run of the failed job passed, and the same
gate passed on `0671a0c`, `c647981` and `c985fcc` the same evening, none of
which touch the watchdog or the stop.

[INFERENCE] A runner that did not schedule the watchdog thread inside the
stall window, the hazard the quiet arm's 5000 ms already allows for. First
sighting; nothing in `bench/log` or ROADMAP records this arm going silent
before.
