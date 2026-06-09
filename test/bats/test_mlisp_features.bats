#!/usr/bin/env bats
# test/bats/test_mlisp_features.bats
# BDD specs for features 11-14 (unsubscribe assist, -request, headers,
# BCC privacy, bounce, auto-subscribe, metrics).
# Written RED before any source changes.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" \
             "${SCRATCH}/var" "${SCRATCH}/metrics"
    cp "${MLISP_HOME_ORIG}/state/state.sexp" "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp "${SCRATCH}/templates/"

    # Capturing sendmail stub
    cat > "${SCRATCH}/bin/sendmail" << 'STUB'
#!/bin/sh
cat >> "SCRATCH_DIR/var/outbound.eml"
printf '\x00---END---\x00\n' >> "SCRATCH_DIR/var/outbound.eml"
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
# FEATURE 11: Unsubscribe assistance + smartlist procmail compat
# ═══════════════════════════════════════════════════════════════════════════════

@test "F11-1 'remove me' in subject triggers unsubscribe" {
    printf 'From: dwight@example.com\r\nSubject: remove me\r\n\r\n\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run grep "dwight@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "F11-2 'remove' in subject triggers unsubscribe" {
    printf 'From: dwight@example.com\r\nSubject: remove\r\n\r\n\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run grep "dwight@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "F11-3 'signoff' in subject triggers unsubscribe" {
    printf 'From: dwight@example.com\r\nSubject: signoff discuss\r\n\r\n\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run grep "dwight@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "F11-4 'opt-out' in body triggers unsubscribe" {
    printf 'From: dwight@example.com\r\nSubject: hi\r\n\r\nopt-out\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run grep "dwight@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "F11-5 outbound distribution includes Precedence: list header" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^Precedence: list" "${SCRATCH}/var/outbound.eml"
}

@test "F11-6 procmail recipe includes FROM_DAEMON guard" {
    mkdir -p "${SCRATCH}/home2"
    HOME="${SCRATCH}/home2" "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run > "${SCRATCH}/recipe.txt"
    grep -q "FROM_DAEMON\|FROM_MAILER" "${SCRATCH}/recipe.txt"
}

@test "F11-7 procmail recipe includes Precedence guard" {
    mkdir -p "${SCRATCH}/home2"
    HOME="${SCRATCH}/home2" "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run > "${SCRATCH}/recipe.txt"
    grep -qi "Precedence\|precedence" "${SCRATCH}/recipe.txt"
}

# ═══════════════════════════════════════════════════════════════════════════════
# FEATURE 12: -request address and command-only mode
# ═══════════════════════════════════════════════════════════════════════════════

@test "F12-1 state.sexp contains :request-address for each list" {
    grep -q ":request-address" "${SCRATCH}/state/state.sexp"
}

@test "F12-2 mlisp --mode request rejects regular posts" {
    run bash -c "printf 'From: dwight@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' --mode request mlisp-request"
    [ "$status" -eq 1 ]
}

@test "F12-3 mlisp --mode request handles subscribe command" {
    run bash -c "printf 'From: newguy@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | '${MLISP_BIN}' --mode request mlisp-request"
    [ "$status" -eq 0 ]
    grep -q "newguy@example.com" "${SCRATCH}/state/state.sexp"
}

@test "F12-4 install-procmail emits list-request recipe for each list" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run > "${SCRATCH}/recipe.txt"
    grep -q "request" "${SCRATCH}/recipe.txt"
}

@test "F12-5 mlisp-admin add-list auto-derives :request-address" {
    "${ADMIN_BIN}" --home "${SCRATCH}" \
      add-list security denzuko+mlist-security@panix.com "Security list"
    grep -q "security-request\|request-address" "${SCRATCH}/state/state.sexp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# FEATURE 13: RFC 2369 List-* headers + Usenet headers
# ═══════════════════════════════════════════════════════════════════════════════

@test "F13-1 outbound has List-Unsubscribe header" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^List-Unsubscribe:" "${SCRATCH}/var/outbound.eml"
}

@test "F13-2 List-Unsubscribe points to request address" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "List-Unsubscribe:.*mailto:.*unsubscribe" "${SCRATCH}/var/outbound.eml"
}

@test "F13-3 outbound has List-Subscribe header" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^List-Subscribe:" "${SCRATCH}/var/outbound.eml"
}

@test "F13-4 outbound has List-Post header" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^List-Post:" "${SCRATCH}/var/outbound.eml"
}

@test "F13-5 outbound has List-Help header" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^List-Help:" "${SCRATCH}/var/outbound.eml"
}

@test "F13-6 outbound has X-Mailing-List header" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^X-Mailing-List:" "${SCRATCH}/var/outbound.eml"
}

@test "F13-7 outbound has X-BeenThere header (secondary loop guard)" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "^X-BeenThere:" "${SCRATCH}/var/outbound.eml"
}

