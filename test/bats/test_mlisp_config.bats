#!/usr/bin/env bats
# test/bats/test_mlisp_config.bats
# BDD specifications for XDG config dir support and mlisp-admin binary.
# Write these RED before touching source.
#
# Path resolution priority (lowest → highest):
#   /etc/mlisp/                        compiled-in default
#   $XDG_CONFIG_HOME/mlisp/            XDG spec
#   ~/.config/mlisp/                   XDG fallback
#   $MLISP_HOME                        env override (existing)
#   --home <dir>                       CLI flag (highest)

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"  "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp  "${SCRATCH}/templates/"

    # Stub sendmail
    printf '#!/bin/sh\ncat > /dev/null\nexit 0\n' > "${SCRATCH}/bin/sendmail"
    chmod +x "${SCRATCH}/bin/sendmail"

    # Fake HOME dir for XDG tests
    FAKE_HOME="$(mktemp -d)"

    export MLISP_BIN ADMIN_BIN SCRATCH FAKE_HOME
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
}

teardown() {
    rm -rf "${SCRATCH}" "${FAKE_HOME}"
}

# ── Admin binary exists ───────────────────────────────────────────────────────

@test "CFG-1 mlisp-admin binary exists and is executable" {
    [ -x "${ADMIN_BIN}" ]
}

@test "CFG-2 mlisp-admin prints usage with no args" {
    run "${ADMIN_BIN}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "CFG-3 mlisp-admin --help exits 0" {
    run "${ADMIN_BIN}" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"mlisp-admin"* ]]
}

# ── --home flag overrides all other path sources ──────────────────────────────

@test "CFG-4 mlisp --home flag uses specified dir for state" {
    # With --home pointing at SCRATCH, mlisp should read SCRATCH/state/state.sexp
    run bash -c "printf 'From: dwight@example.com\r\nSubject: help\r\n\r\nhelp\r\n' \
      | '${MLISP_BIN}' --home '${SCRATCH}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "CFG-5 mlisp --home unknown-list exits 1 (reads correct state)" {
    run bash -c "printf 'From: x@example.com\r\nSubject: hi\r\n\r\nbody\r\n' \
      | '${MLISP_BIN}' --home '${SCRATCH}' no-such-list"
    [ "$status" -eq 1 ]
}

@test "CFG-6 mlisp --home takes precedence over MLISP_HOME" {
    # MLISP_HOME points at an empty dir (no state.sexp) — should fail with exit 2
    # --home points at SCRATCH (valid state) — should succeed
    EMPTY="$(mktemp -d)"
    mkdir -p "${EMPTY}/state" "${EMPTY}/templates"
    run bash -c "printf 'From: dwight@example.com\r\nSubject: help\r\n\r\nhelp\r\n' \
      | MLISP_HOME='${EMPTY}' '${MLISP_BIN}' --home '${SCRATCH}' mlisp-discuss"
    [ "$status" -eq 0 ]
    rm -rf "${EMPTY}"
}

# ── XDG_CONFIG_HOME resolution ────────────────────────────────────────────────

@test "CFG-7 mlisp reads state from XDG_CONFIG_HOME/mlisp when set" {
    XDG_DIR="${FAKE_HOME}/.xdg"
    mkdir -p "${XDG_DIR}/mlisp/state" "${XDG_DIR}/mlisp/templates"
    cp "${SCRATCH}/state/state.sexp"  "${XDG_DIR}/mlisp/state/"
    cp "${SCRATCH}/templates/"*.sexp  "${XDG_DIR}/mlisp/templates/"

    run bash -c "printf 'From: dwight@example.com\r\nSubject: help\r\n\r\nhelp\r\n' \
      | XDG_CONFIG_HOME='${XDG_DIR}' \
        MLISP_SENDMAIL='${SCRATCH}/bin/sendmail' \
        HOME='${FAKE_HOME}' \
        '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

@test "CFG-8 mlisp reads state from HOME/.config/mlisp when XDG_CONFIG_HOME unset" {
    mkdir -p "${FAKE_HOME}/.config/mlisp/state" \
             "${FAKE_HOME}/.config/mlisp/templates"
    cp "${SCRATCH}/state/state.sexp" \
       "${FAKE_HOME}/.config/mlisp/state/"
    cp "${SCRATCH}/templates/"*.sexp \
       "${FAKE_HOME}/.config/mlisp/templates/"

    run bash -c "printf 'From: dwight@example.com\r\nSubject: help\r\n\r\nhelp\r\n' \
      | env -i HOME='${FAKE_HOME}' \
              MLISP_SENDMAIL='${SCRATCH}/bin/sendmail' \
              PATH='${PATH}' \
              '${MLISP_BIN}' mlisp-discuss"
    [ "$status" -eq 0 ]
}

# ── mlisp-admin show-config ───────────────────────────────────────────────────

@test "CFG-9 mlisp-admin show-config prints config dir" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"config-dir"* ]]
    [[ "$output" == *"${SCRATCH}"* ]]
}

@test "CFG-10 mlisp-admin show-config prints state.sexp path" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-config
    [[ "$output" == *"state.sexp"* ]]
}

