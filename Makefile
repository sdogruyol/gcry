CRYSTAL ?= crystal
BIN := bin

.PHONY: all spec format format-check samples bench clean help

all: spec samples

help:
	@echo "Targets: spec format format-check samples bench clean"

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

clean:
	rm -rf $(BIN)
