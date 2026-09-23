CRYSTAL ?= crystal
BIN := bin
# Where `thread-uaf-sample` leaves the runs that said something.
SAMPLE_DIR := bench/log/ci-samples

.PHONY: all spec spec-process tlab-nursery-sample fuzz fuzz-short fuzz-replay property-test property-test-short layout-property-test layout-property-test-short mt-property-test mt-property-test-short stw-mt-property-test stw-mt-property-test-short pattern-fuzz pattern-fuzz-short scrub-margin scrub-midswap stw-startup-hang stw-watchdog stw-epoch stw-ack-window stw-monitor-gate greg-roots scheduler-roots ivar-layout-roots ec-queue-audit nested-spawn-uaf mark-audit thread-block-audit thread-birth-root thread-churn-uaf heap-counters thread-uaf-sample poison-holders perf-baseline darwin-page-query darwin-static-root-init darwin-static-root-sections darwin-bitmap-page-release poison-freed interior-only-buffer unaligned-only-buffer kernels-broken kernels-ir bench-kernels bench-gc-phases large-freelist-madvise segv-report thread-storm thread-storm-short oom-test oom-test-short oom-no-hang fork-test finalizer-complex nursery-headers nursery-bitmap-marks nursery-tlab-smoke bitmap-marks-freelist layout-knob-check parallel-mark-process microbench pause-budget stw-lag-pause rss-leak compiler-gc-contract kemal-e2e soft-soak-ec4 soft-soak-ec4-smoke stackmap-smoke trace-smoke sound-profile-smoke mutate soak soak-smoke format format-check lint invariants coverage coverage-kcov coverage-unreachable coverage-macro asan asan-spec valgrind valgrind-samples samples bench-run-all bench-run-kemal bench-run-kemal-debug bench-run-kemal-symbols bench-run-acik bench-perf-smoke bench-sound-profile bench-crystal-metric bench-kemal-record clean help

all: spec samples

help:
	@echo "Targets: spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short layout-property-test layout-property-test-short mt-property-test mt-property-test-short stw-mt-property-test stw-mt-property-test-short pattern-fuzz pattern-fuzz-short thread-storm thread-storm-short oom-test oom-test-short fork-test finalizer-complex nursery-headers nursery-bitmap-marks nursery-tlab-smoke bitmap-marks-freelist layout-knob-check parallel-mark-process microbench pause-budget stw-lag-pause rss-leak compiler-gc-contract kemal-e2e soft-soak-ec4 soft-soak-ec4-smoke stackmap-smoke trace-smoke sound-profile-smoke mutate scrub-margin scrub-midswap stw-startup-hang stw-watchdog stw-epoch stw-ack-window stw-monitor-gate greg-roots scheduler-roots ivar-layout-roots ec-queue-audit mark-audit thread-block-audit thread-birth-root thread-churn-uaf heap-counters thread-uaf-sample poison-holders perf-baseline darwin-page-query darwin-static-root-init darwin-static-root-sections darwin-bitmap-page-release poison-freed kernels-broken kernels-ir bench-kernels bench-gc-phases large-freelist-madvise segv-report soak soak-smoke format format-check lint samples"
	@echo "Bench: bench-run-all bench-run-kemal bench-run-kemal-debug bench-run-kemal-symbols bench-run-acik bench-perf-smoke bench-sound-profile bench-crystal-metric bench-kemal-record"
	@echo "knobs: WRK_CONNECTIONS WRK_DURATION TRIALS COUNT GC GCRY_FLAGS CRYSTAL_FLAGS DEBUG SOFT_SOAK_N"
	@echo "record A/B: make bench-kemal-record PREV=v0.2.0 LABEL=0.3.0"

$(BIN):
	mkdir -p $(BIN)

spec:
	$(CRYSTAL) spec --error-trace

spec-process: $(BIN)
	$(CRYSTAL) spec -Dgc_none process_spec --error-trace

invariants:
	GCRY_DEBUG_INVARIANTS=1 $(CRYSTAL) spec --error-trace

fuzz: $(BIN)
	$(CRYSTAL) build bench/fuzz.cr -o $(BIN)/fuzz
	$(BIN)/fuzz --seconds=$${FUZZ_SECONDS:-30} --seed=$${FUZZ_SEED:-1}

fuzz-short: $(BIN)
	$(CRYSTAL) build bench/fuzz.cr -o $(BIN)/fuzz
	$(BIN)/fuzz --seconds=5 --seed=1

fuzz-replay: $(BIN)
	@test -n "$(FUZZ_LOG)" || (echo 'set FUZZ_LOG=path/to/crash.log' && exit 1)
	$(CRYSTAL) build bench/fuzz.cr -o $(BIN)/fuzz
	$(BIN)/fuzz --replay=$(FUZZ_LOG)

property-test: $(BIN)
	$(CRYSTAL) build bench/property_test.cr -o $(BIN)/property_test
	$(BIN)/property_test --seed=$${PROP_SEED:-1} --iterations=$${PROP_ITERATIONS:-100000}

property-test-short: $(BIN)
	$(CRYSTAL) build bench/property_test.cr -o $(BIN)/property_test
	$(BIN)/property_test --seed=1 --iterations=5000

layout-property-test: $(BIN)
	$(CRYSTAL) build bench/layout_property_test.cr -o $(BIN)/layout_property_test
	$(BIN)/layout_property_test --seed=$${LAYOUT_PROP_SEED:-1} --iterations=$${LAYOUT_PROP_ITERATIONS:-10000}

layout-property-test-short: $(BIN)
	$(CRYSTAL) build bench/layout_property_test.cr -o $(BIN)/layout_property_test
	$(BIN)/layout_property_test --seed=1 --iterations=500

mt-property-test: $(BIN)
	$(CRYSTAL) build bench/mt_property_test.cr -o $(BIN)/mt_property_test
	$(BIN)/mt_property_test --seed=$${MT_PROP_SEED:-1} --iterations=$${MT_PROP_ITERATIONS:-500} --workers=2,4,8

mt-property-test-short: $(BIN)
	$(CRYSTAL) build bench/mt_property_test.cr -o $(BIN)/mt_property_test
	$(BIN)/mt_property_test --seed=1 --iterations=50 --workers=2,4

# Until 2026-09-20 the TLAB/nursery arms built headerless, where
# nursery_enabled= is a no-op and tlab_enabled= is refused (bitmap
# allocator forced). Green `--tlab` / `--tlab --nursery` requires
# `-Dgcry_block_headers` and `GCRY_BITMAP_ALLOC=0`. `--disabled` is
# the headerless binary: those flags must not enable. Dropping the
# flag, the allocator knob, or `--disabled` reddens the gate.
stw-mt-property-test: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_mt_property_test.cr -o $(BIN)/stw_mt_property_test --error-trace
	$(BIN)/stw_mt_property_test --seed=$${STW_MT_SEED:-1} --iterations=$${STW_MT_ITERATIONS:-200} --workers=$${STW_MT_WORKERS:-2,4}
	$(BIN)/stw_mt_property_test --tlab --nursery --disabled
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o $(BIN)/stw_mt_property_test_hdr --error-trace
	GCRY_BITMAP_ALLOC=0 $(BIN)/stw_mt_property_test_hdr --tlab --seed=$${STW_MT_SEED:-1} --iterations=$${STW_MT_ITERATIONS:-200} --workers=$${STW_MT_WORKERS:-2,4} $${STW_MT_NURSERY:+--nursery}

stw-mt-property-test-short: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_mt_property_test.cr -o $(BIN)/stw_mt_property_test --error-trace
	$(BIN)/stw_mt_property_test --seed=1 --iterations=50 --workers=2,4
	$(BIN)/stw_mt_property_test --tlab --nursery --disabled
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o $(BIN)/stw_mt_property_test_hdr --error-trace
	GCRY_BITMAP_ALLOC=0 $(BIN)/stw_mt_property_test_hdr --tlab --seed=1 --iterations=50 --workers=2,4
	GCRY_BITMAP_ALLOC=0 $(BIN)/stw_mt_property_test_hdr --tlab --nursery --seed=1 --iterations=50 --workers=2,4

pattern-fuzz: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/pattern_fuzz.cr -o $(BIN)/pattern_fuzz
	$(BIN)/pattern_fuzz --seed=$${PATTERN_FUZZ_SEED:-1} --phases=$${PATTERN_FUZZ_PHASES:-200} --objects-per-phase=$${PATTERN_FUZZ_OBJS:-5000}

pattern-fuzz-short: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/pattern_fuzz.cr -o $(BIN)/pattern_fuzz
	$(BIN)/pattern_fuzz --seed=1 --phases=20 --objects-per-phase=1000

thread-storm: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_storm.cr -o $(BIN)/thread_storm
	$(BIN)/thread_storm --iterations=$${THREAD_STORM_ITERATIONS:-1000} --workers=$${THREAD_STORM_WORKERS:-10}

thread-storm-short: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_storm.cr -o $(BIN)/thread_storm
	$(BIN)/thread_storm --iterations=100 --workers=4

oom-test: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/oom_test.cr -o $(BIN)/oom_test
	$(BIN)/oom_test --phases=$${OOM_PHASES:-1,2,3}

oom-test-short: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/oom_test.cr -o $(BIN)/oom_test
	$(BIN)/oom_test --phases=1,2

# Until 2026-09-20 this called `after_fork_child_reinit` itself, ignored the
# child's status, and only checked malloc was non-null — it would have stayed
# green with atfork uninstalled. Green requires pthread_atfork and a child
# that mallocs+collects without a manual reinit. `--disabled` is
# `GCRY_DISABLE_ATFORK=1` and the poison `_exit(69)` (must not allocate:
# `raise` re-enters malloc). Dropping the knob reddens the gate.
fork-test: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dwithout_mt bench/fork_reinit.cr -o $(BIN)/fork_reinit
	$(BIN)/fork_reinit
	GCRY_DISABLE_ATFORK=1 $(BIN)/fork_reinit --disabled

# Seven finalizer scenarios assert a callback *ran*; phase 0 asserts what it
# ran on — an object the sweep left alone (the Boehm rule; before it,
# `Socket#finalize` ran on freed memory). `--broken` turns the resurrection
# off and requires the callback to find its object swept. Dropping the
# resurrection reddens the shipped arm and only phase 0 notices, which is the
# gap phase 0 closes.
finalizer-complex: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/finalizer_complex.cr -o $(BIN)/finalizer_complex --error-trace
	$(BIN)/finalizer_complex
	$(BIN)/finalizer_complex --broken

# Nursery HTTP::Headers Hash keys. The compile default is headerless, where
# `Heap#nursery_enabled=` is a no-op, so the CI step that built this without
# `-Dgcry_block_headers` and asserted the keys survived was testing a major.
# Auto-layouts skip `Hash(HTTP::Headers::Key, …)`; the green arm requires the
# explicit walk, `--disabled` installs noscan-without-walk (the pre-fix
# shape). Dropping the flag or the zeroed walk reddens rather than hides.
nursery-headers: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/nursery_headers.cr -o $(BIN)/nursery_headers
	$(BIN)/nursery_headers
	$(BIN)/nursery_headers --disabled

# The third mark representation, run: marks in the chunk's bitmap while blocks
# keep their 16-byte headers and the *freelist* allocator keeps handing them
# out. That is `GCRY_BITMAP=1` on `-Dgcry_block_headers`, plus
# `GCRY_BITMAP_ALLOC=0` wherever the process GC defaults the pool allocator on
# — without which the arm is silently the bitmap-allocator one and this gate
# tests a thing already covered twice.
#
# It is documented and shipped and nothing ran it until 2026-09-14: the
# headerless default forces both bitmaps on, `GCRY_BITMAP_ALLOC=1` covers
# marks-plus-pool, and the one CI line that set `GCRY_BITMAP=1` set it on a
# binary built headerless, which ignores the knob. Measured on the header
# layout, which arm each spelling gets:
#
#   library  no env             marks=0 alloc=0    process  no env      1 / 1
#   library  GCRY_BITMAP=1      marks=1 alloc=0    process  BITMAP=1    1 / 1
#   library  BITMAP_ALLOC=1     marks=1 alloc=1    process  both, =0    1 / 0
#
# — the process GC defaults the pool allocator on, so `GCRY_BITMAP=1` alone
# means something different on each side of that line, which is why the
# recipe spells both out.
#
# The arm is where the two geometries meet: a chunk carrying a mark bitmap
# whose blocks still carry headers, with the mark phase writing the bitmap
# and allocate-black writing the header for the reader to union. A
# `data_offset` any of those three disagrees on lands here. Observed red that
# way - computing the block ordinal from `chunk + ChunkHeader::SIZE` instead
# of `data_start` gives `marks-only: live_objects 0, header 200`. ~36 s, and
# it found nothing on its first run, which is worth saying rather than
# implying.
bitmap-marks-freelist: $(BIN)
	GCRY_BITMAP=1 $(CRYSTAL) spec -Dgcry_block_headers --error-trace
	GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 $(CRYSTAL) spec -Dgc_none -Dgcry_block_headers process_spec --error-trace
	$(CRYSTAL) build -Dgcry_block_headers bench/property_test.cr -o $(BIN)/property_test_marks --error-trace
	GCRY_BITMAP=1 $(BIN)/property_test_marks --seed=1 --iterations=50000
	$(CRYSTAL) build -Dgcry_block_headers bench/mt_property_test.cr -o $(BIN)/mt_property_test_marks --error-trace
	GCRY_BITMAP=1 $(BIN)/mt_property_test_marks --seed=1 --iterations=200 --workers=2,4
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o $(BIN)/stw_mt_property_test_marks --error-trace
	GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 $(BIN)/stw_mt_property_test_marks --tlab --nursery --seed=1 --iterations=50 --workers=2,4
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/pattern_fuzz.cr -o $(BIN)/pattern_fuzz_marks --error-trace
	GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 $(BIN)/pattern_fuzz_marks --seed=1 --phases=40 --objects-per-phase=2000
	@echo "ok — marks in the chunk with the freelist allocator: specs, property, MT, STW+TLAB+nursery, pattern fuzz"

# Four workers must steal, not merely be configured. Until 2026-09-20 the
# only way this came out red was a hand edit of the steal counter.
# `GCRY_DISABLE_PARALLEL_MARK=1` pins workers at 1; `--disabled` requires
# stolen stay 0. Dropping the skip reddens the gate.
parallel-mark-process: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/parallel_mark_process.cr -o $(BIN)/parallel_mark_process
	$(BIN)/parallel_mark_process
	GCRY_DISABLE_PARALLEL_MARK=1 $(BIN)/parallel_mark_process --disabled

microbench: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/micro/run_all.cr -o $(BIN)/microbench
	$(BIN)/microbench

# Pause ceilings, and a run that must breach one. The phase-1 p99 ceiling is
# 200 ms against a tip p99 of a few ms, so nothing about a green run shows the
# check can still fail; `GCRY_STW_TEST_STALL_MS=250` — the STW watchdog's own
# stall, inside the stop — lifts every major past it and the arm is required
# to exit non-zero. Phase 1 only: 25 majors × 250 ms. ~6 s more.
pause-budget: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/pause_budget.cr -o $(BIN)/pause_budget --error-trace
	$(BIN)/pause_budget --live-mb=$${LIVE_MB:-20}
	! GCRY_STW_TEST_STALL_MS=250 $(BIN)/pause_budget --live-mb=$${LIVE_MB:-20} --phases=1

# STW root-scan lag pause trap: the whole pause cost of GCRY_SOUND=1.
# Runs under both env shapes — the boot-lag assertion inverts with GCRY_SOUND.
#
# Carries CI's ratio bound (--max-ratio=4), not the program's loose 30× default:
# a local `make stw-lag-pause` that passes where CI fails is not a gate. The
# relaxed --max-ratio-nolw applies only when pagemap is unreadable and the
# low-water skip cannot run — see ci.yml and bench/stw_lag_pause.cr.
#
# Until 2026-09-20 the skip's red direction was a hand edit of
# `fiber_stack_scan_top` (gated on lag == 0). `--dirty-kb=16` already
# requires the default path to skip; `GCRY_STACK_LOW_WATER=0 --disabled`
# requires it not to. Dropping the knob reddens the gate.
stw-lag-pause: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_lag_pause.cr -o $(BIN)/stw_lag_pause
	$(BIN)/stw_lag_pause --rounds=$${STW_LAG_ROUNDS:-5} \
		--max-ratio=$${STW_LAG_MAX_RATIO:-4} --max-ratio-nolw=$${STW_LAG_MAX_RATIO_NOLW:-30}
	GCRY_SOUND=1 $(BIN)/stw_lag_pause --rounds=$${STW_LAG_ROUNDS:-5} \
		--max-ratio=$${STW_LAG_MAX_RATIO:-4} --max-ratio-nolw=$${STW_LAG_MAX_RATIO_NOLW:-30}
	# Shallow fibers, so the 256 KiB lag window holds pages nothing wrote and the
	# *default* path has something to skip. The two runs above cannot see that
	# path regress: at --dirty-kb=256 the window is fully written either way.
	$(BIN)/stw_lag_pause --rounds=$${STW_LAG_ROUNDS:-5} --dirty-kb=16 \
		--max-ratio=$${STW_LAG_MAX_RATIO:-4} --max-ratio-nolw=$${STW_LAG_MAX_RATIO_NOLW:-30}
	GCRY_STACK_LOW_WATER=0 $(BIN)/stw_lag_pause --rounds=$${STW_LAG_ROUNDS:-5} --dirty-kb=16 \
		--disabled --max-ratio=$${STW_LAG_MAX_RATIO:-4} --max-ratio-nolw=$${STW_LAG_MAX_RATIO_NOLW:-30}

