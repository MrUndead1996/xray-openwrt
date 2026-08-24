#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

LOCK_ROOT="$TEST_ROOT/lock"
MOCK_LOG="$TEST_ROOT/mock.log"
INIT_SCRIPT="$TEST_ROOT/bin/xray-init"
export MOCK_LOG

cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/sh
printf 'logger %s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$TEST_ROOT/bin/chown" <<'EOF'
#!/bin/sh
printf 'chown %s\n' "$*" >> "$MOCK_LOG"
[ "${CHOWN_STATUS:-0}" -eq 0 ]
EOF

cat > "$TEST_ROOT/bin/chmod" <<'EOF'
#!/bin/sh
printf 'chmod %s\n' "$*" >> "$MOCK_LOG"
[ "${CHMOD_STATUS:-0}" -eq 0 ]
EOF

cat > "$TEST_ROOT/bin/mv" <<'EOF'
#!/bin/sh
printf 'mv %s\n' "$*" >> "$MOCK_LOG"
[ "${MV_STATUS:-0}" -eq 0 ] || exit "$MV_STATUS"
/bin/mv "$@"
EOF

cat > "$TEST_ROOT/bin/kill" <<'EOF'
#!/bin/sh
exit "${KILL_STATUS:-0}"
EOF

cat > "$INIT_SCRIPT" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >> "$MOCK_LOG"
exit "${INIT_STATUS:-0}"
EOF

/bin/chmod +x "$TEST_ROOT/bin/logger" "$TEST_ROOT/bin/chown" \
    "$TEST_ROOT/bin/chmod" "$TEST_ROOT/bin/mv" "$TEST_ROOT/bin/kill" \
    "$INIT_SCRIPT"

XRAY_LOCK_ROOT=$LOCK_ROOT
XRAY_INIT_SCRIPT=$INIT_SCRIPT
XRAY_KILL=$TEST_ROOT/bin/kill
XRAY_PROC_ROOT=$TEST_ROOT/proc
export XRAY_LOCK_ROOT XRAY_INIT_SCRIPT XRAY_KILL XRAY_PROC_ROOT

. files/usr/libexec/xray/common

assert_status 0 xray_lock_acquire core-update
assert_file_exists "$LOCK_ROOT/core-update/pid"
assert_eq "$$" "$(cat "$LOCK_ROOT/core-update/pid")"

assert_status 1 xray_lock_acquire core-update
assert_file_contains "$MOCK_LOG" 'busy lock: core-update'

mkdir -p "$LOCK_ROOT/permission-lock" "$XRAY_PROC_ROOT/4242"
printf '%s\n' 4242 > "$LOCK_ROOT/permission-lock/pid"
KILL_STATUS=1
export KILL_STATUS
assert_status 1 xray_lock_acquire permission-lock
assert_eq 4242 "$(cat "$LOCK_ROOT/permission-lock/pid")"
assert_file_contains "$MOCK_LOG" 'busy lock: permission-lock'

xray_lock_release core-update
mkdir -p "$LOCK_ROOT/core-update"
printf '%s\n' 999999 > "$LOCK_ROOT/core-update/pid"
assert_status 0 xray_lock_acquire core-update
assert_eq "$$" "$(cat "$LOCK_ROOT/core-update/pid")"
if ! grep -F -x -q -e \
    "mv $LOCK_ROOT/core-update $LOCK_ROOT/core-update.reclaim" "$MOCK_LOG"; then
    printf '%s\n' 'FAIL: stale lock must move through the shared reclaim guard' >&2
    exit 1
fi
unset KILL_STATUS

mkdir -p "$LOCK_ROOT/other-update"
printf '%s\n' 999999 > "$LOCK_ROOT/other-update/pid"
xray_lock_release core-update
assert_file_not_exists "$LOCK_ROOT/core-update"
assert_file_exists "$LOCK_ROOT/other-update/pid"

source_file="$TEST_ROOT/source"
destination="$TEST_ROOT/destination"
printf '%s\n' new > "$source_file"
printf '%s\n' old > "$destination"
xray_atomic_install "$source_file" "$destination" 0755 root root
assert_eq new "$(cat "$destination")"
assert_file_contains "$MOCK_LOG" "chmod 0755 $destination.new.$$"
assert_file_contains "$MOCK_LOG" "chown root:root $destination.new.$$"
assert_file_contains "$MOCK_LOG" "mv $destination.new.$$ $destination"
assert_file_not_exists "$destination.new.$$"

printf '%s\n' old > "$destination"
CHOWN_STATUS=1
export CHOWN_STATUS
assert_status 1 xray_atomic_install "$source_file" "$destination" 0755 root root
assert_eq old "$(cat "$destination")"
assert_file_not_exists "$destination.new.$$"
unset CHOWN_STATUS

CHMOD_STATUS=1
export CHMOD_STATUS
assert_status 1 xray_atomic_install "$source_file" "$destination" 0755 root root
assert_eq old "$(cat "$destination")"
assert_file_not_exists "$destination.new.$$"
unset CHMOD_STATUS

MV_STATUS=1
export MV_STATUS
assert_status 1 xray_atomic_install "$source_file" "$destination" 0755 root root
assert_eq old "$(cat "$destination")"
assert_file_not_exists "$destination.new.$$"
unset MV_STATUS

INIT_STATUS=7
export INIT_STATUS
assert_status 7 xray_service_running
assert_file_contains "$MOCK_LOG" 'init running'

printf '%s\n' 'PASS: common helpers'
