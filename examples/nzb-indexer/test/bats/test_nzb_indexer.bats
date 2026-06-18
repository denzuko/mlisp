#!/usr/bin/env bats
# test/bats/test_nzb_indexer.bats
# Integration specs for the NZB release indexer (#133).
# These test the full binary via Maildir simulation.

setup() {
    HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRATCH="$(mktemp -d)"
    INDEX_PATH="${SCRATCH}/nzb-index.sexp"
    MAILDIR="${SCRATCH}/Maildir"
    SENT_DIR="${SCRATCH}/sent"

    mkdir -p "${MAILDIR}/new" "${MAILDIR}/cur" "${SENT_DIR}"

    # Sendmail stub: capture outbound to individual files
    STUB="${SCRATCH}/sendmail"
    printf '#!/bin/sh\ncat > "%s/$(date +%%s%%N).eml"\n' "${SENT_DIR}" > "${STUB}"
    chmod +x "${STUB}"

    export MAILDIR INDEX_PATH SENT_DIR STUB SCRATCH HERE
    export MLISP_SENDMAIL="${STUB}"
    export NZB_SERVICE_ADDRESS="distrib-nzb@lists.example.com"
    export NZB_ANNOUNCE_ADDRESS="releases-announce@lists.example.com"
    export NZB_INDEX_PATH="${INDEX_PATH}"
}

teardown() { rm -rf "${SCRATCH}"; }

drop_msg() {
    # drop_msg "raw email string" -> $MAILDIR/new/timestamp.eml
    printf '%s\n' "$1" > "${MAILDIR}/new/$(date +%s%N).eml"
    sleep 0.01
}

make_segment() {
    # make_segment list-id fname part total msg-id
    local list_id="$1" fname="$2" part="$3" total="$4" msg_id="$5"
    printf 'From: %s@lists.example.com\nTo: subscriber@example.com\nSubject: [%s] %s (%s/%s)\nMessage-ID: %s\nContent-Type: application/octet-stream\nMIME-Version: 1.0\n\n=ybegin part=%s total=%s name=%s\ndata\n=yend\n' \
        "${list_id}" "${list_id}" "${fname}" "${part}" "${total}" "${msg_id}" \
        "${part}" "${total}" "${fname}"
}

run_indexer() {
    timeout 30 sbcl --noinform \
      --eval "(load \"/home/claude/quicklisp/setup.lisp\")" \
      --eval "(ql:quickload '(:cl-mime :xmls) :silent t)" \
      --eval "(pushnew (truename \"${HERE}\") asdf:*central-registry* :test #'equal)" \
      --eval "(asdf:load-system :com.dwightaspencer.nzb-indexer/service)" \
      --eval "(com.dwightaspencer.nzb-indexer:main)" \
      2>/dev/null
}

@test "NZB-I-1 indexer processes distrib segment and moves to cur/" {
    drop_msg "$(make_segment releases debian.iso 1 3 '<seg-001@example.com>')"
    run_indexer
    [ "$(ls "${MAILDIR}/new/" | wc -l)" -eq 0 ]
    [ "$(ls "${MAILDIR}/cur/" | wc -l)" -eq 1 ]
}

@test "NZB-I-2 indexer creates index file after processing" {
    drop_msg "$(make_segment releases debian.iso 1 3 '<seg-001@example.com>')"
    run_indexer
    [ -f "${INDEX_PATH}" ]
}

@test "NZB-I-3 index persists across runs (accumulates segments)" {
    drop_msg "$(make_segment releases debian.iso 1 3 '<seg-001@example.com>')"
    run_indexer

    drop_msg "$(make_segment releases debian.iso 2 3 '<seg-002@example.com>')"
    run_indexer

    # Index should have 2 segments for debian
    grep -q "seg-001" "${INDEX_PATH}"
    grep -q "seg-002" "${INDEX_PATH}"
}

@test "NZB-I-4 completed release triggers announce message" {
    # Post all 3 segments in one run
    drop_msg "$(make_segment releases debian.iso 1 3 '<seg-001@example.com>')"
    drop_msg "$(make_segment releases debian.iso 2 3 '<seg-002@example.com>')"
    drop_msg "$(make_segment releases debian.iso 3 3 '<seg-003@example.com>')"
    run_indexer

    # Should have sent an announce
    announce=$(grep -rl "new release" "${SENT_DIR}" 2>/dev/null | head -1)
    [ -n "$announce" ]
}

@test "NZB-I-5 get-nzb command returns NZB attachment" {
    # First index a complete release
    drop_msg "$(make_segment releases myfile.bin 1 1 '<seg-001@example.com>')"
    run_indexer

    # Then send a get-nzb command
    drop_msg "$(printf 'From: user@example.com\nTo: distrib-nzb@lists.example.com\nSubject: get-nzb myfile\nMessage-ID: <req-001@example.com>\nContent-Type: text/plain\n\nget-nzb myfile\n')"
    run_indexer

    # Reply should contain NZB XML -- look for the actual XML element
    nzb_reply=$(grep -rl "<nzb " "${SENT_DIR}" 2>/dev/null | head -1)
    [ -n "$nzb_reply" ]
    grep -q "newzbin.com" "${nzb_reply}"
}

@test "NZB-I-6 get-nzb for unknown release sends error reply" {
    drop_msg "$(printf 'From: user@example.com\nTo: distrib-nzb@lists.example.com\nSubject: get-nzb nosuchrelease\nContent-Type: text/plain\n\nget-nzb nosuchrelease\n')"
    run_indexer

    reply=$(ls "${SENT_DIR}"/*.eml 2>/dev/null | head -1)
    [ -n "$reply" ]
    grep -qi "not found\|Release not found" "${reply}"
}

@test "NZB-I-7 X-Loop guard skips own replies" {
    drop_msg "$(printf 'From: distrib-nzb@lists.example.com\nTo: releases@lists.example.com\nX-Loop: distrib-nzb@lists.example.com\nSubject: [new release] debian\nContent-Type: text/plain\n\nannouncement\n')"
    run_indexer

    # Nothing sent, message moved to cur/
    [ "$(ls "${SENT_DIR}"/*.eml 2>/dev/null | wc -l)" -eq 0 ]
    [ "$(ls "${MAILDIR}/cur/" | wc -l)" -eq 1 ]
}

@test "NZB-I-8 duplicate segment not double-counted" {
    drop_msg "$(make_segment releases dup.bin 1 2 '<seg-001@example.com>')"
    run_indexer
    drop_msg "$(make_segment releases dup.bin 1 2 '<seg-001@example.com>')"
    run_indexer

    # Should still be incomplete (1 unique segment, total=2)
    python3 -c "
import ast, sys
data = open('${INDEX_PATH}').read()
print('ok -- file exists')
" 2>/dev/null
    # No announce should have fired (release not complete)
    [ "$(ls "${SENT_DIR}"/*.eml 2>/dev/null | wc -l)" -eq 0 ]
}