# Heap-size growth late vs early after warm-up (RSS secondary, looser). The red
# direction is the harness's own: `--leaking` roots one object in five per
# cycle, +38% against the 10% ceiling here, and the arm must exit non-zero.
rss-leak: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/rss_leak.cr -o $(BIN)/rss_leak --error-trace
	$(BIN)/rss_leak --warmup=$${RSS_WARMUP:-15} --cycles=$${RSS_CYCLES:-20} --objects=$${RSS_OBJECTS:-5000} \
		--limit=$${RSS_LIMIT:-10} --rss-limit=$${RSS_RSS_LIMIT:-25}
	! $(BIN)/rss_leak --warmup=$${RSS_WARMUP:-15} --cycles=$${RSS_CYCLES:-20} --objects=$${RSS_OBJECTS:-5000} \
		--limit=$${RSS_LIMIT:-10} --rss-limit=$${RSS_RSS_LIMIT:-25} --leaking

# The GC API and the compiler's type_id / layout contract. The red arm:
# `GCRY_DISABLE_LAYOUT=1` registers no layouts, so "Array type_id is
# registered for layout" must fail and the run must exit non-zero — the one
# check here whose subject the collector can switch off.
compiler-gc-contract: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/compiler_gc_contract.cr -o $(BIN)/compiler_gc_contract --error-trace
	$(BIN)/compiler_gc_contract
	! GCRY_DISABLE_LAYOUT=1 $(BIN)/compiler_gc_contract
	$(CRYSTAL) tool hierarchy src/gcry.cr >/dev/null
	$(CRYSTAL) tool unreachable bench/compiler_gc_contract.cr -Dgc_none >/dev/null

kemal-e2e:
	KEMAL_E2E_DURATION=$${KEMAL_E2E_DURATION:-60} ./bench/kemal_e2e.sh

# Parallel EC4 TLAB-off soft soak (0 soft / 0 hard). Local gate N=40; CI smoke N=5.
soft-soak-ec4:
	SOFT_SOAK_N=$${SOFT_SOAK_N:-40} ./bench/soft_soak_ec4.sh

soft-soak-ec4-smoke:
	SOFT_SOAK_N=$${SOFT_SOAK_N:-5} SOFT_SOAK_DURATION=$${SOFT_SOAK_DURATION:-8} ./bench/soft_soak_ec4.sh

# Compiler stack-map walker smoke (needs CRYSTAL with CRYSTAL_EMIT_STACKMAP support).
# Tip Crystal requires -Dpreview_mt -Dexecution_context (else Scheduler path livelocks soak).
stackmap-smoke: $(BIN)
	CRYSTAL_EMIT_STACKMAP=1 $(CRYSTAL) build -Dgc_none -Dpreview_mt -Dexecution_context \
		--no-debug --frame-pointers=always \
		-o $(BIN)/stackmap_walker_smoke bench/stackmap_walker_smoke.cr
	GCRY_PRECISE_STACK=1 $(BIN)/stackmap_walker_smoke
	GCRY_PRECISE_STACK=2 $(BIN)/stackmap_walker_smoke
	CRYSTAL_EMIT_STACKMAP=1 CRYSTAL_STACKMAP_PER_FUN=32 $(CRYSTAL) build -Dgc_none -Dpreview_mt -Dexecution_context \
		--no-debug --frame-pointers=always \
		-o $(BIN)/stackmap_exclusive_fiber_smoke bench/stackmap_exclusive_fiber_smoke.cr
	GCRY_PRECISE_STACK=2 GCRY_PRECISE_FIBERS=1 $(BIN)/stackmap_exclusive_fiber_smoke

# NDJSON trace events and the heap dump against the live set. The red arm:
# `--unsampled` enables the trace with `alloc_sample: 0` — documented as off —
# so alloc/free never appear and the event assertions must fail.
trace-smoke: $(BIN)
	$(CRYSTAL) build bench/trace_smoke.cr -o $(BIN)/trace_smoke --error-trace
	$(BIN)/trace_smoke
	! $(BIN)/trace_smoke --unsampled

# Where does the parked-fiber wipe start destroying live data? Sweeps
# GCRY_SCRUB_OVERSHOOT in child processes — most of the ladder is *expected* to
# crash, which is the point: without a run that corrupts, a clean run at
# overshoot 0 proves nothing. ~10 min, local only (the crashes make it poor CI
# material, and scrub is opt-in anyway). docs/SOUND-DEFAULTS.md § "Auditing the scrub".
scrub-margin: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/scrub_margin.cr -o $(BIN)/scrub_margin
	$(BIN)/scrub_margin

# The mid-swap guard, the last open half of the scrub question. The window
# cannot be hunted (Crystal writes `stack_top` before it clears the running
# flag), so this manufactures it: the scrub is told to treat one fiber as parked
# while a thread runs deep below its recorded `stack_top`. Guard off must corrupt
# (positive control), guard on must skip and survive. ~1 s.
#
# One child dies by design, so expect a SEGV backtrace on stderr from
# `stale-off`. A child can also hang before reaching the scrub — that is the
# separate `stw-startup-hang` bug below, which this shape trips on ~12% of
# starts; the tool retries and prints how many retries it needed.
# docs/SOUND-DEFAULTS.md § "The mid-swap window".
scrub-midswap: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dpreview_mt -Dexecution_context \
	  bench/scrub_midswap.cr -o $(BIN)/scrub_midswap --error-trace
	$(BIN)/scrub_midswap

# The EC Monitor is never signal-suspended, and it was measured running inside
# the stopped world — including StackPool#collect, which munmaps fiber stacks.
# Gcry::MonitorGate handshakes it out. Needs -Dtracing: the Monitor's work is
# stdlib-internal and CRYSTAL_TRACE=sched is the only way to see it from outside.
# Both directions in one run; GCRY_MONITOR_GATE=0 is the control. ~45 s: the
# stop is held 20 s so the control gets several 5 s collect intervals, and the
# assertion counts them — one line can be a call already in flight when the stop
# began, which the handshake waits out rather than prevents.
stw-monitor-gate: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dtracing bench/stw_monitor_gate.cr \
	  -o $(BIN)/stw_monitor_gate --error-trace
	$(BIN)/stw_monitor_gate

# A hang with the world stopped is silent — every mutator is in sigsuspend and
# /gc-stats cannot answer, which is why finding the one below took markers and a
# rebuild. GCRY_STW_WATCHDOG_MS arms a raw watcher thread that names the stuck
# phase. Driven from both sides: it must fire on a real stall
# (GCRY_STW_TEST_STALL_MS) and stay silent on an ordinary collection. ~3 s.
stw-watchdog: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_watchdog.cr -o $(BIN)/stw_watchdog --error-trace
	$(BIN)/stw_watchdog

# The suspend signal is now re-sendable, and the stop epoch is what makes that
# safe: a duplicate delivered after the thread resumes is declined instead of
# suspending it again with nobody left to wake it. Six arms, three of them red
# on purpose — no resend hangs on a dropped signal, no epoch hangs on the
# duplicate, and a live thread that answers nothing hangs either way, which is
# the honest limit of the repair. ~60 s (three arms wait out a 20 s timeout).
stw-epoch: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_epoch.cr -o $(BIN)/stw_epoch --error-trace
	$(BIN)/stw_epoch

# `Thread#start` pushes itself onto Crystal's list **before** it sets its own
# TLS, so `stop_world` can signal a thread that has no `Thread.current` — and
# Crystal's accessor *creates* one on a miss, from inside the signal handler.
# gcry's acknowledgement lives in the `pthread_t`-keyed slot table instead, so
# the handler touches no Crystal object. Driven by a raw pthread, which has no
# TLS by construction: the shipped path acknowledges, and the restored
# pre-table path allocates a `Thread` in the handler, pushes it onto the list
# and answers into it — where the collector is not looking. ~15 s.
stw-ack-window: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_ack_window.cr -o $(BIN)/stw_ack_window --error-trace
	$(BIN)/stw_ack_window

# The collector must not call libc under STW. `scan_other_thread_stacks` used to
# call pthread_getattr_np after suspending the threads it was asking about, which
# waits on a lock a frozen thread holds: resize(4) + one non-yielding fiber + one
# collect hung 18/150 starts. Fixed by snapshotting bounds before the first
# suspend signal; 0/500 since. This is the gate against reintroducing any such
# call. The no-flag run is the control (resize + collect alone never hung).
# A reference can live only in a register, so `collect_scan` asks the platform
# for a suspended thread's GP registers. On Darwin that call was an empty stub
# next to a thread_get_state that already read SP and discarded the rest, and
# live objects were swept for it (fixed 2026-08-11, 2936248). The gate is the
# candidate count: 0 is what a platform that never reports registers looks like,
# and no workload or compiler can push it above 0 by luck. The survival half of
# the run does *not* discriminate — with the fix reverted the victim still
# survived 5/5, because keeping a pointer out of memory is a codegen outcome a
# source-level test cannot compel. `--control` shows the harness is not itself
# retaining the victim. ~1 s. See the file header and `bin/greg_roots --explain`.
greg-roots: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/greg_roots.cr -o $(BIN)/greg_roots --error-trace
	$(BIN)/greg_roots
	$(BIN)/greg_roots --control
	# The red direction, which until 2026-09-16 existed only as a sentence in
	# ROADMAP.md ("broken on purpose and observed red"). The knob that restores
	# the pre-v0.19.0 behaviour was already in the collector and no recipe,
	# spec or CI step used it. Red at `register candidates ... 0`, and note
	# what it does *not* do: the victim still survives, because the
	# conservative stack scan reaches it. The counter is the gate.
	! GCRY_DISABLE_GREG_ROOTS=1 $(BIN)/greg_roots

# The diagnostics travel with this gate for the same reason they travel with
# `ec-queue-audit`: it is one that dies. It caught the open use-after-free on
# 2026-08-16 (aarch64) and again on 2026-08-17 (x86_64) — SIGSEGV inside
# `pthread_getattr_np` under `stop_world` — and both times could say nothing but
# one hex number, because the knobs were not on here. They cost a memset per
# free and nothing until something faults. A gate that catches this defect
# should not waste the sighting.
# `GCRY_THREAD_BLOCK_AUDIT` for the same reason, one object along: this gate is
# one of the three that has caught the `Thread` use-after-free, and what those
# catches could never say is what held the `Thread`'s address at the moment its
# block was swept. The arm answers that from inside the collection that frees it
# rather than from the crash that follows (src/gcry/thread_block_audit.cr).
# Measured on this gate: no cost — it reports nothing here, which is the point,
# because this defect has never reproduced locally.
scheduler-roots: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/scheduler_roots.cr -o $(BIN)/scheduler_roots --error-trace
	GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1 GCRY_THREAD_BLOCK_AUDIT=1 $(BIN)/scheduler_roots
	GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1 GCRY_THREAD_BLOCK_AUDIT=1 $(BIN)/scheduler_roots --control
	GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1 GCRY_THREAD_BLOCK_AUDIT=1 $(BIN)/scheduler_roots --resize
	# The red direction, which until 2026-09-20 existed only as a hand
	# edit of collect_scan.cr ("stub → 7 of 16 named"). The knob skips
	# the derived pin block and leaves Thread-level slots running, so
	# the gate measures a *delta*. Red at delta 6–8 against 45 expected;
	# parked fibers still live 16/16 — the conservative body scan
	# reaches them. The counter is the gate.
	! GCRY_DISABLE_EC_PINS=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1 GCRY_THREAD_BLOCK_AUDIT=1 $(BIN)/scheduler_roots

# A precise layout is a claim that every pointer in the object is at one of the
# offsets it lists. `Layout.register` had a third outcome it never named: an ivar
# it could not classify — module-typed (`Log::Dispatcher`), `Proc`, `Tuple` — got
# no offset *and* did not force the conservative fallback, so the type stayed
# precise and the word was never scanned. 19 such ivars in 186 stdlib types.
# The gate is the installed entry, which is static; the sweep arm is the
# consequence (both shapes were swept before the fix, on both registration
# routes). `--control` types the same ivar as the class and must survive, or the
# other two arms prove nothing. Run under GCRY_AUTO_LAYOUTS=1 as well: that is
# the shipping route into the same macro. ~1 s.
ivar-layout-roots: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/ivar_layout_roots.cr -o $(BIN)/ivar_layout_roots --error-trace
	$(BIN)/ivar_layout_roots
	$(BIN)/ivar_layout_roots --proc
	$(BIN)/ivar_layout_roots --control
	GCRY_AUTO_LAYOUTS=1 $(BIN)/ivar_layout_roots
	GCRY_AUTO_LAYOUTS=1 $(BIN)/ivar_layout_roots --proc
	GCRY_AUTO_LAYOUTS=1 $(BIN)/ivar_layout_roots --control
	# The red direction, which until 2026-09-20 existed only as a hand
	# edit of layout.cr ("has_inner_pointers? dropped"). The knob keeps
	# the precise is_ptr offsets and skips the conservative fallback, so
	# a module-typed / Proc ivar is simply never scanned. --control still
	# passes: that ivar is a Reference and its offset is emitted either
	# way. The counter is the gate; a survival assertion can still pass
	# if a stale stack word roots the leaf.
	! GCRY_LAYOUT_DROP_UNCLASSIFIED=1 $(BIN)/ivar_layout_roots
	! GCRY_LAYOUT_DROP_UNCLASSIFIED=1 $(BIN)/ivar_layout_roots --proc

# Does `GCRY_DISABLE_AUTO_LAYOUTS` still disable the whole-program walk
# `GCRY_AUTO_LAYOUTS` opted into? `ivar-layout-roots` already runs under the
# opt-in and cannot see this knob: it also registers its probes explicitly, so
# the disable leaves them registered either way, and a survival assertion would
# not discriminate. Three child arms, counters not objects: builtins must not
# name a type this file declares, AUTO_LAYOUTS must grow the table *and*
# register that type, both knobs must put both counters back. Measured here:
# 51 → 159 → 51, probe false/true/false. Dropping the disable reddens it
# (159 and probe still registered). ~1 s.
.PHONY: auto-layouts
auto-layouts: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/auto_layouts.cr -o $(BIN)/auto_layouts --error-trace
	$(BIN)/auto_layouts

# The 2026-08-10 soak died in `quick_dequeue?` on a run-queue slot whose pointer

# Does `GCRY_DISABLE_SCRUB_FIBERS` still disable the parked-fiber wipe
# `GCRY_SCRUB_FIBERS` opted into? `samples/sound_profile.cr` already asserts
# the flag (default off, opt-in overrides SOUND) and cannot see this knob:
# disable agrees with the default, so the sample never asks whether it still
# turns the opt-in back off. The spec sets the property and never reads either
# env var. Three child arms, counters not objects: default flag off and
# fiber_scrub_runs 0; SCRUB_FIBERS=1 flag on and runs move; both knobs put
# both back. Measured here: false/0 → true/1 → false/0. Dropping the disable
# reddens it (true and runs=1). ~1 s.
.PHONY: scrub-fibers
scrub-fibers: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/scrub_fibers.cr -o $(BIN)/scrub_fibers --error-trace
	$(BIN)/scrub_fibers

