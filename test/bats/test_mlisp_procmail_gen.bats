#!/usr/bin/env bats
# test/bats/test_mlisp_procmail_gen.bats
# BDD specs for mlisp-procmail-gen: s-expr recipe DSL -> procmailrc

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    PMG_BIN="${MLISP_HOME_ORIG}/bin/mlisp-procmail-gen"

    SCRATCH="$(mktemp -d)"
    export SCRATCH PMG_BIN
}

@test "PMG-1 single recipe prints procmail block to stdout" {
    cat > "${SCRATCH}/recipe.lisp" <<'EOF'
(:recipe :marker "mlisp: mlisp-discuss"
         :guards ("!^FROM_DAEMON" "!^FROM_MAILER")
         :match  "^^TO_mlisp-discuss@panix.com"
         :pipe   "/usr/local/bin/mlisp --home /etc/mlisp ")
EOF
    run "${PMG_BIN}" "${SCRATCH}/recipe.lisp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# mlisp: mlisp-discuss"* ]]
    [[ "$output" == *":0"* ]]
    [[ "$output" == *"!^FROM_DAEMON"* ]]
    [[ "$output" == *"* ^^TO_mlisp-discuss@panix.com"* ]]
    [[ "$output" == *"| /usr/local/bin/mlisp --home /etc/mlisp "* ]]
}

@test "PMG-2 recipe-set with multiple recipes prints both blocks" {
    cat > "${SCRATCH}/recipe.lisp" <<'EOF'
(:recipe-set
  (:recipe :marker "mlisp: mlisp-discuss"
           :guards () :match "^^TO_mlisp-discuss@panix.com"
           :pipe "/usr/local/bin/mlisp")
  (:recipe :marker "mlisp: mlisp-discuss-request"
           :guards () :match "^^TO_mlisp-discuss-request@panix.com"
           :pipe "/usr/local/bin/mlisp --mode request"))
EOF
    run "${PMG_BIN}" "${SCRATCH}/recipe.lisp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# mlisp: mlisp-discuss"* ]]
    [[ "$output" == *"# mlisp: mlisp-discuss-request"* ]]
}

@test "PMG-3 --output appends recipe to file with Added message" {
    cat > "${SCRATCH}/recipe.lisp" <<'EOF'
(:recipe :marker "mlisp: mlisp-discuss"
         :guards () :match "^^TO_mlisp-discuss@panix.com"
         :pipe "/usr/local/bin/mlisp")
EOF
    run "${PMG_BIN}" --output "${SCRATCH}/procmailrc" "${SCRATCH}/recipe.lisp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Added mlisp: mlisp-discuss"* ]]
    grep -q "# mlisp: mlisp-discuss" "${SCRATCH}/procmailrc"
    grep -q "^:0$" "${SCRATCH}/procmailrc"
}

@test "PMG-4 --output is idempotent: second run skips existing marker" {
    cat > "${SCRATCH}/recipe.lisp" <<'EOF'
(:recipe :marker "mlisp: mlisp-discuss"
         :guards () :match "^^TO_mlisp-discuss@panix.com"
         :pipe "/usr/local/bin/mlisp")
EOF
    "${PMG_BIN}" --output "${SCRATCH}/procmailrc" "${SCRATCH}/recipe.lisp" >/dev/null

    run "${PMG_BIN}" --output "${SCRATCH}/procmailrc" "${SCRATCH}/recipe.lisp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped mlisp: mlisp-discuss"* ]]

    # Marker appears exactly once in the file
    count=$(grep -c "# mlisp: mlisp-discuss" "${SCRATCH}/procmailrc")
    [ "$count" -eq 1 ]
}

@test "PMG-5 --dry-run with --output does not modify the file" {
    cat > "${SCRATCH}/recipe.lisp" <<'EOF'
(:recipe :marker "mlisp: mlisp-discuss"
         :guards () :match "^^TO_mlisp-discuss@panix.com"
         :pipe "/usr/local/bin/mlisp")
EOF
    run "${PMG_BIN}" --output "${SCRATCH}/procmailrc" --dry-run "${SCRATCH}/recipe.lisp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# mlisp: mlisp-discuss"* ]]
    [ ! -e "${SCRATCH}/procmailrc" ]
}

@test "PMG-6 no args prints usage and exits nonzero" {
    run "${PMG_BIN}"
    [ "$status" -ne 0 ]
}

@test "PMG-7 --help prints usage and exits zero" {
    run "${PMG_BIN}" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: mlisp-procmail-gen"* ]]
}

@test "PMG-8 nonexistent recipe file errors" {
    run "${PMG_BIN}" "${SCRATCH}/does-not-exist.lisp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such file"* ]]
}
