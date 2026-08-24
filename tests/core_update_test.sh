#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

UPDATER="$PWD/files/usr/bin/update-xray-core"
COMMON="$PWD/files/usr/libexec/xray/common"
MOCK_LOG="$TEST_ROOT/mock.log"
DOWNLOADS="$TEST_ROOT/downloads"
CORE_DIR="$TEST_ROOT/usr/bin"
TMP_ROOT="$TEST_ROOT/tmp"
LOCK_ROOT="$TEST_ROOT/lock"
CONFIG="$TEST_ROOT/etc/xray/config.json"
INIT_SCRIPT="$TEST_ROOT/bin/xray-init"
ROLLBACK_SCRIPT="$TEST_ROOT/bin/rollback-xray-core"
CURRENT_BIN="$CORE_DIR/xray"
CURRENT_SHA="$CORE_DIR/xray.sha256"
PREVIOUS_BIN="$CORE_DIR/xray.previous"
PREVIOUS_SHA="$CORE_DIR/xray.previous.sha256"
EXPECTED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export MOCK_LOG DOWNLOADS EXPECTED_SHA

mkdir -p "$DOWNLOADS" "$(dirname "$CONFIG")"
printf '%s\n' zip-content > "$DOWNLOADS/Xray-linux-arm64-v8a.zip"
printf '%s\n' '{"inbounds":[]}' > "$CONFIG"

cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/sh
printf 'logger %s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$TEST_ROOT/bin/wget" <<'EOF'
#!/bin/sh
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O) output=$2; shift 2 ;;
        *) url=$1; shift ;;
    esac
done
printf 'wget %s\n' "$url" >> "$MOCK_LOG"
case "$url" in
    *.dgst) printf '%s\n' "${DGST_CONTENT:?}" > "$output" ;;
    *.zip) cp "$DOWNLOADS/Xray-linux-arm64-v8a.zip" "$output" ;;
    *) exit 1 ;;
esac
EOF

cat > "$TEST_ROOT/bin/sha256sum" <<'EOF'
#!/bin/sh
printf 'sha256sum %s\n' "$1" >> "$MOCK_LOG"
printf '%s  %s\n' "${ZIP_SHA:-$EXPECTED_SHA}" "$1"
EOF

cat > "$TEST_ROOT/bin/unzip" <<'EOF'
#!/bin/sh
printf 'unzip %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
    -l)
        printf '%s\n' 'Archive: archive.zip'
        printf '%s\n' '  Length      Date    Time    Name'
        printf '%s\n' '---------  ---------- -----   ----'
        for entry in ${ARCHIVE_ENTRIES:-xray}; do
            printf '%s\n' "       10  2026-01-01 00:00   $entry"
        done
        printf '%s\n' '---------                     -------'
        ;;
    -p)
        cat <<'CANDIDATE'
#!/bin/sh
case "$1" in
    version) exit "${CANDIDATE_VERSION_STATUS:-0}" ;;
    run) exit "${CANDIDATE_CONFIG_STATUS:-0}" ;;
    *) exit 1 ;;
esac
CANDIDATE
        ;;
    *) exit 1 ;;
esac
EOF

cat > "$TEST_ROOT/bin/chown" <<'EOF'
#!/bin/sh
printf 'chown %s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$INIT_SCRIPT" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >> "$MOCK_LOG"
exit "${INIT_STATUS:-0}"
EOF

cat > "$ROLLBACK_SCRIPT" <<'EOF'
#!/bin/sh
printf 'rollback %s\n' "$*" >> "$MOCK_LOG"
exit "${ROLLBACK_STATUS:-0}"
EOF

/bin/chmod +x "$TEST_ROOT/bin/logger" "$TEST_ROOT/bin/wget" \
    "$TEST_ROOT/bin/sha256sum" "$TEST_ROOT/bin/unzip" \
    "$TEST_ROOT/bin/chown" "$INIT_SCRIPT" "$ROLLBACK_SCRIPT"

run_updater() {
    XRAY_COMMON="$COMMON" \
    XRAY_CORE_TMP_ROOT="$TMP_ROOT" \
    XRAY_LOCK_ROOT="$LOCK_ROOT" \
    XRAY_INIT_SCRIPT="$INIT_SCRIPT" \
    XRAY_ROLLBACK_SCRIPT="$ROLLBACK_SCRIPT" \
    XRAY_BIN="$CURRENT_BIN" \
    XRAY_SHA_FILE="$CURRENT_SHA" \
    XRAY_PREVIOUS_BIN="$PREVIOUS_BIN" \
    XRAY_PREVIOUS_SHA_FILE="$PREVIOUS_SHA" \
    XRAY_CONFIG="$CONFIG" \
    sh "$UPDATER"
}

reset_state() {
    rm -rf "$CORE_DIR" "$TMP_ROOT" "$LOCK_ROOT"
    mkdir -p "$CORE_DIR" "$TMP_ROOT"
    : > "$MOCK_LOG"
    DGST_CONTENT="$EXPECTED_SHA Xray-linux-arm64-v8a.zip"
    ZIP_SHA="$EXPECTED_SHA"
    ARCHIVE_ENTRIES=xray
    CANDIDATE_VERSION_STATUS=0
    CANDIDATE_CONFIG_STATUS=0
    INIT_STATUS=0
    ROLLBACK_STATUS=0
    export DGST_CONTENT ZIP_SHA ARCHIVE_ENTRIES CANDIDATE_VERSION_STATUS \
        CANDIDATE_CONFIG_STATUS INIT_STATUS ROLLBACK_STATUS
}