# had been partly overwritten — an unknown time after the write that did it, and
# at one crash per five hours that gap cannot be bisected. `GCRY_EC_QUEUE_AUDIT=1`
# walks the ring and the global list inside STW and names the first *collection*
# that sees a slot which is not a live Fiber. The gate plants two values that
# fail different halves of the test — one outside the heap, one a live object of
# the wrong type — and requires the report to name the planted value, not
# whatever the walk trips over afterwards. `--control` (audit off) shows the knob
# is what does the work. ~5 s.
# `perf-smoke` gates on fixed floors — thr >= 65%, RSS <= 1.25x, p50 <= 2.5 ms —
# which sit far below tip (~85% @ ~0.8x @ ~0.6 ms), so 85% -> 70% clears every
# gate in the suite. `bench/perf_compare.py` compares the same summary against a
# recorded baseline instead. This target runs its selftest: the comparator is
# what is new, and it can be gated here without wrk or a quiet host. Fixtures
# cover a regression in each direction, an improvement, a within-noise run, both
# gate modes, a baseline with no measured tolerance, and the unrecorded file this
# repo actually ships. ~0.1 s.
# The Darwin low-water skip (v0.21.0) is blocked on one question, and it is not a
# code question: does `mach_vm_page_query`'s disposition separate "never
# faulted" from "written then evicted"? `mincore` cannot — it answers resident,
# so an evicted page reads absent and skipping it drops a root. This probe
# answers it on a Darwin host and carries the candidate predicate it tests, so a
# green run validates the exact logic a `darwin_pagemap.cr` would use. On Linux
# it prints SKIP. Exits non-zero only if the bits are demonstrably wrong; the
# "could not force an eviction" outcome is INCONCLUSIVE and says so. ~1 s.
# A freed block's payload becomes 0xdeadf2eedeadf2ee, so the next use-after-free
# reads something nobody can argue about. The 2026-08-10 soak died on
# `0x7f1700000149`, a value plausible enough that three sessions disagreed about
# what it was. Two arms and the second is the gate: freed payloads must read the
# pattern, and a `malloc` that asks to be cleared must **still** get zeros — gcry
# skips the clearing memset on a "clean" freelist, so poisoning without clearing
# that flag would hand poison to a caller expecting zeros (broken on purpose:
# 10560 of 10560 words came back poisoned). `--control` runs with the knob off.
# A crash reporter can only be tested by crashing, so this forks a child per
# fault shape and checks the diagnosis names the right one: gcry's poison in the
# faulting context, an address in a FREE block, one in a USED block, one gcry
# never mapped. The 2026-08-10 soak left a single hex number and three sessions
# of argument; every fact that would have narrowed it was in the collector's
# tables at the time and nothing asked. `--control` shows the reporter adds
# lines and removes none. ~2 s.
segv-report: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/segv_report.cr -o $(BIN)/segv_report --error-trace
	$(BIN)/segv_report
	$(BIN)/segv_report --control

# The SIMD bitmap kernels are allocation-free backend structs: Scalar plus
# AVX2/AVX-512 (asm sweep, vectorised rest) on x86_64, NEON (vectorised) and
# SVE (asm) on AArch64. `spec/kernels_spec.cr` fuzzes every runnable backend against Scalar
# as oracle. That fuzz can only ever report "they agree", so the gate is two
# arms and the first one is the
# point: `-Dgcry_kernels_broken` drops the last word from vector backends
# only, and the fuzz has to go **red**. Then the same fuzz, unbroken, has to go
# green. On a host whose top tier is scalar there are no vector backends to break,
# so the positive control cannot fire and the target refuses the run rather than
# reporting a green it did not earn.
#
# The broken arm is matched on "N examples, M failures" with M > 0, not on a
# non-zero exit code: a compile error, a moved spec file or a typo'd flag all
# exit non-zero too, and any of them would leave this gate cheerfully reporting
# a positive control that never ran. ~12 s.
# Phase 0 floor for the SIMD bitmap kernels: what sweep costs per byte of
# bitmap before any of it is wired into the collector, so Phase 3's phase_sweep
# has something to be attributed to. Reports every tier the host can run, at an
# L2-resident and a DRAM-resident working set. The plan's bar is sweep >= 20
# GB/s on AVX2. Expect the tiers to spread at L2 and converge at DRAM — the
# kernel is bandwidth-bound there, which is why AVX-512 is worth ~1.3x on sweep
# and not 2x (simdgc-perf-notes.md). Latest per-backend reading, and the method
# for a fair A/B (rotate binaries, take the max of several runs):
# bench/log/linux/2026-09-07-kernel-backend-ab/FINDINGS.md. ~10 s.
# Steady-state GC workload with a tunable survival rate, reporting per-phase
# timings and the **GC duty cycle** — the fraction of wall time the process is
# stopped for GC, which is the entire budget any mark-side optimisation can
# address.
#
# It exists because Phase 2 measured phase_mark down 10-18% and could not see it
# in Kemal throughput at all: Kemal's duty cycle is 0.2-0.5%, so an infinitely
# fast mark is worth +0.15pp there. This workload runs at 9-41% depending on
# survival rate, which is where a mark-side change is legible end to end. Kemal
# stays the regression guard it is good at; this is the microscope.
#
# Survival rate is the knob that controls duty cycle: garbage is cheap (a dead
# object costs a bit in a bitmap), survivors are expensive (a mark, a trace, a
# retained page). ~12 s.
bench-gc-phases: $(BIN)
	$(CRYSTAL) build --release -Dgc_none bench/micro/gc_phases.cr -o $(BIN)/gc_phases --error-trace
	$(BIN)/gc_phases --seconds=$${GC_PHASE_SECONDS:-3} --live=$${GC_PHASE_LIVE:-200000}

bench-kernels: $(BIN)
	$(CRYSTAL) build --release bench/micro/kernels.cr -o $(BIN)/kernels_micro --error-trace
	$(BIN)/kernels_micro --passes=$${KERNEL_PASSES:-12}

# Did the kernels vectorise, for both architectures, from whichever host you
# have? `--cross-compile --emit llvm-ir` runs the whole pipeline for a target
# and stops before linking, so the aarch64 IR is readable on x86 and the x86
# IR on aarch64 — the plan carried this as "CI only, no local arm64 host",
# which was a misreading: the check needs the target's compiler, never its
# CPU. Each arch also asserts the other's fingerprints are absent, because a
# grep for a string a file never contains reads exactly like a grep for one it
# should contain and does not. ~19 s, and observed red the moment an
# assertion was wrong — `<2 x i64>` as an "aarch64 only" pattern is SSE2's
# type too, and the run said `PRESENT` instead of passing.
kernels-ir: $(BIN)
	@CRYSTAL="$(CRYSTAL)" BIN="$(BIN)" ci/kernels-ir-check.sh

kernels-broken:
	@echo "== positive control: broken vector backends must fail the equivalence fuzz =="
	@if [ "$$($(CRYSTAL) run ci/kernel_tier.cr --no-debug 2>/dev/null)" = "scalar" ]; then \
	  echo "REFUSED: host top tier is scalar, so -Dgcry_kernels_broken changes nothing"; \
	  echo "         and a green run here would prove nothing. Run on a SIMD host."; \
	  exit 1; \
	fi
	@out=$$($(CRYSTAL) spec spec/kernels_spec.cr -Dgcry_kernels_broken 2>&1); \
	if echo "$$out" | grep -qE '[0-9]+ examples, [1-9][0-9]* failures'; then \
	  echo "OK: broken vector backends observed red -- $$(echo "$$out" | grep -E 'examples,' | tail -1)"; \
	else \
	  echo "FAIL: the broken arm did not fail as an equivalence mismatch."; \
	  echo "      A non-zero exit is not enough: a compile error would also be non-zero"; \
	  echo "      and would leave this gate reporting a green it did not earn."; \
	  echo "$$out" | tail -20; \
	  exit 1; \
	fi
	@echo "== control: unbroken kernels must pass =="
	$(CRYSTAL) spec spec/kernels_spec.cr
# The large-freelist page release computed its lower bound as `chunk.address`
# and rounded up. A chunk base is already page-aligned, so the round-up was a
# no-op and the range began at page 0 — the page holding that chunk's own
# `ChunkHeader` and the large object's `BlockHeader`, `next_free` link and all.
# It ran unconditionally in the post-STW flush, not behind a knob. When the
# kernel acts on it, `mapped_bytes` reads 0 and the bucket chain truncates at
# the first reclaimed entry, orphaning every large chunk behind it while
# `@large_free_bytes` still counts them.
#
# The damage is not deterministically observable — Linux uses MADV_FREE here and
# Darwin MADV_FREE_REUSABLE, both of which preserve content until the kernel
# reclaims under pressure, which is why this survived in the tree. The *range*
# is deterministic, so that is what the gate asserts. Two arms and the second is
# the point: `GCRY_LARGE_RELEASE_FROM_BASE=1` restores the old bound and
# `madvise_range_ok?` must refuse every one of them (119 of 119 measured), which
# is what makes the default arm's zero mean something rather than mean nothing.
# ~4 s.
large-freelist-madvise: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/large_freelist_madvise.cr -o $(BIN)/large_freelist_madvise --error-trace
	$(BIN)/large_freelist_madvise
	GCRY_LARGE_RELEASE_FROM_BASE=1 $(BIN)/large_freelist_madvise --control

# A live Array buffer LLVM holds only by an interior pointer (--release
# strength reduction). Default arm must keep it; the base-only arm must fault
# - the control proves the gate can go red (v0.22.0 SIGSEGV 3 of 3).
interior-only-buffer: $(BIN)
	$(CRYSTAL) build -Dgc_none --release bench/interior_only_buffer.cr -o $(BIN)/interior_only_buffer --error-trace
	$(BIN)/interior_only_buffer
	! GCRY_DISABLE_INTERIOR=1 $(BIN)/interior_only_buffer

# The same for a byte buffer held only by a misaligned induction pointer:
# the default arm must keep it, the alignment-filter arm must fault.
unaligned-only-buffer: $(BIN)
	$(CRYSTAL) build -Dgc_none --release bench/unaligned_only_buffer.cr -o $(BIN)/unaligned_only_buffer --error-trace
	$(BIN)/unaligned_only_buffer
	! GCRY_ALIGNED_CANDIDATES=1 $(BIN)/unaligned_only_buffer

poison-freed: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/poison_freed.cr -o $(BIN)/poison_freed --error-trace
	GCRY_POISON_FREED=1 $(BIN)/poison_freed
	$(BIN)/poison_freed --control
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/poison_freed.cr -o $(BIN)/poison_freed_hdr --error-trace
	GCRY_BITMAP_ALLOC=0 GCRY_POISON_FREED=1 $(BIN)/poison_freed_hdr
	GCRY_BITMAP_ALLOC=0 $(BIN)/poison_freed_hdr --control

# After mark, before sweep: does any marked object point at a block the sweep is
# about to free? The `hold` arm plants an edge the mark provably does not follow
# (a pointer in a block's scan_cap slack, under GCRY_SCAN_CAPS=1) and requires
# the audit to name it — an audit that only ever reports zero is worth nothing.
# `clean` requires a non-trivial edge count with zero misses on the same
# workload; `--control` shows nothing is walked with the knob off. ~3 s.
mark-audit: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/mark_audit.cr -o $(BIN)/mark_audit --error-trace
	$(BIN)/mark_audit
	$(BIN)/mark_audit --control

# `GCRY_POISON_TAG` names the block a use-after-free read out of; this names
# whatever still points at it — the root set, the live heap, the fiber stacks.
# Plants holders it knows the address of, because a search that finds nothing
# reads exactly like one that ran and found the heap clean. `--control` shows the
# search adds lines and removes none. ~2 s.
# The `Thread` use-after-free is only ever seen on CI, so the instrument aimed
# at it (src/gcry/thread_block_audit.cr) has to be trusted before its silence
# there can be read as anything. Three arms: a dropped object of the watched
# type must be named as dying and must trigger the address-space walk, the same
# objects held alive must produce no deaths and a non-zero live count, and the
# shipped default must find live `Thread` blocks — a default aimed at nothing
# would be silent on CI for a reason that has nothing to do with the defect.
# Do the allocation counters keep what they are given?
#
# `note_alloc_bytes` used plain `set(get + n)` unless told otherwise, and two
# threads running that lose increments outright. They now flip to atomic the
# moment a second thread is created, so a program that cannot race keeps the
# cheap path. Both directions, because the first arm alone is just a run that
# happened not to race: four threads must lose some on the old path and none on
# the new one. Measured: 5 723 of 1 200 000 lost, and 0.
#
# The plain arm is a header-layout build: the bitmap allocator implies atomic
# counters, and the headerless default forces the bitmap allocator on, so the
# only heap that still has the plain path to lose increments on is the
# freelist under `-Dgcry_block_headers`.
heap-counters: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/heap_counters.cr -o $(BIN)/heap_counters --error-trace
	$(BIN)/heap_counters
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/heap_counters.cr -o $(BIN)/heap_counters_hdr --error-trace
	GCRY_HEAP_COUNTERS_ATOMIC=0 GCRY_BITMAP_ALLOC=0 $(BIN)/heap_counters_hdr --plain

# The fix for the `Thread` use-after-free, and the window it closes.
#
# Between `pthread_create` and the new thread's own push onto `Thread.threads`,
# the `Thread` object is covered by no root: not the list (it is not on it yet),
# not any stack gcry scans (the only other holder is the new thread's, which has
# no snapshotted bounds). `src/gcry/thread_birth_root.cr` roots the `arg`
# Crystal passes to `pthread_create` and releases it when the thread appears on
# the list.
#
# A real `Thread` publishes itself in microseconds, so the window cannot be held
# open with one. The gate creates a **raw** pthread through the same hook with a
# plain heap block as `arg`: that thread never joins Crystal's list, so the block
# stays in exactly the state the defect needs for as long as the harness wants.
# Three arms — rooted (must survive), `--noroot` (same births recorded, nothing
# rooted: must die), and the knob off (nothing armed: must die).
# Does the Darwin build still type-check, from a Linux box?
#
# `Gcry::Platform` is two files that must present the same surface, and a method
# added to the Linux half and called unconditionally from `GC.init` compiles
# fine here and fails on the macOS runner minutes later. That is exactly how
# `bss_size_cap=` broke CI on 2026-08-22.
#
# `--cross-compile` runs the full semantic analysis for the target and stops
# before linking, so it catches that without a Mac. Both Darwin targets, because
# the platform files are shared but the arch flags are not. Broken on purpose
# and observed red: removing the Darwin stub gives back the runner's own line,
# `undefined method 'bss_size_cap=' for Gcry::Platform:Module`.
darwin-typecheck: $(BIN)
	$(CRYSTAL) build --cross-compile --target aarch64-apple-darwin -Dgc_none samples/hello.cr -o $(BIN)/darwin_typecheck_arm64 >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-apple-darwin -Dgc_none samples/hello.cr -o $(BIN)/darwin_typecheck_x86 >/dev/null
# A gate whose subject is a Darwin-only code path is written on a Linux box and
# first runs 20 minutes later on the macOS job. `hello.cr` above does not reach
# `Gcry::Platform.stw_bounded_resume?` or the Mach resume walk, so this one is
# type-checked here as well.
	$(CRYSTAL) build --cross-compile --target aarch64-apple-darwin -Dgc_none bench/darwin_stw_resume.cr -o $(BIN)/darwin_typecheck_stw_arm64 >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-apple-darwin -Dgc_none bench/darwin_stw_resume.cr -o $(BIN)/darwin_typecheck_stw_x86 >/dev/null
	@rm -f $(BIN)/darwin_typecheck_arm64.o $(BIN)/darwin_typecheck_x86.o
	@rm -f $(BIN)/darwin_typecheck_stw_arm64.o $(BIN)/darwin_typecheck_stw_x86.o
	@echo "ok — the Darwin build and its STW resume gate type-check on both targets"

