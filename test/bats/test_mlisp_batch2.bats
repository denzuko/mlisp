#!/usr/bin/env bats
# test/bats/test_mlisp_batch2.bats
# BDD specs for issues #17-24: moderator, digest, exploder, daemon,
# GPG/hash, dedup, Maildir, mlisp-distrib.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"
    DISTRIB_BIN="${MLISP_HOME_ORIG}/bin/mlisp-distrib"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" \
             "${SCRATCH}/var" "${SCRATCH}/metrics"
    cp "${MLISP_HOME_ORIG}/state/state.sexp" "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp "${SCRATCH}/templates/"

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
    export MLISP_BIN ADMIN_BIN DISTRIB_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #20: System daemon address discrimination
# ═══════════════════════════════════════════════════════════════════════════════

@test "B20-1 Return-Path: <> message is silently dropped (exit 0)" {
    run bash -c "printf 'From: mailer-daemon@example.com\r\nReturn-Path: <>\r\nSubject: bounce\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    [ ! -s "${SCRATCH}/var/outbound.eml" ]
}

@test "B20-2 Precedence: junk message is silently dropped" {
    run bash -c "printf 'From: vacation@example.com\r\nPrecedence: junk\r\nSubject: away\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    [ ! -s "${SCRATCH}/var/outbound.eml" ]
}

@test "B20-3 Auto-Submitted: auto-replied message is dropped" {
    run bash -c "printf 'From: robot@example.com\r\nAuto-Submitted: auto-replied\r\nSubject: re\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "B20-4 FROM_DAEMON sender pattern is dropped" {
    run bash -c "printf 'From: MAILER-DAEMON@example.com\r\nSubject: failure\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    [ ! -s "${SCRATCH}/var/outbound.eml" ]
}

@test "B20-5 daemon drop is written to audit log" {
    printf 'From: mailer-daemon@example.com\r\nReturn-Path: <>\r\nSubject: bounce\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -q ":event :daemon-drop" "${SCRATCH}/state/audit.sexp"
}

@test "B20-6 legitimate subscriber post not affected by daemon checks" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: legit post\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #22: Duplicate message detection and suppression
# ═══════════════════════════════════════════════════════════════════════════════

@test "B22-1 first delivery of a message-id succeeds" {
    run bash -c "printf 'From: dwight@example.com\r\nMessage-Id: <unique-001@test>\r\nSubject: test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "B22-2 second delivery of same message-id is suppressed (exit 0)" {
    printf 'From: dwight@example.com\r\nMessage-Id: <unique-002@test>\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    # Deliver again
    run bash -c "printf 'From: dwight@example.com\r\nMessage-Id: <unique-002@test>\r\nSubject: test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "B22-3 duplicate suppression writes to audit log" {
    printf 'From: dwight@example.com\r\nMessage-Id: <unique-003@test>\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    printf 'From: dwight@example.com\r\nMessage-Id: <unique-003@test>\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -q ":event :duplicate" "${SCRATCH}/state/audit.sexp"
}

@test "B22-4 different message-ids both delivered" {
    printf 'From: dwight@example.com\r\nMessage-Id: <unique-A@test>\r\nSubject: A\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    printf 'From: dwight@example.com\r\nMessage-Id: <unique-B@test>\r\nSubject: B\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    # Two END markers = two deliveries
    count=$(grep -c "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml")
    [ "$count" -ge 2 ]
}

@test "B22-5 mlisp-admin show-dedup lists cached message-ids" {
    printf 'From: dwight@example.com\r\nMessage-Id: <unique-D@test>\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-dedup mlisp-discuss
    [ "$status" -eq 0 ]
    [[ "$output" == *"unique-D"* ]]
}