install_current() {
    printf '%s\n' old-binary > "$CURRENT_BIN"
    /bin/chmod 0755 "$CURRENT_BIN"
    printf '%s\n' cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc > "$CURRENT_SHA"
}

assert_log_count() {
    expected=$1
    text=$2
    actual=$(grep -F -c -e "$text" "$MOCK_LOG" || :)
    assert_eq "$expected" "$actual" "expected $expected occurrences of: $text"
}

assert_exact_log_count() {
    expected=$1
    text=$2
    actual=$(grep -F -x -c -e "$text" "$MOCK_LOG" || :)
    assert_eq "$expected" "$actual" "expected $expected exact occurrences of: $text"
}

assert_cleanup() {
    if find "$TMP_ROOT" -mindepth 1 -print -quit | grep -q .; then
        printf '%s\n' 'FAIL: temporary updater files must be removed' >&2
        exit 1
    fi
    assert_file_not_exists "$LOCK_ROOT/core-update"
}

# 1. A matching validated state must avoid the ZIP and restart.
reset_state
install_current
printf '%s\n' "$EXPECTED_SHA" > "$CURRENT_SHA"
run_updater
assert_log_count 1 '.dgst'
assert_exact_log_count 0 'wget https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip'
assert_log_count 0 'init restart_runtime'
assert_cleanup

# 2. A malformed digest must stop before downloading the archive.
reset_state
install_current
DGST_CONTENT='not a checksum'
export DGST_CONTENT
if run_updater; then
    printf '%s\n' 'FAIL: malformed digest must fail' >&2
    exit 1
fi
assert_log_count 1 '.dgst'
assert_exact_log_count 0 'wget https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip'
assert_cleanup

# 3. A bad ZIP checksum must leave existing state untouched.
reset_state
install_current
ZIP_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export ZIP_SHA
if run_updater; then
    printf '%s\n' 'FAIL: checksum mismatch must fail' >&2
    exit 1
fi
assert_eq old-binary "$(cat "$CURRENT_BIN")"
assert_eq cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc "$(cat "$CURRENT_SHA")"
assert_file_not_exists "$PREVIOUS_BIN"
assert_file_not_exists "$PREVIOUS_SHA"
assert_cleanup

# 4. An archive without the regular xray payload must be rejected.
reset_state
install_current
ARCHIVE_ENTRIES=README.md
export ARCHIVE_ENTRIES
if run_updater; then
    printf '%s\n' 'FAIL: archive without xray must fail' >&2
    exit 1
fi
assert_eq old-binary "$(cat "$CURRENT_BIN")"
assert_cleanup

# 5. A candidate that fails its version command must not install.
reset_state
install_current
CANDIDATE_VERSION_STATUS=1
export CANDIDATE_VERSION_STATUS
if run_updater; then
    printf '%s\n' 'FAIL: invalid candidate version must fail' >&2
    exit 1
fi
assert_eq old-binary "$(cat "$CURRENT_BIN")"
assert_cleanup

# 6. A candidate that rejects the user config must not install.
reset_state
install_current
CANDIDATE_CONFIG_STATUS=1
export CANDIDATE_CONFIG_STATUS
if run_updater; then
    printf '%s\n' 'FAIL: invalid candidate config must fail' >&2
    exit 1
fi
assert_eq old-binary "$(cat "$CURRENT_BIN")"
assert_cleanup

# 7. A successful transaction preserves old state and installs the new runtime.
reset_state
install_current
run_updater
assert_file_contains "$CURRENT_BIN" 'case "$1" in'
assert_eq "$EXPECTED_SHA" "$(cat "$CURRENT_SHA")"
assert_eq old-binary "$(cat "$PREVIOUS_BIN")"
assert_eq cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc "$(cat "$PREVIOUS_SHA")"
assert_log_count 1 'init restart_runtime'
assert_cleanup

# 8. A failed restart invokes automatic rollback and remains a failure.
reset_state
install_current
INIT_STATUS=1
export INIT_STATUS
if run_updater; then
    printf '%s\n' 'FAIL: failed restart must fail even when rollback succeeds' >&2
    exit 1
fi
assert_log_count 1 'init restart_runtime'
assert_log_count 1 'rollback --automatic'
assert_cleanup

# 9. First installation must not fabricate previous state.
reset_state
run_updater
assert_file_exists "$CURRENT_BIN"
assert_file_exists "$CURRENT_SHA"
assert_file_not_exists "$PREVIOUS_BIN"
assert_file_not_exists "$PREVIOUS_SHA"
assert_cleanup

# 10. An active lock must reject concurrent work before either download.
reset_state
mkdir -p "$LOCK_ROOT/core-update"
printf '%s\n' "$$" > "$LOCK_ROOT/core-update/pid"
if run_updater; then
    printf '%s\n' 'FAIL: concurrent update must fail' >&2
    exit 1
fi
assert_log_count 0 'wget '
rm -rf "$LOCK_ROOT/core-update"

# 11. Cleanup also applies to the successful and every failing path above.
assert_cleanup

printf '%s\n' 'PASS: core updater'
