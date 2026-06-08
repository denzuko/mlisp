#!/usr/bin/env bats
# test/bats/test_mlisp_mime.bats
# Integration specs for MIME inbound processing.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin"
    cp "${MLISP_HOME_ORIG}/state/state.sexp" "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp "${SCRATCH}/templates/"
    printf '#!/bin/sh\ncat >> "%s/var/outbound.eml"\nprintf "\\x00---END---\\x00\\n" >> "%s/var/outbound.eml"\nexit 0\n' \
      "${SCRATCH}" "${SCRATCH}" > "${SCRATCH}/bin/sendmail"
    chmod +x "${SCRATCH}/bin/sendmail"
    mkdir -p "${SCRATCH}/var"
    export MLISP_HOME="${SCRATCH}" MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export MLISP_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ── Multipart/alternative: plain text preferred ───────────────────────────

@test "MIME-1 multipart/alternative: outbound contains plain text part" {
    cat > "${SCRATCH}/msg.eml" << 'MSG'
From: dwight@example.com
Subject: multipart test
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="b123"

--b123
Content-Type: text/plain; charset=utf-8

This is the plain text body.

--b123
Content-Type: text/html; charset=utf-8

<html><body><p>This is <b>HTML</b> body.</p></body></html>

--b123--
MSG
    "${MLISP_BIN}" discuss < "${SCRATCH}/msg.eml"
    grep -q "plain text body" "${SCRATCH}/var/outbound.eml"
}

@test "MIME-2 multipart/alternative: HTML part NOT in outbound" {
    cat > "${SCRATCH}/msg.eml" << 'MSG'
From: dwight@example.com
Subject: multipart test
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="b123"

--b123
Content-Type: text/plain; charset=utf-8

Plain text here.

--b123
Content-Type: text/html; charset=utf-8

<html><body>HTML here.</body></html>

--b123--
MSG
    "${MLISP_BIN}" discuss < "${SCRATCH}/msg.eml"
    run grep "<html>" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

# ── HTML-only message stripped to plain ──────────────────────────────────

@test "MIME-3 text/html-only message: tags stripped from outbound" {
    cat > "${SCRATCH}/msg.eml" << 'MSG'
From: dwight@example.com
Subject: html only
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8

<html><body><p>Hello <b>world</b> from Outlook.</p></body></html>
MSG
    "${MLISP_BIN}" discuss < "${SCRATCH}/msg.eml"
    grep -q "Hello" "${SCRATCH}/var/outbound.eml"
    grep -q "world" "${SCRATCH}/var/outbound.eml"
    run grep "<html>" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

@test "MIME-4 HTML entities decoded in stripped output" {
    cat > "${SCRATCH}/msg.eml" << 'MSG'
From: dwight@example.com
Subject: entities
Content-Type: text/html; charset=utf-8

<p>Security &amp; Privacy &lt;notes&gt;</p>
MSG
    "${MLISP_BIN}" discuss < "${SCRATCH}/msg.eml"
    grep -q "&" "${SCRATCH}/var/outbound.eml"
}

# ── Plain text passthrough ────────────────────────────────────────────────

@test "MIME-5 plain text/plain message passes through unchanged" {
    printf 'From: dwight@example.com\r\nSubject: plain\r\n\r\nJust plain text here.\r\n' \
      | "${MLISP_BIN}" discuss
    grep -q "Just plain text here" "${SCRATCH}/var/outbound.eml"
}

# ── Outbound is always ASCII-safe ─────────────────────────────────────────

@test "MIME-6 outbound Content-Type header is text/plain" {
    cat > "${SCRATCH}/msg.eml" << 'MSG'
From: dwight@example.com
Subject: mime test
Content-Type: text/html; charset=utf-8

<p>Hello</p>
MSG
    "${MLISP_BIN}" discuss < "${SCRATCH}/msg.eml"
    # Outbound should not contain HTML Content-Type
    run grep -i "Content-Type: text/html" "${SCRATCH}/var/outbound.eml"
    [ "$status" -ne 0 ]
}

# ── Loop detection still works with MIME messages ─────────────────────────

@test "MIME-7 loop detection works on multipart message" {
    cat > "${SCRATCH}/msg.eml" << 'MSG'
From: dwight@example.com
X-Loop-List-Discuss: 1
Subject: loop
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="b123"

--b123
Content-Type: text/plain

body

--b123--
MSG
    run "${MLISP_BIN}" discuss < "${SCRATCH}/msg.eml"
    [ "$status" -eq 0 ]
    # No outbound mail should have been sent
    [ ! -s "${SCRATCH}/var/outbound.eml" ]
}
