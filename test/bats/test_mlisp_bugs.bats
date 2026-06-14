#!/usr/bin/env bats
# test/bats/test_mlisp_bugs.bats
# BDD specs for mlisp-bugs: submit, append, close, control
# Architecture: bug state lives in the Maildir + pseudo-headers.
# state.sexp holds only bug-counter and package config.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BUGS_BIN="${MLISP_HOME_ORIG}/bin/mlisp-bugs"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" "${SCRATCH}/var"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"  "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp  "${SCRATCH}/templates/"

    printf '#!/bin/sh\ncat >> "%s/var/outbound.eml"\necho "MLISP_MSG_END" >> "%s/var/outbound.eml"\nexit 0\n' \
      "${SCRATCH}" "${SCRATCH}" > "${SCRATCH}/bin/sendmail"
    chmod +x "${SCRATCH}/bin/sendmail"

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export BUGS_BIN ADMIN_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ═══════════════════════════════════════════════════════════════════════════════
# Package registration
# ═══════════════════════════════════════════════════════════════════════════════

@test "BUG-1 bugs-add-package creates package config in state.sexp" {
    run "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner maintainer@example.com
    [ "$status" -eq 0 ]
    grep -q "mlisp" "${SCRATCH}/state/state.sexp"
}

@test "BUG-2 bugs-add-package sets bug-counter to 0" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    grep -q "bug-counter" "${SCRATCH}/state/state.sexp"
    grep "bug-counter" "${SCRATCH}/state/state.sexp" | grep -q "0"
}

@test "BUG-3 bugs-list-packages shows registered packages" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    run "${ADMIN_BIN}" bugs-list-packages
    [ "$status" -eq 0 ]
    [[ "$output" == *"mlisp"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Submit mode: new bug
# ═══════════════════════════════════════════════════════════════════════════════

@test "BUG-4 submit assigns bug #1 to first report" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: alice@example.com\r\nSubject: memory leak in parser\r\n\r\nPackage: mlisp\r\nSeverity: important\r\n\r\nThe parser leaks on large inputs.\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    grep -q "Bug#1" "${SCRATCH}/var/outbound.eml"
}

@test "BUG-5 submit increments bug counter in state.sexp" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: a@example.com\r\nSubject: bug one\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: b@example.com\r\nSubject: bug two\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    grep "bug-counter" "${SCRATCH}/state/state.sexp" | grep -q "2"
}

@test "BUG-6 submit injects pseudo-header block above original body" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: alice@example.com\r\nSubject: crash on empty input\r\n\r\nPackage: mlisp\r\nSeverity: critical\r\n\r\nReproduction: echo "" | mlisp\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    # Pseudo-headers must appear BEFORE original body
    grep -q "Reported-by: alice@example.com" "${SCRATCH}/var/outbound.eml"
    grep -q "Date:" "${SCRATCH}/var/outbound.eml"
    grep -q "Message-ID:" "${SCRATCH}/var/outbound.eml"
}

@test "BUG-7 submit subject becomes Bug#N: original subject" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: a@example.com\r\nSubject: crash on empty input\r\nMessage-ID: <abc@example.com>\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    grep -qi "Subject:.*Bug#1:.*crash on empty input" "${SCRATCH}/var/outbound.eml"
}

@test "BUG-8 submit distributes to package owner and reporter" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner maintainer@example.com
    printf 'From: reporter@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    # outbound.eml should have multiple MLISP_MSG_END (one per recipient)
    count=$(grep -c "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml")
    [ "$count" -ge 1 ]
}

@test "BUG-9 submit archives message to Maildir" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    [ -d "${SCRATCH}/state/maildir/mlisp-bugs/new" ]
    [ "$(ls "${SCRATCH}/state/maildir/mlisp-bugs/new" | wc -l)" -ge 1 ]
}

@test "BUG-10 submit with default severity when not specified" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: a@example.com\r\nSubject: minor issue\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    grep -q "Severity: normal" "${SCRATCH}/var/outbound.eml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Append mode: reply to existing bug thread
# ═══════════════════════════════════════════════════════════════════════════════