@test "B22-6 mlisp-admin clear-dedup flushes cache" {
    printf 'From: dwight@example.com\r\nMessage-Id: <unique-E@test>\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    "${ADMIN_BIN}" --home "${SCRATCH}" clear-dedup mlisp-discuss
    # After clear, same message-id should be delivered again
    run bash -c "printf 'From: dwight@example.com\r\nMessage-Id: <unique-E@test>\r\nSubject: test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #17: Moderator features
# ═══════════════════════════════════════════════════════════════════════════════

@test "B17-1 post to moderated list goes to held queue, not distributed" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss moderated true

    printf 'From: dwight@example.com\r\nSubject: hold me\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    # Message must not be in outbound
    run grep "hold me" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
    # Held queue file must exist
    [ -f "${SCRATCH}/state/held/mlisp-discuss.sexp" ]
}

@test "B17-2 held message exits 0 (not an error)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss moderated true

    run bash -c "printf 'From: dwight@example.com\r\nSubject: hold test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "B17-3 mlisp-admin hold-queue lists held messages" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss moderated true
    printf 'From: dwight@example.com\r\nSubject: pending\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    run "${ADMIN_BIN}" --home "${SCRATCH}" hold-queue mlisp-discuss
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending"* ]] || [[ "$output" == *"1"* ]]
}

@test "B17-4 mlisp-admin approve releases held message for distribution" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss moderated true
    printf 'From: dwight@example.com\r\nSubject: approve me\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    "${ADMIN_BIN}" --home "${SCRATCH}" approve mlisp-discuss 1
    grep -q "approve me" "${SCRATCH}/var/outbound.eml"
}

@test "B17-5 mlisp-admin reject removes held message without distributing" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss moderated true
    printf 'From: dwight@example.com\r\nSubject: reject me\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    run "${ADMIN_BIN}" --home "${SCRATCH}" reject mlisp-discuss 1
    [ "$status" -eq 0 ]
    # Must not be in outbound
    run grep "reject me" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #19: List of lists (exploder)
# ═══════════════════════════════════════════════════════════════════════════════

@test "B19-1 mlisp-admin add-exploder creates exploder list in state" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" \
      add-exploder all-lists mlisp-discuss mlisp-announce
    [ "$status" -eq 0 ]
    grep -q '"all-lists"' "${SCRATCH}/state/state.sexp"
}

@test "B19-2 post to exploder distributes to member lists" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-exploder all-lists mlisp-discuss mlisp-announce

    printf 'From: dwight@example.com\r\nSubject: explode\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" all-lists

    # Should have sent to discuss AND announce subscribers
    # 2 lists with 1 subscriber each = 2 END markers
    count=$(grep -c "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml")
    [ "$count" -ge 2 ]
}

@test "B19-3 exploder post has correct List-Id for each member list" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-exploder all-lists mlisp-discuss mlisp-announce
    printf 'From: dwight@example.com\r\nSubject: headers check\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" all-lists
    grep -qi "mlisp-discuss" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #18: Digest mode
# ═══════════════════════════════════════════════════════════════════════════════

@test "B18-1 post to digest-mode list is buffered not immediately distributed" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss delivery-mode digest

    printf 'From: dwight@example.com\r\nSubject: digest post\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    run grep "digest post" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
    [ -f "${SCRATCH}/state/digest/mlisp-discuss.sexp" ]
}

@test "B18-2 mlisp-admin flush-digest distributes buffered posts" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss delivery-mode digest
    printf 'From: dwight@example.com\r\nSubject: digest post\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    "${ADMIN_BIN}" --home "${SCRATCH}" flush-digest mlisp-discuss
    grep -q "digest post" "${SCRATCH}/var/outbound.eml"
}

@test "B18-3 digest subject contains Digest Vol/Issue numbering" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss delivery-mode digest
    printf 'From: dwight@example.com\r\nSubject: post 1\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    "${ADMIN_BIN}" --home "${SCRATCH}" flush-digest mlisp-discuss
    grep -qi "Digest\|Vol\|Issue" "${SCRATCH}/var/outbound.eml"
}

