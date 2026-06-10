#!/bin/sh
# ci/run-tests.sh — mlisp portable test runner
#
# Runs the full test suite against the current working tree.
# Exits 0 on full pass, 1 on any failure.
#
# Usage:
#   ./ci/run-tests.sh                    # run all suites
#   ./ci/run-tests.sh --fast             # build + smoke test only
#   ./ci/run-tests.sh --suite test_mlisp # run one BATS suite
#
# Requirements: sbcl, bats-core, groff
# No root required.  No external services.  No daemons.

set -e

PASS=0
FAIL=0
SUITE=""
FAST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --fast)   FAST=1; shift ;;
        --suite)  SUITE="$2"; shift 2 ;;
        *)        echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log() { printf '[ci] %s\n' "$*"; }
fail() { printf '[ci] FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

# ─── Build ────────────────────────────────────────────────────────────────────

log "Building mlisp..."
if sbcl --non-interactive --load build.lisp 2>&1 | grep -q "\[build\] Compiling"; then
    pass
else
    fail "build.lisp"
    exit 1
fi

log "Building mlisp-admin..."
if sbcl --non-interactive --load build-admin.lisp 2>&1 | grep -q "\[build\] Compiling"; then
    pass
else
    fail "build-admin.lisp"
    exit 1
fi

log "Building mlisp-distrib..."
if sbcl --non-interactive --load build-distrib.lisp 2>&1 | grep -q "\[build\] Compiling"; then
    pass
else
    fail "build-distrib.lisp"
    exit 1
fi

if [ "$FAST" = "1" ]; then
    log "Fast mode: skipping integration tests"
    log "Result: build passed"
    exit 0
fi

# ─── FiveAM unit tests ────────────────────────────────────────────────────────

log "Running FiveAM unit tests..."
for f in test/fiveam/test-mlisp.lisp test/fiveam/test-mlisp-mime.lisp; do
    result=$(sbcl --non-interactive \
        --eval '(load "/home/user/quicklisp/setup.lisp" :if-does-not-exist nil)' \
        --eval "(require :asdf)" \
        --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
        --load "$f" 2>&1 | grep -E "Pass:|Fail:")
    if echo "$result" | grep -q "Fail: 0"; then
        n=$(echo "$result" | grep -oE "Pass: [0-9]+" | grep -oE "[0-9]+")
        log "  $f: $n passed"
        pass
    else
        fail "$f: $result"
    fi
done

# ─── BATS integration tests ───────────────────────────────────────────────────

BATS_SUITES="
test_mlisp
test_mlisp_regression
test_mlisp_compliance
test_mlisp_config
test_mlisp_procmail
test_mlisp_namespace
test_mlisp_mime
test_mlisp_features
test_mlisp_batch2
test_mlisp_gpg
test_mlisp_v04a
test_mlisp_v04b
test_mlisp_v04cd
test_mlisp_v05
test_mlisp_v06
test_mlisp_filters
"

if [ -n "$SUITE" ]; then
    BATS_SUITES="$SUITE"
fi

TOTAL_BATS=0
FAILED_SUITES=""

for suite in $BATS_SUITES; do
    bats_file="test/bats/${suite}.bats"
    [ -f "$bats_file" ] || continue
    log "  $suite..."
    n_pass=$(MLISP_HOME="$(pwd)" bats --tap "$bats_file" 2>/dev/null | grep -c "^ok" || true)
    n_fail=$(MLISP_HOME="$(pwd)" bats --tap "$bats_file" 2>/dev/null | grep -c "^not ok" || true)
    TOTAL_BATS=$((TOTAL_BATS + n_pass))
    if [ "$n_fail" -gt 0 ]; then
        fail "$suite: $n_fail failures"
        FAILED_SUITES="$FAILED_SUITES $suite"
    fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────

log ""
log "Results: $TOTAL_BATS BATS tests passed, $FAIL failures"

if [ "$FAIL" -gt 0 ]; then
    log "Failed suites:$FAILED_SUITES"
    exit 1
fi

log "All tests passed."
exit 0