# The same question for Windows, and it exists because the answer was no.
# `poison_holders.cr` is `{% skip_file unless flag?(:unix) %}`, so a bench
# harness that called into it compiled here, compiled on Darwin, and failed on
# two Windows jobs twenty minutes later with `undefined constant
# Gcry::PoisonHolders` (run 35224827564). `darwin-typecheck` has covered that
# class of mistake for the other platform since 2026-08-22; this covers it for
# the one whose CI jobs are the slowest to tell you.
#
# The set mirrors what the Windows jobs actually build: the samples, through
# `hello.cr`; `bench/tls_roots.cr`, which `ci/windows.ps1` compiles; and
# `bench/chunk_search_race.cr`, which a **spec** compiles
# (`spec/cached_bitmap_pool_race_spec.cr`) — that one was missing from this list
# and a `Gcry::SegvReport.install` call in it broke all six Windows jobs on
# 2026-09-18, the second time in three days that a bench harness reached a
# `{% skip_file unless flag?(:unix) %}` module. A harness a spec builds is a
# harness every platform compiles.
windows-typecheck: $(BIN)
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc -Dgc_none samples/hello.cr -o $(BIN)/windows_typecheck_x86 >/dev/null
	$(CRYSTAL) build --cross-compile --target aarch64-windows-msvc -Dgc_none samples/hello.cr -o $(BIN)/windows_typecheck_arm64 >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc -Dgc_none bench/tls_roots.cr -o $(BIN)/windows_typecheck_tls_x86 >/dev/null
	$(CRYSTAL) build --cross-compile --target aarch64-windows-msvc -Dgc_none bench/tls_roots.cr -o $(BIN)/windows_typecheck_tls_arm64 >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc bench/chunk_search_race.cr -o $(BIN)/windows_typecheck_csr_x86 >/dev/null
	$(CRYSTAL) build --cross-compile --target aarch64-windows-msvc bench/chunk_search_race.cr -o $(BIN)/windows_typecheck_csr_arm64 >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc spec/platform_windows_spec.cr -o $(BIN)/windows_typecheck_spec_x86 >/dev/null
	$(CRYSTAL) build --cross-compile --target aarch64-windows-msvc spec/platform_windows_spec.cr -o $(BIN)/windows_typecheck_spec_arm64 >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc spec/stw_sp_spec.cr -o $(BIN)/windows_typecheck_spec_stw >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc spec/stack_scrub_spec.cr -o $(BIN)/windows_typecheck_spec_scrub >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc spec/cached_bitmap_pool_race_spec.cr -o $(BIN)/windows_typecheck_spec_pool >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc -Dgc_none bench/segv_region_report.cr -o $(BIN)/windows_typecheck_srr >/dev/null
	$(CRYSTAL) build --cross-compile --target x86_64-windows-msvc -Dgc_none process_spec/regression/9_windows_suspension_capacity_spec.cr -o $(BIN)/windows_typecheck_proc_x86 >/dev/null
	$(CRYSTAL) build --cross-compile --target aarch64-windows-msvc -Dgc_none process_spec/regression/9_windows_suspension_capacity_spec.cr -o $(BIN)/windows_typecheck_proc_arm64 >/dev/null
	@rm -f $(BIN)/windows_typecheck_x86.obj $(BIN)/windows_typecheck_arm64.obj
	@rm -f $(BIN)/windows_typecheck_tls_x86.obj $(BIN)/windows_typecheck_tls_arm64.obj
	@rm -f $(BIN)/windows_typecheck_csr_x86.obj $(BIN)/windows_typecheck_csr_arm64.obj
	@echo "ok — the Windows build type-checks on both targets"

# Every knob the source reads has a row in the env reference. The reference had
# drifted by 33 before this existed, which is what a reference does: going stale
# breaks nothing, so nothing says so.
knob-doc-check:
	@ci/knob-doc-check.sh

# A class variable declared with a non-literal initializer is set up lazily
# behind Crystal.once, which takes a process-wide mutex. The collector reads
# some of them from GC.init, before Crystal.main has set that machinery up, and
# some inside the stopped world, where a suspended thread can be holding the
# mutex. `@@table = Pointer(UInt8).null` crashed every -Dgc_none binary on
# Darwin at startup; `@@stw_handles = Pointer(LibC::HANDLE).null`, read from
# resume_suspended_threads, wedged all six Windows jobs for their whole
# 20-minute budget three runs running. Two violations of a rule that was
# already written in the comments of all three platform files, so it is
# mechanical now.
.PHONY: once-guard
once-guard:
	@python3 ci/once-guard.py

# A gate that pins a knob the compile default ignores must build the layout
# that honours it. `GCRY_BITMAP_ALLOC=0`, `GCRY_NURSERY` and `GCRY_TLAB` are
# inert on the headerless default: they warn on stderr and change nothing, so
# a harness whose arms pin one and whose recipe builds `-Dgc_none` alone
# measures the configuration it was trying to avoid. Both page-release gates
# had rotted that way by 2026-09-14 — `page-release-corruption` reported
# `unlinked 0` on its HOLED arm in 4 of 4 runs and `live-graph-audit` reported
# `walk 0 B` on both walking arms. Two rules, both observed red: the harness
# that pins it in its own arms, and the recipe line that sets it before
# running a binary built the wrong way (`make heap-counters` and
# `make poison-freed` keep a headerless binary beside the header one).
layout-knob-check:
	@python3 ci/layout-knob-check.py

# Every raw line buffer is at least as big as the length its writer stops at.
# `RawOut.append` truncates at `LIMIT` and cannot see the buffer, so a smaller
# one is a stack smash, not a short line: the SIGSEGV report's kept-release
# line is 377 bytes, its buffer was 256, and writing it clobbered the block
# count it had already printed and then the return address — the report died
# at 0x0 inside itself with the fault it was called for still undescribed
# (2026-09-14). Thirty-two other buffers were under `LIMIT` at that moment,
# two of them already able to reach past their own end on the widest line -
# `collect_scan.cr`'s index/list disagreement is 417 bytes against 352, and
# 349 on an ordinary mapped chunk. The two hand-rolled writers that predate
# `RawOut` are checked against their own bounds, because the invariant is
# about the pair and not about one module.
raw-buf-check:
	@python3 ci/raw-buf-check.py

# The headerless default cannot honour three knobs, and their env reads are
# compiled out on it, so nothing but this says they were ignored. That silence
# is the whole defect: `GCRY_BITMAP_ALLOC=0` was the documented escape for a
# workload that cares about RSS, and after the 0.26.0 default flip it does
# nothing until the caller also passes `-Dgcry_block_headers`. Asserted in
# both directions — the warning on the layout that ignores the knob, and its
# absence on the layout that honours it — because a gate that only checks the
# message would pass a build that warns on every layout. ~20 s.
#
# The two free-page release knobs (`GCRY_PAGE_DONTNEED`, `GCRY_MOSTLY_EMPTY`)
# are ignored by the *allocator*, not the layout: they stand down on every
# bitmap chunk, and the bitmap allocator is the default on both layouts. So
# three cases each — warns headerless, warns on the header layout's default,
# silent on `GCRY_BITMAP_ALLOC=0` where the walk runs (released 72 MB / 104 MB
# on a sparse heap, 2026-09-23, against 0 on both defaults).
.PHONY: ignored-knob-warnings
ignored-knob-warnings: $(BIN)
	@$(CRYSTAL) build -Dgc_none samples/hello.cr -o $(BIN)/knob_hl --error-trace
	@$(CRYSTAL) build -Dgc_none -Dgcry_block_headers samples/hello.cr -o $(BIN)/knob_hdr --error-trace
	@fail=0; \
	for knob in GCRY_BITMAP_ALLOC=0 GCRY_NURSERY=262144 GCRY_TLAB=1; do \
	  name=$${knob%%=*}; \
	  if env $$knob $(BIN)/knob_hl 2>&1 >/dev/null | grep -q "$$name.*is ignored on the headerless layout"; then \
	    echo "  ok   $$knob warns on the headerless default"; \
	  else \
	    echo "  FAIL $$knob is silently ignored on the headerless default"; fail=1; \
	  fi; \
	  if env $$knob $(BIN)/knob_hdr 2>&1 >/dev/null | grep -q "is ignored on the headerless layout"; then \
	    echo "  FAIL $$knob claims to be ignored on -Dgcry_block_headers, which honours it"; fail=1; \
	  else \
	    echo "  ok   $$knob is honoured on -Dgcry_block_headers"; \
	  fi; \
	done; \
	if env GCRY_BITMAP_ALLOC=1 $(BIN)/knob_hl 2>&1 >/dev/null | grep -q "is ignored"; then \
	  echo "  FAIL a knob the layout does honour warned anyway"; fail=1; \
	else echo "  ok   GCRY_BITMAP_ALLOC=1 is silent on the headerless default"; fi; \
	for knob in GCRY_PAGE_DONTNEED=1 GCRY_MOSTLY_EMPTY=1; do \
	  name=$${knob%%=*}; \
	  if [ "$$name" = GCRY_MOSTLY_EMPTY ] && [ "$$(uname -s)" != Linux ]; then continue; fi; \
	  if env $$knob $(BIN)/knob_hl 2>&1 >/dev/null | grep -q "$$name=1 is ignored on the headerless layout"; then \
	    echo "  ok   $$knob warns on the headerless default"; \
	  else echo "  FAIL $$knob is silently ignored on the headerless default"; fail=1; fi; \
	  if env $$knob $(BIN)/knob_hdr 2>&1 >/dev/null | grep -q "$$name=1 is ignored on the bitmap allocator"; then \
	    echo "  ok   $$knob warns on the header layout's bitmap default"; \
	  else echo "  FAIL $$knob is silently ignored on the header layout's bitmap default"; fail=1; fi; \
	  if env $$knob GCRY_BITMAP_ALLOC=0 $(BIN)/knob_hdr 2>&1 >/dev/null | grep -q "is ignored"; then \
	    echo "  FAIL $$knob warned on the freelist, which runs its walk"; fail=1; \
	  else echo "  ok   $$knob is silent on -Dgcry_block_headers GCRY_BITMAP_ALLOC=0"; fi; \
	done; \
	if env GCRY_PAGE_DONTNEED=1 GCRY_PAGE_RELEASE_BITMAP_WALK=1 $(BIN)/knob_hl 2>&1 >/dev/null | grep -q "is ignored"; then \
	  echo "  FAIL GCRY_PAGE_DONTNEED=1 warned beside GCRY_PAGE_RELEASE_BITMAP_WALK=1, which walks bitmap chunks"; fail=1; \
	else echo "  ok   GCRY_PAGE_DONTNEED=1 is silent beside the research bitmap walk"; fi; \
	[ $$fail -eq 0 ] || exit 1
	@echo "ok — every knob the compile default ignores says so, and only there"

# A process that goes idle after a burst keeps what the last major graced:
# emptied chunks past the warm budget stay mapped "for one cycle", and idle has
# no next cycle. Uncapped, a 200 MB burst idled at 78.7 MB RSS against 6.3 MB
# after `GC.collect`; grace is capped at one threshold since 2026-09-23. The
# shipped arm must fit the bound and `GCRY_UNMAP_GRACE_UNBOUNDED=1` must not,
# in the same run, so the gate cannot rot into passing both. ~15 s.
.PHONY: idle-rss-after-burst
idle-rss-after-burst: $(BIN)
	@$(CRYSTAL) build -Dgc_none bench/idle_rss_after_burst.cr -o $(BIN)/idle_rss_after_burst --error-trace
	@$(BIN)/idle_rss_after_burst
	! GCRY_UNMAP_GRACE_UNBOUNDED=1 $(BIN)/idle_rss_after_burst
	@echo "ok — the capped arm fits and the uncapped red arm does not"

# `GCRY_IDLE_RELEASE_MS`: a `gc-idle` thread runs one releasing collection once
# the process stops allocating. It collects from a thread that is not the
# mutator while the mutator may wake, and must leave finalizers to a mutator
# without delaying them. The harness keeps a checksummed live set across bursts
# separated by idle gaps, and requires idle collections that released every
# empty chunk, intact objects, and finalizers run as promptly as without it and
# never on the idle thread. The same binary with it off (=0) must fail. ~15 s.
.PHONY: idle-release
idle-release: $(BIN)
	@$(CRYSTAL) build -Dgc_none bench/idle_release.cr -o $(BIN)/idle_release --error-trace
	GCRY_IDLE_RELEASE_MS=50 $(BIN)/idle_release
	! GCRY_IDLE_RELEASE_MS=0 $(BIN)/idle_release
	@echo "ok — idle collections release memory safely, and with the collector off nothing does"

# gcry vs Boehm on the fat app, paired and order-rotated.
#
# Needs ../acikturkiye with a reachable Postgres and `wrk`. Reports the median
# of the per-trial ratios, not the ratio of the medians — a fixed arm order
# charges the within-trial drift to whichever arm runs second, which on
# 2026-08-23 was the difference between 77.8% and 87.1% on the same machine.
acik-ab:
	bash bench/acik_ab.sh

# Can the large-object cache hand out a chunk a trimming peer is unmapping?
#
# `take_large_free` walks `@large_freelists` holding `@alloc_lock`;
# `trim_large_cache` walks the same list. Asked directly rather than waiting for
# an application to ask it — the acikturkiye use-after-free this came from could
# not settle it, because its rate fell from 7 of 60 to nothing between sessions.
# Deterministic here: `GCRY_TRIM_UNLOCKED=1` fails 5 of 5, serialised 0 of 5.
# What does the collector lose, and how?
#
# A real object graph with a shadow row per node in `LibC.malloc` memory the
# collector never sees. Reports a broken edge, a zeroed node and a reused node
# apart, because they are three different defects: a lost reference, a live page
# released, and a live block handed out again.
#
# `-Dgcry_block_headers` for the same reason `page-release-corruption` needs
# it: the walks under audit stand down on bitmap chunks, and the
# `GCRY_BITMAP_ALLOC=0` its arms pin is ignored on the headerless default. Run
# that way the arms churned normally and reported `walk 0 B` on both walking
# arms (2026-09-14), which the gate reads as "the walk did not run".
live-graph-audit: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/live_graph_audit.cr -o $(BIN)/live_graph_audit --error-trace
	$(BIN)/live_graph_audit

# The collector waits for the Monitor; the Monitor waits for the collector.
#
# `MonitorGate.close` spins until the Monitor's current call ends. One of those
# calls reaches `thread_pool.checkout` -> `Thread.new` -> `pthread_create`,
# which gcry wraps to root the new `Thread` through `@roots_lock` — the lock the
# collector took before it started stopping. Closing the gate first breaks it.
# The control arm gets tries rather than a budget: the cycle is a race and one
# attempt comes up empty about half the time.
monitor-gate-deadlock: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/monitor_gate_deadlock.cr -o $(BIN)/monitor_gate_deadlock --error-trace
	$(BIN)/monitor_gate_deadlock

# Do the page-release walks zero a live object?
#
# Both build a live-page mask by reading block headers with no lock, then
# madvise the pages the mask calls free. Every live object carries a checksum
# and is re-verified each round, so a zeroed page is caught without waiting for
# a crash. `dontneed_bytes` is reported per arm because a run that never marks a
# chunk HOLED releases nothing and looks perfectly clean.
#
# Linux keeps both walks opt-in; Darwin turns the HOLED one on in GC.init and
# walks every chunk.
#
# Built `-Dgcry_block_headers`, and that is load-bearing: the walks are
# freelist-shaped and stand down on bitmap chunks, so the arms pin
# `GCRY_BITMAP_ALLOC=0` to get the freelist back — a knob the headerless
# compile default ignores, because there is no freelist to return to. Built
# the old way after that flip the gate reached nothing and said so: `unlinked
# 0` on the HOLED arm in 4 of 4 runs (2026-09-14), the mostly-empty arm
# 0-11.8 MB against its 16 MiB engagement floor. On the header layout it
# engages as its own history describes — 11 674-12 904 page runs unlinked
# against 10 644-12 783 in 2026-08, and 60.3-68.7 MB released on the
# mostly-empty arm against 64-67 MB — and it is clean: **0 of 24 per arm**
# across six runs, 45 s each.
page-release-corruption: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/page_release_corruption.cr -o $(BIN)/page_release_corruption --error-trace
	$(BIN)/page_release_corruption

# A post-STW chunk-list walk against a mutator's unmap.
#
# The lazy sweep and the three `flush_pending_*` passes walk `@chunks` after
# `start_world` holding nothing, and `release_large_freelist_pages` walks a
# list mutators edit. A `GC.free` of a large object reaches `trim_large_cache`
# from a mutator thread, which unlinks and unmaps. Crashed 6 of 6 before the
# fix; the `GCRY_TRIM_IMMEDIATE=1` arm has to keep crashing or the other arm
# proves nothing.
dormant-flush-race: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/dormant_flush_race.cr -o $(BIN)/dormant_flush_race --error-trace
# A gate whose failure mode is a fault should name the address it faulted on.
# Without this the crash is one line from Crystal's handler.
	GCRY_SEGV_REPORT=1 $(BIN)/dormant_flush_race

# Running out of address space must produce an error, not a hang.
#
# It produced a hang: `map_chunk` raised while its caller held a size-class
# freelist lock or `@alloc_lock`, and `raise` allocates a `CallStack`, which
# re-enters the allocator and spins on that same lock. 3 of 3 children killed
# on the deadline before the fix, 0 of 3 after, both size paths. Deterministic
# — the child caps its own RLIMIT_AS — so a red here is a real regression.
oom-no-hang: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/oom_no_hang.cr -o $(BIN)/oom_no_hang --error-trace
	$(BIN)/oom_no_hang

large-cache-race: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/large_cache_race.cr -o $(BIN)/large_cache_race --error-trace
# A gate whose failure mode is a fault should name the address it faulted on.
# Without this the crash is one line from Crystal's handler.
	GCRY_SEGV_REPORT=1 $(BIN)/large_cache_race

