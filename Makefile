# mlisp Makefile
# Targets: all build test test-unit test-bats clean install

SBCL      ?= sbcl
BATS      ?= bats
GROFF     ?= groff
PREFIX    ?= /usr/local
MLISP_BIN := bin/mlisp

.PHONY: all build test test-unit test-bats clean install

all: build

## ── Compile ──────────────────────────────────────────────────────────────────

build: $(MLISP_BIN)

$(MLISP_BIN): src/mlisp.lisp build.lisp
	@mkdir -p bin
	$(SBCL) --non-interactive --load build.lisp

## ── Tests ────────────────────────────────────────────────────────────────────

test: test-unit test-bats

test-unit:
	@echo "==> FiveAM unit tests"
	$(SBCL) --non-interactive --load test/fiveam/test-mlisp.lisp

test-bats: $(MLISP_BIN)
	@echo "==> BATS integration tests"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp.bats

## ── Install ──────────────────────────────────────────────────────────────────

install: build
	install -d $(PREFIX)/bin
	install -m 0755 $(MLISP_BIN) $(PREFIX)/bin/mlisp
	install -d $(PREFIX)/share/mlisp/state
	install -d $(PREFIX)/share/mlisp/templates
	install -m 0644 state/state.sexp $(PREFIX)/share/mlisp/state/state.sexp
	install -m 0644 templates/*.sexp $(PREFIX)/share/mlisp/templates/

## ── Clean ────────────────────────────────────────────────────────────────────

clean:
	rm -f $(MLISP_BIN)
	find . -name '*.fasl' -delete
