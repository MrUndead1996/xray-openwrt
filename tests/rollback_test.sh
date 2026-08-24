#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

ROLLBACK="$PWD/files/usr/bin/rollback-xray-core"
COMMON="$PWD/files/usr/libexec/xray/common"
MOCK_LOG="$TEST_ROOT/mock.log"
CORE_DIR="$TEST_ROOT/usr/bin"
TMP_ROOT="$TEST_ROOT/tmp"
LOCK_ROOT="$TEST_ROOT/lock"
CONFIG="$TEST_ROOT/etc/xray/config.json"
INIT_SCRIPT="$TEST_ROOT/bin/xray-init"
CURRENT_BIN="$CORE_DIR/xray"
CURRENT_SHA="$CORE_DIR/xray.sha256"
PREVIOUS_BIN="$CORE_DIR/xray.previous"
PREVIOUS_SHA="$CORE_DIR/xray.previous.sha256"
CURRENT_SHA_VALUE=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
PREVIOUS_SHA_VALUE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export MOCK_LOG

cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/sh
printf 'logger %s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$TEST_ROOT/bin/chown" <<'EOF'
#!/bin/sh
printf 'chown %s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$INIT_SCRIPT" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >> "$MOCK_LOG"
count_file="${INIT_COUNT_FILE:?}"
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "${INTERRUPT_ON_RESTART:-0}" = 1 ] && [ "$count" -eq 1 ]; then
    kill -TERM "$PPID"
fi
if [ "${INIT_FAIL_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
    exit 1
fi
exit 0
EOF

/bin/chmod +x "$TEST_ROOT/bin/logger" "$TEST_ROOT/bin/chown" "$INIT_SCRIPT"

write_runtime() {
    name=$1
    prefix=$2
    destination=$3

    cat > "$destination" <<EOF
#!/bin/sh
# $name
case "\$1" in
    version) exit "\${${prefix}_VERSION_STATUS:-0}" ;;
    run) exit "\${${prefix}_CONFIG_STATUS:-0}" ;;
    *) exit 1 ;;
esac
EOF
    /bin/chmod 0755 "$destination"
}

reset_state() {
    rm -rf "$CORE_DIR" "$TMP_ROOT" "$LOCK_ROOT"
    mkdir -p "$CORE_DIR" "$TMP_ROOT" "$(dirname "$CONFIG")"
    : > "$MOCK_LOG"
    INIT_COUNT_FILE="$TEST_ROOT/init-count"
    rm -f "$INIT_COUNT_FILE"
    PREVIOUS_VERSION_STATUS=0
    PREVIOUS_CONFIG_STATUS=0
    INIT_FAIL_FIRST=0
    INTERRUPT_ON_RESTART=0
    export INIT_COUNT_FILE PREVIOUS_VERSION_STATUS PREVIOUS_CONFIG_STATUS \
        INIT_FAIL_FIRST INTERRUPT_ON_RESTART
    printf '%s\n' '{"inbounds":[]}' > "$CONFIG"
    write_runtime current-runtime CURRENT "$CURRENT_BIN"
    write_runtime previous-runtime PREVIOUS "$PREVIOUS_BIN"
    printf '%s\n' "$CURRENT_SHA_VALUE" > "$CURRENT_SHA"
    printf '%s\n' "$PREVIOUS_SHA_VALUE" > "$PREVIOUS_SHA"
}

run_rollback() {
    XRAY_COMMON="$COMMON" \
    XRAY_CORE_TMP_ROOT="$TMP_ROOT" \
    XRAY_LOCK_ROOT="$LOCK_ROOT" \
    XRAY_INIT_SCRIPT="$INIT_SCRIPT" \
    XRAY_BIN="$CURRENT_BIN" \
    XRAY_SHA_FILE="$CURRENT_SHA" \
    XRAY_PREVIOUS_BIN="$PREVIOUS_BIN" \
    XRAY_PREVIOUS_SHA_FILE="$PREVIOUS_SHA" \
    XRAY_CONFIG="$CONFIG" \
    sh "$ROLLBACK" "$@"
}

assert_log_count() {
    expected=$1
    text=$2
    actual=$(grep -F -c -e "$text" "$MOCK_LOG" || :)
    assert_eq "$expected" "$actual" "expected $expected occurrences of: $text"
}