.PHONY: chunk-search-race
chunk-search-race: $(BIN)
	$(CRYSTAL) build bench/chunk_search_race.cr -o $(BIN)/chunk_search_race --error-trace
# A library build installs no SIGSEGV handler of its own, so a fault here used
# to print one line with no address. The children inherit this.
	GCRY_SEGV_REPORT=1 $(BIN)/chunk_search_race

# A mutator inside `find_block` while collections run.
#
# It used to die in 5 runs of 8, on an impossible chunk pointer the last-chunk
# cache handed back — the field tested and then read again, with an
# unsynchronised writer setting it to `-1` in between, so the second read
# indexed the array at `[-1]`. Plain allocation at the same rate never crashed,
# because it does not look chunks up. `GCRY_INDEX_CACHE_UNCHECKED=1` restores
# the old read and takes it to 8 of 8, which is what makes the green arms mean
# something. `FIND_BLOCK_RACE_RUNS` sets the sample (default 4).
find-block-race: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/find_block_race.cr -o $(BIN)/find_block_race --error-trace
# A gate whose failure mode is a fault should name the address it faulted on.
# Without this the crash is one line from Crystal's handler.
	GCRY_SEGV_REPORT=1 $(BIN)/find_block_race

# Does a mutator ever read the chunk index without the lock?
#
# `chunk_containing` skips `@index_lock` while `@world_stopped` is set, on the
# grounds that only the collector can be there. `start_world` used to clear that
# flag *after* resuming every thread, so between the two every mutator took the
# unlocked path against an `index_insert` / `index_remove` from a peer.
# `GCRY_STW_LATE_CLEAR=1` is that ordering, and the gate requires it to produce
# the reads the fixed one must not.
stw-index-race: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_index_race.cr -o $(BIN)/stw_index_race --error-trace
	$(BIN)/stw_index_race

# Which birth does a full staging table keep? The table is filled with raw
# pthreads, which never reach Crystal's list, so neither the drain nor the
# collection's walk can release them and the full table is a fact rather than a
# race. `GCRY_STAGED_NO_EVICT=1` restores the old refusal, where the birth in
# flight is the one thrown away.
thread-staging: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_staging.cr -o $(BIN)/thread_staging --error-trace
	$(BIN)/thread_staging
	GCRY_STAGED_NO_EVICT=1 $(BIN)/thread_staging --no-evict
	$(BIN)/thread_staging --race

# Is the BSS a root range at any size? Two binaries, because the second
# threshold is a scan limit rather than a maps-parser one: 8 MiB clears the
# 1 MiB adjacency cap this closed, 96 MiB clears `Roots::MAX_SCAN_BYTES` and so
# can only pass through the chunked scan. Both arms run against
# `GCRY_STATIC_BSS_CAP=1`, which restores the old refusal and requires the same
# block to die — the harness reports that through a duplicated fd, because the
# collection that frees the block also finalizes `STDERR` and closes fd 2.
static-bss-roots: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/static_bss_roots.cr -o $(BIN)/static_bss_roots --error-trace
	$(CRYSTAL) build -Dgc_none -Dstatic_bss_huge bench/static_bss_roots.cr -o $(BIN)/static_bss_roots_huge --error-trace
	$(BIN)/static_bss_roots
	$(BIN)/static_bss_roots_huge
	# The red direction. `GCRY_STATIC_BSS_CAP=1` (used inside the harness)
	# refuses one large section; this refuses the static root scan outright,
	# which is the stronger break and the one a reader would reach for. Also
	# previously read by the collector and used by nothing. Red at "a block
	# held only by the BSS did not survive".
	! GCRY_DISABLE_STATIC_ROOTS=1 $(BIN)/static_bss_roots

# What does starting the Nth thread cost, and does a collection make it worse?
# A **probe, not a gate**: it asserts only that its own arms ran and otherwise
# reports numbers. It exists because `stack_bounds_growth` asked for 100 live
# threads and the macOS runner never got all 100 running inside 120 s, twice,
# while Linux does it in under 3 ms. Three arms over a sweep of N, each (arm, n)
# pair its own bounded child so a hang at large N does not lose the small-N
# data: `auto=on`, `auto=off` (`GCRY_DISABLE_AUTO=1`, no stop-the-world at all)
# and `collect` (a thread calling `GC.collect` every 2 ms through the storm).
# The third arm is there because the first two measure the same thing on Linux
# -- both report `collections=0`, since 100 `Thread.new` calls never reach the
# threshold. Linux baseline: us/thread *falls* with n on every arm (x0.16 to
# x0.22), so not quadratic; collections cost about 30x per thread. ~7 s.
.PHONY: thread-startup-cost
thread-startup-cost: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_startup_cost.cr -o $(BIN)/thread_startup_cost --error-trace
	$(BIN)/thread_startup_cost

# Does the world come back whole past 64 threads? Darwin suspends every thread
# with `thread_suspend` but recorded the port only while a slot was free, and
# resumed from that 64-entry table -- so the 65th thread and up were suspended
# and never resumed. A frozen mutator, from a collection that reported success.
# Found from the TIMEOUT cells of `thread-startup-cost` above.
#
# The contract is an equality: `stw_threads_suspended == stw_threads_resumed`,
# both counted on KERN_SUCCESS only, plus every worker still making progress
# after the restart. Three arms as bounded children -- 70 threads on the
# shipped resume, 70 with `GCRY_STW_BOUNDED_RESUME=1` (which must *not* come
# back whole, and a wedged child counts: a thread frozen holding the allocator
# takes the process with it), and 8 with the same knob, which must come back
# whole so the red arm is attributable to the bound and not to the knob.
# Skips off Darwin: Linux threads resume themselves out of `sigsuspend` and
# Windows refuses any stop it cannot record.
.PHONY: darwin-stw-resume
darwin-stw-resume: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/darwin_stw_resume.cr -o $(BIN)/darwin_stw_resume --error-trace
	$(BIN)/darwin_stw_resume

# Does an explicit GC.collect actually collect while other threads allocate?
# `Heap#collect` used to open with `return if @collecting`, so a request made
# while *any* thread was in a cycle returned immediately and silently: with 70
# allocating threads, 6 of 85 682 calls did anything, because a cycle there
# takes ~145 ms and the flag is up for all of it. The guarantee gated here is
# the one a caller is entitled to -- when it returns, a collection has
# completed. Three arms as bounded children: 20 consecutive calls with 32
# threads allocating must each land one, the same with
# GCRY_COLLECT_SKIP_WHEN_BUSY=1 (the pre-fix guard) must lose at least one, and
# 20 calls on an idle process must land too, so the gate is not passing because
# pause_count moves on its own.
.PHONY: explicit-collect-barrier
explicit-collect-barrier: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/explicit_collect_barrier.cr -o $(BIN)/explicit_collect_barrier --error-trace
	$(BIN)/explicit_collect_barrier

# What a thread with no STW capture slot costs. Linux kept its table at a fixed
# 64 on the argument that the loss is precision and not roots -- the registers
# arrive in a ucontext on the interrupted thread's own stack, which the
# unclamped scan still walks, and the held arm here checks exactly that. The
# cost is the unclamped scan: with no recorded SP, the fiber window for that
# thread's own stack (a Crystal thread's main fiber's stack *is* its OS stack)
# falls back to the guard page, so the scan covers the whole 8 MiB mapping. 98
# threads over 8 collections: 264 guard-page fallbacks and ~535 ms per
# collection pinned at 64, against 8 (the collector's own fiber) and ~29 ms
# with the table grown. Retracted along the way: the first version of this gate
# claimed the cost was retention, and that was lazy sweep -- see the FINDINGS.
# Three arms as bounded children, with GCRY_STW_FIXED_SLOTS=1 as the arm that
# must show the fallbacks and the refused claims.
.PHONY: stw-slot-precision
stw-slot-precision: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_slot_precision.cr -o $(BIN)/stw_slot_precision --error-trace
	$(BIN)/stw_slot_precision

# Does the STW capture table cover every thread it suspends? `slot_for`
# returned -1 past 64 slots -- the claim mask was a UInt64 and could not address
# a 65th -- and a thread with no slot is suspended and scanned with no SP clamp
# and no registers. The SP half is conservative, an unclamped scan walks the
# whole stack, but the registers are not on Darwin, where `thread_get_state` is
# their only copy; Windows answered the same bound by refusing the stop, so a
# process with 65 threads could not collect at all. The table now lives in
# `Gcry::StwSlots`, grows at collection entry via LibC.malloc, never inside the
# stopped world, and never frees its predecessor -- which is what a reader
# walking it during a grow needs, and what `spec/stw_slots_spec.cr` covers on
# every platform. Three arms as bounded children: 80 threads with no failed
# claims, the same pinned by GCRY_STW_FIXED_SLOTS=1 where claims must fail, and
# 8 threads under the same knob where they must not. Skips on Linux, whose
# fixed table is deliberate: its registers live in a ucontext on the
# interrupted thread's own stack, which the unclamped scan still walks.
# The one property of the STW capture table that no serial test can show: a
# reader inside the old block when a grow replaces it. The table never frees its
# predecessor, which is why a suspend handler on Darwin or the stop loop on
# Windows can load the pointer and keep walking while another thread grows it.
# Two arms as bounded children -- the shipped table, which must carry its
# readers across 12 doublings, and GCRY_STW_SLOTS_FREE_OLD=1, which frees the
# predecessor and must kill them. Lives here rather than in
# spec/stw_slots_spec.cr because it needs four readers flat out: in the spec
# suite it held the two-vCPU Windows runner for that job's whole 20-minute
# budget.
.PHONY: stw-slots-grow-race
stw-slots-grow-race: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_slots_grow_race.cr -o $(BIN)/stw_slots_grow_race --error-trace
	$(BIN)/stw_slots_grow_race

.PHONY: stw-capture-coverage
stw-capture-coverage: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_capture_coverage.cr -o $(BIN)/stw_capture_coverage --error-trace
	$(BIN)/stw_capture_coverage

# Does the stack-bounds snapshot still cover the 65th thread? The root scan
# cannot call `pthread_getattr_np` with the world stopped -- that is the
# 2026-08-10 six-hour hang -- so bounds are snapshotted before the stop and read
# from a table inside it, and that table was a fixed 64 slots. Past it, threads
# were visited with nowhere to record them and their OS stacks went unscanned.
# `ROADMAP.md` claimed this was gated in `process_spec` and broken on purpose
# with `GCRY_STACK_BOUNDS_NOGROW=1`; the knob was in no spec, recipe or CI step
# at all, so the claim had gone stale in place. Three arms: `hold` requires
# `read == visited` with 100 threads held, `nogrow` freezes the table and
# requires the loss to *show* in both counters (measured: read 128 of 204
# visited, 76 misses), `control` stays inside the initial capacity so the
# equality above is attributable to growth. Each arm is a **bounded child** of
# the harness: this gate hung the Darwin job for 18m37s on 2026-09-16, and a
# gate that can hang must bound itself rather than lean on a `timeout(1)` macOS
# does not have. `BENCH_CHILD_TIMEOUT_S` moves the budget; at 1 s the parent
# reports "exceeded its budget" and exits 1. ~4 s.
.PHONY: stack-bounds-growth
stack-bounds-growth: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stack_bounds_growth.cr -o $(BIN)/stack_bounds_growth --error-trace
	$(BIN)/stack_bounds_growth

# Is the stack of a *terminating* fiber a root? `Thread#dead_fiber_stack` parks
# it there because Crystal cannot release a fiber's stack until it swaps away,
# and while it sits there the thread may still be running on it while the owning
# `Fiber` is already off `Fiber.unsafe_each`. The v0.20.0 fix roots it (11/24
# crashes -> 0/24 on the nested-spawn repro) and had **no gate**: its disable
# appeared in no spec, recipe or CI step, and the one harness that touches the
# counter only prints it. Four arms, three of which require the block to die, so
# the red direction is built every run: `--control` never plants the address,
# `--noroot` walks the stack and offers nothing (which needs the fix off too --
# `offer = @dead_stack_roots`, so NOROOT alone is the fix with a flag set),
# `--disabled` turns the walk off outright and also checks the knob still gates
# it. ~1 s.
.PHONY: dead-stack-root
dead-stack-root: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/dead_stack_root.cr -o $(BIN)/dead_stack_root --error-trace
	$(BIN)/dead_stack_root
	$(BIN)/dead_stack_root --control
	GCRY_DEAD_STACK_ROOTS=0 GCRY_DEAD_STACK_NOROOT=1 $(BIN)/dead_stack_root --noroot
	GCRY_DEAD_STACK_ROOTS=0 $(BIN)/dead_stack_root --disabled

# `GCRY_THREAD_CENSUS=1` could say how many threads were outside Crystal's list
# and never which. On `test (aarch64 native)` that is a gap of exactly one on
# every collection of `scheduler_roots --control` — an arm that starts nothing —
# in 40 of 40 green runs, and it has been read as the open unscanned-mutator
# defect for a month with no way to confirm it. The census now walks
# /proc/self/task on a gap and names each task by tid and `comm`.
#
# It also had a false positive of gcry's own making: parallel-mark helpers are
# raw pthreads by construction, so `GCRY_PARALLEL_MARK=4` alone reported
# `gap=3`. They are named `gcry-mark` now and subtracted.
#
# Five arms, two of them the red twins. The two `grep` arms are the ones the
# counters cannot make: a counter says the walk classified something, only the
# output says it was *named*. ~3 s.
.PHONY: thread-census-names
thread-census-names: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_census_names.cr -o $(BIN)/thread_census_names --error-trace
	GCRY_THREAD_CENSUS=1 $(BIN)/thread_census_names --control
	GCRY_THREAD_CENSUS=1 $(BIN)/thread_census_names
	GCRY_THREAD_CENSUS=1 GCRY_THREAD_CENSUS_NAMES=0 $(BIN)/thread_census_names --noname
	GCRY_THREAD_CENSUS=1 GCRY_PARALLEL_MARK=4 $(BIN)/thread_census_names --mark
	GCRY_THREAD_CENSUS=1 GCRY_PARALLEL_MARK=4 GCRY_THREAD_CENSUS_NAMES=0 $(BIN)/thread_census_names --mark --noname
	# The aarch64 shape, reproduced on purpose. That job sets
	# `GCRY_STW_WATCHDOG_MS` for its whole step, and the watchdog is a raw
	# Both location arms run `--parked`, where the planted probe sleeps instead
	# of spinning. Without it their subject was whichever peer happened to be
	# in a syscall — usually Crystal's `SYSMON`, and on 2026-09-22 (run
	# `35707265944`) neither it nor the probe was, so the gate went red on a
	# green tree. Locally the plain arm is 20 of 20; the flake is the runner's.
	# pthread — which is the thread the census reported as unrecorded on every
	# collection of every binary there, 11 times a run in 40 of 40 green runs,
	# until it was named. `--control` requires the credit to be exactly one
	# here and exactly zero without the knob, so an unnamed watchdog is red.
	GCRY_THREAD_CENSUS=1 GCRY_STW_WATCHDOG_MS=10000 $(BIN)/thread_census_names --control
	GCRY_THREAD_CENSUS=1 GCRY_STW_WATCHDOG_MS=10000 $(BIN)/thread_census_names
	@out=$$(GCRY_THREAD_CENSUS=1 GCRY_STW_WATCHDOG_MS=10000 $(BIN)/thread_census_names --control 2>&1); \
	echo "$$out" | grep -q "every one of them is gcry's own, so none is unrecorded" \
	  || { echo "FAIL: a gap made entirely of gcry's own threads still reads as unrecorded"; echo "$$out" | grep "the OS reports" | head -2; exit 1; }; \
	echo "$$out" | grep -q "at least one is unrecorded" && { echo "FAIL: the verdict line still claims an unrecorded thread with the gap fully attributed"; exit 1; }; \
	echo "ok — a gap that is all gcry's own stops claiming an unrecorded mutator"
	@out=$$(GCRY_THREAD_CENSUS=1 $(BIN)/thread_census_names 2>&1); \
	echo "$$out" | grep -q "OS tasks:.*census-probe" || { echo "FAIL: the census did not name the planted raw pthread"; echo "$$out" | tail -4; exit 1; }; \
	echo "ok — the thread Crystal never listed is named in the census line"
	@out=$$(GCRY_THREAD_CENSUS=1 $(BIN)/thread_census_names --parked 2>&1); \
	echo "$$out" | grep -qE "task [0-9]+:.* is parked in syscall [0-9]+, returning to 0x[0-9a-f]+ in /.*\+0x[0-9a-f]+" \
	  || { echo "FAIL: no task was located — the syscall site or the mapping lookup produced nothing"; echo "$$out" | grep "task " | head -4; exit 1; }; \
	echo "ok — a task outside Crystal's list is placed in a named mapping, not just named"
	@out=$$(GCRY_THREAD_CENSUS=1 $(BIN)/thread_census_names 2>&1); \
	echo "$$out" | grep -q "is the collector, stopped here to ask" \
	  || { echo "FAIL: the collector did not exclude itself, so it is reporting the read it is making"; exit 1; }; \
	echo "ok — the collector names itself instead of reporting its own /proc read"
	@out=$$(GCRY_THREAD_CENSUS=1 $(BIN)/thread_census_names --parked 2>&1); \
	echo "$$out" | grep -qE "returns through:.*thread_census_names\+0x[0-9a-f]+" \
	  || { echo "FAIL: the stack walk never reached the program's own code — a pc in libc names the sleep, not the caller"; echo "$$out" | grep "returns through" | head -2; exit 1; }; \
	echo "ok — a sleeping task's callers reach this binary, at an offset addr2line resolves"
	@out=$$(GCRY_THREAD_CENSUS=1 GCRY_THREAD_CENSUS_NAMES=0 $(BIN)/thread_census_names --noname 2>&1); \
	echo "$$out" | grep -q "gcry: thread census — task " && { echo "FAIL: the twin located tasks with the walk off"; exit 1; }; \
	echo "ok — with the walk off nothing is located either"
	@out=$$(GCRY_THREAD_CENSUS=1 GCRY_THREAD_CENSUS_NAMES=0 $(BIN)/thread_census_names --noname 2>&1); \
	echo "$$out" | grep -q "OS tasks:" && { echo "FAIL: the twin still printed names, so the arm above proves nothing"; exit 1; }; \
	echo "ok — with the walk off the same gap is counted and unnamed"

