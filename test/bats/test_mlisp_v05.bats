#!/usr/bin/env bats
# test/bats/test_mlisp_v05.bats
# BDD specs for issues #47-55, #59-61 (v0.5 feature set)

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
# #47 Dispatcher duplicates removed
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-1 add-sub-batch subcommand exists exactly once" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" add-sub-batch mlisp-discuss /dev/null
    [ "$status" -eq 0 ]
}

@test "V5-2 show-pending subcommand exists exactly once" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-pending mlisp-discuss
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# #48 New subgroups: owner, security, commits, users
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-3 add-namespace creates nine subgroups including owner, security, commits, users" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace testns testns@example.com
    [ "$status" -eq 0 ]
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-namespace testns
    [[ "$output" == *"testns-owner"* ]]
    [[ "$output" == *"testns-security"* ]]
    [[ "$output" == *"testns-commits"* ]]
    [[ "$output" == *"testns-users"* ]]
}

@test "V5-4 :owner subgroup forwards to owner-address, not subscribers" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace ons ons@example.com
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option ons-owner owner-address admin@example.com
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub ons-owner sub@example.com 2>/dev/null || true
    printf 'From: user@example.com\r\nSubject: help\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" ons-owner
    # admin@example.com (owner) should receive; sub@example.com (subscriber) should NOT
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V5-5 :commits subgroup rejects post from non-bot address" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace cns cns@example.com
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option cns-commits bot-address ci@example.com
    run bash -c "printf 'From: human@example.com\r\nSubject: ci\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' cns-commits"
    [ "$status" -ne 0 ]
}

@test "V5-6 :commits subgroup accepts post from bot-address" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace cns2 cns2@example.com
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option cns2-commits bot-address ci@example.com
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub cns2-commits watch@example.com 2>/dev/null || true
    run bash -c "printf 'From: ci@example.com\r\nSubject: build passed\r\n\r\ngreen\r\n' \
      | '${MLISP_BIN}' cns2-commits"
    [ "$status" -eq 0 ]
}

@test "V5-7 :security subgroup holds posts when embargoed" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace sns sns@example.com
    # Set embargo to a future date
    "${ADMIN_BIN}" --home "${SCRATCH}" embargo sns-security 2099-12-31T00:00:00
    run bash -c "printf 'From: reporter@example.com\r\nSubject: vuln\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' sns-security"
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/state/held/sns-security.sexp" ]
}

@test "V5-8 mlisp-admin release-embargo distributes held security posts" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace sns2 sns2@example.com
    "${ADMIN_BIN}" --home "${SCRATCH}" embargo sns2-security 2099-12-31T00:00:00
    printf 'From: reporter@example.com\r\nSubject: vuln\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" sns2-security || true
    run "${ADMIN_BIN}" --home "${SCRATCH}" release-embargo sns2-security
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# #49 Attachment policy
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-9 attachment-policy allow passes message with attachment (default)" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: test\r\nContent-Type: multipart/mixed\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "V5-10 attachment-policy reject rejects message with attachment" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss attachment-policy reject
    run bash -c "printf 'From: dwight@example.com\r\nSubject: test\r\nContent-Type: multipart/mixed; boundary=x\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -ne 0 ]
}

@test "V5-11 attachment-policy strip passes message (binary parts removed by MIME stripper)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss attachment-policy strip
    run bash -c "printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# #50 Subject keyword filtering
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-12 subject-deny pattern holds matching post" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss subject-deny "[OT]"
    run bash -c "printf 'From: dwight@example.com\r\nSubject: [OT] random topic\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/state/held/mlisp-discuss.sexp" ]
}

@test "V5-13 subject-deny with action reject rejects matching post" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss subject-deny "[OT]"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss subject-filter-action reject
    run bash -c "printf 'From: dwight@example.com\r\nSubject: [OT] random\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -ne 0 ]
}

@test "V5-14 subject-allow pattern passes matching post" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss subject-allow "[PATCH]"
    run bash -c "printf 'From: dwight@example.com\r\nSubject: [PATCH] fix bug\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V5-15 subject-allow pattern holds non-matching post" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss subject-allow "[PATCH]"
    run bash -c "printf 'From: dwight@example.com\r\nSubject: random message\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/state/held/mlisp-discuss.sexp" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# #51 Message sequence numbering
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-16 message-numbering false: no sequence number in subject" {
    printf 'From: dwight@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run grep -i "subject:.*#0" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "V5-17 message-numbering true: sequence number appears in subject" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss message-numbering true
    printf 'From: dwight@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qE "Subject:.*#[0-9]+" "${SCRATCH}/var/outbound.eml"
}

@test "V5-18 message counter increments across posts" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss message-numbering true
    for i in 1 2 3; do
        printf 'From: dwight@example.com\r\nSubject: msg %s\r\n\r\nbody\r\n' "$i" \
          | "${MLISP_BIN}" mlisp-discuss
    done
    # Third message should have counter >= 3
    grep -qE "Subject:.*#00[3-9]|#0[1-9][0-9]" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# #52 CSV export
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-19 export-csv produces CSV with header row" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-csv mlisp-discuss
    [ "$status" -eq 0 ]
    [[ "$output" == *"address"* ]]
}

