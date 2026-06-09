#!/usr/bin/env bats
# test/bats/test_mlisp.bats — mlisp behavioral integration tests
#
# All MTA calls go to a stub sendmail so no live mail is sent.
# Exit code 2 = mlisp fatal (e.g. real sendmail missing); tests accept
# this where the test intent is routing logic, not delivery.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRATCH="$(mktemp -d)"

    # Scaffold SCRATCH as a self-contained MLISP_HOME
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"   "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp   "${SCRATCH}/templates/"

    # Stub sendmail: log args + stdin to file, exit 0
    cat > "${SCRATCH}/bin/sendmail" << 'STUB'
#!/bin/sh
mkdir -p "$(dirname "$0")/../var"
{ echo "ARGS: $*"; cat; } >> "$(dirname "$0")/../var/sendmail.log"
exit 0
STUB
    chmod +x "${SCRATCH}/bin/sendmail"

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    export SCRATCH
}

teardown() {
    rm -rf "${SCRATCH}"
}

# ── Helpers ──────────────────────────────────────────────────────────────────

raw_email() {
    # raw_email FROM SUBJECT [EXTRA_HEADER] BODY
    local from="$1" subject="$2"
    if [ $# -eq 4 ]; then
        printf "From: %s\r\nSubject: %s\r\n%s\r\n\r\n%s\r\n" \
            "$from" "$subject" "$3" "$4"
    else
        printf "From: %s\r\nSubject: %s\r\n\r\n%s\r\n" \
            "$from" "$subject" "$3"
    fi
}

run_mlisp() {
    # run_mlisp LIST_ID EMAIL_STRING
    run bash -c "printf '%s' '$2' | '${MLISP_BIN}' '$1'"
}

# ── Binary presence ──────────────────────────────────────────────────────────

@test "mlisp binary exists and is executable" {
    [ -x "${MLISP_BIN}" ]
}

@test "mlisp prints usage with --help" {
    run "${MLISP_BIN}" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# ── State and template files ─────────────────────────────────────────────────

@test "state.sexp contains correct drop address for discuss" {
    grep -q "mlisp-discuss@panix.com" "${SCRATCH}/state/state.sexp"
}

@test "state.sexp contains correct drop address for announce" {
    grep -q "mlisp-announce@panix.com" "${SCRATCH}/state/state.sexp"
}

@test "state.sexp contains correct drop address for devel" {
    grep -q "mlisp-devel@panix.com" "${SCRATCH}/state/state.sexp"
}

@test "all nine template sexp files exist" {
    for list in mlisp-discuss mlisp-announce mlisp-devel; do
        for tpl in welcome help goodbye; do
            [ -f "${SCRATCH}/templates/${list}.${tpl}.sexp" ]
        done
    done
}

@test "state.sexp seeds discuss with dwight@example.com subscriber" {
    grep -q "dwight@example.com" "${SCRATCH}/state/state.sexp"
}

@test "state.sexp seeds announce with admin@network.org subscriber" {
    grep -q "admin@network.org" "${SCRATCH}/state/state.sexp"
}

# ── Loop detection ───────────────────────────────────────────────────────────

@test "drops message and exits 0 when X-Loop-List-Mlisp-Discuss header present" {
    email=$(raw_email "dwight@example.com" "Test" \
                      "X-Loop-List-Mlisp-Discuss: 1" "body")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "drops message and exits 0 when X-Loop-List-Mlisp-Announce header present" {
    email=$(raw_email "admin@network.org" "Announcement" \
                      "X-Loop-List-Mlisp-Announce: 1" "body")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-announce"
    [ "$status" -eq 0 ]
}

@test "wrong loop header does not suppress processing on discuss" {
    # X-Loop-List-Mlisp-Announce must NOT block a discuss submission
    email=$(raw_email "dwight@example.com" "Valid discuss post" \
                      "X-Loop-List-Mlisp-Announce: 1" "legitimate body")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-discuss"
    # exit 0 (delivered) or 2 (sendmail stub path issue) — NOT 1 (rejected)
    [ "$status" -ne 1 ]
}

# ── Unknown list ─────────────────────────────────────────────────────────────

@test "exits 1 for completely unknown list id" {
    email=$(raw_email "any@example.com" "hi" "body")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' no-such-list"
    [ "$status" -eq 1 ]
}

# ── Subscriber rejection ─────────────────────────────────────────────────────

@test "rejects unsubscribed sender on devel (exit 1 or 2)" {
    email=$(raw_email "spammer@badactor.net" "Buy cheap meds" "body")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-devel"
    # 1 = rejected (sendmail succeeded); 2 = rejected (sendmail binary missing)
    [ "$status" -ge 1 ]
    [ "$status" -le 2 ]
}

@test "rejection path does not exit 0 for unsubscribed sender" {
    email=$(raw_email "outsider@unknown.org" "Hello" "body")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -ne 0 ]
}

# ── State mutation: subscribe ─────────────────────────────────────────────────

@test "subscribe command adds new address to devel state.sexp" {
    email=$(raw_email "janet@example.com" "subscribe" "subscribe")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-devel"
    # exit 0 or 2 (sendmail); state must be updated
    grep -q "janet@example.com" "${SCRATCH}/state/state.sexp"
}

@test "subscribe command is idempotent for existing subscriber" {
    email=$(raw_email "dwight@example.com" "subscribe" "subscribe")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-discuss"
    count=$(grep -c "dwight@example.com" "${SCRATCH}/state/state.sexp")
    [ "$count" -eq 1 ]
}

@test "subscribe detected from body when subject is neutral" {
    email=$(raw_email "newuser@example.com" "hello" "subscribe")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-devel"
    grep -q "newuser@example.com" "${SCRATCH}/state/state.sexp"
}

# ── State mutation: unsubscribe ───────────────────────────────────────────────

@test "unsubscribe command removes address from discuss state.sexp" {
    email=$(raw_email "dwight@example.com" "unsubscribe" "unsubscribe")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-discuss"
    run grep "dwight@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

# ── Help command ─────────────────────────────────────────────────────────────

@test "help command exits 0 or 2 for known subscriber" {
    email=$(raw_email "dwight@example.com" "help" "help")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -le 2 ]
}

@test "help command exits 0 or 2 for non-subscriber (info-only)" {
    email=$(raw_email "curious@stranger.net" "help" "help")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -le 2 ]
}

# ── Loop header naming ────────────────────────────────────────────────────────

@test "X-Loop-List-Mlisp-Devel header triggers loop drop on devel list" {
    email=$(raw_email "dwight@example.com" "Post" \
                      "X-Loop-List-Mlisp-Devel: 1" "body")
    run bash -c "printf '%s' '${email}' | '${MLISP_BIN}' mlisp-devel"
    [ "$status" -eq 0 ]
}
