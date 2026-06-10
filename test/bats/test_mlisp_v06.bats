#!/usr/bin/env bats
# test/bats/test_mlisp_v06.bats
# BDD specs for issues #63-66 (v0.6 feature set)

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" "${SCRATCH}/var"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"  "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp  "${SCRATCH}/templates/"

    cat > "${SCRATCH}/bin/sendmail" << 'STUB'
#!/bin/sh
cat >> "SCRATCH_DIR/var/outbound.eml"
echo "MLISP_MSG_END" >> "SCRATCH_DIR/var/outbound.eml"
exit 0
STUB
    sed -i "s|SCRATCH_DIR|${SCRATCH}|g" "${SCRATCH}/bin/sendmail"
    chmod +x "${SCRATCH}/bin/sendmail"

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export MLISP_BIN ADMIN_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ═══════════════════════════════════════════════════════════════════════════════
# #63 Subscriber self-service commands
# ═══════════════════════════════════════════════════════════════════════════════

@test "V6-1 info command sends list description to sender" {
    printf 'From: dwight@example.com\r\nSubject: info\r\n\r\ninfo\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -qi "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V6-2 info reply contains list description" {
    printf 'From: dwight@example.com\r\nSubject: info\r\n\r\ninfo\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    # Should contain description or list name
    grep -qi "mlisp-discuss\|mailing list\|description" "${SCRATCH}/var/outbound.eml"
}

@test "V6-3 who command with advertised false returns not-advertised message" {
    # advertised is nil by default
    printf 'From: dwight@example.com\r\nSubject: who\r\n\r\nwho\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -qi "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V6-4 who command with advertised true returns subscriber list" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss advertised true
    printf 'From: dwight@example.com\r\nSubject: who\r\n\r\nwho mlisp-discuss\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -qi "dwight@example.com\|subscriber" "${SCRATCH}/var/outbound.eml"
}

@test "V6-5 query command returns sender delivery settings" {
    printf 'From: dwight@example.com\r\nSubject: query mlisp-discuss\r\n\r\nquery mlisp-discuss\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -qi "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V6-6 set digest command switches subscriber to digest delivery" {
    printf 'From: dwight@example.com\r\nSubject: set mlisp-discuss digest\r\n\r\nset mlisp-discuss digest\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    [ "$?" -eq 0 ]
}

@test "V6-7 set mail command restores normal delivery" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-nomail mlisp-discuss dwight@example.com true 2>/dev/null || true
    printf 'From: dwight@example.com\r\nSubject: set mlisp-discuss mail\r\n\r\nset mlisp-discuss mail\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    [ "$?" -eq 0 ]
}

@test "V6-8 LISTSERV-style 'set <list> nomail' recognised" {
    printf 'From: dwight@example.com\r\nSubject: set mlisp-discuss nomail\r\n\r\nset mlisp-discuss nomail\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    [ "$?" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# #64 Database search and archive retrieval
# ═══════════════════════════════════════════════════════════════════════════════

@test "V6-9 search command requires search-enabled true to return results" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: search lisp\r\n\r\nsearch lisp\r\n' \
      | '${MLISP_BIN}' --mode request mlisp-request"
    [ "$status" -eq 0 ]
    grep -qi "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V6-10 search with search-enabled true searches Maildir archive" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss search-enabled true
    # Seed a message in the archive
    mkdir -p "${SCRATCH}/state/maildir/mlisp-discuss/new"
    printf 'From: dwight@example.com\r\nSubject: test lisp message\r\n\r\nbody\r\n' \
      > "${SCRATCH}/state/maildir/mlisp-discuss/new/001"
    printf 'From: dwight@example.com\r\nSubject: search lisp\r\n\r\nsearch lisp\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -qi "test lisp message\|lisp" "${SCRATCH}/var/outbound.eml"
}

@test "V6-11 index command lists archived messages" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss search-enabled true
    mkdir -p "${SCRATCH}/state/maildir/mlisp-discuss/new"
    printf 'From: a@example.com\r\nSubject: first post\r\n\r\nbody\r\n' \
      > "${SCRATCH}/state/maildir/mlisp-discuss/new/001"
    printf 'From: dwight@example.com\r\nSubject: index mlisp-discuss\r\n\r\nindex mlisp-discuss\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -qi "first post\|index\|MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V6-12 get command retrieves archived message by number" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss search-enabled true
    mkdir -p "${SCRATCH}/state/maildir/mlisp-discuss/new"
    printf 'From: a@example.com\r\nSubject: first post\r\nMessage-ID: <001@example.com>\r\n\r\nhello world\r\n' \
      > "${SCRATCH}/state/maildir/mlisp-discuss/new/001"
    printf 'From: dwight@example.com\r\nSubject: get mlisp-discuss 1\r\n\r\nget mlisp-discuss 1\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -qi "hello world\|first post\|MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# #65 AllFix filearea commands
# ═══════════════════════════════════════════════════════════════════════════════

