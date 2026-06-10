#!/usr/bin/env bats
# test/bats/test_mlisp_filters.bats
# Filter pipeline tests (pre/post-filter hooks, #66)
# These are isolated from the main v06 suite to avoid BATS env interactions.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" "${SCRATCH}/var"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"  "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp  "${SCRATCH}/templates/"

    # Simple sendmail stub using printf (avoids heredoc+sed substitution)
    printf '#!/bin/sh\ncat >> "%s/var/outbound.eml"\necho "MLISP_MSG_END" >> "%s/var/outbound.eml"\nexit 0\n' \
      "${SCRATCH}" "${SCRATCH}" > "${SCRATCH}/bin/sendmail"
    chmod +x "${SCRATCH}/bin/sendmail"

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export MLISP_BIN ADMIN_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ─── Pre-filter: exit 1 rejects ─────────────────────────────────────────────

@test "FLT-1 pre-filter exit 1 rejects message (mlisp exits non-zero)" {
    printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "${SCRATCH}/bin/reject"
    chmod +x "${SCRATCH}/bin/reject"
    "${ADMIN_BIN}" set-option mlisp-discuss pre-filter "${SCRATCH}/bin/reject"
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      > "${SCRATCH}/var/msg.eml"
    run bash -c "'${MLISP_BIN}' mlisp-discuss < '${SCRATCH}/var/msg.eml'"
    [ "$status" -ne 0 ]
}

# ─── Pre-filter: header modification passes through ─────────────────────────

@test "FLT-2 pre-filter can modify message headers" {
    printf '#!/bin/sh\nsed "s/SUBJECT:/SUBJECT: [FILTERED]/"\n' \
      > "${SCRATCH}/bin/tag"
    chmod +x "${SCRATCH}/bin/tag"
    "${ADMIN_BIN}" set-option mlisp-discuss pre-filter "${SCRATCH}/bin/tag"
    printf 'From: dwight@example.com\r\nSubject: original\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss 2>/dev/null || true
    grep -qi "FILTERED" "${SCRATCH}/var/outbound.eml"
}

# ─── Post-filter: invoked after header assembly ──────────────────────────────

@test "FLT-3 post-filter is invoked after header assembly" {
    printf '#!/bin/sh\ntouch "%s/var/pf-ran"\ncat\nexit 0\n' \
      "${SCRATCH}" > "${SCRATCH}/bin/pf"
    chmod +x "${SCRATCH}/bin/pf"
    rm -f "${SCRATCH}/var/pf-ran"
    "${ADMIN_BIN}" set-option mlisp-discuss post-filter "${SCRATCH}/bin/pf"
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss 2>/dev/null || true
    [ -f "${SCRATCH}/var/pf-ran" ]
}

# ─── Filter chain: first rejection stops remaining filters ───────────────────

@test "FLT-4 multiple pre-filters: first rejection stops chain" {
    printf '#!/bin/sh\ncat\nexit 0\n'         > "${SCRATCH}/bin/f1"; chmod +x "${SCRATCH}/bin/f1"
    printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "${SCRATCH}/bin/f2"; chmod +x "${SCRATCH}/bin/f2"
    printf '#!/bin/sh\ncat\nexit 0\n'         > "${SCRATCH}/bin/f3"; chmod +x "${SCRATCH}/bin/f3"
    "${ADMIN_BIN}" set-option mlisp-discuss \
      pre-filter "${SCRATCH}/bin/f1 ${SCRATCH}/bin/f2 ${SCRATCH}/bin/f3"
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      > "${SCRATCH}/var/msg.eml"
    run bash -c "'${MLISP_BIN}' mlisp-discuss < '${SCRATCH}/var/msg.eml'"
    [ "$status" -ne 0 ]
}
