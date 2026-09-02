CRYSTAL ?= crystal
BIN := bin
# Where `thread-uaf-sample` leaves the runs that said something.
SAMPLE_DIR := bench/log/ci-samples

.PHONY: all spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short layout-property-test layout-property-test-short mt-property-test mt-property-test-short stw-mt-property-test stw-mt-property-test-short pattern-fuzz pattern-fuzz-short scrub-margin scrub-midswap stw-startup-hang stw-watchdog stw-monitor-gate greg-roots scheduler-roots ivar-layout-roots ec-queue-audit nested-spawn-uaf mark-audit thread-block-audit thread-birth-root heap-counters thread-uaf-sample poison-holders perf-baseline darwin-page-query poison-freed large-freelist-madvise segv-report thread-storm thread-storm-short oom-test oom-test-short oom-no-hang fork-test finalizer-complex nursery-headers parallel-mark-process microbench pause-budget stw-lag-pause rss-leak compiler-gc-contract kemal-e2e soft-soak-ec4 soft-soak-ec4-smoke stackmap-smoke trace-smoke sound-profile-smoke mutate soak soak-smoke format format-check lint invariants coverage coverage-kcov coverage-unreachable coverage-macro asan asan-spec valgrind valgrind-samples samples bench-run-all bench-run-kemal bench-run-kemal-debug bench-run-kemal-symbols bench-run-acik bench-perf-smoke bench-sound-profile bench-crystal-metric bench-kemal-record clean help

all: spec samples

help:
	@echo "Targets: spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short layout-property-test layout-property-test-short mt-property-test mt-property-test-short stw-mt-property-test stw-mt-property-test-short pattern-fuzz pattern-fuzz-short thread-storm thread-storm-short oom-test oom-test-short fork-test finalizer-complex nursery-headers parallel-mark-process microbench pause-budget stw-lag-pause rss-leak compiler-gc-contract kemal-e2e soft-soak-ec4 soft-soak-ec4-smoke stackmap-smoke trace-smoke sound-profile-smoke mutate scrub-margin scrub-midswap stw-startup-hang stw-watchdog stw-monitor-gate greg-roots scheduler-roots ivar-layout-roots ec-queue-audit mark-audit thread-block-audit thread-birth-root heap-counters thread-uaf-sample poison-holders perf-baseline darwin-page-query poison-freed large-freelist-madvise segv-report soak soak-smoke format format-check lint samples"
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

stw-mt-property-test: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_mt_property_test.cr -o $(BIN)/stw_mt_property_test
	$(BIN)/stw_mt_property_test --seed=$${STW_MT_SEED:-1} --iterations=$${STW_MT_ITERATIONS:-200} --workers=$${STW_MT_WORKERS:-2,4} $${STW_MT_TLAB:+--tlab}

stw-mt-property-test-short: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/stw_mt_property_test.cr -o $(BIN)/stw_mt_property_test
	$(BIN)/stw_mt_property_test --seed=1 --iterations=50 --workers=2,4
	$(BIN)/stw_mt_property_test --tlab --seed=1 --iterations=50 --workers=2,4
	$(BIN)/stw_mt_property_test --tlab --nursery --seed=1 --iterations=50 --workers=2,4

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

fork-test: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/fork_reinit.cr -o $(BIN)/fork_reinit
	$(BIN)/fork_reinit

finalizer-complex: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/finalizer_complex.cr -o $(BIN)/finalizer_complex
	$(BIN)/finalizer_complex

nursery-headers: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/nursery_headers.cr -o $(BIN)/nursery_headers
	$(BIN)/nursery_headers

parallel-mark-process: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/parallel_mark_process.cr -o $(BIN)/parallel_mark_process
	$(BIN)/parallel_mark_process

microbench: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/micro/run_all.cr -o $(BIN)/microbench
	$(BIN)/microbench

pause-budget: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/pause_budget.cr -o $(BIN)/pause_budget
	$(BIN)/pause_budget --live-mb=$${LIVE_MB:-20}

