CRYSTAL ?= crystal
BIN := bin
KEMAL_DIR := bench/kemal
WRK ?= wrk
WRK_CONNECTIONS ?= 100
WRK_DURATION ?= 30
WRK_BASE_URL ?= http://127.0.0.1:3001
WRK_PATHS ?= / /json
PORT ?= 3001

.PHONY: all spec spec-process fuzz fuzz-short format format-check samples bench bench-kemal bench-kemal-boehm bench-kemal-wrk bench-kemal-record bench-perf-smoke clean help

all: spec samples

help:
	@echo "Targets: spec spec-process fuzz fuzz-short format format-check samples bench bench-kemal bench-kemal-boehm bench-kemal-wrk bench-kemal-record bench-perf-smoke clean"
	@echo "wrk knobs: WRK_CONNECTIONS=$(WRK_CONNECTIONS) WRK_DURATION=$(WRK_DURATION) WRK_PATHS='$(WRK_PATHS)' PORT=$(PORT)"
	@echo "record: make bench-kemal-record PREV=v0.2.0 LABEL=0.3.0"

$(BIN):
	mkdir -p $(BIN)

spec:
	$(CRYSTAL) spec --error-trace

# Process GC facade tests (gcry is the process collector).
spec-process: $(BIN)
	$(CRYSTAL) spec -Dgc_none process_spec --error-trace

fuzz: $(BIN)
	$(CRYSTAL) build bench/fuzz.cr -o $(BIN)/fuzz
	$(BIN)/fuzz $${FUZZ_SECONDS:-30} $${FUZZ_SEED:-1}

fuzz-short: $(BIN)
	$(CRYSTAL) build bench/fuzz.cr -o $(BIN)/fuzz
	$(BIN)/fuzz 5 1

format:
	$(CRYSTAL) tool format

format-check:
	$(CRYSTAL) tool format --check

samples: $(BIN)
	$(CRYSTAL) build -Dgc_none samples/hello.cr -o $(BIN)/hello
	$(CRYSTAL) build -Dgc_none samples/min.cr -o $(BIN)/min
	$(CRYSTAL) build -Dgc_none samples/alloc.cr -o $(BIN)/alloc
	$(CRYSTAL) build -Dgc_none samples/stress.cr -o $(BIN)/stress
	$(CRYSTAL) build -Dgc_none samples/json_churn.cr -o $(BIN)/json_churn
	$(CRYSTAL) build -Dgc_none samples/stw_sp_clamp.cr -o $(BIN)/stw_sp_clamp

bench: $(BIN)
	$(CRYSTAL) build bench/churn.cr -o $(BIN)/churn

# Short A/B thr gate (needs wrk). MIN_PCT=70 by default.
bench-perf-smoke:
	PORT=$(PORT) ./bench/perf_smoke.sh

# Realistic Kemal HTTP server under gcry (-Dgc_none).
bench-kemal: $(BIN)
	cd $(KEMAL_DIR) && shards install
	cd $(KEMAL_DIR) && $(CRYSTAL) build -Dgc_none --release src/server.cr -o ../../$(BIN)/kemal-gcry

# Same app on Crystal's default Boehm GC (for A/B).
bench-kemal-boehm: $(BIN)
	cd $(KEMAL_DIR) && shards install
	cd $(KEMAL_DIR) && $(CRYSTAL) build --release src/server.cr -o ../../$(BIN)/kemal-boehm

# Start kemal-gcry and run wrk against / and /json (fresh process per path).
bench-kemal-wrk: bench-kemal
	@command -v $(WRK) >/dev/null || (echo "wrk not found; install wrk" && exit 1)
	@for path in $(WRK_PATHS); do \
	  echo "=== wrk $$path ==="; \
	  PORT=$(PORT) $(BIN)/kemal-gcry & echo $$! > $(BIN)/kemal-gcry.pid; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do \
	    curl -sf -o /dev/null $(WRK_BASE_URL)/ && break; \
	    sleep 0.3; \
	  done; \
	  $(WRK) -c $(WRK_CONNECTIONS) -d $(WRK_DURATION) $(WRK_BASE_URL)$$path; \
	  kill $$(cat $(BIN)/kemal-gcry.pid) 2>/dev/null || true; \
	  wait $$(cat $(BIN)/kemal-gcry.pid) 2>/dev/null || true; \
	  rm -f $(BIN)/kemal-gcry.pid; \
	  sleep 0.3; \
	done

# A/B previous tag vs current tree for / and /json; prints docs/PERF.md History rows.
# Example: make bench-kemal-record PREV=v0.2.0 LABEL=0.3.0
bench-kemal-record:
	@test -n "$(PREV)" || (echo "set PREV=vX.Y.Z" && exit 1)
	@test -n "$(LABEL)" || (echo "set LABEL=A.B.C" && exit 1)
	PREV=$(PREV) LABEL=$(LABEL) PORT=$(PORT) WRK_CONNECTIONS=$(WRK_CONNECTIONS) WRK_DURATION=$(WRK_DURATION) WRK_BASE_URL=$(WRK_BASE_URL) WRK_PATHS="$(WRK_PATHS)" ./bench/record_kemal.sh

clean:
	rm -rf $(BIN)
	rm -rf $(KEMAL_DIR)/lib $(KEMAL_DIR)/.shards $(KEMAL_DIR)/shard.lock