assert_cleanup() {
    if find "$TMP_ROOT" -mindepth 1 -print -quit | grep -q .; then
        printf '%s\n' 'FAIL: temporary rollback files must be removed' >&2
        exit 1
    fi
    assert_file_not_exists "$LOCK_ROOT/core-update"
}

# 1. Missing or malformed previous state must fail without touching current state.
reset_state
rm -f "$PREVIOUS_BIN"
if run_rollback; then
    printf '%s\n' 'FAIL: rollback without a previous binary must fail' >&2
    exit 1
fi
assert_file_contains "$CURRENT_BIN" current-runtime
assert_cleanup

reset_state
printf '%s\n' invalid > "$PREVIOUS_SHA"
if run_rollback; then
    printf '%s\n' 'FAIL: rollback with an invalid previous checksum must fail' >&2
    exit 1
fi
assert_file_contains "$CURRENT_BIN" current-runtime
assert_cleanup

# 2. Candidate validation failure must preserve both installed state pairs.
reset_state
PREVIOUS_VERSION_STATUS=1
export PREVIOUS_VERSION_STATUS
if run_rollback; then
    printf '%s\n' 'FAIL: previous runtime failing version must be rejected' >&2
    exit 1
fi
assert_file_contains "$CURRENT_BIN" current-runtime
assert_eq "$CURRENT_SHA_VALUE" "$(cat "$CURRENT_SHA")"
assert_file_contains "$PREVIOUS_BIN" previous-runtime

reset_state
PREVIOUS_CONFIG_STATUS=1
export PREVIOUS_CONFIG_STATUS
if run_rollback; then
    printf '%s\n' 'FAIL: previous runtime failing configuration validation must be rejected' >&2
    exit 1
fi
assert_file_contains "$CURRENT_BIN" current-runtime
assert_file_contains "$PREVIOUS_BIN" previous-runtime
assert_cleanup

# 3. Successful rollback swaps complete binary/checksum pairs and restarts once.
reset_state
run_rollback > "$TEST_ROOT/manual-output"
assert_file_contains "$CURRENT_BIN" previous-runtime
assert_eq "$PREVIOUS_SHA_VALUE" "$(cat "$CURRENT_SHA")"
assert_file_contains "$PREVIOUS_BIN" current-runtime
assert_eq "$CURRENT_SHA_VALUE" "$(cat "$PREVIOUS_SHA")"
assert_log_count 1 'init restart_runtime'
assert_file_contains "$TEST_ROOT/manual-output" 'rollback completed'
assert_cleanup

# 4. Failed restart restores the original pairs and starts the original runtime once.
reset_state
INIT_FAIL_FIRST=1
export INIT_FAIL_FIRST
if run_rollback; then
    printf '%s\n' 'FAIL: restart failure must keep rollback unsuccessful' >&2
    exit 1
fi
assert_file_contains "$CURRENT_BIN" current-runtime
assert_eq "$CURRENT_SHA_VALUE" "$(cat "$CURRENT_SHA")"
assert_file_contains "$PREVIOUS_BIN" previous-runtime
assert_eq "$PREVIOUS_SHA_VALUE" "$(cat "$PREVIOUS_SHA")"
assert_log_count 2 'init restart_runtime'
assert_cleanup

# 5. Automatic mode is noninteractive and reports through the updater log tag.
reset_state
run_rollback --automatic > "$TEST_ROOT/automatic-output"
assert_eq '' "$(cat "$TEST_ROOT/automatic-output")"
assert_file_contains "$MOCK_LOG" 'logger -t xray-update -- automatic rollback requested'
assert_cleanup

# 6. The updater and rollback use the same lock before any runtime change.
reset_state
mkdir -p "$LOCK_ROOT/core-update"
printf '%s\n' "$$" > "$LOCK_ROOT/core-update/pid"
if run_rollback; then
    printf '%s\n' 'FAIL: an active core-update lock must reject rollback' >&2
    exit 1
fi
assert_file_contains "$CURRENT_BIN" current-runtime
rm -rf "$LOCK_ROOT/core-update"

# 7. An interrupt after state installation must never leave the active runtime absent.
reset_state
INTERRUPT_ON_RESTART=1
export INTERRUPT_ON_RESTART
if run_rollback; then
    printf '%s\n' 'FAIL: interrupted rollback must fail' >&2
    exit 1
fi
assert_file_exists "$CURRENT_BIN"
assert_cleanup

printf '%s\n' 'PASS: core rollback'
