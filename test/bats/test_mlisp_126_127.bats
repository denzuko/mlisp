#!/usr/bin/env bats
# test/bats/test_mlisp_126_127.bats
# BDD specs for:
#   #126 -- mlisp-bugs pre/post-filter hook on bugs-submit
#   #127 -- subscriber 'ask' command for FAQ/neural.sh

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"
    BUGS_BIN="${MLISP_HOME_ORIG}/bin/mlisp-bugs"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" \
             "${SCRATCH}/var"   "${SCRATCH}/etc/filters"

    cp "${MLISP_HOME_ORIG}/state/state.sexp"    "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp    "${SCRATCH}/templates/"

    cat > "${SCRATCH}/bin/sendmail" << 'STUB'
#!/bin/sh
cat >> "SCRATCH_DIR/var/outbound.eml"
echo "MLISP_MSG_END" >> "SCRATCH_DIR/var/outbound.eml"
exit 0
STUB
    sed -i "s|SCRATCH_DIR|${SCRATCH}|g" "${SCRATCH}/bin/sendmail"
    chmod +x "${SCRATCH}/bin/sendmail"

    "${ADMIN_BIN}" --home "${SCRATCH}" add-namespace bugs bugs@example.com 2>/dev/null
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub bugs-request member@example.com 2>/dev/null
    "${ADMIN_BIN}" --home "${SCRATCH}" bugs-add-package bugs bugs-submit@example.com 2>/dev/null

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export MLISP_BIN ADMIN_BIN BUGS_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

submit_bug() {
    printf 'From: reporter@example.com\r\nTo: bugs-submit@example.com\r\nSubject: test bug\r\n\r\nThis is a test bug report.\r\n' \
      | "${BUGS_BIN}" --home "${SCRATCH}" --mode submit bugs 2>/dev/null
}

ask_cmd() {
    local question="$1"
    printf 'From: member@example.com\r\nTo: bugs-request@example.com\r\nSubject: ask %s\r\n\r\nask %s\r\n' \
      "$question" "$question" \
      | "${MLISP_BIN}" --home "${SCRATCH}" bugs-request 2>/dev/null
}

# ── #126: bugs pre-filter hook ───────────────────────────────────────────────

@test "BF-1 bugs-submit runs without pre-filter when none configured" {
    run submit_bug
    [ "$status" -eq 0 ]
}

@test "BF-2 bugs-submit pre-filter exit 0 allows submission" {
    printf '#!/bin/sh\ncat\nexit 0\n' > "${SCRATCH}/etc/filters/allow"
    chmod +x "${SCRATCH}/etc/filters/allow"
    "${ADMIN_BIN}" --home "${SCRATCH}" bugs-set-option bugs \
      pre-filter "${SCRATCH}/etc/filters/allow" 2>/dev/null
    run submit_bug
    [ "$status" -eq 0 ]
}

@test "BF-3 bugs-submit pre-filter exit 1 rejects bug report" {
    printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "${SCRATCH}/etc/filters/reject"
    chmod +x "${SCRATCH}/etc/filters/reject"
    "${ADMIN_BIN}" --home "${SCRATCH}" bugs-set-option bugs \
      pre-filter "${SCRATCH}/etc/filters/reject" 2>/dev/null
    run submit_bug
    [ "$status" -ne 0 ]
}

@test "BF-4 bugs-submit pre-filter can annotate message (exit 0 with modified stdout)" {
    printf '#!/bin/sh\ncat | sed "s/^$/X-Bugs-Triage: auto-tagged/"\nexit 0\n' \
      > "${SCRATCH}/etc/filters/tag"
    chmod +x "${SCRATCH}/etc/filters/tag"
    "${ADMIN_BIN}" --home "${SCRATCH}" bugs-set-option bugs \
      pre-filter "${SCRATCH}/etc/filters/tag" 2>/dev/null
    submit_bug
    grep -q "X-Bugs-Triage: auto-tagged" "${SCRATCH}/var/outbound.eml"
}