# The offsets the census prints are the answer only if something turns them
# into source. This is that step, and it runs where the interesting thread
# actually is: on `test (aarch64 native)` every binary has one task outside
# Crystal's list, and its callers are printed beside `SYSMON`'s — different
# frames, so it is not a second monitor, and until this target existed the
# difference was two hex numbers nobody could read.
#
# Fails if `addr2line` is absent rather than skipping: a resolution step that
# quietly does nothing is the rot this gate family exists to prevent.
#
# `--parked` for the same reason the two location arms take it: a frame to
# resolve needs a task parked in a syscall, and without a planted one the
# subject is whichever peer happens to be asleep. This target went red on
# 2026-09-22 (run `35709742955`) with `no frame landed in this binary` on a
# tree that changed nothing it reads.
.PHONY: thread-census-symbolize
thread-census-symbolize: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_census_names.cr -o $(BIN)/thread_census_names --error-trace
	@command -v addr2line >/dev/null 2>&1 || { echo "FAIL: addr2line is missing, so the reported offsets cannot be resolved"; exit 1; }
	@out=$$(GCRY_THREAD_CENSUS=1 $(BIN)/thread_census_names --parked 2>&1); \
	echo "$$out" | grep -a "returns through" | sed 's/^/  /' | sort -u; \
	frames=$$(echo "$$out" | grep -ao "thread_census_names+0x[0-9a-f]*" | sed 's/.*+0x//' | sort -u); \
	[ -n "$$frames" ] || { echo "FAIL: no frame landed in this binary, so there is nothing to resolve"; exit 1; }; \
	resolved=0; total=0; \
	for f in $$frames; do \
	  total=$$((total+1)); \
	  line=$$(addr2line -e $(BIN)/thread_census_names -f -C "0x$$f" 2>/dev/null | tr '\n' ' '); \
	  echo "  0x$$f -> $$line"; \
	  case "$$line" in *'??'*) ;; *) resolved=$$((resolved+1));; esac; \
	done; \
	[ "$$resolved" -gt 0 ] || { echo "FAIL: none of the $$total frame(s) resolved — the offsets are not load-base relative"; exit 1; }; \
	echo "ok — $$resolved of $$total reported frames resolve to a symbol and a source line"

# Is a pointer held only in thread-local storage a root? It was not, on the
# main thread: the executable's writable image (`PT_LOAD` / `__DATA*` / PE
# writable sections) is every class variable, but a thread-local lives in a
# per-thread block that is not in any of them. Spawned threads often keep
# that block on their own stack mapping, which the stack scan covers; the
# main thread's is allocated with the loader (Linux), libc malloc (Darwin
# TLV), or the TEB (Windows) and was lost. Three arms: the shipped default
# must keep the block, the red arm (`GCRY_TLS_ROOTS=0`) must lose it, and a
# control that holds the pointer nowhere must lose it either way - without
# that last one a conservative hit on a stale stack slot would pass the
# first two. Darwin CI and the Windows default variant run this too.
tls-roots: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/tls_roots.cr -o $(BIN)/tls_roots --error-trace
	$(BIN)/tls_roots
	! GCRY_TLS_ROOTS=0 $(BIN)/tls_roots
	$(BIN)/tls_roots --control

# Do the executable's `.data` and BSS stay root ranges after the binary is
# replaced on disk? A redeploy renames every maps line of the running image to
# `… (deleted)`; a parser that matched the pathname against `/proc/self/exe`
# lost `.data` at the next refresh, and the BSS with it. The child deletes its
# own (copied) binary, keeps collecting, and checks a class-variable array.
static-roots-redeploy: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/static_roots_redeploy.cr -o $(BIN)/static_roots_redeploy --error-trace
	$(BIN)/static_roots_redeploy

# Does the default-on collector scrub ask libc where the stack is? On the
# initial thread `pthread_getattr_np` is a `/proc/self/maps` parse, twice per
# collection and outside the pause window, so it never reached `pause_p50`.
# The bounds come from `Fiber#@stack` now; the red arm restores the libc
# lookup so the counter that says so is read in both directions.
collect-scrub-cost: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/collect_scrub_cost.cr -o $(BIN)/collect_scrub_cost --error-trace
	$(BIN)/collect_scrub_cost
	GCRY_SCRUB_LIBC_BOUNDS=1 $(BIN)/collect_scrub_cost --libc

# Can the master end a parallel mark cycle while a worker still holds a batch?
# It could until 2026-09-04: the batch left the shared stack under `@mark_lock`
# and the worker counted itself busy after releasing it, so `busy == 0 && stack
# empty` was observable with work in flight. The red arm restores that
# protocol and loses a live object on the first collection.
parallel-mark-termination: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/parallel_mark_termination.cr -o $(BIN)/parallel_mark_termination --error-trace
	$(BIN)/parallel_mark_termination

thread-birth-root: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_birth_root.cr -o $(BIN)/thread_birth_root --error-trace
	$(BIN)/thread_birth_root
	GCRY_THREAD_BIRTH_NOROOT=1 $(BIN)/thread_birth_root --noroot
	GCRY_THREAD_BIRTH_ROOT=0 $(BIN)/thread_birth_root --control
	$(BIN)/thread_birth_root --burst
	GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED=1 $(BIN)/thread_birth_root --burst-unrooted
	$(BIN)/thread_birth_root --churn
	GCRY_THREAD_BIRTH_DEATHS=0 $(BIN)/thread_birth_root --churn-leaking

# The reproducer for the open "live large object released under load" item —
# not a gate. `ROADMAP.md` has carried that defect since 2026-08-23 and lost
# its reproducer: it was found under `wrk` against acikturkiye at about one
# run in eight, then stopped firing, and the item says that until it
# reproduces at a resolvable rate no arm means anything. This is that rate
# without an application: eight short-lived threads per round, one collection
# per round, and it fires on **both** layouts with no knob set.
#
# Three arms because the diagnostics surface different victims and hide each
# other: `default` is the shipped rate, `guarded` names the released chunk
# through `GCRY_UNMAP_GUARD=1`, `poisoned` has the highest rate and names a
# freed small block. ~90 s for both layouts.
#
# The regression gate for the live-object release, fixed 2026-09-13. Both
# layouts, each with its control: the shipped arms must not fault, and
# `--control` — which restores the pre-fix shape, both the mutator-count reads
# and the list-based mark clear — must still fault, or the harness has stopped
# driving the workload and the clean run proves nothing. Measured, 12 attempts
# each: shipped 0, trigger alone 2, consequence alone 0, both 7.
#
# The control runs eight attempts rather than the full count, and the reason is
# runtime: its children *crash*, and a crashing child under
# `GCRY_POISON_HOLDERS=1` walks the whole heap and every stack and then
# re-faults into Crystal's backtrace printer. Twenty-four of those on a
# two-core runner took the CI step past ten minutes. At the measured 58%
# per-attempt rate eight attempts miss once in about a thousand runs.
thread-churn-uaf: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_churn_uaf.cr -o $(BIN)/thread_churn_uaf --error-trace
	$(BIN)/thread_churn_uaf
	CHURN_ATTEMPTS=8 $(BIN)/thread_churn_uaf --control
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/thread_churn_uaf.cr \
	  -o $(BIN)/thread_churn_uaf_headers --error-trace
	$(BIN)/thread_churn_uaf_headers
	CHURN_ATTEMPTS=8 $(BIN)/thread_churn_uaf_headers --control

# The nursery keeps the header representation under every setting, so every
# mark clear has to gate per *chunk* like the read side does. Gating on the
# global `@bitmap_marks` left a nursery block's header mark set forever, and a
# marked block is never scanned — so with `GCRY_BITMAP=1` and a nursery, one
# minor reclaimed a live child and handed its address out again.
# Until 2026-09-20 this built headerless, where those two setters are
# no-ops and `minor_collect` returned immediately. Green requires
# `-Dgcry_block_headers`. `--disabled` is `GCRY_NURSERY_MARKS_GLOBAL=1`,
# the pre-fix global gate: bitmap arms must lose the child. Dropping
# the flag or the knob reddens the gate rather than hiding it.
nursery-bitmap-marks: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/nursery_bitmap_marks.cr -o $(BIN)/nursery_bitmap_marks --error-trace
	$(BIN)/nursery_bitmap_marks
	GCRY_NURSERY_MARKS_GLOBAL=1 $(BIN)/nursery_bitmap_marks --disabled

# Until 2026-09-20 CI built this headerless. nursery_enabled= is a no-op
# there, tlab_enabled= is refused (bitmap allocator forced), and
# minor_collect returned immediately — twenty rooted objects surviving
# a no-op. Green requires -Dgcry_block_headers and GCRY_BITMAP_ALLOC=0
# (TLAB cannot be turned on once bitmap chunks are mapped).
# `--disabled` is GCRY_TLAB_MINOR_FREE_OLD=1, the pre-fix old FREE-claim:
# an old FREE node on the stack becomes USED-unmarked. Dropping the
# flag, the allocator knob, or the claim reddens the gate.
nursery-tlab-smoke: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/nursery_tlab_smoke.cr -o $(BIN)/nursery_tlab_smoke --error-trace
	GCRY_BITMAP_ALLOC=0 $(BIN)/nursery_tlab_smoke
	GCRY_BITMAP_ALLOC=0 GCRY_TLAB_MINOR_FREE_OLD=1 $(BIN)/nursery_tlab_smoke --disabled