@test "F13-8 List-Id format is RFC 2919 compliant (<name.domain>)" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qE "^List-Id: <[a-z].*\.[a-z]" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# FEATURE 8: BCC delivery + address privacy
# ═══════════════════════════════════════════════════════════════════════════════

@test "F08-1 outbound To header is list drop address not subscriber address" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    # To: should be the list drop address
    grep -qi "^To:.*mlisp-discuss@panix.com" "${SCRATCH}/var/outbound.eml"
}

@test "F08-2 outbound message does not expose other subscriber addresses" {
    # Add a second subscriber first
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss alice@example.com

    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    # alice's address must not appear in outbound headers
    run grep -i "alice@example.com" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# FEATURE 9: Bounce management
# ═══════════════════════════════════════════════════════════════════════════════

@test "F09-1 mlisp --mode bounce is accepted as a valid mode" {
    # Empty DSN — should not crash, exit 0
    run bash -c "printf 'From: mailer-daemon@panix.com\r\nContent-Type: message/delivery-status\r\n\r\n\r\n' \
      | '${MLISP_BIN}' --mode bounce mlisp-discuss"
    [ "$status" -le 1 ]
}

@test "F09-2 DSN with Final-Recipient increments bounce count in state" {
    cat > "${SCRATCH}/dsn.eml" << 'DSN'
From: mailer-daemon@example.com
To: mlisp-discuss@panix.com
Subject: Delivery Status Notification
MIME-Version: 1.0
Content-Type: multipart/report; report-type=delivery-status; boundary="b1"

--b1
Content-Type: text/plain

Delivery failed.

--b1
Content-Type: message/delivery-status

Reporting-MTA: dns; example.com
Final-Recipient: rfc822; dwight@example.com
Action: failed
Status: 5.1.1

--b1--
DSN
    "${MLISP_BIN}" --mode bounce mlisp-discuss < "${SCRATCH}/dsn.eml"
    grep -q ":bounce-count" "${SCRATCH}/state/state.sexp"
}

@test "F09-3 mlisp-admin show-bounces lists addresses with bounce count" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-bounces mlisp-discuss
    [ "$status" -eq 0 ]
}

@test "F09-4 mlisp-admin clear-bounces resets a subscriber bounce count" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" clear-bounces mlisp-discuss dwight@example.com
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# FEATURE 10: Auto-subscribe on first post
# ═══════════════════════════════════════════════════════════════════════════════

@test "F10-1 list with :auto-subscribe nil rejects unknown sender" {
    # devel has :auto-subscribe nil by default
    run bash -c "printf 'From: unknown@example.com\r\nSubject: post\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-devel"
    [ "$status" -ne 0 ]
}

@test "F10-2 list with :auto-subscribe t delivers post and adds subscriber" {
    # Enable auto-subscribe on discuss first
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss auto-subscribe true

    run bash -c "printf 'From: firstpost@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
    grep -q "firstpost@example.com" "${SCRATCH}/state/state.sexp"
}

@test "F10-3 auto-subscribe writes :auto-subscribed audit event" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss auto-subscribe true

    printf 'From: firstpost@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss

    grep -q ":event :auto-subscribed" "${SCRATCH}/state/audit.sexp"
}

@test "F10-4 mlisp-admin set-option auto-subscribe true persists to state" {
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option mlisp-discuss auto-subscribe true
    grep -q ":auto-subscribe t" "${SCRATCH}/state/state.sexp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# FEATURE 14: Prometheus metrics exporter
# ═══════════════════════════════════════════════════════════════════════════════

@test "F14-1 metrics/mlisp.prom created after first mlisp run" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    [ -f "${SCRATCH}/metrics/mlisp.prom" ]
}

@test "F14-2 metrics file contains mlisp_messages_total" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -q "mlisp_messages_total" "${SCRATCH}/metrics/mlisp.prom"
}

@test "F14-3 metrics file contains mlisp_subscribers_total gauge" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -q "mlisp_subscribers_total" "${SCRATCH}/metrics/mlisp.prom"
}

@test "F14-4 metrics labels include list name" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qE 'list="mlisp-discuss"' "${SCRATCH}/metrics/mlisp.prom"
}

@test "F14-5 mlisp-admin export-metrics writes metrics file" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" export-metrics
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/metrics/mlisp.prom" ]
}

@test "F14-6 command reply includes Disposition-Notification-To header" {
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -qi "Disposition-Notification-To\|Return-Receipt-To" \
        "${SCRATCH}/var/outbound.eml"
}

@test "F14-7 outbound contains no HTML img tags (no pixel tracking)" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    run grep -i "<img" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "F14-8 metrics file contains loop_drops counter" {
    # Trigger a loop drop
    printf 'From: dwight@example.com\r\nX-Loop-List-Mlisp-Discuss: 1\r\nSubject: loop\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    printf 'From: dwight@example.com\r\nSubject: real\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" mlisp-discuss
    grep -q "mlisp_loop_drops_total\|loop_drops" "${SCRATCH}/metrics/mlisp.prom"
}