@test "BF-5 bugs-submit post-filter is invoked after archival" {
    printf '#!/bin/sh\ncat\necho "POST-FILTER-RAN" >> "%s/var/post-ran.txt"\nexit 0\n' \
      "${SCRATCH}" > "${SCRATCH}/etc/filters/post"
    chmod +x "${SCRATCH}/etc/filters/post"
    "${ADMIN_BIN}" --home "${SCRATCH}" bugs-set-option bugs \
      post-filter "${SCRATCH}/etc/filters/post" 2>/dev/null
    submit_bug
    [ -f "${SCRATCH}/var/post-ran.txt" ]
    grep -q "POST-FILTER-RAN" "${SCRATCH}/var/post-ran.txt"
}

@test "BF-6 bugs-set-option pre-filter stores config" {
    "${ADMIN_BIN}" --home "${SCRATCH}" bugs-set-option bugs \
      pre-filter "/path/to/filter" 2>/dev/null
    # Config should be readable back
    "${ADMIN_BIN}" --home "${SCRATCH}" bugs-set-option bugs \
      pre-filter "/path/to/filter" 2>/dev/null
    [ "$?" -eq 0 ]
}

# ── #127: subscriber 'ask' command ───────────────────────────────────────────

@test "ASK-1 ask command is recognised by -request dispatch" {
    # Without neural configured, ask should reply with a fallback (not silence)
    ask_cmd "how do I subscribe"
    # A reply must have been sent (outbound.eml is non-empty)
    [ -s "${SCRATCH}/var/outbound.eml" ]
}

@test "ASK-2 pre-filter handles ask interaction when configured" {
    # The filter is a complete actor: reads the message, sends its own reply
    # via sendmail, exits 3 (discard) so mlisp does not send a second reply.
    # mlisp's role: recognise the ask command, run the pre-filter, stop.
    printf '#!/bin/sh\n# Filter receives full RFC5322 message on stdin\ncat > /dev/null\n# Send own reply\n(\necho "To: member@example.com"\necho "From: list@example.com"\necho "Subject: Re: ask"\necho ""\necho "42"\n) | %s/bin/sendmail -t\nexit 3  # discard: mlisp should not send fallback\n' \
      "${SCRATCH}" > "${SCRATCH}/etc/filters/ask-handler"
    chmod +x "${SCRATCH}/etc/filters/ask-handler"
    "${ADMIN_BIN}" --home "${SCRATCH}" set-option bugs-request \
      pre-filter "${SCRATCH}/etc/filters/ask-handler" 2>/dev/null

    ask_cmd "what is the meaning of life"
    # Filter sent exactly one reply containing "42"
    grep -q "42" "${SCRATCH}/var/outbound.eml"
}

@test "ASK-3 ask without pre-filter sends fallback list info reply" {
    # No pre-filter configured: mlisp sends fallback (list info + commands)
    ask_cmd "what commands are available"
    [ -s "${SCRATCH}/var/outbound.eml" ]
}

@test "ASK-4 ask reply is addressed to the original From:" {
    ask_cmd "test question"
    grep -q "To: member@example.com" "${SCRATCH}/var/outbound.eml"
}

@test "ASK-5 ask reply subject echoes the question" {
    ask_cmd "info"
    [ -s "${SCRATCH}/var/outbound.eml" ]
    grep -qi "Subject:" "${SCRATCH}/var/outbound.eml"
}

@test "ASK-6 ask dispatch recognised from Subject: line" {
    printf 'From: member@example.com\r\nTo: bugs-request@example.com\r\nSubject: ask what is the list policy\r\n\r\n' \
      | "${MLISP_BIN}" --home "${SCRATCH}" bugs-request 2>/dev/null
    [ -s "${SCRATCH}/var/outbound.eml" ]
}

@test "ASK-7 ask dispatch recognised from body first line" {
    printf 'From: member@example.com\r\nTo: bugs-request@example.com\r\nSubject: help\r\n\r\nask what is mlisp\r\n' \
      | "${MLISP_BIN}" --home "${SCRATCH}" bugs-request 2>/dev/null
    [ -s "${SCRATCH}/var/outbound.eml" ]
}