@test "CFG-11 mlisp-admin show-config prints templates dir" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" show-config
    [[ "$output" == *"templates"* ]]
}

# ── mlisp-admin init ──────────────────────────────────────────────────────────

@test "CFG-12 mlisp-admin init scaffolds state.sexp in new dir" {
    NEWDIR="${SCRATCH}/newconfig"
    run "${ADMIN_BIN}" init --dir "${NEWDIR}"
    [ "$status" -eq 0 ]
    [ -f "${NEWDIR}/state/state.sexp" ]
}

@test "CFG-13 mlisp-admin init scaffolds templates in new dir" {
    NEWDIR="${SCRATCH}/newconfig2"
    run "${ADMIN_BIN}" init --dir "${NEWDIR}"
    [ -d "${NEWDIR}/templates" ]
    [ -f "${NEWDIR}/templates/mlisp-discuss.welcome.sexp" ]
}

@test "CFG-14 mlisp-admin init is idempotent (safe to run twice)" {
    NEWDIR="${SCRATCH}/newconfig3"
    "${ADMIN_BIN}" init --dir "${NEWDIR}"
    run "${ADMIN_BIN}" init --dir "${NEWDIR}"
    [ "$status" -eq 0 ]
}

# ── mlisp-admin list-lists ────────────────────────────────────────────────────

@test "CFG-15 mlisp-admin list-lists prints all list IDs" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-lists
    [ "$status" -eq 0 ]
    [[ "$output" == *"mlisp-discuss"* ]]
    [[ "$output" == *"mlisp-announce"* ]]
    [[ "$output" == *"mlisp-devel"* ]]
}

@test "CFG-16 mlisp-admin list-lists prints drop addresses" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-lists
    [[ "$output" == *"panix.com"* ]]
}

# ── mlisp-admin list-subs ─────────────────────────────────────────────────────

@test "CFG-17 mlisp-admin list-subs prints subscriber addresses" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [ "$status" -eq 0 ]
    [[ "$output" == *"dwight@example.com"* ]]
}

@test "CFG-18 mlisp-admin list-subs prints consent timestamps" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs mlisp-discuss
    [[ "$output" == *"subscribed-at"* ]]
}

@test "CFG-19 mlisp-admin list-subs unknown list exits 1" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" list-subs no-such-list
    [ "$status" -eq 1 ]
}

# ── mlisp-admin add-sub ───────────────────────────────────────────────────────

@test "CFG-20 mlisp-admin add-sub adds address to state.sexp" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-devel newguy@example.com
    [ "$status" -eq 0 ]
    grep -q "newguy@example.com" "${SCRATCH}/state/state.sexp"
}

@test "CFG-21 mlisp-admin add-sub records consent-method as admin-add" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-devel admin@example.com
    grep -q "admin-add" "${SCRATCH}/state/state.sexp"
}

@test "CFG-22 mlisp-admin add-sub writes audit event" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-devel audit@example.com
    [ -f "${SCRATCH}/state/audit.sexp" ]
    grep -q ":event :subscribe" "${SCRATCH}/state/audit.sexp"
}

@test "CFG-23 mlisp-admin add-sub is idempotent" {
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub mlisp-discuss dwight@example.com
    count=$(grep -c "dwight@example.com" "${SCRATCH}/state/state.sexp")
    [ "$count" -eq 1 ]
}

# ── mlisp-admin rm-sub ────────────────────────────────────────────────────────

@test "CFG-24 mlisp-admin rm-sub removes address from state.sexp" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" rm-sub mlisp-discuss dwight@example.com
    [ "$status" -eq 0 ]
    run grep "dwight@example.com" "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "CFG-25 mlisp-admin rm-sub writes erasure audit event" {
    "${ADMIN_BIN}" --home "${SCRATCH}" rm-sub mlisp-discuss dwight@example.com
    grep -q ":event :unsubscribe" "${SCRATCH}/state/audit.sexp"
}

@test "CFG-26 mlisp-admin rm-sub on non-member exits 0 (no-op)" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" rm-sub mlisp-discuss nobody@example.com
    [ "$status" -eq 0 ]
}

# ── mlisp-admin add-list / rm-list ───────────────────────────────────────────

@test "CFG-27 mlisp-admin add-list creates new list in state.sexp" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" \
      add-list security denzuko+mlist-security@panix.com "Security list"
    [ "$status" -eq 0 ]
    grep -q '"security"' "${SCRATCH}/state/state.sexp"
}

@test "CFG-28 mlisp-admin rm-list removes list from state.sexp" {
    "${ADMIN_BIN}" --home "${SCRATCH}" \
      add-list tmp denzuko+mlist-tmp@panix.com "Temp list"
    run "${ADMIN_BIN}" --home "${SCRATCH}" rm-list tmp
    [ "$status" -eq 0 ]
    run grep '"tmp"' "${SCRATCH}/state/state.sexp"
    [ "$status" -ne 0 ]
}

@test "CFG-29 mlisp-admin rm-list unknown list exits 1" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" rm-list no-such-list
    [ "$status" -eq 1 ]
}