@test "BUG-11 append distributes reply to bug thread" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner maintainer@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    : > "${SCRATCH}/var/outbound.eml"
    printf 'From: maintainer@example.com\r\nSubject: Re: Bug#1: bug\r\n\r\nCan you reproduce on v0.6?\r\n' \
      | "${BUGS_BIN}" --mode append mlisp 1
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "BUG-12 append archives reply to Maildir" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: b@example.com\r\nSubject: Re: Bug#1: bug\r\n\r\nreply\r\n' \
      | "${BUGS_BIN}" --mode append mlisp 1
    count=$(ls "${SCRATCH}/state/maildir/mlisp-bugs/new" | wc -l)
    [ "$count" -ge 2 ]
}

@test "BUG-13 append to nonexistent bug exits non-zero" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    run bash -c "printf 'From: a@example.com\r\nSubject: Re: Bug#99\r\n\r\ntext\r\n' \
      | '${BUGS_BIN}' --mode append mlisp 99"
    [ "$status" -ne 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Close mode: bug-N-done
# ═══════════════════════════════════════════════════════════════════════════════

@test "BUG-14 close mode writes closed status to Maildir" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner maintainer@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: maintainer@example.com\r\nSubject: Re: Bug#1: bug\r\n\r\nFixed in v0.6.1.\r\n' \
      | "${BUGS_BIN}" --mode close mlisp 1
    # Closed marker is a message in the archive with [CLOSED] in subject
    grep -rl "CLOSED" "${SCRATCH}/state/maildir/mlisp-bugs/new/" | grep -q .
}

@test "BUG-15 close sends notification to original reporter and owner" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner maintainer@example.com
    printf 'From: reporter@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    : > "${SCRATCH}/var/outbound.eml"
    printf 'From: maintainer@example.com\r\nSubject: Fixed\r\n\r\nFixed.\r\n' \
      | "${BUGS_BIN}" --mode close mlisp 1
    grep -q "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml"
}

@test "BUG-16 bugs-show reports open status for open bug" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: a@example.com\r\nSubject: open bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"open"* ]]
}

@test "BUG-17 bugs-show reports closed status after close" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: m@example.com\r\nSubject: Fixed\r\n\r\nFixed.\r\n' \
      | "${BUGS_BIN}" --mode close mlisp 1
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [[ "$output" == *"closed"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Control mode: structured commands
# ═══════════════════════════════════════════════════════════════════════════════

@test "BUG-18 control severity command updates severity in archive" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: m@example.com\r\nSubject: control\r\n\r\nseverity 1 critical\r\n' \
      | "${BUGS_BIN}" --mode control mlisp
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [[ "$output" == *"critical"* ]]
}

@test "BUG-19 control tags+ command adds tag" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: m@example.com\r\nSubject: control\r\n\r\ntags 1 + patch\r\n' \
      | "${BUGS_BIN}" --mode control mlisp
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [[ "$output" == *"patch"* ]]
}

@test "BUG-20 control tags- command removes tag" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\nTags: patch\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: m@example.com\r\nSubject: control\r\n\r\ntags 1 - patch\r\n' \
      | "${BUGS_BIN}" --mode control mlisp
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [[ "$output" != *"patch"* ]]
}

@test "BUG-21 control retitle command changes bug title in archive" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: vague title\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: m@example.com\r\nSubject: control\r\n\r\nretitle 1 specific crash in parse-headers\r\n' \
      | "${BUGS_BIN}" --mode control mlisp
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [[ "$output" == *"specific crash in parse-headers"* ]]
}

@test "BUG-22 control owner command assigns owner" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: m@example.com\r\nSubject: control\r\n\r\nowner 1 alice@example.com\r\n' \
      | "${BUGS_BIN}" --mode control mlisp
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [[ "$output" == *"alice@example.com"* ]]
}

@test "BUG-23 control close command closes bug" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: m@example.com\r\nSubject: control\r\n\r\nclose 1\r\n' \
      | "${BUGS_BIN}" --mode control mlisp
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [[ "$output" == *"closed"* ]]
}

@test "BUG-24 control quit stops processing remaining commands" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    # quit before close — bug should remain open
    printf 'From: m@example.com\r\nSubject: control\r\n\r\nquit\r\nclose 1\r\n' \
      | "${BUGS_BIN}" --mode control mlisp
    run "${ADMIN_BIN}" bugs-show mlisp 1
    [[ "$output" == *"open"* ]]
}

