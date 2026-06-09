#!/usr/bin/env bats
# test/bats/test_mlisp_namespace.bats
# BDD specifications for namespace-subgroup address convention.
# Issue #30: listid-subgroup@host model.
#
# Subgroup roles:
#   :discuss   — subscriber-writable, moderated general discussion
#   :announce  — owner-post-only notifications
#   :devel     — patches and VCS traffic, subscriber-writable
#   :distrib   — binary attachment channel
#   :request   — command-only (subscribe/unsubscribe/help)

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" "${SCRATCH}/var"
    cp "${MLISP_HOME_ORIG}/state/state.sexp" "${SCRATCH}/state/"
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
# add-namespace: creates all 5 subgroup records at once
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-1 mlisp-admin add-namespace creates all 5 subgroup records" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    [ "$status" -eq 0 ]
    grep -q '"mlisp-discuss"'  "${SCRATCH}/state/state.sexp"
    grep -q '"mlisp-announce"' "${SCRATCH}/state/state.sexp"
    grep -q '"mlisp-devel"'    "${SCRATCH}/state/state.sexp"
    grep -q '"mlisp-distrib"'  "${SCRATCH}/state/state.sexp"
    grep -q '"mlisp-request"'  "${SCRATCH}/state/state.sexp"
}

@test "NS-2 add-namespace generates correct drop addresses" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    grep -q "mlisp-discuss@panix.com"  "${SCRATCH}/state/state.sexp"
    grep -q "mlisp-announce@panix.com" "${SCRATCH}/state/state.sexp"
    grep -q "mlisp-devel@panix.com"    "${SCRATCH}/state/state.sexp"
    grep -q "mlisp-distrib@panix.com"  "${SCRATCH}/state/state.sexp"
    grep -q "mlisp-request@panix.com"  "${SCRATCH}/state/state.sexp"
}

@test "NS-3 add-namespace records :subgroup for each list" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    grep -q ":subgroup :discuss"  "${SCRATCH}/state/state.sexp"
    grep -q ":subgroup :announce" "${SCRATCH}/state/state.sexp"
    grep -q ":subgroup :devel"    "${SCRATCH}/state/state.sexp"
    grep -q ":subgroup :distrib"  "${SCRATCH}/state/state.sexp"
    grep -q ":subgroup :request"  "${SCRATCH}/state/state.sexp"
}

@test "NS-4 add-namespace --subgroups limits which subgroups are created" {
    # Use a new namespace not in seed state
    run "${ADMIN_BIN}" --home "${SCRATCH}" \
      add-namespace testns test@example.com --subgroups discuss,request
    [ "$status" -eq 0 ]
    grep -q '"testns-discuss"' "${SCRATCH}/state/state.sexp"
    grep -q '"testns-request"' "${SCRATCH}/state/state.sexp"
    run grep '"testns-devel"' "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "NS-5 add-namespace is idempotent (safe to run twice)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    run "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    [ "$status" -eq 0 ]
    count=$(grep -c '"mlisp-discuss"' "${SCRATCH}/state/state.sexp")
    [ "$count" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# list-namespace: namespace prefix extraction
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-6 mlisp-admin list-namespace shows all subgroups for a namespace" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-namespace mlisp
    [ "$status" -eq 0 ]
    [[ "$output" == *"mlisp-discuss"*  ]]
    [[ "$output" == *"mlisp-request"*  ]]
    [[ "$output" == *":discuss"*       ]]
    [[ "$output" == *":request"*       ]]
}

@test "NS-7 list-namespace on unknown namespace exits 1" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-namespace no-such-ns
    [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# -request subgroup: command routing
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-8 mlisp-request list rejects posts (--mode request behaviour)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    run bash -c "printf 'From: user@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' --mode request mlisp-request"
    [ "$status" -eq 1 ]
}

@test "NS-9 subscribe command to -request subscribes to sibling subgroup" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    printf 'From: newuser@example.com\r\nSubject: subscribe discuss\r\n\r\nsubscribe discuss\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -q "newuser@example.com" "${SCRATCH}/state/state.sexp"
}

@test "NS-10 -request subscribe without subgroup name subscribes to -discuss" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    grep -q "newuser@example.com" "${SCRATCH}/state/state.sexp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# -announce subgroup: owner-post-only
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-11 post to -announce from non-owner is rejected" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    run bash -c "printf 'From: subscriber@example.com\r\nSubject: announcement\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-announce"
    [ "$status" -ne 0 ]
}

@test "NS-12 post to -announce from list owner is accepted" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    "${ADMIN_BIN}" --home "${SCRATCH}" \
      set-option mlisp-announce owner-address owner@example.com
    run bash -c "printf 'From: owner@example.com\r\nSubject: Release v1.0\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-announce"
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# -discuss subgroup: standard moderated list behaviour
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-13 subscriber can post to -discuss" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss dwight@example.com
    run bash -c "printf 'From: dwight@example.com\r\nSubject: hi\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "NS-14 non-subscriber cannot post to -discuss" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    run bash -c "printf 'From: outsider@example.com\r\nSubject: hi\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# -devel subgroup: subscriber-writable, patch-friendly
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-15 subscriber can post to -devel" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-devel dwight@example.com
    run bash -c "printf 'From: dwight@example.com\r\nSubject: [PATCH] fix typo\r\n\r\n--- a/foo\n+++ b/foo\r\n' \
      | '${MLISP_BIN}' mlisp-devel"
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# List-* headers use subgroup-aware request address
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-16 List-Unsubscribe points to -request sibling not self" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss dwight@example.com
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "List-Unsubscribe:.*mlisp-request" "${SCRATCH}/var/outbound.eml"
}

@test "NS-17 List-Id uses namespace-subgroup format" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss dwight@example.com
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "List-Id:.*mlisp-discuss" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# procmail: install-procmail for a namespace
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-18 install-procmail for namespace generates 5 recipe blocks" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    count=$(grep -c "^:0" "${HOME}/.procmailrc")
    [ "$count" -ge 5 ]
}

@test "NS-19 dry-run install-procmail shows all namespace subgroup recipes" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run
    [[ "$output" == *"mlisp-discuss"*  ]]
    [[ "$output" == *"mlisp-request"*  ]]
    [[ "$output" == *"mlisp-announce"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Seed state.sexp uses namespace-subgroup convention
# ═══════════════════════════════════════════════════════════════════════════════

@test "NS-20 default state.sexp uses mlisp-subgroup@host pattern" {
    grep -q "mlisp-discuss"  "${MLISP_HOME_ORIG}/state/state.sexp"
    grep -q "mlisp-announce" "${MLISP_HOME_ORIG}/state/state.sexp"
    grep -q "mlisp-request"  "${MLISP_HOME_ORIG}/state/state.sexp"
}

@test "NS-21 default state.sexp has :subgroup fields" {
    grep -q ":subgroup" "${MLISP_HOME_ORIG}/state/state.sexp"
}
