#!/usr/bin/env bats
# test/bats/test_mlisp_v04a.bats
# BDD specs for issues #33-35, #37-38:
#   max message size, Reply-To munging, NOMAIL,
#   non-member post policy, list locking.

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
# ISSUE #33: Max message size
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4A-1 post under max-message-size-kb is delivered" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss max-message-size-kb 10
    run bash -c "printf 'From: dwight@example.com\r\nSubject: small\r\n\r\nhello\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V4A-2 post over max-message-size-kb is rejected (exit 1)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss max-message-size-kb 1
    # Build a >1KB message body
    body=$(python3 -c "print('x' * 1100)")
    run bash -c "printf 'From: dwight@example.com\r\nSubject: big\r\n\r\n${body}\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -ne 0 ]
}

@test "V4A-3 oversized post is not distributed to subscribers" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss max-message-size-kb 1
    body=$(python3 -c "print('x' * 1100)")
    printf 'From: dwight@example.com\r\nSubject: big\r\n\r\n'"${body}"'\r\n' \
      | "${MLISP_BIN}" mlisp-discuss || true
    run grep "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "V4A-4 max-message-size-kb 0 disables size check" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss max-message-size-kb 0
    body=$(python3 -c "print('x' * 5000)")
    run bash -c "printf 'From: dwight@example.com\r\nSubject: big\r\n\r\n${body}\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #34: Reply-To munging
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4A-5 reply-to-munging none preserves original Reply-To" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss reply-to-munging none
    printf 'From: dwight@example.com\r\nReply-To: personal@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "Reply-To: personal@example.com" "${SCRATCH}/var/outbound.eml"
}

@test "V4A-6 reply-to-munging list sets Reply-To to list address" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss reply-to-munging list
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "Reply-To:.*mlisp-discuss" "${SCRATCH}/var/outbound.eml"
}

@test "V4A-7 reply-to-munging poster sets Reply-To to sender" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss reply-to-munging poster
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "Reply-To:.*dwight@example.com" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #35: Per-subscriber NOMAIL
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4A-8 nomail command via -request suspends delivery" {
    # Clear all seed subscribers from discuss, add only our test address
    "${ADMIN_BIN}" --home "${SCRATCH}" rm-sub mlisp-discuss dwight@example.com 2>/dev/null || true
    "${ADMIN_BIN}" --home "${SCRATCH}" rm-sub mlisp-discuss admin@network.org 2>/dev/null || true
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss nomail-test@example.com 2>/dev/null || true
    # Set nomail via -request
    printf 'From: nomail-test@example.com\r\nSubject: nomail\r\n\r\nnomail\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    # Flush any prior output
    : > "${SCRATCH}/var/outbound.eml"
    # Post to list — nomail-test should not receive it (only subscriber, has nomail)
    printf 'From: nomail-test@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss || true
    run grep "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "V4A-9 mail command via -request resumes delivery" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss resume-test@example.com 2>/dev/null || true
    printf 'From: resume-test@example.com\r\nSubject: nomail\r\n\r\nnomail\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    printf 'From: resume-test@example.com\r\nSubject: mail\r\n\r\nmail\r\n' \
      | "${MLISP_BIN}" --mode request mlisp-request
    : > "${SCRATCH}/var/outbound.eml"
    printf 'From: resume-test@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "V4A-10 mlisp-admin set-nomail sets flag directly" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" set-nomail mlisp-discuss dwight@example.com true
    [ "$status" -eq 0 ]
}

@test "V4A-11 list-subs shows NOMAIL flag for suspended subscribers" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-nomail mlisp-discuss dwight@example.com true
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" == *"NOMAIL"* ]] || [[ "$output" == *"nomail"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #37: Non-member post policy
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4A-12 non-member-action reject returns error (default)" {
    run bash -c "printf 'From: outsider@example.com\r\nSubject: hi\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -ne 0 ]
}

@test "V4A-13 non-member-action hold queues post, exits 0" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss non-member-action hold
    run bash -c "printf 'From: outsider@example.com\r\nSubject: hi\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/state/held/mlisp-discuss.sexp" ]
}

@test "V4A-14 non-member-action discard silently drops, exits 0" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss non-member-action discard
    run bash -c "printf 'From: outsider@example.com\r\nSubject: spam\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    run grep "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "V4A-15 non-member-action discard writes audit event" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss non-member-action discard
    printf 'From: outsider@example.com\r\nSubject: spam\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -q ":event :non-member-discard" "${SCRATCH}/state/audit.sexp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE #38: List locking
# ═══════════════════════════════════════════════════════════════════════════════

@test "V4A-16 mlisp-admin lock sets :locked t" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" lock mlisp-discuss
    [ "$status" -eq 0 ]
    grep -q ":locked t" "${SCRATCH}/state/state.sexp"
}

@test "V4A-17 post to locked list goes to held queue" {
    "${ADMIN_BIN}" --home "${SCRATCH}" lock mlisp-discuss
    printf 'From: dwight@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    [ -f "${SCRATCH}/state/held/mlisp-discuss.sexp" ]
}

@test "V4A-18 post to locked list exits 0 (not an error)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" lock mlisp-discuss
    run bash -c "printf 'From: dwight@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "V4A-19 mlisp-admin unlock clears :locked flag" {
    "${ADMIN_BIN}" --home "${SCRATCH}" lock mlisp-discuss
    run "${ADMIN_BIN}" --home "${SCRATCH}" unlock mlisp-discuss
    [ "$status" -eq 0 ]
    run grep ":locked t" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "V4A-20 post to unlocked list delivers normally" {
    "${ADMIN_BIN}" --home "${SCRATCH}" lock mlisp-discuss
    "${ADMIN_BIN}" --home "${SCRATCH}" unlock mlisp-discuss
    run bash -c "printf 'From: dwight@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}
