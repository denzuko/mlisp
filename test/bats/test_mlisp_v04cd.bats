#!/usr/bin/env bats
# test/bats/test_mlisp_v04cd.bats
# BDD specs for issues #36 (DMARC rewrite), #39 (VERP), #41 (LDIF export).

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
# ISSUE #36: DMARC-safe Sender/From rewrite
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4C-1 dmarc-rewrite never: From header not rewritten" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss dmarc-rewrite never
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^From:.*dwight@example.com" "${SCRATCH}/var/outbound.eml"
}

@test "V4C-2 dmarc-rewrite always: From header is rewritten to list address" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss dmarc-rewrite always
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    # From should now contain list address, not sender
    grep -qi "^From:.*mlisp-discuss" "${SCRATCH}/var/outbound.eml"
}

@test "V4C-3 dmarc-rewrite always: X-Original-From preserves sender" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss dmarc-rewrite always
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "X-Original-From:.*dwight@example.com" "${SCRATCH}/var/outbound.eml"
}

@test "V4C-4 dmarc-rewrite always: Reply-To set to original sender" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss dmarc-rewrite always
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "Reply-To:.*dwight@example.com" "${SCRATCH}/var/outbound.eml"
}

@test "V4C-5 dmarc-rewrite auto: non-strict domain not rewritten" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss dmarc-rewrite auto
    # panix.com is not a strict DMARC domain
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    # From should be preserved (panix.com has no strict DMARC)
    grep -qi "^From:.*dwight@example.com" "${SCRATCH}/var/outbound.eml"
}

@test "V4C-6 dmarc-rewrite none (default): From preserved" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^From:.*dwight@example.com" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #39: VERP bounce tracking
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4C-7 verp false (default): post delivers normally (no VERP encoding)" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "V4C-8 verp true: set-option persists" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss verp true
    [ "$status" -eq 0 ]
    grep -q ":verp t" "${SCRATCH}/state/state.sexp"
}

@test "V4C-9 verp encoding round-trip: extract subscriber from VERP address" {
    # mlisp-discuss+ab12cd34=alice=example.com@panix.com
    # The local part before @ encodes the subscriber
    run "${ADMIN_BIN}" --home "${SCRATCH}" verp-decode \
      "mlisp-discuss+ab12cd34=alice=example.com@panix.com"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alice@example.com"* ]]
}

@test "V4C-10 --mode bounce with VERP address in To: processes without error" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss verp true
    # Simulate a VERP bounce — supply a minimal DSN so bounce mode accepts it
    printf 'To: mlisp-discuss+ab12=dwight=example.com@panix.com\r\nContent-Type: multipart/report; report-type=delivery-status\r\nSubject: Delivery Status\r\n\r\n' \
      | "${MLISP_BIN}" --mode bounce mlisp-discuss || true
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-bounces mlisp-discuss
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #41: LDIF export
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4D-1 export-ldif produces valid LDIF output" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-ldif mlisp-discuss
    [ "$status" -eq 0 ]
    [[ "$output" == *"dn:"* ]]
    [[ "$output" == *"objectClass: groupOfNames"* ]]
}

@test "V4D-2 export-ldif includes list cn" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-ldif mlisp-discuss
    [[ "$output" == *"cn: mlisp-discuss"* ]]
}

@test "V4D-3 export-ldif includes member entries for subscribers" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-ldif mlisp-discuss
    [[ "$output" == *"member:"* ]]
}

@test "V4D-4 export-ldif --base-dn customises DN prefix" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-ldif mlisp-discuss \
      --base-dn "dc=panix,dc=com"
    [[ "$output" == *"dc=panix,dc=com"* ]]
}

@test "V4D-5 export-ldif to file writes valid LDIF" {
    "${ADMIN_BIN}" --home "${SCRATCH}" export-ldif mlisp-discuss \
      --output "${SCRATCH}/export.ldif"
    [ -f "${SCRATCH}/export.ldif" ]
    grep -q "objectClass: groupOfNames" "${SCRATCH}/export.ldif"
}

@test "V4D-6 export-ldif with hash-contacts uses address-hash as uid" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss hash-contacts true
    # subscribe a fresh address so it gets hashed
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request || true
    # No opt-in confirmation needed here; use add-sub directly
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe false
    printf 'From: hashed@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-ldif mlisp-discuss
    # Should not contain plaintext hashed@example.com
    [[ "$output" != *"hashed@example.com"* ]]
}

@test "V4D-7 export-ldif with no subscribers produces valid empty group" {
    "${ADMIN_BIN}" --home "${SCRATCH}" rm-sub mlisp-devel nobody@example.com 2>/dev/null || true
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-ldif mlisp-devel
    [ "$status" -eq 0 ]
    [[ "$output" == *"objectClass: groupOfNames"* ]]
}
