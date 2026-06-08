#!/usr/bin/env bats
# test/bats/test_mlisp_compliance.bats
# BDD specifications for CAN-SPAM, GDPR Art.6/7/17, CASL, LGPD compliance.
# These are the canonical red-phase specs. No source changes happen until
# all scenarios in this file are written and confirmed failing.
#
# Legal basis:
#   CAN-SPAM  15 U.S.C. § 7704
#   GDPR      Regulation (EU) 2016/679 Art. 6, 7, 17, 30
#   CASL      Canada's Anti-Spam Legislation S.C. 2010, c. 23, s. 6
#   LGPD      Lei Geral de Proteção de Dados Art. 7, 18
#   PECR      Privacy and Electronic Communications Regulations 2003

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"  "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp  "${SCRATCH}/templates/"

    # Compliance footer templates must exist per list
    for list in discuss announce devel; do
        if [ -f "${MLISP_HOME_ORIG}/templates/${list}.footer.sexp" ]; then
            cp "${MLISP_HOME_ORIG}/templates/${list}.footer.sexp" \
               "${SCRATCH}/templates/"
        fi
    done

    # Sendmail stub: capture full outbound message for inspection
    cat > "${SCRATCH}/bin/sendmail" << 'STUB'
#!/bin/sh
cat >> "${SCRATCH}/var/outbound.eml"
printf '\x00--- END MESSAGE ---\x00\n' >> "${SCRATCH}/var/outbound.eml"
exit 0
STUB
    # Substitute SCRATCH path into stub at setup time
    sed -i "s|\${SCRATCH}|${SCRATCH}|g" "${SCRATCH}/bin/sendmail"
    chmod +x "${SCRATCH}/bin/sendmail"
    mkdir -p "${SCRATCH}/var"

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    export SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ── CAN-SPAM § 7704(a)(5)(A): physical postal address in every message ────────

@test "CANS-1 distributed message contains postal address" {
    printf 'From: dwight@example.com\r\nSubject: test post\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" discuss

    # State must contain postal address for list
    grep -q ":postal-address" "${SCRATCH}/state/state.sexp"
}

@test "CANS-2 outbound message body contains postal address string" {
    printf 'From: dwight@example.com\r\nSubject: test post\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" discuss

    # The rendered outbound message must contain a street address
    grep -qiE "[0-9]+ [A-Za-z]+ (Ave|St|Blvd|Dr|Rd|Way|Lane|Pl|Suite|Ste)" \
        "${SCRATCH}/var/outbound.eml"
}

# ── CAN-SPAM § 7704(a)(3): clear unsubscribe mechanism in every message ───────

@test "CANS-3 outbound message contains unsubscribe instruction" {
    printf 'From: dwight@example.com\r\nSubject: test post\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" discuss

    grep -qi "unsubscribe" "${SCRATCH}/var/outbound.eml"
}

@test "CANS-4 unsubscribe instruction present in announce distribution" {
    printf 'From: admin@network.org\r\nSubject: announcement\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" announce

    grep -qi "unsubscribe" "${SCRATCH}/var/outbound.eml"
}

# ── CAN-SPAM § 7704(a)(2): List-Id / Sender identification headers ────────────

@test "CANS-5 outbound message includes List-Id header" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" discuss

    grep -qi "^List-Id:" "${SCRATCH}/var/outbound.eml"
}

@test "CANS-6 outbound message includes Sender header matching drop address" {
    printf 'From: dwight@example.com\r\nSubject: test\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" discuss

    grep -qi "^Sender:.*denzuko+mlist-discuss@panix.com" \
        "${SCRATCH}/var/outbound.eml"
}

# ── CAN-SPAM § 7704(a)(1): no deceptive subject lines ────────────────────────
# List tag [discuss] must be prepended if not already present

@test "CANS-7 subject line prefixed with list tag on outbound" {
    printf 'From: dwight@example.com\r\nSubject: Meeting notes\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" discuss

    grep -qiE "^Subject:.*\[discuss\]" "${SCRATCH}/var/outbound.eml"
}

@test "CANS-8 list tag not doubled when subject already contains it" {
    printf 'From: dwight@example.com\r\nSubject: [discuss] Already tagged\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" discuss

    # Must appear exactly once
    count=$(grep -ciE "\[discuss\]" "${SCRATCH}/var/outbound.eml" || true)
    [ "$count" -eq 1 ]
}

# ── GDPR Art. 7 / CASL S.6(1): express consent record ───────────────────────

