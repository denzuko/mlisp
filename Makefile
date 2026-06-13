# mlisp Makefile — v0.3.0

SBCL      ?= sbcl
BATS      ?= bats
PREFIX    ?= /usr/local
QL_SETUP  := $(HOME)/quicklisp/setup.lisp
SBCL_QL   := $(if $(wildcard $(QL_SETUP)),--eval '(load "$(QL_SETUP)")',)

.PHONY: all build-all build \
        test test-unit test-bats clean install

## ── Default ──────────────────────────────────────────────────────────────────

all: build-all

## ── Compile ──────────────────────────────────────────────────────────────────
##
## Pattern rule: every build-X.lisp (X != "" / plain "build.lisp") produces
## bin/mlisp-X, depending on mlisp-X.asd + src/*.lisp + bin/mlisp (the core
## library all other binaries link against). bin/mlisp itself is built from
## build.lisp via mlisp.asd. BINS is derived from the filesystem, so adding
## a new build-foo.lisp + mlisp-foo.asd automatically gets `make build-all`,
## `make install`, and `make clean` support with zero Makefile changes.

EXTRA_BINS := $(patsubst build-%.lisp,mlisp-%,$(filter-out build.lisp,$(wildcard build-*.lisp)))
BINS       := mlisp $(EXTRA_BINS)

build-all: $(addprefix bin/,$(BINS))

build: bin/mlisp

bin/mlisp: mlisp.asd src/*.lisp build.lisp
	$(SBCL) --non-interactive $(SBCL_QL) --load build.lisp

bin/mlisp-%: mlisp-%.asd build-%.lisp src/*.lisp bin/mlisp
	$(SBCL) --non-interactive $(SBCL_QL) --load build-$*.lisp

# build-admin / build-bugs / build-distrib / build-procmail-gen / ... aliases
build-%: bin/mlisp-%
	@true

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

# Every test/bats/*.bats file is run; adding a new spec file picks it up
# automatically with zero Makefile changes.
BATS_SPECS := $(wildcard test/bats/*.bats)

test-bats: $(addprefix bin/,$(BINS))
	@for f in $(BATS_SPECS); do \
	  echo "==> BATS: $$f"; \
	  MLISP_HOME=$(CURDIR) $(BATS) --tap "$$f" || exit 1; \
	 done

## ── Install ──────────────────────────────────────────────────────────────────

install: build-all
	install -d $(PREFIX)/bin
	@for b in $(BINS); do \
	  echo "install -m 0755 bin/$$b $(PREFIX)/bin/$$b"; \
	  install -m 0755 bin/$$b $(PREFIX)/bin/$$b; \
	 done
	install -d $(PREFIX)/share/mlisp/state
	install -d $(PREFIX)/share/mlisp/templates
	install -d $(PREFIX)/share/mlisp/etc
	install -m 0644 state/state.sexp           $(PREFIX)/share/mlisp/state/
	install -m 0644 templates/*.sexp           $(PREFIX)/share/mlisp/templates/
	install -m 0644 etc/procmailrc.sample      $(PREFIX)/share/mlisp/etc/

## ── Clean ────────────────────────────────────────────────────────────────────

clean:
	rm -f $(addprefix bin/,$(BINS))
	find . -name '*.fasl' -delete

# ─── Manpages ────────────────────────────────────────────────────────────────

MANDIR ?= /usr/local/share/man
MAN1 = src/man/mlisp.1 src/man/mlisp-admin.1 src/man/mlisp-distrib.1
MAN7 = src/man/mlisp-intro.7

man:
	install -d $(MANDIR)/man1 $(MANDIR)/man7
	install -m 644 $(MAN1) $(MANDIR)/man1/
	install -m 644 $(MAN7) $(MANDIR)/man7/
	@echo "Installed manpages to $(MANDIR)"

docs: $(MAN1) $(MAN7)
	mkdir -p doc
	@for f in $(MAN1) $(MAN7); do \
	  out=doc/$$(basename $$f .1)$$(basename $$f .7).html; \
	  groff -man -Thtml $$f > doc/$$(basename $$f).html 2>/dev/null; \
	  echo "  $$f -> doc/$$(basename $$f).html"; \
	done

.PHONY: man docs

# ─── Quicklisp dist ──────────────────────────────────────────────────────────

DIST_VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null || date +%Y-%m-%d)
DIST_PREFIX  = mlisp-$(DIST_VERSION)
DIST_BASE_URL ?= http://panix.com/~denzuko/dist/mlisp
DIST_DIR     = dist/$(DIST_VERSION)
PANIX_USER  ?= denzuko
PANIX_HOST  ?= panix.com
PANIX_PATH  ?= public_html/dist/mlisp

dist: dist/distinfo.txt $(DIST_DIR)/systems.txt $(DIST_DIR)/releases.txt

dist/$(DIST_PREFIX).tgz:
	@mkdir -p dist
	git archive --prefix=$(DIST_PREFIX)/ HEAD | gzip > $@
	@echo "Created $@ ($$(wc -c < $@) bytes)"

$(DIST_DIR)/distinfo.txt: dist/$(DIST_PREFIX).tgz
	@mkdir -p $(DIST_DIR)
	@echo "name: mlisp"                                              > $@
	@echo "version: $(DIST_VERSION)"                                >> $@
	@echo "system-index-url: $(DIST_BASE_URL)/$(DIST_VERSION)/systems.txt" >> $@
	@echo "release-index-url: $(DIST_BASE_URL)/$(DIST_VERSION)/releases.txt" >> $@
	@echo "canonical-distinfo-url: $(DIST_BASE_URL)/distinfo.txt"  >> $@
	@echo "dist-type: ql-dist"                                      >> $@
	@echo "archive-base-url: $(DIST_BASE_URL)/$(DIST_VERSION)/"    >> $@
	cp $(DIST_DIR)/distinfo.txt dist/distinfo.txt
	@echo "Generated $@"

$(DIST_DIR)/systems.txt:
	@mkdir -p $(DIST_DIR)
	@echo "mlisp mlisp.asd mlisp"               > $@
	@echo "mlisp mlisp-admin.asd mlisp-admin mlisp" >> $@
	@echo "mlisp mlisp-distrib.asd mlisp-distrib mlisp" >> $@
	@echo "Generated $@"

$(DIST_DIR)/releases.txt: dist/$(DIST_PREFIX).tgz $(DIST_DIR)/distinfo.txt
	$(eval SIZE := $(shell wc -c < dist/$(DIST_PREFIX).tgz))
	$(eval MD5  := $(shell md5sum dist/$(DIST_PREFIX).tgz | cut -d' ' -f1))
	$(eval SHA1 := $(shell sha1sum dist/$(DIST_PREFIX).tgz | cut -d' ' -f1))
	@echo "mlisp $(DIST_BASE_URL)/$(DIST_VERSION)/$(DIST_PREFIX).tgz $(SIZE) $(MD5) $(SHA1) $(DIST_PREFIX) mlisp.asd mlisp-admin.asd mlisp-distrib.asd" > $@
	cp dist/$(DIST_PREFIX).tgz $(DIST_DIR)/$(DIST_PREFIX).tgz
	@echo "Generated $@ ($(SIZE) bytes, md5=$(MD5))"

dist/distinfo.txt: $(DIST_DIR)/distinfo.txt

dist-upload: dist
	rsync -avz --delete dist/ $(PANIX_USER)@$(PANIX_HOST):$(PANIX_PATH)/
	@echo "Uploaded to $(PANIX_HOST):$(PANIX_PATH)/"

dist-clean:
	rm -rf dist/

.PHONY: dist dist-upload dist-clean