# STW root-scan lag pause trap: the whole pause cost of GCRY_SOUND=1.
# Runs under both env shapes — the boot-lag assertion inverts with GCRY_SOUND.
#
# Carries CI's ratio bound (--max-ratio=4), not the program's loose 30× default:
# a local `make stw-lag-pause` that passes where CI fails is not a gate. The
# relaxed --max-ratio-nolw applies only when pagemap is unreadable and the
# low-water skip cannot run — see ci.yml and bench/stw_lag_pause.cr.
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

rss-leak: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/rss_leak.cr -o $(BIN)/rss_leak
	$(BIN)/rss_leak --warmup=$${RSS_WARMUP:-15} --cycles=$${RSS_CYCLES:-20} --objects=$${RSS_OBJECTS:-5000}

compiler-gc-contract: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/compiler_gc_contract.cr -o $(BIN)/compiler_gc_contract
	$(BIN)/compiler_gc_contract
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

trace-smoke: $(BIN)
	$(CRYSTAL) build bench/trace_smoke.cr -o $(BIN)/trace_smoke
	$(BIN)/trace_smoke

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

# The 2026-08-10 soak died in `quick_dequeue?` on a run-queue slot whose pointer
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

poison-freed: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/poison_freed.cr -o $(BIN)/poison_freed --error-trace
	GCRY_POISON_FREED=1 $(BIN)/poison_freed
	$(BIN)/poison_freed --control

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
heap-counters: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/heap_counters.cr -o $(BIN)/heap_counters --error-trace
	$(BIN)/heap_counters
	GCRY_HEAP_COUNTERS_ATOMIC=0 $(BIN)/heap_counters --plain

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
	@rm -f $(BIN)/darwin_typecheck_arm64.o $(BIN)/darwin_typecheck_x86.o
	@echo "ok — the Darwin build type-checks on both targets"

# Every knob the source reads has a row in the env reference. The reference had
# drifted by 33 before this existed, which is what a reference does: going stale
# breaks nothing, so nothing says so.
knob-doc-check:
	@ci/knob-doc-check.sh

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
live-graph-audit: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/live_graph_audit.cr -o $(BIN)/live_graph_audit --error-trace
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
page-release-corruption: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/page_release_corruption.cr -o $(BIN)/page_release_corruption --error-trace
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
	$(BIN)/dormant_flush_race

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
	$(BIN)/large_cache_race

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
	$(BIN)/find_block_race

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