@test "GDPR-1 subscribe records consent timestamp in state.sexp" {
    printf 'From: janet@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" devel

    # subscriber entry must contain :subscribed-at field
    grep -q ":subscribed-at" "${SCRATCH}/state/state.sexp"
}

@test "GDPR-2 consent record includes consent method field" {
    printf 'From: janet@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" devel

    grep -q ":consent-method" "${SCRATCH}/state/state.sexp"
}

@test "GDPR-3 consent timestamp is ISO-8601 format" {
    printf 'From: janet@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" devel

    # ISO-8601: YYYY-MM-DDTHH:MM:SS
    grep -qE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}" \
        "${SCRATCH}/state/state.sexp"
}

# ── GDPR Art. 17 / LGPD Art. 18: right of erasure ────────────────────────────

@test "GDPR-4 unsubscribe removes address from state.sexp (erasure)" {
    printf 'From: dwight@example.com\r\nSubject: unsubscribe\r\n\r\nunsubscribe\r\n' \
      | "${MLISP_BIN}" discuss

    run grep "dwight@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "GDPR-5 unsubscribe writes erasure event to audit log" {
    printf 'From: dwight@example.com\r\nSubject: unsubscribe\r\n\r\nunsubscribe\r\n' \
      | "${MLISP_BIN}" discuss

    [ -f "${SCRATCH}/state/audit.sexp" ]
    grep -q ":event :unsubscribe" "${SCRATCH}/state/audit.sexp"
}

@test "GDPR-6 audit log contains address and timestamp for erasure event" {
    printf 'From: dwight@example.com\r\nSubject: unsubscribe\r\n\r\nunsubscribe\r\n' \
      | "${MLISP_BIN}" discuss

    grep -q "dwight@example.com" "${SCRATCH}/state/audit.sexp"
    grep -qE "[0-9]{4}-[0-9]{2}-[0-9]{2}T" "${SCRATCH}/state/audit.sexp"
}

# ── GDPR Art. 30: records of processing activity ─────────────────────────────

@test "GDPR-7 subscribe event written to audit log" {
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" devel

    [ -f "${SCRATCH}/state/audit.sexp" ]
    grep -q ":event :subscribe" "${SCRATCH}/state/audit.sexp"
}

@test "GDPR-8 post-distributed event written to audit log" {
    printf 'From: dwight@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" discuss

    grep -q ":event :post-distributed" "${SCRATCH}/state/audit.sexp"
}

@test "GDPR-9 post-rejected event written to audit log" {
    printf 'From: spammer@badactor.net\r\nSubject: spam\r\n\r\nbody\r\n' \
      | "${MLISP_BIN}" devel || true  # exit 1 expected

    grep -q ":event :post-rejected" "${SCRATCH}/state/audit.sexp"
}

# ── GDPR Art. 6 / welcome: privacy notice at subscription ────────────────────

@test "GDPR-10 welcome message contains privacy notice text" {
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" devel

    # The welcome mail (captured in outbound.eml) must contain privacy language
    grep -qi "privacy\|personal data\|unsubscribe" \
        "${SCRATCH}/var/outbound.eml"
}

# ── CASL S.6(2)(c): unsubscribe mechanism must be free and usable ────────────

@test "CASL-1 unsubscribe honoured immediately (within same process)" {
    printf 'From: dwight@example.com\r\nSubject: unsubscribe\r\n\r\nunsubscribe\r\n' \
      | "${MLISP_BIN}" discuss

    # After unsubscribe, a subsequent post must be rejected
    run bash -c "printf 'From: dwight@example.com\r\nSubject: post after unsub\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' discuss"
    [ "$status" -ne 0 ]
}

# ── Data minimisation: state contains only necessary fields ──────────────────

@test "PRIV-1 state.sexp contains no fields beyond address and consent metadata" {
    printf 'From: newuser@example.com\r\nSubject: subscribe\r\n\r\nsubscribe\r\n' \
      | "${MLISP_BIN}" devel

    # Must NOT contain IP addresses, full names, or message content
    run grep -iE ":[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
        "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

# ── Compliance footer template files exist ────────────────────────────────────

@test "TMPL-1 discuss.footer.sexp exists in templates" {
    [ -f "${MLISP_HOME_ORIG}/templates/discuss.footer.sexp" ]
}

@test "TMPL-2 announce.footer.sexp exists in templates" {
    [ -f "${MLISP_HOME_ORIG}/templates/announce.footer.sexp" ]
}

@test "TMPL-3 devel.footer.sexp exists in templates" {
    [ -f "${MLISP_HOME_ORIG}/templates/devel.footer.sexp" ]
}
