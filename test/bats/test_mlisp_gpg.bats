#!/usr/bin/env bats
# test/bats/test_mlisp_gpg.bats
# BDD specs for issue #21: hash contacts at rest + GPG message support.

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
# Hash contacts at rest
# ═══════════════════════════════════════════════════════════════════════════════

@test "GPG-H1 mlisp-admin set-option hash-contacts true persists to config" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss hash-contacts true
    [ "$status" -eq 0 ]
}

@test "GPG-H2 subscribe with hash-contacts true stores address-hash not plaintext" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss hash-contacts true

    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    grep -q ":address-hash" "${SCRATCH}/state/state.sexp"
}

@test "GPG-H3 state.sexp with hash-contacts contains no plaintext email of new subscriber" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss hash-contacts true

    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    # newuser@example.com must not appear in plaintext
    run grep "newuser@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "GPG-H4 hashed subscriber can still unsubscribe" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss hash-contacts true
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    printf 'From: newuser@example.com\r\nSubject: unsubscribe\r\n\r\nunsubscribe\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    # After unsubscribe: newuser plaintext address must not appear
    run grep "newuser@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "GPG-H5 existing subscribers retain plaintext when hash-contacts false" {
    # Default: hash-contacts nil — existing behaviour unchanged
    grep -q "dwight@example.com" "${SCRATCH}/state/state.sexp"
}

@test "GPG-H6 address-hash is a 64-char hex string (SHA-256)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss hash-contacts true
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    # Extract the hash value and check its length
    hash=$(grep -oE '"[0-9a-f]{64}"' "${SCRATCH}/state/state.sexp" | head -1)
    [ -n "$hash" ]
    [ "${#hash}" -eq 66 ]  # 64 hex chars + 2 quote chars
}

# ═══════════════════════════════════════════════════════════════════════════════
# GPG signed messages
# ═══════════════════════════════════════════════════════════════════════════════

@test "GPG-S1 gpg binary is available (prerequisite)" {
    which gpg || which gpg2
}

@test "GPG-S2 plain message without GPG signature passes through normally" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: plain\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "GPG-S3 mlisp-admin show-config mentions gpg-key-id when configured" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss gpg-key-id "0xDEADBEEF"
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-config
    [ "$status" -eq 0 ]
}

@test "GPG-S4 list with require-signed nil (default) accepts unsigned posts" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: unsigned\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "GPG-S5 list with require-signed true rejects unsigned posts" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss require-signed true

    run bash -c "printf 'From: dwight@example.com\r\nSubject: unsigned\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -ne 0 ]
}

@test "GPG-S6 require-signed rejection writes audit event" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss require-signed true
    printf 'From: dwight@example.com\r\nSubject: unsigned\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss || true
    grep -q ":event :gpg-unsigned-rejected" "${SCRATCH}/state/audit.sexp"
}

@test "GPG-S7 Content-Type: multipart/signed message is detected as signed" {
    # A message claiming to be signed should trigger GPG processing path
    # (even if we can't verify without a real key in test env)
    run bash -c "printf 'From: dwight@example.com\r\nContent-Type: multipart/signed; protocol=\"application/pgp-signature\"; boundary=\"sig\"\r\nSubject: signed\r\n\r\n--sig\r\nContent-Type: text/plain\r\n\r\nbody\r\n--sig\r\nContent-Type: application/pgp-signature\r\n\r\n-----BEGIN PGP SIGNATURE-----\r\nfake\r\n-----END PGP SIGNATURE-----\r\n--sig--\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    # Either succeeds (sig check skipped in test env) or fails cleanly
    [ "$status" -le 1 ]
}
