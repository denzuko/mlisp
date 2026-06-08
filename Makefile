# mlisp Makefile — v0.3.0

SBCL      ?= sbcl
BATS      ?= bats
PREFIX    ?= /usr/local
QL_SETUP  := $(HOME)/quicklisp/setup.lisp
SBCL_QL   := $(if $(wildcard $(QL_SETUP)),--eval '(load "$(QL_SETUP)")',)

.PHONY: all build-all build build-admin build-distrib \
        test test-unit test-bats clean install

## ── Default ──────────────────────────────────────────────────────────────────

all: build-all

## ── Compile ──────────────────────────────────────────────────────────────────

build-all: bin/mlisp bin/mlisp-admin bin/mlisp-distrib

build: bin/mlisp

bin/mlisp: mlisp.asd src/*.lisp build.lisp
	$(SBCL) --non-interactive $(SBCL_QL) --load build.lisp

build-admin: bin/mlisp-admin

bin/mlisp-admin: mlisp-admin.asd src/admin.lisp bin/mlisp
	$(SBCL) --non-interactive $(SBCL_QL) --load build-admin.lisp

build-distrib: bin/mlisp-distrib

bin/mlisp-distrib: mlisp-distrib.asd src/distrib.lisp bin/mlisp
	$(SBCL) --non-interactive $(SBCL_QL) --load build-distrib.lisp

## ── Tests ────────────────────────────────────────────────────────────────────

test: test-unit test-bats

test-unit:
	@echo "==> FiveAM: mlisp"
	$(SBCL) --non-interactive $(SBCL_QL) \
	  --eval "(ql:quickload :fiveam :silent t)" \
	  --eval "(push (truename \".\") asdf:*central-registry*)" \
	  --load test/fiveam/test-mlisp.lisp
	@echo "==> FiveAM: mlisp-mime"
	$(SBCL) --non-interactive $(SBCL_QL) \
	  --eval "(ql:quickload :fiveam :silent t)" \
	  --eval "(push (truename \".\") asdf:*central-registry*)" \
	  --load test/fiveam/test-mlisp-mime.lisp

test-bats: bin/mlisp bin/mlisp-admin bin/mlisp-distrib
	@echo "==> BATS: integration (21)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp.bats
	@echo "==> BATS: regression (8)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_regression.bats
	@echo "==> BATS: compliance (23)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_compliance.bats
	@echo "==> BATS: config/admin (29)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_config.bats
	@echo "==> BATS: procmail (25)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_procmail.bats
	@echo "==> BATS: MIME (7)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_mime.bats
	@echo "==> BATS: features (38)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_features.bats
	@echo "==> BATS: batch2 (33)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_batch2.bats
	@echo "==> BATS: GPG/hash (13)"
	MLISP_HOME=$(CURDIR) $(BATS) --tap test/bats/test_mlisp_gpg.bats

## ── Install ──────────────────────────────────────────────────────────────────

install: build-all
	install -d $(PREFIX)/bin
	install -m 0755 bin/mlisp          $(PREFIX)/bin/mlisp
	install -m 0755 bin/mlisp-admin    $(PREFIX)/bin/mlisp-admin
	install -m 0755 bin/mlisp-distrib  $(PREFIX)/bin/mlisp-distrib
	install -d $(PREFIX)/share/mlisp/state
	install -d $(PREFIX)/share/mlisp/templates
	install -d $(PREFIX)/share/mlisp/etc
	install -m 0644 state/state.sexp           $(PREFIX)/share/mlisp/state/
	install -m 0644 templates/*.sexp           $(PREFIX)/share/mlisp/templates/
	install -m 0644 etc/procmailrc.sample      $(PREFIX)/share/mlisp/etc/

## ── Clean ────────────────────────────────────────────────────────────────────

clean:
	rm -f bin/mlisp bin/mlisp-admin bin/mlisp-distrib
	find . -name '*.fasl' -delete
