CRYSTAL ?= crystal
BIN := bin
KEMAL_DIR := bench/kemal
WRK ?= wrk
WRK_CONNECTIONS ?= 100
WRK_DURATION ?= 30
WRK_URL ?= http://127.0.0.1:3001/
PORT ?= 3001

.PHONY: all spec format format-check samples bench bench-kemal bench-kemal-boehm bench-kemal-wrk clean help

all: spec samples

help:
	@echo "Targets: spec format format-check samples bench bench-kemal bench-kemal-boehm bench-kemal-wrk clean"
	@echo "wrk knobs: WRK_CONNECTIONS=$(WRK_CONNECTIONS) WRK_DURATION=$(WRK_DURATION) WRK_URL=$(WRK_URL) PORT=$(PORT)"

$(BIN):
	mkdir -p $(BIN)

spec:
	$(CRYSTAL) spec --error-trace

format:
	$(CRYSTAL) tool format

format-check:
	$(CRYSTAL) tool format --check

samples: $(BIN)
	$(CRYSTAL) build -Dgc_none samples/hello.cr -o $(BIN)/hello
	$(CRYSTAL) build -Dgc_none samples/min.cr -o $(BIN)/min
	$(CRYSTAL) build -Dgc_none samples/alloc.cr -o $(BIN)/alloc
	$(CRYSTAL) build -Dgc_none samples/stress.cr -o $(BIN)/stress

bench: $(BIN)
	$(CRYSTAL) build bench/churn.cr -o $(BIN)/churn

# Realistic Kemal HTTP server under gcry (-Dgc_none).
bench-kemal: $(BIN)
	cd $(KEMAL_DIR) && shards install
	cd $(KEMAL_DIR) && $(CRYSTAL) build -Dgc_none --release src/server.cr -o ../../$(BIN)/kemal-gcry

# Same app on Crystal's default Boehm GC (for A/B).
bench-kemal-boehm: $(BIN)
	cd $(KEMAL_DIR) && shards install
	cd $(KEMAL_DIR) && $(CRYSTAL) build --release src/server.cr -o ../../$(BIN)/kemal-boehm

# Start kemal-gcry and run wrk against /. Override duration/connections via env.
bench-kemal-wrk: bench-kemal
	@command -v $(WRK) >/dev/null || (echo "wrk not found; install wrk" && exit 1)
	@PORT=$(PORT) $(BIN)/kemal-gcry & echo $$! > $(BIN)/kemal-gcry.pid; \
	trap 'kill $$(cat $(BIN)/kemal-gcry.pid) 2>/dev/null || true; rm -f $(BIN)/kemal-gcry.pid' EXIT INT TERM; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
	  curl -sf -o /dev/null $(WRK_URL) && break; \
	  sleep 0.3; \
	done; \
	$(WRK) -c $(WRK_CONNECTIONS) -d $(WRK_DURATION) $(WRK_URL)

clean:
	rm -rf $(BIN)
	rm -rf $(KEMAL_DIR)/lib $(KEMAL_DIR)/.shards $(KEMAL_DIR)/shard.lock
