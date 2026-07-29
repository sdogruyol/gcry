CRYSTAL ?= crystal
BIN := bin

.PHONY: all spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short layout-property-test layout-property-test-short mt-property-test mt-property-test-short stw-mt-property-test stw-mt-property-test-short pattern-fuzz pattern-fuzz-short thread-storm thread-storm-short oom-test oom-test-short fork-test finalizer-complex nursery-headers parallel-mark-process microbench pause-budget rss-leak compiler-gc-contract kemal-e2e trace-smoke mutate soak soak-smoke format format-check lint invariants coverage coverage-kcov coverage-unreachable coverage-macro asan asan-spec valgrind valgrind-samples samples bench-run-all bench-run-kemal bench-run-kemal-debug bench-run-kemal-symbols bench-run-acik bench-perf-smoke bench-kemal-record clean help

all: spec samples

help:
	@echo "Targets: spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short layout-property-test layout-property-test-short mt-property-test mt-property-test-short stw-mt-property-test stw-mt-property-test-short pattern-fuzz pattern-fuzz-short thread-storm thread-storm-short oom-test oom-test-short fork-test finalizer-complex nursery-headers parallel-mark-process microbench pause-budget rss-leak compiler-gc-contract kemal-e2e trace-smoke mutate soak soak-smoke format format-check lint samples"
	@echo "Bench: bench-run-all bench-run-kemal bench-run-kemal-debug bench-run-kemal-symbols bench-run-acik bench-perf-smoke bench-kemal-record"
	@echo "knobs: WRK_CONNECTIONS WRK_DURATION TRIALS COUNT GC GCRY_FLAGS CRYSTAL_FLAGS DEBUG"
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
	$(BIN)/stw_mt_property_test --tlab --seed=1 --iterations=50 --workers=2

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

rss-leak: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/rss_leak.cr -o $(BIN)/rss_leak
	$(BIN)/rss_leak --cycles=$${RSS_CYCLES:-20} --objects=$${RSS_OBJECTS:-5000}

compiler-gc-contract: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/compiler_gc_contract.cr -o $(BIN)/compiler_gc_contract
	$(BIN)/compiler_gc_contract
	$(CRYSTAL) tool hierarchy src/gcry.cr >/dev/null
	$(CRYSTAL) tool unreachable bench/compiler_gc_contract.cr -Dgc_none >/dev/null

kemal-e2e:
	KEMAL_E2E_DURATION=$${KEMAL_E2E_DURATION:-60} ./bench/kemal_e2e.sh

trace-smoke: $(BIN)
	$(CRYSTAL) build bench/trace_smoke.cr -o $(BIN)/trace_smoke
	$(BIN)/trace_smoke

mutate:
	./bench/mutations/run.sh

soak: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/soak.cr -o $(BIN)/soak
	$(BIN)/soak --duration=$${SOAK_DURATION:-86400} --telemetry=/tmp/gcry-soak.log

soak-smoke: $(BIN)
	$(CRYSTAL) build -Dgc_none bench/soak.cr -o $(BIN)/soak
	$(BIN)/soak --duration=10 --telemetry=/tmp/gcry-soak-smoke.log

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

# Short A/B thr gate for CI (needs wrk). MIN_PCT=70 by default.
bench-perf-smoke:
	BENCH_RUNS=$(BENCH_RUNS) PORT=$(PORT) ./bench/perf_smoke.sh

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