#!/usr/bin/env bats
# test/bats/test_mlisp_init_bootstrap.bats
# BDD specs for #107: XDG default path chain bootstrap.
#
# Unlike every other suite, these specs deliberately do NOT set
# MLISP_HOME -- that's the entire point. They instead set HOME to an
# isolated scratch directory and run mlisp-admin with a clean
# environment (env -i) to exercise the zero-config "first run" path
# that mlisp-home's XDG branch (and cmd-init's bootstrap target) cover.
#
# Priority (highest -> lowest), per src/state.lisp:
#   --home flag > $MLISP_HOME > $XDG_CONFIG_HOME or ~/.config/mlisp
#     > /etc/mlisp/ > directory of the running binary
#
# A true "$HOME entirely unset, passwd-fallback via
# (user-homedir-pathname)" spec is intentionally NOT included here:
# under env -i with no HOME, xdg-config-home resolves to the *real*
# passwd home directory of whatever account runs the test (e.g.
# /root/.config/mlisp on CI), which would write outside SCRATCH --
# an unacceptable side effect on a shared runner. That code path
# (xdg-config-home falling back to (user-homedir-pathname) when $HOME
# is unset) was verified manually; see #107.

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"

    SCRATCH="$(mktemp -d)"
    export SCRATCH ADMIN_BIN
}

@test "INIT-1 zero-config init bootstraps to \$HOME/.config/mlisp" {
    run env -i HOME="${SCRATCH}/home" PATH="$PATH" "${ADMIN_BIN}" init
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/home/.config/mlisp/state/state.sexp" ]
}

@test "INIT-2 subsequent zero-flag command finds the bootstrapped XDG state" {
    env -i HOME="${SCRATCH}/home" PATH="$PATH" "${ADMIN_BIN}" init >/dev/null

    run env -i HOME="${SCRATCH}/home" PATH="$PATH" "${ADMIN_BIN}" show-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"${SCRATCH}/home/.config/mlisp"* ]]
}

@test "INIT-3 second zero-flag command operates on data written by zero-config init" {
    env -i HOME="${SCRATCH}/home" PATH="$PATH" "${ADMIN_BIN}" init >/dev/null
    env -i HOME="${SCRATCH}/home" PATH="$PATH" "${ADMIN_BIN}" \
        add-namespace zerocfg zerocfg@example.com >/dev/null

    run env -i HOME="${SCRATCH}/home" PATH="$PATH" "${ADMIN_BIN}" list-lists
    [ "$status" -eq 0 ]
    [[ "$output" == *"zerocfg-discuss"* ]]
}

@test "INIT-4 \$XDG_CONFIG_HOME overrides ~/.config when both could apply" {
    run env -i HOME="${SCRATCH}/home" XDG_CONFIG_HOME="${SCRATCH}/xdgcfg" PATH="$PATH" \
        "${ADMIN_BIN}" init
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/xdgcfg/mlisp/state/state.sexp" ]
    [ ! -e "${SCRATCH}/home/.config" ]
}

@test "INIT-5 --home flag overrides zero-config bootstrap target" {
    run env -i HOME="${SCRATCH}/home" PATH="$PATH" \
        "${ADMIN_BIN}" --home "${SCRATCH}/explicit/" init
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/explicit/state/state.sexp" ]
    [ ! -e "${SCRATCH}/home/.config" ]
}

@test "INIT-6 MLISP_HOME env override takes precedence over XDG bootstrap" {
    run env -i HOME="${SCRATCH}/home" MLISP_HOME="${SCRATCH}/envhome" PATH="$PATH" \
        "${ADMIN_BIN}" init
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/envhome/state/state.sexp" ]
    [ ! -e "${SCRATCH}/home/.config" ]
}

@test "INIT-7 --dir flag still overrides everything (explicit, unchanged)" {
    run env -i HOME="${SCRATCH}/home" MLISP_HOME="${SCRATCH}/envhome" PATH="$PATH" \
        "${ADMIN_BIN}" init --dir "${SCRATCH}/explicit-dir"
    [ "$status" -eq 0 ]
    [ -f "${SCRATCH}/explicit-dir/state/state.sexp" ]
    [ ! -e "${SCRATCH}/envhome" ]
}
