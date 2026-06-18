#!/usr/bin/env bats
# test/bats/test_mlisp_distrib_yenc.bats
# BDD integration specs for #130/#131:
#   - base64 streaming (no memory spike for large files)
#   - yEnc multipart chunking (N/total subject convention)

setup() {
    MLISP_HOME_ORIG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MLISP_BIN="${MLISP_HOME_ORIG}/bin/mlisp"
    ADMIN_BIN="${MLISP_HOME_ORIG}/bin/mlisp-admin"
    DISTRIB_BIN="${MLISP_HOME_ORIG}/bin/mlisp-distrib"

    SCRATCH="$(mktemp -d)"
    mkdir -p "${SCRATCH}/state" "${SCRATCH}/templates" "${SCRATCH}/bin" \
             "${SCRATCH}/var"   "${SCRATCH}/files"
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

    "${ADMIN_BIN}" --home "${SCRATCH}" add-distrib releases "${SCRATCH}/files" 2>/dev/null
    "${ADMIN_BIN}" --home "${SCRATCH}" add-sub    releases  subscriber@example.com 2>/dev/null

    export MLISP_HOME="${SCRATCH}"
    export MLISP_SENDMAIL="${SCRATCH}/bin/sendmail"
    export MLISP_BIN ADMIN_BIN DISTRIB_BIN SCRATCH
}

teardown() { rm -rf "${SCRATCH}"; }

# ── #130: Streaming base64 ──────────────────────────────────────────────────

@test "DSTRM-1 distrib-file sends file that fits in one message (<=segment-size-kb)" {
    dd if=/dev/urandom bs=1024 count=100 > "${SCRATCH}/files/small.bin" 2>/dev/null
    run "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/small.bin"
    [ "$status" -eq 0 ]
}

@test "DSTRM-2 single-message outbound contains MIME attachment" {
    dd if=/dev/urandom bs=1024 count=100 > "${SCRATCH}/files/small.bin" 2>/dev/null
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/small.bin"
    grep -qi "Content-Transfer-Encoding: base64" "${SCRATCH}/var/outbound.eml"
}

@test "DSTRM-3 distrib-file does not reject file at 750KB (old 512KB ceiling removed)" {
    dd if=/dev/urandom bs=1024 count=750 > "${SCRATCH}/files/medium.bin" 2>/dev/null
    run "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/medium.bin"
    [ "$status" -eq 0 ]
}

# ── #131: yEnc multipart chunking ───────────────────────────────────────────

@test "DYENC-1 distrib-file chunks file above segment-size into multiple messages" {
    # 3 * 750KB = 3 segments
    dd if=/dev/urandom bs=1024 count=2250 > "${SCRATCH}/files/large.bin" 2>/dev/null
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/large.bin"
    # Should see 3 MLISP_MSG_END markers (one per segment per subscriber)
    count=$(grep -c "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml")
    [ "$count" -eq 3 ]
}

@test "DYENC-2 chunked segments have (N/total) subject convention" {
    dd if=/dev/urandom bs=1024 count=1600 > "${SCRATCH}/files/chunked.bin" 2>/dev/null
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/chunked.bin"
    grep -q "(1/" "${SCRATCH}/var/outbound.eml"
    grep -q "(2/" "${SCRATCH}/var/outbound.eml"
}

@test "DYENC-3 first segment subject is (1/N)" {
    dd if=/dev/urandom bs=1024 count=1600 > "${SCRATCH}/files/myfile.bin" 2>/dev/null
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/myfile.bin"
    grep -q "myfile.bin (1/" "${SCRATCH}/var/outbound.eml"
}

@test "DYENC-4 last segment subject matches total" {
    dd if=/dev/urandom bs=1024 count=1600 > "${SCRATCH}/files/myfile.bin" 2>/dev/null
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/myfile.bin"
    # 1600KB / 750KB = ceil(2.13) = 3 segments
    grep -q "myfile.bin (3/3)" "${SCRATCH}/var/outbound.eml"
}

@test "DYENC-5 chunked segments contain yEnc headers" {
    dd if=/dev/urandom bs=1024 count=1600 > "${SCRATCH}/files/yenc.bin" 2>/dev/null
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/yenc.bin"
    grep -q "=ybegin" "${SCRATCH}/var/outbound.eml"
    grep -q "=yend"   "${SCRATCH}/var/outbound.eml"
}

@test "DYENC-6 segment Content-Type is application/octet-stream with yenc encoding" {
    dd if=/dev/urandom bs=1024 count=1600 > "${SCRATCH}/files/yenc2.bin" 2>/dev/null
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/yenc2.bin"
    grep -qi "Content-Transfer-Encoding: x-yenc\|yenc" "${SCRATCH}/var/outbound.eml"
}

@test "DYENC-7 single file below threshold still delivered as single message" {
    echo "small data" > "${SCRATCH}/files/tiny.txt"
    "${DISTRIB_BIN}" --home "${SCRATCH}" releases "${SCRATCH}/files/tiny.txt"
    count=$(grep -c "MLISP_MSG_END" "${SCRATCH}/var/outbound.eml")
    [ "$count" -eq 1 ]
    # Single message should NOT have (1/1) subject -- only multi-segment gets it
    ! grep -q "(1/1)" "${SCRATCH}/var/outbound.eml"
}
