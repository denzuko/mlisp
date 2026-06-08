#!/usr/bin/env bats
# test/bats/test_mlisp_regression.bats
# Regression suite isolating the three known failure modes.
# Each test is a minimal reproducer for one root cause.
# ALL must pass before those fixes land in test_mlisp.bats.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"  "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp  "${SCRATCH}/templates/"

    # Stub sendmail: drains stdin fully before exiting, prevents broken-pipe
    cat > "${SCRATCH}/bin/sendmail" << 'STUB'
#!/bin/sh
cat > /dev/null
exit 0
STUB
    chmod +x "${SCRATCH}/bin/sendmail"

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    export SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ── Root cause A: broken-pipe kills subscribe/help flows ─────────────────────
# Scenario: subscribe from body line, brand-new address, devel list.
# Binary must exit 0 and persist the new subscriber.

@test "RC-A subscribe from body: exits 0 with stdin-draining sendmail stub" {
    run bash -c "printf 'From: newuser@example.com\r\nSubject: hello\r\n\r\nsubscribe\r\n' \
      | '${MLISP_BIN}' devel"
    [ "$status" -eq 0 ]
}

@test "RC-A subscribe from body: address persisted in state.sexp" {
    printf 'From: newuser@example.com\r\nSubject: hello\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" devel
    grep -q "newuser@example.com" "${SCRATCH}/state/state.sexp"
}

@test "RC-A help from subject: exits 0 with stdin-draining sendmail stub" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: help\r\n\r\nhelp\r\n' \
      | '${MLISP_BIN}' discuss"
    [ "$status" -eq 0 ]
}

# ── Root cause B: setf on getf alias does not mutate *state* ─────────────────
# Scenario: unsubscribe from an address that IS in the list.
# Binary must exit 0 AND the address must be absent from state.sexp afterward.

@test "RC-B unsubscribe: exits 0" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: unsubscribe\r\n\r\nunsubscribe\r\n' \
      | '${MLISP_BIN}' discuss"
    [ "$status" -eq 0 ]
}

@test "RC-B unsubscribe: address removed from state.sexp" {
    printf 'From: dwight@example.com\r\nSubject: unsubscribe\r\n\r\nunsubscribe\r\n' \
      | "${MLISP_BIN}" discuss
    run grep "dwight@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "RC-B add-then-remove: address absent after subscribe then unsubscribe" {
    printf 'From: tmp@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" devel
    grep -q "tmp@example.com" "${SCRATCH}/state/state.sexp"

    printf 'From: tmp@example.com\r\nSubject: unsubscribe\r\n\r\nunsubscribe\r\n' \
      | "${MLISP_BIN}" devel
    run grep "tmp@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

# ── Root cause C: wrong-list loop header suppresses delivery ─────────────────
# Scenario: message has X-Loop-List-Announce but is routed to *discuss*.
# A subscriber posting to discuss must NOT be suppressed by an announce header.

@test "RC-C wrong-list loop header: discuss subscriber gets exit 0 not 1" {
    run bash -c "printf 'From: dwight@example.com\r\nX-Loop-List-Announce: 1\r\nSubject: real post\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' discuss"
    [ "$status" -eq 0 ]
}

@test "RC-C correct loop header still suppresses on same list" {
    run bash -c "printf 'From: dwight@example.com\r\nX-Loop-List-Discuss: 1\r\nSubject: loop\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' discuss"
    [ "$status" -eq 0 ]
    # verify no sendmail was invoked (log must be absent or empty)
}
