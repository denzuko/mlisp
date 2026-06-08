#!/usr/bin/env bats
# test/bats/test_mlisp_procmail.bats
# BDD specifications for procmail integration.
# Written RED before any source changes.
#
# Covers:
#   etc/procmailrc.sample     canonical sample recipe file
#   mlisp-admin install-procmail [--list <id>] [--dry-run]

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" \
             "${SCRATCH}/home"
    cp "${MLISP_HOME_ORIG}/state/state.sexp"  "${SCRATCH}/state/"
    cp "${MLISP_HOME_ORIG}/templates/"*.sexp  "${SCRATCH}/templates/"

    # Fake HOME so we can inspect ~/.procmailrc without touching real one
    export HOME="${SCRATCH}/home"
    export MLISP_HOME="${SCRATCH}"
    export ADMIN_BIN MLISP_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ── Sample file ───────────────────────────────────────────────────────────────

@test "PM-1 etc/procmailrc.sample exists in repo" {
    [ -f "${MLISP_HOME_ORIG}/etc/procmailrc.sample" ]
}

@test "PM-2 procmailrc.sample contains a :0 recipe block" {
    grep -q "^:0" "${MLISP_HOME_ORIG}/etc/procmailrc.sample"
}

@test "PM-3 procmailrc.sample contains TO_ address match" {
    grep -qE "^\* \^TO_" "${MLISP_HOME_ORIG}/etc/procmailrc.sample"
}

@test "PM-4 procmailrc.sample contains a pipe to mlisp binary" {
    grep -qE "^\| .*/mlisp" "${MLISP_HOME_ORIG}/etc/procmailrc.sample"
}

@test "PM-5 procmailrc.sample has one block per list (3 total)" {
    count=$(grep -c "^:0" "${MLISP_HOME_ORIG}/etc/procmailrc.sample")
    [ "$count" -eq 3 ]
}

# ── install-procmail subcommand exists ───────────────────────────────────────

@test "PM-6 mlisp-admin install-procmail --help exits 0" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --help
    [ "$status" -eq 0 ]
}

@test "PM-7 mlisp-admin --help mentions install-procmail" {
    run "${ADMIN_BIN}" --help
    [[ "$output" == *"install-procmail"* ]]
}

# ── dry-run ───────────────────────────────────────────────────────────────────

@test "PM-8 install-procmail --dry-run exits 0" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run
    [ "$status" -eq 0 ]
}

@test "PM-9 install-procmail --dry-run prints recipe blocks" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run
    [[ "$output" == *":0"* ]]
}

@test "PM-10 install-procmail --dry-run does NOT write ~/.procmailrc" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run
    [ ! -f "${HOME}/.procmailrc" ]
}

@test "PM-11 install-procmail --dry-run output contains mlisp binary path" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run
    [[ "$output" == *"mlisp"* ]]
}

@test "PM-12 install-procmail --dry-run output contains --home path" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --dry-run
    [[ "$output" == *"--home"* ]]
}

# ── actual install ────────────────────────────────────────────────────────────

@test "PM-13 install-procmail creates ~/.procmailrc when absent" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    [ "$status" -eq 0 ]
    [ -f "${HOME}/.procmailrc" ]
}

@test "PM-14 install-procmail appends :0 recipe block to ~/.procmailrc" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    grep -q "^:0" "${HOME}/.procmailrc"
}

@test "PM-15 install-procmail writes TO_ match for each list drop address" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    grep -q "denzuko+mlist-discuss@panix.com"  "${HOME}/.procmailrc"
    grep -q "denzuko+mlist-announce@panix.com" "${HOME}/.procmailrc"
    grep -q "denzuko+mlist-devel@panix.com"    "${HOME}/.procmailrc"
}

@test "PM-16 install-procmail recipe pipes to mlisp with --home flag" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    grep -qE "mlisp --home .+ discuss" "${HOME}/.procmailrc"
}

@test "PM-17 install-procmail appends 3 recipe blocks (one per list)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    count=$(grep -c "^:0" "${HOME}/.procmailrc")
    [ "$count" -eq 3 ]
}

# ── idempotency ───────────────────────────────────────────────────────────────

@test "PM-18 install-procmail is idempotent (running twice = same result)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    count=$(grep -c "^:0" "${HOME}/.procmailrc")
    [ "$count" -eq 3 ]
}

@test "PM-19 install-procmail preserves existing ~/.procmailrc content" {
    echo "# My existing procmail rules" > "${HOME}/.procmailrc"
    echo ":0" >> "${HOME}/.procmailrc"
    echo "* ^Subject: SPAM" >> "${HOME}/.procmailrc"
    echo "/dev/null" >> "${HOME}/.procmailrc"

    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail

    # Original content must still be present
    grep -q "My existing procmail rules" "${HOME}/.procmailrc"
    grep -q "SPAM" "${HOME}/.procmailrc"
}

@test "PM-20 install-procmail appends AFTER existing content" {
    echo "# existing" > "${HOME}/.procmailrc"
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail

    # "existing" must come before ":0" for mlisp
    existing_line=$(grep -n "existing" "${HOME}/.procmailrc" | cut -d: -f1)
    first_recipe=$(grep -n "^:0" "${HOME}/.procmailrc" | head -1 | cut -d: -f1)
    [ "$existing_line" -lt "$first_recipe" ]
}

# ── --list filter ─────────────────────────────────────────────────────────────

@test "PM-21 install-procmail --list discuss installs only discuss recipe" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list discuss
    count=$(grep -c "^:0" "${HOME}/.procmailrc")
    [ "$count" -eq 1 ]
    grep -q "discuss" "${HOME}/.procmailrc"
}

@test "PM-22 install-procmail --list discuss does not add announce or devel" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list discuss
    run grep "announce" "${HOME}/.procmailrc"
    [ "$status" -ne 0 ]
}

@test "PM-23 install-procmail --list with unknown id exits 1" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list no-such-list
    [ "$status" -eq 1 ]
}

# ── recipe correctness ────────────────────────────────────────────────────────

@test "PM-24 generated recipe uses correct list-id as mlisp argument" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list devel
    grep -qE "mlisp .* devel$" "${HOME}/.procmailrc"
}

@test "PM-25 generated recipe has mlisp-managed comment block for idempotency" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list discuss
    grep -q "mlisp: discuss" "${HOME}/.procmailrc"
}