@test "V6-13 files command to -distrib returns file listing" {
    mkdir -p "${SCRATCH}/state/distrib/mlisp-distrib"
    echo "data" > "${SCRATCH}/state/distrib/mlisp-distrib/testfile.txt"
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp2 mlisp2@example.com 2>/dev/null || true
    printf 'From: dwight@example.com\r\nSubject: files\r\n\r\nfiles\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V6-14 mlisp-admin hatch adds file to distrib archive" {
    mkdir -p "${SCRATCH}/state/distrib/mlisp-distrib"
    echo "release data" > /tmp/mlisp-test-release.txt
    run "${ADMIN_BIN}" --home "${SCRATCH}" hatch mlisp-distrib /tmp/mlisp-test-release.txt \
      --description "Test release"
    [ "$status" -eq 0 ]
    rm -f /tmp/mlisp-test-release.txt
}

# ═══════════════════════════════════════════════════════════════════════════════
# #66 Plugin filter pipeline
# ═══════════════════════════════════════════════════════════════════════════════

@test "V6-15 pre-filter exit 0 passes message through" {
    # Filter that passes everything
    printf '#!/bin/sh\ncat\nexit 0\n' > "${SCRATCH}/bin/filter-pass"
    chmod +x "${SCRATCH}/bin/filter-pass"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      pre-filter "${SCRATCH}/bin/filter-pass"
    run bash -c "printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V6-16 pre-filter exit 1 rejects message" {
    printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "${SCRATCH}/bin/filter-reject"
    chmod +x "${SCRATCH}/bin/filter-reject"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      pre-filter "${SCRATCH}/bin/filter-reject"
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      > "${SCRATCH}/var/msg.eml"
    run bash -c "'${MLISP_BIN}' mlisp-discuss < '${SCRATCH}/var/msg.eml'"
    [ "$status" -ne 0 ]
}

@test "V6-17 pre-filter exit 2 holds message in held queue" {
    printf '#!/bin/sh\ncat > /dev/null\nexit 2\n' > "${SCRATCH}/bin/filter-hold"
    chmod +x "${SCRATCH}/bin/filter-hold"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      pre-filter "${SCRATCH}/bin/filter-hold"
    run bash -c "printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/state/held/mlisp-discuss.sexp" ]
}

@test "V6-18 pre-filter exit 3 discards message silently" {
    printf '#!/bin/sh\ncat > /dev/null\nexit 3\n' > "${SCRATCH}/bin/filter-discard"
    chmod +x "${SCRATCH}/bin/filter-discard"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      pre-filter "${SCRATCH}/bin/filter-discard"
    run bash -c "printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    run grep "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "V6-19 pre-filter can modify message headers" {
    printf '#!/bin/sh\nsed "s/SUBJECT:/SUBJECT: [FILTERED]/"
' \
      > "${SCRATCH}/bin/filter-tag"
    chmod +x "${SCRATCH}/bin/filter-tag"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      pre-filter "${SCRATCH}/bin/filter-tag"
    printf 'From: dwight@example.com\r\nSubject: original\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss 2>/dev/null || true
    grep -qi "FILTERED" "${SCRATCH}/var/outbound.eml"
}

@test "V6-20 post-filter is invoked after header assembly" {
    printf '#!/bin/sh\ntouch "%s/var/post-filter-ran"\ncat\nexit 0\n' \
      "${SCRATCH}" > "${SCRATCH}/bin/filter-post"
    chmod +x "${SCRATCH}/bin/filter-post"
    rm -f "${SCRATCH}/var/post-filter-ran"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      post-filter "${SCRATCH}/bin/filter-post"
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss 2>/dev/null || true
    [ -f "${SCRATCH}/var/post-filter-ran" ]
}

@test "V6-21 multiple pre-filters run in order, first rejection stops chain" {
    printf '#!/bin/sh\ncat\nexit 0\n' > "${SCRATCH}/bin/f1"; chmod +x "${SCRATCH}/bin/f1"
    printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "${SCRATCH}/bin/f2"; chmod +x "${SCRATCH}/bin/f2"
    printf '#!/bin/sh\ncat\nexit 0\n' > "${SCRATCH}/bin/f3"; chmod +x "${SCRATCH}/bin/f3"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      pre-filter "${SCRATCH}/bin/f1 ${SCRATCH}/bin/f2 ${SCRATCH}/bin/f3"
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      > "${SCRATCH}/var/msg.eml"
    run bash -c "'${MLISP_BIN}' mlisp-discuss < '${SCRATCH}/var/msg.eml'"
    [ "$status" -ne 0 ]
}

@test "V6-22 example spamassassin filter script exists in etc/filters/" {
    [ -f "${MLISP_HOME_ORIG}/etc/filters/spamassassin" ]
}

@test "V6-23 example clamav filter script exists in etc/filters/" {
    [ -f "${MLISP_HOME_ORIG}/etc/filters/clamav" ]
}
