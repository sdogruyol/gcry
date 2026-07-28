CRYSTAL ?= crystal
BIN := bin

.PHONY: all spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short format format-check lint invariants coverage coverage-kcov coverage-unreachable coverage-macro asan asan-spec valgrind valgrind-samples samples bench-run-all bench-run-kemal bench-run-kemal-debug bench-run-kemal-symbols bench-run-acik bench-perf-smoke bench-kemal-record clean help

all: spec samples

help:
	@echo "Targets: spec spec-process fuzz fuzz-short fuzz-replay property-test property-test-short format format-check lint samples"
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
	PORT=$(PORT) ./bench/perf_smoke.sh

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