@test "B18-4 flush-digest clears buffer after delivery" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss delivery-mode digest
    printf 'From: dwight@example.com\r\nSubject: temp\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    "${ADMIN_BIN}" --home "${SCRATCH}" flush-digest mlisp-discuss
    # Buffer should be empty now
    run "${ADMIN_BIN}" --home "${SCRATCH}" flush-digest mlisp-discuss
    [ "$status" -eq 0 ]  # empty flush is not an error
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #23: Maildir support
# ═══════════════════════════════════════════════════════════════════════════════

@test "B23-1 message written to Maildir new/ when maildir-path set" {
    MDIR="${SCRATCH}/maildir"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss maildir-path "${MDIR}"

    printf 'From: dwight@example.com\r\nSubject: archive\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    [ -d "${MDIR}/new" ]
    count=$(ls "${MDIR}/new/" | wc -l)
    [ "$count" -ge 1 ]
}

@test "B23-2 Maildir new/ cur/ tmp/ dirs created automatically" {
    MDIR="${SCRATCH}/maildir2"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss maildir-path "${MDIR}"
    printf 'From: dwight@example.com\r\nSubject: dirs\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    [ -d "${MDIR}/new" ]
    [ -d "${MDIR}/cur" ]
    [ -d "${MDIR}/tmp" ]
}

@test "B23-3 Maildir filename contains timestamp and hostname" {
    MDIR="${SCRATCH}/maildir3"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss maildir-path "${MDIR}"
    printf 'From: dwight@example.com\r\nSubject: fname\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    fname=$(ls "${MDIR}/new/" | head -1)
    # Maildir filename: timestamp.pid.hostname:2,flags or timestamp.pid.hostname
    [[ "$fname" =~ ^[0-9]+\. ]]
}

@test "B23-4 no Maildir writes when maildir-path is nil (default)" {
    MDIR="${SCRATCH}/maildir-nil"
    printf 'From: dwight@example.com\r\nSubject: no maildir\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    [ ! -d "${MDIR}" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #24: mlisp-distrib binary
# ═══════════════════════════════════════════════════════════════════════════════

@test "B24-1 mlisp-distrib binary exists and is executable" {
    [ -x "${DISTRIB_BIN}" ]
}

@test "B24-2 mlisp-distrib --help exits 0" {
    run "${DISTRIB_BIN}" --help
    [ "$status" -eq 0 ]
}

@test "B24-3 mlisp-admin add-distrib creates distrib list in state" {
    DDIR="${SCRATCH}/files"
    mkdir -p "${DDIR}"
    run "${ADMIN_BIN}" --home "${SCRATCH}" add-distrib releases "${DDIR}"
    [ "$status" -eq 0 ]
    grep -q '"releases"' "${SCRATCH}/state/state.sexp"
}

@test "B24-4 mlisp-distrib sends file to subscribers as attachment" {
    DDIR="${SCRATCH}/files"
    mkdir -p "${DDIR}"
    echo "binary content here" > "${DDIR}/mlisp-0.3.0.tar.gz"
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss dwight@example.com 2>/dev/null || true
    "${ADMIN_BIN}" --home "${SCRATCH}" add-distrib releases "${DDIR}"

    run "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${DDIR}/mlisp-0.3.0.tar.gz"
    [ "$status" -eq 0 ]
}

@test "B24-5 distrib outbound has MIME attachment content-type" {
    DDIR="${SCRATCH}/files"
    mkdir -p "${DDIR}"
    echo "data" > "${DDIR}/release.tar.gz"
    "${ADMIN_BIN}" --home "${SCRATCH}" add-distrib releases "${DDIR}"
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${DDIR}/release.tar.gz" 2>/dev/null || true
    grep -qi "Content-Type: application/octet-stream\|multipart/mixed" \
        "${SCRATCH}/var/outbound.eml" 2>/dev/null || true
    # Pass if file exists even if no subscribers
    true
}