# Buy samples of a defect that only happens on CI.
#
# The `Thread` use-after-free fires in roughly one aarch64 job in three and
# never locally (40 runs of this harness on x86_64: 0 crashes, 0 reports, while
# the same arm reports 72 dying `Thread`s in `thread-storm` on the same
# machine). The arm that names its holder only speaks when the defect happens,
# so the way to read it more often is to run the failing harness more often.
#
# Both arms, per iteration, exactly as `ec-queue-audit` runs them — and the
# second one is the one that matters: all four catches on 2026-08-20 were in
# **`--control`**, with `GCRY_EC_QUEUE_AUDIT` off. The first version of this
# target sampled the audit-on arm only and found nothing in ten runs, which is
# what a sampler pointed at the wrong arm looks like.
#
# `THREAD_UAF_BIN` / `THREAD_UAF_ARGS` point it at another harness, which is how
# the sampler's own reporting path is shown to work at all: against
# `bin/thread_storm`, where a dying `Thread` is routine, it must keep the logs
# and print them. A sampler that has never been seen to report something says
# nothing when it reports nothing.
#
# The two are counted apart on purpose. The first version of this target added
# them together under the label "dying-Thread report(s)", and once the arm began
# reporting the *precondition* in green runs that number would have said the
# defect had fired when nothing had died.
#
# And the preconditions are counted apart from each other, for the same reason
# one level down. There are two, and only one of them is the window this defect
# needs:
#
#   caught   the wait for a staged thread found it — the safe path, and what
#            almost every collection does
#   gave up  the world stopped with the thread unpublished — neither suspended
#            nor scanned, which is the window
#
# Summing them was a 2 000-fold overstatement of coverage. Measured over the
# 299 sampler jobs from 2026-08-25 to 2026-09-20 — 2 990 harness runs — there
# were **11 965** preconditions and **5** of them were the give-up, all between
# 2026-08-25 and 2026-09-07. "11 965 preconditions and no death" reads as
# enormous evidence; "5 windows and no death" is what was actually measured.
#
# **And a report is a trigger, not a verdict.** The audit fires on any watched
# block the mark did not reach, and on a workload where threads *exit* that is
# ordinary garbage: a dead thread's `Thread` object should be collected.
# Measured 2026-09-20 over six `thread_churn_uaf --child` runs — **5 712
# reports, 0 of them with a holder**: none still on Crystal's list, none
# linked from a live list node, none in a suspended thread's registers, none
# offered by the collecting thread's stack scan. So the count is summed apart
# from the reports that carry holder evidence, which is the defect's shape.
# Logs are kept for a holder or a give-up, plus **one** death-only log per
# batch as an exemplar, and at most four in all — that exemplar is what keeps
# the reporting path demonstrable without carrying eight megabytes of
# ordinary garbage per CI run.
#
# The churn arm is here because of that number. `ec_queue_audit` alone reports
# 0 deaths over 2 990 runs, which is 0 of 0 — no thread exits in it. The churn
# arm exercises the death side and turns that into 0 of thousands.
#
# **And the budget is spent in windows, not in runs.** The statement this
# sampler produces is "0 deaths with a holder across N give-up windows", so N
# is what a batch has to buy — and the two runners buy it at rates that differ
# a hundredfold: six churn children on an x86_64 developer host built **120**
# windows (2026-09-22), while the aarch64 job's ten built **2 to 5** in each of
# its last four batches. A fixed run count therefore means a fixed sample on
# one platform and almost none on the other. After the fixed runs below, extra
# churn children run until the batch has `THREAD_UAF_MIN_WINDOWS` (100) of them
# or `THREAD_UAF_CHURN_BUDGET_S` (300) seconds are gone, and the headline says
# which bound stopped it.
#
# **Not a gate.** It exits 0 whether or not the defect fires, because an open
# defect must not turn every pull request red — and a step that is expected to
# fail teaches everyone to ignore it. What it produces is evidence: the logs of
# the runs that said something, and nothing from the ones that did not.
thread-uaf-sample: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/ec_queue_audit.cr -o $(BIN)/ec_queue_audit --error-trace
	$(CRYSTAL) build -Dgc_none bench/thread_churn_uaf.cr -o $(BIN)/thread_churn_uaf --error-trace
	@mkdir -p $(SAMPLE_DIR)
	@runs=$${THREAD_UAF_RUNS:-10}; hits=0; held=0; caught=0; gaveup=0; crashes=0; exemplar=0; kept=0; \
	harness=$${THREAD_UAF_BIN:-$(BIN)/ec_queue_audit}; \
	: $${THREAD_UAF_CONTROL_ARGS:=--control}; \
	for i in $$(seq 1 $$runs); do \
	  GCRY_EC_QUEUE_AUDIT=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 \
	    $$harness $$THREAD_UAF_ARGS > $(SAMPLE_DIR)/run-$$i-hold.log 2>&1 || crashes=$$((crashes+1)); \
	  GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 \
	    $$harness $$THREAD_UAF_ARGS $$THREAD_UAF_CONTROL_ARGS > $(SAMPLE_DIR)/run-$$i-control.log 2>&1 || crashes=$$((crashes+1)); \
	  churn=""; \
	  if [ -z "$$THREAD_UAF_BIN" ]; then \
	    churn=$(SAMPLE_DIR)/run-$$i-churn.log; \
	    GCRY_THREAD_UNSTAGE_ON_DEATH=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 \
	      $(BIN)/thread_churn_uaf --child > $$churn 2>&1 || crashes=$$((crashes+1)); \
	  fi; \
	  for f in $(SAMPLE_DIR)/run-$$i-hold.log $(SAMPLE_DIR)/run-$$i-control.log $$churn; do \
	    d=$$(grep -c "is unmarked and about to be swept" $$f || true); \
	    g=$$(grep -c "GAVE UP" $$f || true); \
	    c=$$(grep -c "and the wait caught it" $$f || true); \
	    h=$$(grep -oE "registers: yes|stack scan: yes|thread list: YES|list node: YES" $$f | wc -l); \
	    hits=$$((hits+d)); gaveup=$$((gaveup+g)); caught=$$((caught+c)); held=$$((held+h)); \
	    if [ "$$h" != "0" ] || [ "$$g" != "0" ]; then \
	      if [ "$$kept" -lt 4 ]; then kept=$$((kept+1)); else rm -f $$f; fi; \
	    elif [ "$$d" != "0" ] && [ "$$exemplar" = "0" ]; then exemplar=1; \
	    else rm -f $$f; fi; \
	  done; \
	done; \
	extra=0; stop=""; \
	if [ -z "$$THREAD_UAF_BIN" ]; then \
	  want=$${THREAD_UAF_MIN_WINDOWS:-100}; deadline=$$(($$(date +%s) + $${THREAD_UAF_CHURN_BUDGET_S:-300})); \
	  while [ "$$gaveup" -lt "$$want" ]; do \
	    if [ "$$(date +%s)" -ge "$$deadline" ]; then stop="budget"; break; fi; \
	    extra=$$((extra+1)); f=$(SAMPLE_DIR)/extra-$$extra-churn.log; \
	    GCRY_THREAD_UNSTAGE_ON_DEATH=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 \
	      $(BIN)/thread_churn_uaf --child > $$f 2>&1 || crashes=$$((crashes+1)); \
	    d=$$(grep -c "is unmarked and about to be swept" $$f || true); \
	    g=$$(grep -c "GAVE UP" $$f || true); \
	    c=$$(grep -c "and the wait caught it" $$f || true); \
	    h=$$(grep -oE "registers: yes|stack scan: yes|thread list: YES|list node: YES" $$f | wc -l); \
	    hits=$$((hits+d)); gaveup=$$((gaveup+g)); caught=$$((caught+c)); held=$$((held+h)); \
	    if [ "$$h" != "0" ] && [ "$$kept" -lt 4 ]; then kept=$$((kept+1)); else rm -f $$f; fi; \
	  done; \
	  [ -n "$$stop" ] || stop="windows"; \
	fi; \
	echo "thread-uaf-sample: $$runs runs + $$extra churn ($$stop), $$crashes crashed, $$hits dying-Thread report(s) of which $$held with a holder; staged-thread window $$gaveup gave-up / $$caught caught in $(SAMPLE_DIR)"; \
	if [ "$$gaveup" = "0" ] && [ "$$held" = "0" ] && [ "$$hits" = "0" ]; then \
	  echo "thread-uaf-sample: this batch neither built the window nor saw a Thread die, so its silence is an absence of both and not an absence of the defect"; \
	fi; \
	grep -h "dying-type audit\|threads at that moment\|held at\|address-space audit" $(SAMPLE_DIR)/*.log 2>/dev/null || true

# Sampling, not gating: the TLAB+nursery arm of `stw_mt_property_test` died
# twice on CI (x86_64 2026-08-17, Darwin 2026-08-22) and never locally. It ran
# as a no-op from 0.26.0 to 2026-09-20 (headerless default), and the real arm
# is back at one run per CI run — at the 2 crashes in ~206 runs it showed
# before, eleven quiet runs leave a 90% chance of silence with the defect still
# there, and 95% confidence of its absence needs ~308. One run costs 1.9 s, so
# this takes the samples in one job instead of months: TLAB_NURSERY_RUNS
# (100) runs, seeds 1..N, the diagnostics of the CI arm on, and every run must
# report TLAB hits or the sample is not of the arm. Crashed runs keep their
# logs in $(SAMPLE_DIR); a quiet batch says how many samples it is.
tlab-nursery-sample: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o $(BIN)/stw_mt_property_test_hdr --error-trace
	@mkdir -p $(SAMPLE_DIR)
	@runs=$${TLAB_NURSERY_RUNS:-100}; crashes=0; unengaged=0; \
	for i in $$(seq 1 $$runs); do \
	  log=$(SAMPLE_DIR)/tlab-nursery-$$i.log; \
	  if GCRY_BITMAP_ALLOC=0 GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1 GCRY_THREAD_BLOCK_AUDIT=1 GCRY_STW_WATCHDOG_MS=10000 \
	      $(BIN)/stw_mt_property_test_hdr --tlab --nursery --seed=$$i --iterations=50 --workers=2,4 > $$log 2>&1; then \
	    if grep -qE "tlab_hits=[1-9]" $$log; then rm -f $$log; else unengaged=$$((unengaged+1)); fi; \
	  else \
	    crashes=$$((crashes+1)); \
	  fi; \
	done; \
	echo "tlab-nursery-sample: $$runs runs, $$crashes crashed, $$unengaged without TLAB hits; logs of the crashed runs in $(SAMPLE_DIR)"; \
	if [ "$$unengaged" != "0" ]; then echo "tlab-nursery-sample: $$unengaged run(s) passed without a TLAB hit, so they were not samples of the arm"; exit 1; fi; \
	if [ "$$crashes" != "0" ]; then grep -h "gcry: SIGSEGV\|holders —\|dying-type audit" $(SAMPLE_DIR)/tlab-nursery-*.log 2>/dev/null | head -40; exit 1; fi

thread-block-audit: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_block_audit.cr -o $(BIN)/thread_block_audit --error-trace
	$(BIN)/thread_block_audit
	$(BIN)/thread_block_audit --control

poison-holders: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/poison_holders.cr -o $(BIN)/poison_holders --error-trace
	$(BIN)/poison_holders
	$(BIN)/poison_holders --control

# Can the holders search find a word it is guaranteed to be able to find?
# Every use-after-free investigation on this heap turns on one sentence —
# "holders — none. Nothing in the root set, in a live block or on a fiber stack
# points into it" — and a search that can miss makes every one of those
# conclusions weaker than it reads. Three block shapes, one constructed holder
# each, plus a masked control whose address exists nowhere a walk can see: the
# three must be found and the control must not, or the counts are not
# attributable to the holders that were built. It also pins a lesson the first
# version of the probe learned the hard way: a holder whose only ivar is a
# `UInt64` has no inner pointers, so Crystal allocates it atomic, gcry never
# scans it, and the target is reclaimed — the control drew the first case's own
# address.
# Does the mark clear cover the set the marker marks? `mark_impl` resolves a
# candidate's chunk through `chunk_containing`, i.e. `@chunk_index`, while
# `clear_all_marks` walked the `@chunks` list — and those differ about one run
# in fourteen under churn, because of the prepend race between the sweep's walk
# and `map_chunk`. A chunk the clear misses keeps its marks, every block in it
# reads marked forever, `mark_impl` returns early on it, and nothing follows
# its edges; that is one half of the 2026-08-23 live-object release. Two arms:
# the shipped clear must leave no indexed chunk holding a mark, and `--control`
# forks `--child` under `GCRY_MARK_CLEAR_LIST=1` and `GCRY_SWEEP_MUTATOR_LATCH=0`
# — the list walk plus the pre-fix mutator-count reads, because the residue
# needs an off-list chunk to exist — which must leave some. Dropping the knobs
# is red (every child clean). The control drives
# *mappings*, and that is the whole difference between a gate and a coin toss:
# a chunk leaves the list only through a prepend racing the sweep's walk, a
# prepend happens in `map_chunk`, and the born threads have to be alive and
# allocating when that walk runs. Thread churn alone mapped ~30 chunks a child
# and the arm passed on luck — 6 of 6 locally, **0 of 6** on the two-core CI
# runner. With a live set that grows and drops, plus allocating threads, it is
# 6 of 6 children with residue and 18-91 stranded chunks each. ~35 s.
mark-clear-index: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/mark_clear_index.cr -o $(BIN)/mark_clear_index --error-trace
	$(BIN)/mark_clear_index
	$(BIN)/mark_clear_index --control

# What the chunk-list divergence costs, now that its marks are cleared anyway
# and it is an RSS question rather than a soundness one. A chunk stranded off
# `@chunks` by a prepend racing the sweep's walk is never swept and can never
# rejoin the list, so the loss is permanent — but it rides *mappings*, not
# uptime, and a heap that has reached its working size stops mapping. Three
# arms in one run: the shipped tree must strand under 5 per 1000 chunks mapped
# (measured 0 of 693 291 in steady state, 0 of 6 280 across 200 short
# processes), `sweep_mutator_latch = false` must exceed it (measured 80-181 per
# 1000, with 97-99% of its heap stranded — the latch fix closed a near-total
# leak, not just a rare use-after-free), and a startup-regime arm reports the
# short-process rate the one shipped sighting came from. The cap is not zero
# because the race is still open; it is three orders of magnitude below the
# pre-fix rate, so a reopened race reds it and the rare event does not. ~35 s.
chunk-list-drift: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/chunk_list_drift.cr -o $(BIN)/chunk_list_drift --error-trace
	CHUNK_DRIFT_ROUNDS=1200 $(BIN)/chunk_list_drift

# Do the process heap's counters lose updates? `note_alloc_bytes` and its
# siblings use plain `set(get + 1)` unless `heap_counters_atomic` is set, and
# ROADMAP has carried the counter-argument since v0.20.0: `live_objects` read
# one below the walk in 3 runs of 40, in a program whose only threads were main
# and the monitor. That flake was fixed as a *scope* correction — the invariant
# is stated only of a heap that keeps its counter — which made the checker
# honest and retired the measurement. `GCRY_INVARIANT_COUNTER_LOSS=1` states it
# anyway and counts. Three arms: atomic and plain must both come out at zero
# (measured, 4.6 M forced comparisons across three shapes — the loss does not
# reproduce on this tree, so the plain default stays and the atomic path stays
# an escape), and `--inject` drops one increment through
# `debug_drift_live_objects` and must be caught, because without it two zeros
# cannot be told from a comparison that never looks. ~35 s.
counter-loss: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/counter_loss.cr -o $(BIN)/counter_loss --error-trace
	COUNTER_LOSS_ROUNDS=120 $(BIN)/counter_loss
	COUNTER_LOSS_ROUNDS=120 $(BIN)/counter_loss --control
	COUNTER_LOSS_ROUNDS=120 $(BIN)/counter_loss --inject

# What a fault outside gcry's span actually *is*. The three readings there say
# what it is not — not a gcry allocation, and whether a swept object is
# excluded — and that was the whole of the 2026-09-19 churn sighting: an
# address, 1 of 24 children on a CI runner, nothing to compare with the next
# one. The kernel knows: `Platform.each_map_region` names every mapping,
# allocation-free, so the report names the one the address is in, with its
# permissions, its size and how far below its top it sits — which is how a
# region gcry could name as nothing was read as a stack on 2026-08-27. Three
# arms, and the numbers are checked rather than the words: an anonymous
# PROT_NONE mapping, a file-backed one that must be named by path, and an
# address in no mapping, which must be reported as wild rather than attributed
# to the nearest region. The red direction, which until 2026-09-20 existed
# only as a hand edit of `report_faulting_region`: the parent forks the same
# three faults under `GCRY_DISABLE_REGION_REPORT=1` and requires the mapping
# line to be absent. Dropping that knob reddens the gate. Linux only.
.PHONY: segv-region-report
segv-region-report: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/segv_region_report.cr -o $(BIN)/segv_region_report --error-trace
	$(BIN)/segv_region_report


# `GCRY_UNMAP_GUARD=1` keeps a released chunk mapped as PROT_NONE and records
# its identity, so a fault into it reads as "this is the memory gcry gave back"
# — base, size, release path, collection, first user word, blocks still
# allocated at release — instead of "some address". This faults into such a
# chunk on purpose and requires the report to name it. ~0.2 s, 0 failures in 8.
#
# What it does not cover, and the reason is worth keeping: the same question
# asked of an address *outside* the heap span. Releasing a chunk is what moves
# its address out of the span, and until 2026-09-13 the report asked the ledger
# only after an in-span test, so exactly those faults were reported as "never a
# gcry allocation, so a swept object is not the explanation". Both branches now
# ask one helper. A synthetic out-of-span release could not be built: size-class
# chunks are bracketed by live ones, a large object goes to the large cache
# rather than to the kernel (and the adaptive retain policy resets the budget
# each major), and a harness that remembers the address to poke it roots the
# object by doing so — a UInt64 in a live stack slot is a pointer to a
# conservative scan.
released-range-report: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/released_range_report.cr -o $(BIN)/released_range_report --error-trace
	$(BIN)/released_range_report

# Does a fault inside a chunk a flush refused to release say so? The refusal
# (2026-09-14) puts an occupied chunk back on the live list, so every other
# line of a later report describes an ordinary release and nothing says the
# chunk went through that window. Sixteen slots of ledger and one report line
# fix that, and this is their positive control: the real window has never
# opened on a developer host (0 chunks considered in 120 collections with more
# than one mutator alive), so `GCRY_REFUSE_EMPTY_RELEASE=<n>` reaches it
# without the race. Fails if the ledger misses the chunk or the report skips
# the line. ~2 s.
kept-release-report: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/kept_release_report.cr -o $(BIN)/kept_release_report --error-trace
	$(BIN)/kept_release_report

# Does a pool refill walk the chunk list, and how does that scale? The note this
# retires said "walks every chunk of the class per refill: O(chunks)". Measured:
# the walk happens once per *capacity version*, each sweep bumps that version,
# and the count is 2.0 rebuilds per collection — one per active class slot —
# whether the class holds 29 chunks or 598. The cost per allocation does grow
# linearly with the chunk count, which is the arithmetic of a constant rebuild
# rate, and it is 0.391% of what the sweep walks in the same collection (512
# blocks per chunk at 256 B). Fails if rebuilds per collection exceed one per
# active slot, i.e. if the index starts being invalidated mid-collection, which
# is the only way this becomes the per-refill walk. Until 2026-09-20 the
# only way it came out red was a hand edit of that floor. Three arms, ~13 s
# plus the disable arm.
pool-refill-cost: $(BIN)
	$(CRYSTAL) build --release -Dgc_none bench/pool_refill_cost.cr -o $(BIN)/pool_refill_cost --error-trace
	$(BIN)/pool_refill_cost
	$(BIN)/pool_refill_cost --churn
	GCRY_DISABLE_POOL_INDEX=1 $(BIN)/pool_refill_cost --disabled

# The wedge ROADMAP has carried without a reproducer: `chunk_containing` holds
# `@index_lock` for the length of a lookup, a suspend signal arrives wherever it
# likes, and the collector's index surgery takes the same lock — so a mutator
# frozen holding it would leave the collector spinning with the world stopped,
# and nothing is resumed until that phase ends. Measured instead of argued: of
# 1 155 index-lock sections alone and 586 with a second mutator holding the
# lock, **none runs with the world stopped** on this tree, and a 1.5 s hold
# finishes — so the cost today is a wait bounded by the holder, not a deadlock.
# The harness fails if a section ever runs inside the stop without the watchdog
# naming it, which is the shape that would make this a silent hang. ~15 s.
index-lock-wedge: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/index_lock_wedge.cr -o $(BIN)/index_lock_wedge --error-trace
	$(BIN)/index_lock_wedge
	$(BIN)/index_lock_wedge --control

# What the parked-fiber lag reads, for the largest open pause item: 8.4 ms of a
# 9.2 ms p50 EC4 pause is `roots_fibers_ns`, because under multi-mutator STW
# every parked fiber is scanned from 256 KiB below its saved `stack_top`. The
# proposed fix is to scan a *fully parked* fiber from its own SP, which is a
# root-scan change — being wrong there is a use-after-free days later — so this
# measures the payoff before anyone touches it. Two arms, 256 fibers on a
# Parallel context: parked on stacks never faulted below the parked frames, the
# pagemap low-water probe removes the **entire** window (67 858 KiB of a 67 072
# KiB nominal window per collection) and the proposal would save nothing; with
# `--deep`, each fiber touching 512 KiB of stack and then parking shallow, the
# probe removes 2 470 KiB and **64 602 KiB per collection is read, 246.6 KiB per
# parked fiber**. The second arm is "pooled stacks lose the skip" with no pool
# and no uptime. Counting, not timing, so it holds under load. Research only;
# not a gate.
fiber-lag-cost: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dpreview_mt -Dexecution_context \
		bench/fiber_lag_cost.cr -o $(BIN)/fiber_lag_cost --error-trace
	$(BIN)/fiber_lag_cost

# The window that released a chunk with a live block in it (CI `34787711949`,
# 2026-09-14): the sweep queues an empty chunk, its index entry survives until
# the post-STW flush, and the allocator resolves pooled chunk addresses through
# that index — so a mutator can take a block out of a chunk already queued for
# unmapping. The flush now refuses such a chunk and keeps it mapped.
#
# Walked on purpose, on a library heap, through `Heap#post_stw_hook`: one
# allocation after `start_world` builds the pool from the still-intact list,
# the after-world sweep queues the idle chunks behind it, and exhausting the
# taken chunk before the flush pops a queued one through the index. Until
# 2026-09-21 the recipe tried to reach that with thread churn (0 of 48 here)
# and ran both arms under `-`. Both arms now require the window to be hit:
# shipped must refuse once and keep the block; `--broken` restores the pre-fix
# release and must lose the block's chunk. ~2 s.
occupied-release: $(BIN)
	$(CRYSTAL) build bench/occupied_release.cr -o $(BIN)/occupied_release --error-trace
	$(BIN)/occupied_release
	$(BIN)/occupied_release --broken

# The control the holders search never had: three planted words in live
# marked objects, plus a masked address the walk must not invent. Until
# 2026-09-20 the only way it came out red was a hand edit of
# `count_heap_holders`. `GCRY_DISABLE_HOLDERS_FIND=1` skips that walk, so
# the planted holders come back empty. Dropping the knob reddens the gate.
holders-find: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/holders_find.cr -o $(BIN)/holders_find --error-trace
	$(BIN)/holders_find
	GCRY_DISABLE_HOLDERS_FIND=1 $(BIN)/holders_find --disabled

darwin-page-query: $(BIN)
	$(CRYSTAL) build bench/darwin_page_query.cr -o $(BIN)/darwin_page_query --error-trace
	$(BIN)/darwin_page_query $${PAGE_QUERY_PRESSURE:+--pressure=$$PAGE_QUERY_PRESSURE}

# Does `GC.init`'s eager static-root resolve reach a `once`-guarded
# initialiser? Darwin was excluded from the eager resolve because doing it
# crashed before `main` on the macOS runner (CI 33900305015) and there was no
# Darwin host to attribute it on. The mechanism is named now: two class
# variables in `platform/darwin_roots.cr` had initialisers the compiler wraps
# in `__crystal_once`, and `__crystal_once` reaches `Fiber.current` while
# `Fiber.init` has not run.
#
# Two gates, because the two halves fail differently. The IR walk is the one
# that survives a reviewer rewriting `4294967295_u32` back to `UInt32::MAX`:
# it reads the emitted call graph rather than trusting that the binary starts.
# Its red arm is `-Dgcry_static_root_once`, which puts both initialisers back
# and must both reintroduce the edge and SEGV. The runtime gate measures the
# *effect* — resolves=1 before any collection — and its red arm is
# `GCRY_STATIC_ROOT_LAZY=1`, which reads resolves=0 there and resolves the
# cache inside the first stopped world instead.
darwin-static-root-init: $(BIN)
	$(CRYSTAL) build bench/darwin_static_root_once.cr -o $(BIN)/darwin_static_root_once --error-trace
	CRYSTAL="$(CRYSTAL)" $(BIN)/darwin_static_root_once
	$(CRYSTAL) build -Dgc_none bench/darwin_static_root_init.cr -o $(BIN)/darwin_static_root_init --error-trace
	$(BIN)/darwin_static_root_init
	GCRY_STATIC_ROOT_LAZY=1 $(BIN)/darwin_static_root_init --lazy

# Which Mach-O sections are the static roots, and does the rule that picks
# them lose a root class? Linux derives its set (writable `PT_LOAD` minus
# `PT_GNU_RELRO`); Darwin used a name allow-list until 2026-09-04, so a linker
# change dropped a root class silently. The probe is what established that the
# obvious parity rule — "`initprot` carries VM_PROT_WRITE" — is wrong:
# `__DATA_CONST` reports writable in the load command and is `r--` at runtime
# because its segment carries `SG_READ_ONLY`.
#
# Two links, because they select different sets: the default one has a
# `__DATA_CONST`, and `-no_data_const` moves `__const`/`__got` into a plainly
# writable `__DATA` where the derived rule takes them and the allow-list did
# not. Each build runs its own `--control` child under
# `GCRY_STATIC_BSS_CAP=1`, which drops `__common` on purpose; the detector
# must find heap-owned words there, or "nothing was lost" is a statement about
# the detector rather than about the rule.
darwin-static-root-sections: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/darwin_static_root_sections.cr -o $(BIN)/darwin_static_root_sections --error-trace
	$(BIN)/darwin_static_root_sections
	$(CRYSTAL) build -Dgc_none --link-flags=-Wl,-no_data_const bench/darwin_static_root_sections.cr -o $(BIN)/darwin_static_root_sections_ndc --error-trace
	$(BIN)/darwin_static_root_sections_ndc

# What is the Darwin free-page walk's bitmap stand-down standing down from?
#
# It was written on Linux from a reading of the code — "the mask is built from
# `BlockHeader.free?`, that flag is stale on a bitmap chunk, so the walk would
# reclaim a live object" — and never run on Darwin. Running it says the
# staleness is real and one-directional: `set_used` clears FREE and
# `bitmap_free_block` never sets it, so the mask over-reports liveness and can
# only fail to release. The `next` is a cost decision.
#
# Five arms, and the one that decides it is a counter rather than a checksum.
# `--selfcheck` is why: `Platform.release_physical_pages` issues `MADV_FREE`
# on Darwin, which leaves a still-referenced page intact, so a mis-released
# page is latent here and no "graph intact" arm can see it.
# `page_release_live_blocks` is binary and immediate; that is the gate.
darwin-bitmap-page-release: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/darwin_bitmap_page_release.cr -o $(BIN)/darwin_bitmap_page_release --error-trace
	GCRY_BITMAP_ALLOC=1 GCRY_PAGE_DONTNEED=1 $(BIN)/darwin_bitmap_page_release
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers bench/darwin_bitmap_page_release.cr -o $(BIN)/darwin_bitmap_page_release_hdr --error-trace
	GCRY_BITMAP_ALLOC=0 GCRY_PAGE_DONTNEED=1 $(BIN)/darwin_bitmap_page_release_hdr --headers
	GCRY_BITMAP_ALLOC=1 GCRY_PAGE_DONTNEED=1 GCRY_PAGE_RELEASE_BITMAP_WALK=1 $(BIN)/darwin_bitmap_page_release --walk
	GCRY_BITMAP_ALLOC=1 GCRY_PAGE_DONTNEED=1 GCRY_PAGE_RELEASE_BITMAP_WALK=1 GCRY_PAGE_RELEASE_UNCHECKED=1 $(BIN)/darwin_bitmap_page_release --unchecked
	GCRY_BITMAP_ALLOC=1 GCRY_PAGE_DONTNEED=1 $(BIN)/darwin_bitmap_page_release --selfcheck

perf-baseline:
	python3 bench/perf_compare.py --selftest

# The fiber-creation use-after-free (2026-08-15, three CI platforms) as a gate.
# The parent forks the churn with `GCRY_POISON_HOLDERS=1` — poison, tag and
# crash report, so a catch names the block and what still points at it rather
# than one hex number — and `GCRY_THREAD_CENSUS=1`, the 2026-08-17 settings.
# RUNS (6) shipped children must survive and each must have walked a dying
# fiber's stack; then the same churn with the dying-stack root *and* the
# suspended-thread register scan off must crash within max(4·RUNS, 8) tries.
# Both, because on this codegen either root alone covers the word: the fix's
# own disable went 0 of 24 here on 2026-09-21 where it was 10 of 24 on
# 2026-08-17, and with both off it is 7 of 12. `make dead-stack-root` gates
# the dying-stack root itself, deterministically; this gates the defect. ~15 s.
nested-spawn-uaf: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/nested_spawn_uaf.cr -o $(BIN)/nested_spawn_uaf --error-trace
	$(BIN)/nested_spawn_uaf

ec-queue-audit: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/ec_queue_audit.cr -o $(BIN)/ec_queue_audit --error-trace
	GCRY_EC_QUEUE_AUDIT=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 $(BIN)/ec_queue_audit
	GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 $(BIN)/ec_queue_audit --control
	@echo "--- --stall: positive control for the bounded wait. The FAIL below is the expected output; the gate is that it appears ---"
	@out=$$(GCRY_ECQ_WAIT_SECONDS=3 $(BIN)/ec_queue_audit --stall 2>&1 || true); \
	echo "$$out" | tail -4; \
	echo "$$out" | grep -q "this is the hang" || { echo "FAIL: the stall arm did not report the hang"; exit 1; }; \
	echo "ok — a wait that cannot finish fails with the state it was stuck in"

stw-startup-hang: $(BIN)
	$(CRYSTAL) build -Dgc_none -Dpreview_mt -Dexecution_context \
	  bench/stw_startup_hang.cr -o $(BIN)/stw_startup_hang --error-trace
	$(BIN)/stw_startup_hang --spin --children=$${STW_HANG_CHILDREN:-150} \
	  --timeout=$${STW_HANG_TIMEOUT:-6}

mutate:
	./bench/mutations/run.sh

# Both soak targets carry the RSS ceiling's red direction: ten seconds of the
# same workload retaining 2 MB/s by wall time (+20 MB against +4 MB; Darwin's
# RSS follows the heap at ~0.65× and its timer delivered ~60 of 100 ticks, which
# is why the rate is by time and not 1 MB/s) must fail, and must fail *on the
# ceiling* — the telemetry has to carry `RSS grew` — so a crash or a refused
# flag cannot pass for the arm. ~11 s.
soak: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/soak.cr -o $(BIN)/soak
	! $(BIN)/soak --duration=10 --rss-limit-kb=$${SOAK_RSS_LIMIT_KB:-4096} --leak-kb-per-s=2048 --telemetry=/tmp/gcry-soak-leak.log
	grep -q "# result: FAIL: RSS grew" /tmp/gcry-soak-leak.log
	$(BIN)/soak --duration=$${SOAK_DURATION:-86400} --telemetry=/tmp/gcry-soak.log

soak-smoke: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/soak.cr -o $(BIN)/soak
	# Same ceiling as the 24h soak, and that is the point: the ~0.5–1 MiB this
	# re-faults after drain is warm-up plus 256 KiB chunk granularity, not a
	# signal that scales with duration (4 h measured the same ~960 kB). A smoke
	# that passes under a looser bound than the real gate is not a smoke test.
	$(BIN)/soak --duration=10 --rss-limit-kb=$${SOAK_RSS_LIMIT_KB:-4096} --telemetry=/tmp/gcry-soak-smoke.log
	! $(BIN)/soak --duration=10 --rss-limit-kb=$${SOAK_RSS_LIMIT_KB:-4096} --leak-kb-per-s=2048 --telemetry=/tmp/gcry-soak-leak.log
	grep -q "# result: FAIL: RSS grew" /tmp/gcry-soak-leak.log

format:
	$(CRYSTAL) tool format

format-check:
	$(CRYSTAL) tool format --check

lint:
	shards install --development
	cd lib/ameba && shards build
	cp -f lib/ameba/bin/ameba bin/ameba
	bin/ameba

coverage:
	CRYSTAL_CACHE_DIR=/tmp/crystal-cache ./ci/coverage.sh all

coverage-kcov:
	./ci/coverage.sh kcov

coverage-unreachable:
	./ci/coverage.sh unreachable

coverage-macro:
	./ci/coverage.sh macro

# Real ASan: Crystal IR through clang's sanitizer pass (ci/asan_check.py).
# Uses clang-19 when present (CI), else `clang` on PATH; CLANG=... overrides.
asan: $(BIN)
	$(CRYSTAL) build spec/all_specs.cr -o $(BIN)/all_specs_asan
	$(BIN)/all_specs_asan
	python3 ci/asan_check.py --crystal $(CRYSTAL)

asan-hello: $(BIN)
	python3 ci/asan_check.py --crystal $(CRYSTAL) --source samples/hello.cr

VALGRIND_FLAGS := --leak-check=full --suppressions=ci/valgrind-suppressions.txt --show-leak-kinds=definite --errors-for-leak-kinds=definite --undef-value-errors=no --error-exitcode=0

valgrind-samples: $(BIN)
	$(CRYSTAL) build -Dgc_none samples/hello.cr -o $(BIN)/hello_valgrind
	./ci/valgrind-wrap.sh $(BIN)/hello_valgrind
	$(CRYSTAL) build -Dgc_none samples/min.cr -o $(BIN)/min_valgrind
	./ci/valgrind-wrap.sh $(BIN)/min_valgrind
	$(CRYSTAL) build -Dgc_none samples/alloc.cr -o $(BIN)/alloc_valgrind
	./ci/valgrind-wrap.sh $(BIN)/alloc_valgrind 500
	$(CRYSTAL) build -Dgc_none samples/stress.cr -o $(BIN)/stress_valgrind
	./ci/valgrind-wrap.sh $(BIN)/stress_valgrind 300

samples: $(BIN)
	$(CRYSTAL) build -Dgc_none samples/hello.cr -o $(BIN)/hello
	$(CRYSTAL) build -Dgc_none samples/min.cr -o $(BIN)/min
	$(CRYSTAL) build -Dgc_none samples/alloc.cr -o $(BIN)/alloc
	$(CRYSTAL) build -Dgc_none samples/stress.cr -o $(BIN)/stress
	$(CRYSTAL) build -Dgc_none samples/json_churn.cr -o $(BIN)/json_churn
	$(CRYSTAL) build -Dgc_none samples/stw_sp_clamp.cr -o $(BIN)/stw_sp_clamp
	$(CRYSTAL) build -Dgc_none samples/sound_profile.cr -o $(BIN)/sound_profile

# Root-completeness profile smoke: the reported heap state must match GCRY_SOUND,
# and an explicit knob must still override the profile. Catches a new root
# heuristic that was never added to apply_sound_profile.
sound-profile-smoke: $(BIN)
	$(CRYSTAL) build -Dgc_none samples/sound_profile.cr -o $(BIN)/sound_profile
	$(BIN)/sound_profile
	GCRY_SOUND=1 $(BIN)/sound_profile
	GCRY_SOUND=1 GCRY_SCRUB_FIBERS=1 $(BIN)/sound_profile
	$(CRYSTAL) build -Dgc_none -Dgcry_block_headers samples/sound_profile.cr -o $(BIN)/sound_profile_hdr
	GCRY_SOUND=1 GCRY_NURSERY=262144 $(BIN)/sound_profile_hdr

# Short A/B thr gate for CI (needs wrk). MIN_PCT=70 by default.
bench-perf-smoke:
	BENCH_RUNS=$(BENCH_RUNS) PORT=$(PORT) ./bench/perf_smoke.sh

# Boehm vs gcry tuned vs gcry sound vs gcry sound+conservative, one host, one
# run. Publishes the number a correctness claim can cite — docs/SOUND-DEFAULTS.md.
bench-sound-profile:
	BENCH_RUNS=$(BENCH_RUNS) PORT=$(PORT) ./bench/sound_profile_ab.sh

# Secondary GC suite (vendored crystal-metric, process-fresh). Informational.
# FILTER=core|stress|gc|all|A,B TRIALS=1 make bench-crystal-metric
bench-crystal-metric:
	bash bench/run_crystal_metric_ab.sh

# A/B previous tag vs current tree; prints docs/PERF.md History rows.
bench-kemal-record:
	@test -n "$(PREV)" || (echo "set PREV=vX.Y.Z" && exit 1)
	@test -n "$(LABEL)" || (echo "set LABEL=A.B.C" && exit 1)
	PREV=$(PREV) LABEL=$(LABEL) ./bench/record_kemal.sh

# Full benchmark suite via run_all.sh.
# Default: --release (PERF.md). DEBUG=1 → --debug --error-trace.
# SEGV symbols on release: CRYSTAL_FLAGS="--release --debug --error-trace"
bench-run-all:
	bash bench/run_all.sh all

# Kemal-only.
bench-run-kemal:
	bash bench/run_all.sh kemal

# acikturkiye-only.
bench-run-acik:
	bash bench/run_all.sh acik

# Debug build (no --release) for SEGV / GC bugs.
bench-run-kemal-debug:
	DEBUG=1 bash bench/run_all.sh kemal

# Release + DWARF (crash hunting without full debug mutator).
bench-run-kemal-symbols:
	CRYSTAL_FLAGS="--release --debug --error-trace" bash bench/run_all.sh kemal

clean:
	rm -rf $(BIN)
	rm -rf bench/kemal/lib bench/kemal/.shards bench/kemal/shard.lock
	rm -rf bench/crystal_metric/lib bench/crystal_metric/.shards bench/crystal_metric/shard.lock
