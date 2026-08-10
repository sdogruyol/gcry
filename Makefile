CRYSTAL ?= crystal
BIN := bin

.PHONY: all spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short layout-property-test layout-property-test-short mt-property-test mt-property-test-short stw-mt-property-test stw-mt-property-test-short pattern-fuzz pattern-fuzz-short scrub-margin scrub-midswap stw-startup-hang stw-watchdog thread-storm thread-storm-short oom-test oom-test-short fork-test finalizer-complex nursery-headers parallel-mark-process microbench pause-budget stw-lag-pause rss-leak compiler-gc-contract kemal-e2e soft-soak-ec4 soft-soak-ec4-smoke stackmap-smoke trace-smoke sound-profile-smoke mutate soak soak-smoke format format-check lint invariants coverage coverage-kcov coverage-unreachable coverage-macro asan asan-spec valgrind valgrind-samples samples bench-run-all bench-run-kemal bench-run-kemal-debug bench-run-kemal-symbols bench-run-acik bench-perf-smoke bench-sound-profile bench-crystal-metric bench-kemal-record clean help

all: spec samples

help:
	@echo "Targets: spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short layout-property-test layout-property-test-short mt-property-test mt-property-test-short stw-mt-property-test stw-mt-property-test-short pattern-fuzz pattern-fuzz-short thread-storm thread-storm-short oom-test oom-test-short fork-test finalizer-complex nursery-headers parallel-mark-process microbench pause-budget stw-lag-pause rss-leak compiler-gc-contract kemal-e2e soft-soak-ec4 soft-soak-ec4-smoke stackmap-smoke trace-smoke sound-profile-smoke mutate scrub-margin scrub-midswap stw-startup-hang stw-watchdog soak soak-smoke format format-check lint samples"
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
	# Looser RSS ceil than the 24h soak: 10s GHA smokes re-fault ~0.5–1 MiB
	# after drain (seen 6968→7720 kB, ~11%) and are not a durable leak signal.
	$(BIN)/soak --duration=10 --rss-limit=$${SOAK_SMOKE_RSS_LIMIT:-30} --telemetry=/tmp/gcry-soak-smoke.log

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