thread-birth-root: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_birth_root.cr -o $(BIN)/thread_birth_root --error-trace
	$(BIN)/thread_birth_root
	GCRY_THREAD_BIRTH_NOROOT=1 $(BIN)/thread_birth_root --noroot
	GCRY_THREAD_BIRTH_ROOT=0 $(BIN)/thread_birth_root --control
	$(BIN)/thread_birth_root --burst
	GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED=1 $(BIN)/thread_birth_root --burst-unrooted

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
# **Not a gate.** It exits 0 whether or not the defect fires, because an open
# defect must not turn every pull request red — and a step that is expected to
# fail teaches everyone to ignore it. What it produces is evidence: the logs of
# the runs that said something, and nothing from the ones that did not.
thread-uaf-sample: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/ec_queue_audit.cr -o $(BIN)/ec_queue_audit --error-trace
	@mkdir -p $(SAMPLE_DIR)
	@runs=$${THREAD_UAF_RUNS:-10}; hits=0; pre=0; crashes=0; \
	harness=$${THREAD_UAF_BIN:-$(BIN)/ec_queue_audit}; \
	: $${THREAD_UAF_CONTROL_ARGS:=--control}; \
	for i in $$(seq 1 $$runs); do \
	  GCRY_EC_QUEUE_AUDIT=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 \
	    $$harness $$THREAD_UAF_ARGS > $(SAMPLE_DIR)/run-$$i-hold.log 2>&1 || crashes=$$((crashes+1)); \
	  GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 \
	    $$harness $$THREAD_UAF_ARGS $$THREAD_UAF_CONTROL_ARGS > $(SAMPLE_DIR)/run-$$i-control.log 2>&1 || crashes=$$((crashes+1)); \
	  for f in $(SAMPLE_DIR)/run-$$i-hold.log $(SAMPLE_DIR)/run-$$i-control.log; do \
	    d=$$(grep -c "is unmarked and about to be swept" $$f || true); \
	    p=$$(grep -c "precondition:" $$f || true); \
	    hits=$$((hits+d)); pre=$$((pre+p)); \
	    if [ "$$d" = "0" ] && [ "$$p" = "0" ]; then rm -f $$f; fi; \
	  done; \
	done; \
	echo "thread-uaf-sample: $$runs runs, $$crashes crashed, $$hits dying-Thread report(s), $$pre precondition sighting(s) in $(SAMPLE_DIR)"; \
	grep -h "dying-type audit\|threads at that moment\|held at\|address-space audit" $(SAMPLE_DIR)/*.log 2>/dev/null || true

thread-block-audit: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/thread_block_audit.cr -o $(BIN)/thread_block_audit --error-trace
	$(BIN)/thread_block_audit
	$(BIN)/thread_block_audit --control

poison-holders: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/poison_holders.cr -o $(BIN)/poison_holders --error-trace
	$(BIN)/poison_holders
	$(BIN)/poison_holders --control

darwin-page-query: $(BIN)
	$(CRYSTAL) build bench/darwin_page_query.cr -o $(BIN)/darwin_page_query --error-trace
	$(BIN)/darwin_page_query $${PAGE_QUERY_PRESSURE:+--pressure=$$PAGE_QUERY_PRESSURE}

perf-baseline:
	python3 bench/perf_compare.py --selftest

# The two diagnostics travel with this gate because it is one that dies: on
# 2026-08-15 it took SIGSEGV twice on aarch64 inside `Parallel::Scheduler` →
# `swapcontext`, and left `Invalid memory access at 0xff851bc00008` and nothing
# else — one hex number, the exact problem `GCRY_SEGV_REPORT` was written to fix
# eight commits earlier. A gate that plants corruption on purpose is the last
# place a crash should be allowed to stay anonymous. Measured: both arms pass
# with them on, five runs of each, and the poison run says more.
# `GCRY_POISON_HOLDERS` and not `GCRY_POISON_FREED`, and the difference is the
# whole point: it implies the poison *and* the address tag *and* the crash
# report, at the same runtime cost — the tag is written by the same memset that
# was already happening. The plain poison names no block, and CI proved that
# expensive on 2026-08-16: this gate caught the open use-after-free and the
# report could only say "the poison is untagged, so it names no block". With the
# tag, the same catch names the block, its size, whether the sweep or an explicit
# free released it, and what still points at it. The local repro is quiet, so CI
# is currently the only place this defect is observed — it should not waste a
# sighting.
#
# Not a gate: it fails most runs on purpose, and that is the finding. See the
# file header for the rates and the Boehm control.
nested-spawn-uaf: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/nested_spawn_uaf.cr -o $(BIN)/nested_spawn_uaf --error-trace
	GCRY_POISON_HOLDERS=1 $(BIN)/nested_spawn_uaf

ec-queue-audit: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/ec_queue_audit.cr -o $(BIN)/ec_queue_audit --error-trace
	GCRY_EC_QUEUE_AUDIT=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 $(BIN)/ec_queue_audit
	GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 $(BIN)/ec_queue_audit --control
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

soak: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/soak.cr -o $(BIN)/soak
	$(BIN)/soak --duration=$${SOAK_DURATION:-86400} --telemetry=/tmp/gcry-soak.log

soak-smoke: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/soak.cr -o $(BIN)/soak
	# Same ceiling as the 24h soak, and that is the point: the ~0.5–1 MiB this
	# re-faults after drain is warm-up plus 256 KiB chunk granularity, not a
	# signal that scales with duration (4 h measured the same ~960 kB). A smoke
	# that passes under a looser bound than the real gate is not a smoke test.
	$(BIN)/soak --duration=10 --rss-limit-kb=$${SOAK_RSS_LIMIT_KB:-4096} --telemetry=/tmp/gcry-soak-smoke.log

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

asan: $(BIN)
	$(CRYSTAL) build -Dasan spec/all_specs.cr -o $(BIN)/all_specs_asan
	$(BIN)/all_specs_asan

asan-hello: $(BIN)
	$(CRYSTAL) build -Dasan samples/hello.cr -o $(BIN)/hello_asan
	$(BIN)/hello_asan

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
	GCRY_SOUND=1 GCRY_NURSERY=262144 $(BIN)/sound_profile

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