@test "BUG-25 control comment lines (# prefix) are ignored" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    run bash -c "printf 'From: m@example.com\r\nSubject: control\r\n\r\n# this is a comment\nseverity 1 minor\r\n' \
      | '${BUGS_BIN}' --mode control mlisp"
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# #70 bugs-report: periodic status summary
# ═══════════════════════════════════════════════════════════════════════════════

@test "BUG-26 bugs-report shows open bug count" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    for i in 1 2 3; do
        printf 'From: a@example.com\r\nSubject: bug %s\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' "$i" \
          | "${BUGS_BIN}" --mode submit mlisp
    done
    run "${ADMIN_BIN}" bugs-report mlisp
    [ "$status" -eq 0 ]
    [[ "$output" == *"3"* ]]
}

@test "BUG-27 bugs-report --closed shows only closed bugs" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: open bug\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: a@example.com\r\nSubject: will close\r\n\r\nPackage: mlisp\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: m@example.com\r\nSubject: Fixed\r\n\r\nFixed.\r\n' \
      | "${BUGS_BIN}" --mode close mlisp 2
    run "${ADMIN_BIN}" bugs-report mlisp --closed
    [[ "$output" == *"will close"* ]]
    [[ "$output" != *"open bug"* ]]
}

@test "BUG-28 bugs-report --severity filters by severity" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com \
      --owner m@example.com
    printf 'From: a@example.com\r\nSubject: critical bug\r\n\r\nPackage: mlisp\r\nSeverity: critical\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    printf 'From: a@example.com\r\nSubject: minor issue\r\n\r\nPackage: mlisp\r\nSeverity: minor\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp
    run "${ADMIN_BIN}" bugs-report mlisp --severity critical
    [[ "$output" == *"critical bug"* ]]
    [[ "$output" != *"minor issue"* ]]
}

@test "BUG-29 procmail recipes for all four bug addresses generated" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    run "${ADMIN_BIN}" install-bugs-procmail mlisp --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"bugs-submit"* ]]
    [[ "$output" == *"bugs-control"* ]]
    [[ "$output" == *"mode submit"* ]]
    [[ "$output" == *"mode control"* ]]
}

@test "BUG-30 bugs-report --summarize appends Summary section from external command output" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    printf 'From: a@x.com\r\nSubject: crash\r\n\r\nPackage: mlisp\r\nSeverity: critical\r\n\r\nbody\r\n' \
      | "${BUGS_BIN}" --mode submit mlisp

    run "${ADMIN_BIN}" bugs-report mlisp --summarize "tr a-z A-Z"
    [ "$status" -eq 0 ]
    # Report itself still present, unmodified
    [[ "$output" == *"Bug report for mlisp"* ]]
    # Summary section present, with the report's content uppercased
    [[ "$output" == *"--- Summary (via tr a-z A-Z) ---"* ]]
    [[ "$output" == *"BUG REPORT FOR MLISP"* ]]
}

@test "BUG-31 bugs-report without --summarize has no Summary section" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com
    run "${ADMIN_BIN}" bugs-report mlisp
    [ "$status" -eq 0 ]
    [[ "$output" != *"--- Summary"* ]]
}

@test "BUG-32 bugs-report --summarize with a failing command warns but still prints report" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com

    run "${ADMIN_BIN}" bugs-report mlisp --summarize "/no/such/command"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Bug report for mlisp"* ]]
    [[ "$output" != *"--- Summary"* ]]
    [[ "$output" == *"--summarize command"*"exited"* ]]
}

@test "BUG-33 bugs-report --summarize with empty output (exit 0) warns, no Summary section" {
    "${ADMIN_BIN}" bugs-add-package mlisp mlisp-bugs-submit@panix.com

    # Simulates neural.sh's curl|while|xargs pipeline, which exits 0
    # with empty stdout when curl fails to connect (e.g. no Ollama
    # running at the configured endpoint).
    run "${ADMIN_BIN}" bugs-report mlisp --summarize "true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Bug report for mlisp"* ]]
    [[ "$output" != *"--- Summary"* ]]
    [[ "$output" == *"--summarize command"*"produced no output"* ]]
}