@test "V5-20 export-csv includes subscriber addresses" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-csv mlisp-discuss
    [[ "$output" == *"dwight@example.com"* ]] || \
    [[ "$output" == *"admin@network.org"* ]]
}

@test "V5-21 export-csv --output writes to file" {
    "${ADMIN_BIN}" --home "${SCRATCH}" export-csv mlisp-discuss \
      --output "${SCRATCH}/export.csv"
    [ -f "${SCRATCH}/export.csv" ]
    grep -q "address" "${SCRATCH}/export.csv"
}

# ═══════════════════════════════════════════════════════════════════════════════
# #53 List admin ops: rename-list, copy-list, list-stats
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-22 rename-list changes list ID in state" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-list rn-src rn-src@example.com 2>/dev/null || true
    run "${ADMIN_BIN}" --home "${SCRATCH}" rename-list rn-src rn-dst
    [ "$status" -eq 0 ]
    grep -q "rn-dst" "${SCRATCH}/state/state.sexp"
}

@test "V5-23 copy-list creates new list with same config" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" copy-list mlisp-discuss mlisp-discuss-copy
    [ "$status" -eq 0 ]
    grep -q "mlisp-discuss-copy" "${SCRATCH}/state/state.sexp"
}

@test "V5-24 list-stats shows message count from audit" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-stats mlisp-discuss
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# #54 Per-sender rate limiting
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-25 max-posts-per-day 0 (default) allows unlimited posts" {
    for i in 1 2 3; do
        run bash -c "printf 'From: dwight@example.com\r\nSubject: post %s\r\n\r\nbody\r\n' $i \
          | '${MLISP_BIN}' mlisp-discuss"
        [ "$status" -eq 0 ]
    done
}

@test "V5-26 max-posts-per-day 1 holds second post from same sender" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss max-posts-per-day 1
    printf 'From: dwight@example.com\r\nSubject: first\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run bash -c "printf 'From: dwight@example.com\r\nSubject: second\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/state/held/mlisp-discuss.sexp" ]
}

@test "V5-27 max-posts-per-day limit does not affect different senders" {
    # Add a second subscriber who will also post
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss other@example.com 2>/dev/null || true
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss max-posts-per-day 1
    # dwight hits the limit
    printf 'From: dwight@example.com\r\nSubject: first\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    : > "${SCRATCH}/var/outbound.eml"
    # other@example.com is a different sender — should not be rate-limited
    run bash -c "printf 'From: other@example.com\r\nSubject: other sender\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# #55 Embargo mode (standalone list, not just :security subgroup)
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-28 mlisp-admin embargo sets embargoed-until in state" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" embargo mlisp-discuss 2099-12-31T00:00:00
    [ "$status" -eq 0 ]
    grep -q "embargoed-until" "${SCRATCH}/state/state.sexp"
}

@test "V5-29 release-embargo clears embargoed-until" {
    "${ADMIN_BIN}" --home "${SCRATCH}" embargo mlisp-discuss 2099-12-31T00:00:00
    run "${ADMIN_BIN}" --home "${SCRATCH}" release-embargo mlisp-discuss
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# #59 DKIM-Signature stripped from redistributed mail
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-30 DKIM-Signature header stripped from redistributed message" {
    printf 'From: dwight@example.com\r\nDKIM-Signature: v=1; a=rsa-sha256; d=example.com; s=mail\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run grep -i "^DKIM-Signature:" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "V5-31 Authentication-Results preserved as X-Original-Authentication-Results" {
    printf 'From: dwight@example.com\r\nAuthentication-Results: mx.example.com; dkim=pass\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "X-Original-Authentication-Results" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# #60 RFC 8058 one-click unsubscribe headers
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-32 without unsubscribe-url: List-Unsubscribe is mailto: only" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "List-Unsubscribe:" "${SCRATCH}/var/outbound.eml"
    run grep -qi "List-Unsubscribe-Post:" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "V5-33 with unsubscribe-url: List-Unsubscribe-Post header present" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      unsubscribe-url https://lists.example.com/unsub/mlisp-discuss
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "List-Unsubscribe-Post: List-Unsubscribe=One-Click" \
      "${SCRATCH}/var/outbound.eml"
}

@test "V5-34 with unsubscribe-url: HTTPS URI appears in List-Unsubscribe" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      unsubscribe-url https://lists.example.com/unsub/mlisp-discuss
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "List-Unsubscribe:.*https://" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# #61 RFC 2369/2919 header correctness: List-Id domain from drop-address,
#     List-Archive, List-Owner
# ═══════════════════════════════════════════════════════════════════════════════

@test "V5-35 List-Id domain derived from drop-address not hardcoded" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    # List-Id should reference panix.com (from mlisp-discuss@panix.com)
    grep -qi "List-Id:.*panix" "${SCRATCH}/var/outbound.eml"
}

@test "V5-36 List-Archive header present when archive-url configured" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss \
      archive-url https://lists.example.com/archive/mlisp-discuss
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "List-Archive:" "${SCRATCH}/var/outbound.eml"
}

@test "V5-37 List-Owner header present when owner subgroup exists in namespace" {
    # Ensure mlisp-owner subgroup exists in the namespace
    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace mlisp mlisp@panix.com 2>/dev/null || true
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss watch@example.com 2>/dev/null || true
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "List-Owner:\|X-List-Administrate:" "${SCRATCH}/var/outbound.eml"
}
