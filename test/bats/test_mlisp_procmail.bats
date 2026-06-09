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

@test "PM-5 procmailrc.sample has one block per subgroup (5 total)" {
    count=$(grep -c "^:0" "${MLISP_HOME_ORIG}/etc/procmailrc.sample")
    [ "$count" -eq 5 ]
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
    grep -q "mlisp-discuss@panix.com"  "${HOME}/.procmailrc"
    grep -q "mlisp-announce@panix.com" "${HOME}/.procmailrc"
    grep -q "mlisp-devel@panix.com"    "${HOME}/.procmailrc"
}

@test "PM-16 install-procmail recipe pipes to mlisp with --home flag" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    grep -qE "mlisp --home .+ mlisp-discuss" "${HOME}/.procmailrc"
}

@test "PM-17 install-procmail appends recipe blocks (list + request per list)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    count=$(grep -c "^:0" "${HOME}/.procmailrc")
    # discuss,announce,devel,distrib each get 2; request gets 1 = 9 total
    [ "$count" -eq 9 ]
}

# ── idempotency ───────────────────────────────────────────────────────────────

@test "PM-18 install-procmail is idempotent (running twice = same result)" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail
    count=$(grep -c "^:0" "${HOME}/.procmailrc")
    # Still 9 after two runs (idempotent)
    [ "$count" -eq 9 ]
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

@test "PM-21 install-procmail --list mlisp-discuss installs mlisp-discuss and discuss-request" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list mlisp-discuss
    count=$(grep -c "^:0" "${HOME}/.procmailrc")
    # 2 blocks: discuss list + discuss-request
    [ "$count" -eq 2 ]
    grep -q "mlisp-discuss" "${HOME}/.procmailrc"
}

@test "PM-22 install-procmail --list mlisp-discuss does not add announce or devel" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list mlisp-discuss
    run grep "mlisp-announce" "${HOME}/.procmailrc"
    [ "$status" -ne 0 ]
}

@test "PM-23 install-procmail --list with unknown id exits 1" {
    run "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list no-such-list
    [ "$status" -eq 1 ]
}

# ── recipe correctness ────────────────────────────────────────────────────────

@test "PM-24 generated recipe uses correct list-id as mlisp argument" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list mlisp-devel
    grep -qE "mlisp .* mlisp-devel$" "${HOME}/.procmailrc"
}

@test "PM-25 generated recipe has mlisp-managed comment block for idempotency" {
    "${ADMIN_BIN}" --home "${SCRATCH}" install-procmail --list mlisp-discuss
    grep -q "mlisp: mlisp-discuss" "${HOME}/.procmailrc"
}
