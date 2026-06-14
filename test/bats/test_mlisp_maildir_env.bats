#!/usr/bin/env bats
# test/bats/test_mlisp_maildir_env.bats
# BDD specs for $MAILDIR env var support in (maildir-root).
#
# Per POSIX/freedesktop.org convention, honored by smartlist, procmail,
# debbugs, and notmuch: $MAILDIR (Maildir-format mail spool root) is the
# FIRST place mlisp's internal per-list/per-package Maildir archives are
# resolved -- lists live at $MAILDIR/lists/<list-id>/. When $MAILDIR is
# unset, archives fall back to $MLISP_HOME/state/maildir/<list-id>/ so
# mlisp works out of the box with zero environment configuration.
#
# This is distinct from the per-list `set-option <list> maildir-path
# <path>` mechanism (src/maildir.lisp's maybe-archive-to-maildir), which
# is an opt-in EXTERNAL archive copy for notmuch/mutt and is unaffected
# by $MAILDIR.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BUGS_BIN="${MLISP_HOME_ORIG}/bin/mlisp-bugs"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/maildir" "${SCRATCH}/bin"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"  "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp  "${SCRATCH}/templates/"

    printf '#!/bin/sh\ncat > /dev/null\nexit 0\n' > "${SCRATCH}/bin/sendmail"
    chmod +x "${SCRATCH}/bin/sendmail"

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export BUGS_BIN ADMIN_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

@test "MDENV-1 without \$MAILDIR, bug archive lands under state/maildir/" {
    "${ADMIN_BIN}" bugs-add-package mlisp bugs@x.com
    printf 'From: a@x.com\r\nSubject: bug1\r\n\r\nPackage: mlisp\r\nSeverity: normal\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp

    [ -n "$(find "${SCRATCH}/state/maildir/mlisp-bugs/new" -type f 2>/dev/null)" ]
}

@test "MDENV-2 with \$MAILDIR set, bug archive lands under \$MAILDIR/lists/" {
    export MAILDIR="${SCRATCH}/maildir"
    "${ADMIN_BIN}" bugs-add-package mlisp bugs@x.com
    printf 'From: a@x.com\r\nSubject: bug1\r\n\r\nPackage: mlisp\r\nSeverity: normal\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp

    [ -n "$(find "${SCRATCH}/maildir/lists/mlisp-bugs/new" -type f 2>/dev/null)" ]
    # nothing written to the state/maildir fallback
    [ ! -d "${SCRATCH}/state/maildir/mlisp-bugs" ]
}

@test "MDENV-3 bugs-list finds bugs archived under \$MAILDIR" {
    export MAILDIR="${SCRATCH}/maildir"
    "${ADMIN_BIN}" bugs-add-package mlisp bugs@x.com
    printf 'From: a@x.com\r\nSubject: findme\r\n\r\nPackage: mlisp\r\nSeverity: normal\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp

    run "${ADMIN_BIN}" bugs-list mlisp
    [ "$status" -eq 0 ]
    [[ "$output" == *"findme"* ]]
}

@test "MDENV-4 bugs-list with different \$MAILDIR than write does not find the bug" {
    export MAILDIR="${SCRATCH}/maildir"
    "${ADMIN_BIN}" bugs-add-package mlisp bugs@x.com
    printf 'From: a@x.com\r\nSubject: findme\r\n\r\nPackage: mlisp\r\nSeverity: normal\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp

    # bugs-list without MAILDIR looks in state/maildir/, a different root
    unset MAILDIR
    run "${ADMIN_BIN}" bugs-list mlisp
    [ "$status" -eq 0 ]
    [[ "$output" != *"findme"* ]]
}

@test "MDENV-5 empty \$MAILDIR is treated as unset (falls back to state/maildir/)" {
    export MAILDIR=""
    "${ADMIN_BIN}" bugs-add-package mlisp bugs@x.com
    printf 'From: a@x.com\r\nSubject: bug1\r\n\r\nPackage: mlisp\r\nSeverity: normal\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp

    [ -n "$(find "${SCRATCH}/state/maildir/mlisp-bugs/new" -type f 2>/dev/null)" ]
}

@test "MDENV-6 set-option maildir-path (external archive) is unaffected by \$MAILDIR" {
    export MAILDIR="${SCRATCH}/maildir"
    EXTERNAL="${SCRATCH}/external-archive"

    "${ADMIN_BIN}" set-option mlisp-discuss maildir-path "${EXTERNAL}"

    printf 'From: dwight@example.com\r\nSubject: hello\r\n\r\nbody\r\n' \
      | "${MLISP_HOME_ORIG}/bin/mlisp" mlisp-discuss

    # external archive (explicit maildir-path) used as-is, not under $MAILDIR/lists/
    [ -d "${EXTERNAL}/new" ]
    count=$(ls "${EXTERNAL}/new/" | wc -l)
    [ "$count" -ge 1 ]
    [ ! -d "${SCRATCH}/maildir/lists/mlisp-discuss" ]
}
