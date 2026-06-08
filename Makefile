# mlisp Makefile

SBCL      ?= sbcl
BATS      ?= bats
PREFIX    ?= /usr/local
QL_SETUP  := $(HOME)/quicklisp/setup.lisp
SBCL_FLAGS = --non-interactive $(if $(wildcard $(QL_SETUP)),--eval '(load "$(QL_SETUP")',)

.PHONY: all build build-admin test test-unit test-bats clean install

all: build build-admin

## ── Compile ──────────────────────────────────────────────────────────────────

build: bin/mlisp

bin/mlisp: mlisp.asd src/*.lisp build.lisp
	$(SBCL) --non-interactive \
	  $(shell test -f $(QL_SETUP) && echo "--eval '(load \"$(QL_SETUP)\")'") \
	  --load build.lisp

build-admin: bin/mlisp-admin

bin/mlisp-admin: mlisp-admin.asd src/admin.lisp bin/mlisp
	$(SBCL) --non-interactive \
	  $(shell test -f $(QL_SETUP) && echo "--eval '(load \"$(QL_SETUP)\")'") \
	  --load build-admin.lisp

## ── Tests ────────────────────────────────────────────────────────────────────

test: test-unit test-bats

test-unit:
	@echo "==> FiveAM unit tests"
	$(SBCL) --non-interactive \
	  $(shell test -f $(QL_SETUP) && echo "--eval '(load \"$(QL_SETUP)\")'") \
	  --eval "(ql:quickload :fiveam :silent t)" \
	  --eval "(push (truename \".\") asdf:*central-registry*)" \
	  --load test/fiveam/test-mlisp.lisp

test-bats: bin/mlisp bin/mlisp-admin
	@echo "==> BATS integration tests"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp.bats
	@echo "==> BATS regression tests"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_regression.bats
	@echo "==> BATS compliance tests"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_compliance.bats
	@echo "==> BATS config/admin tests"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_config.bats

## ── Install ──────────────────────────────────────────────────────────────────

install: build build-admin
	install -d $(PREFIX)/bin
	install -m 0755 bin/mlisp       $(PREFIX)/bin/mlisp
	install -m 0755 bin/mlisp-admin $(PREFIX)/bin/mlisp-admin
	install -d $(PREFIX)/share/mlisp/state
	install -d $(PREFIX)/share/mlisp/templates
	install -m 0644 state/state.sexp     $(PREFIX)/share/mlisp/state/
	install -m 0644 templates/*.sexp     $(PREFIX)/share/mlisp/templates/

## ── Clean ────────────────────────────────────────────────────────────────────

clean:
	rm -f bin/mlisp bin/mlisp-admin
	find . -name '*.fasl' -delete
