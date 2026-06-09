#!/usr/bin/env bats
# test/bats/test_mlisp_v04b.bats
# BDD specs for issues #32 (double opt-in) and #40 (mass subscribe).

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
# ISSUE #32: Double opt-in subscribe confirmation
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4B-1 with confirm-subscribe false, subscribe adds immediately" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe false
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" == *"newuser@example.com"* ]]
}

@test "V4B-2 with confirm-subscribe true, subscribe sends challenge, does not add immediately" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe true
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    # Should NOT be a subscriber yet
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" != *"newuser@example.com"* ]]
}

@test "V4B-3 with confirm-subscribe true, challenge email is sent" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe true
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    # A confirmation email should have been sent to newuser
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V4B-4 pending token is written to state/pending" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe true
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    [ -f "${SCRATCH}/state/pending/mlisp-discuss.sexp" ]
}

@test "V4B-5 correct confirm token in reply completes subscription" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe true
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    # Extract token from pending file
    token=$(grep -oE '"[0-9a-f]{16,}"' "${SCRATCH}/state/pending/mlisp-discuss.sexp" | head -1 | tr -d '"')
    [ -n "$token" ]
    # Send confirmation
    printf "From: newuser@example.com\r\nSubject: confirm %s\r\n\r\nconfirm %s\r\n" \
      "$token" "$token" \
      | "${MLISP_BIN}" --mode request mlisp-request
    # Now should be subscribed
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" == *"newuser@example.com"* ]]
}

@test "V4B-6 wrong confirm token is rejected" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe true
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    printf 'From: newuser@example.com\r\nSubject: confirm wrongtoken\r\n\r\nconfirm wrongtoken\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" != *"newuser@example.com"* ]]
}

@test "V4B-7 mlisp-admin show-pending lists pending confirmations" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe true
    printf 'From: pending@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-pending mlisp-discuss
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending@example.com"* ]]
}

@test "V4B-8 mlisp-admin clear-pending removes expired tokens" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe true
    printf 'From: pending@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    run "${ADMIN_BIN}" --home "${SCRATCH}" clear-pending mlisp-discuss
    [ "$status" -eq 0 ]
}

@test "V4B-9 consent-method recorded as double-opt-in on confirmed subscribe" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss confirm-subscribe true
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    token=$(grep -oE '"[0-9a-f]{16,}"' "${SCRATCH}/state/pending/mlisp-discuss.sexp" | head -1 | tr -d '"')
    printf "From: newuser@example.com\r\nSubject: confirm %s\r\n\r\nconfirm %s\r\n" \
      "$token" "$token" \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -q "double-opt-in\|confirmed" "${SCRATCH}/state/state.sexp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #40: Mass subscribe
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4B-10 add-sub-batch adds multiple addresses from stdin" {
    printf 'batch1@example.com\nbatch2@example.com\nbatch3@example.com\n' \
      | "${ADMIN_BIN}" --home "${SCRATCH}" add-sub-batch mlisp-discuss
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" == *"batch1@example.com"* ]]
    [[ "$output" == *"batch2@example.com"* ]]
    [[ "$output" == *"batch3@example.com"* ]]
}

@test "V4B-11 add-sub-batch from file adds addresses" {
    printf 'file1@example.com\nfile2@example.com\n' > "${SCRATCH}/addrs.txt"
    run "${ADMIN_BIN}" --home "${SCRATCH}" add-sub-batch mlisp-discuss "${SCRATCH}/addrs.txt"
    [ "$status" -eq 0 ]
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" == *"file1@example.com"* ]]
}

@test "V4B-12 add-sub-batch is idempotent" {
    printf 'idem@example.com\n' | "${ADMIN_BIN}" --home "${SCRATCH}" add-sub-batch mlisp-discuss
    printf 'idem@example.com\n' | "${ADMIN_BIN}" --home "${SCRATCH}" add-sub-batch mlisp-discuss
    # Should have exactly one entry
    count=$(grep -c "idem@example.com" "${SCRATCH}/state/state.sexp")
    [ "$count" -eq 1 ]
}

@test "V4B-13 add-sub-batch skips blank lines and # comments" {
    printf '# this is a comment\n\ngood@example.com\n   \n# another comment\n' \
      | "${ADMIN_BIN}" --home "${SCRATCH}" add-sub-batch mlisp-discuss
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" == *"good@example.com"* ]]
}

@test "V4B-14 add-sub-batch supports Name <addr> format" {
    printf 'Alice Smith <alice@example.com>\n' \
      | "${ADMIN_BIN}" --home "${SCRATCH}" add-sub-batch mlisp-discuss
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" == *"alice@example.com"* ]]
}

@test "V4B-15 rm-sub-batch removes multiple addresses" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss del1@example.com 2>/dev/null
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss del2@example.com 2>/dev/null
    printf 'del1@example.com\ndel2@example.com\n' \
      | "${ADMIN_BIN}" --home "${SCRATCH}" rm-sub-batch mlisp-discuss
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" != *"del1@example.com"* ]]
    [[ "$output" != *"del2@example.com"* ]]
}
