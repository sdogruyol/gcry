# TLAB+nursery sampler: one stall without a backtrace

CI dispatch run 37226315432 (`078bcb2`, the 2 h soak dispatch), job
"TLAB+nursery sampler (x86_64)": 100 tlab+nursery and 30 tlab-only runs of
`stw_mt_property_test_hdr`, 0 failed, **1 stalled** (`tlab-nursery-44.log`,
seed 10044, workers=4). The make target counts a stall as a failure.

```
task 4147 stw_mt_property state=S wchan=ep_poll
task 4153 stw-mt-2-0 state=S wchan=ep_poll
task 4154 stw-mt-2-1 state=S wchan=futex_do_wait
task 4157 stw-mt-4-0 state=R wchan=0
task 4158 stw-mt-4-1 state=S wchan=ep_poll
task 4159 stw-mt-4-2 state=R wchan=0
task 4160 stw-mt-4-3 state=S wchan=futex_do_wait
--- no gdb backtrace (gdb missing or no live task)
```

No watchdog report and no stop in progress: the last gcry line is the
dying-type audit of collection 51. Two workers on CPU, the rest parked.

[INFERENCE] The shape of crystal-lang/crystal#17486 as the campaigns see it —
two threads spinning at `fiber/execution_context/parallel/scheduler.cr:97`,
no collector frame — but without a backtrace this one cannot be classified,
and TLAB with the nursery is an unsupported combination. Recorded so a second
sighting has something to compare with.

The same evening campaign-053 (`0671a0c`) timed out once in its
`stw_mt_hdr_tlab_nursery` lane, the same binary and flags (seed 20441), and
that run's gdb capture has two threads at `scheduler.cr:97` and no collector
frame: #17486. That is the nearest classified neighbour of this stall.

A second, the next morning: CI run 37268309149 (`cb68f2c`, push), same
job, 1 stalled of 130, same shape (`stw-mt-2-0` and `stw-mt-2-1` on CPU,
everything else asleep, no gdb). The job now installs gdb, as the STW seed
sampler already does, so `run_bounded.sh` can see `scheduler.cr:97` and count
#17486 as upstream instead of as a failure.
