#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

MOCK_LOG="$TEST_ROOT/mock.log"
FUNCTIONS="$TEST_ROOT/functions.sh"
PROCD="$TEST_ROOT/procd.sh"
INIT_SCRIPT="$PWD/files/etc/init.d/xray"
export MOCK_LOG

cat > "$FUNCTIONS" <<'EOF'
config_load() {
    printf 'config_load %s\n' "$1" >> "$MOCK_LOG"
}

config_get() {
    variable=$1
    option=$3
    default=${4:-}

    case "$option" in
        enabled) value=${UCI_ENABLED:-1} ;;
        *) value=$default ;;
    esac

    eval "$variable=\$value"
}
EOF

cat > "$PROCD" <<'EOF'
procd_open_instance() {
    printf 'procd_open_instance %s\n' "$*" >> "$MOCK_LOG"
    return "${PROCD_OPEN_STATUS:-0}"
}

procd_set_param() {
    printf 'procd_set_param %s\n' "$*" >> "$MOCK_LOG"
}

procd_add_jail() {
    printf 'procd_add_jail %s\n' "$*" >> "$MOCK_LOG"
}

procd_add_jail_mount() {
    printf 'procd_add_jail_mount %s\n' "$*" >> "$MOCK_LOG"
}

procd_close_instance() {
    printf 'procd_close_instance %s\n' "$*" >> "$MOCK_LOG"
}

procd_kill() {
    printf 'procd_kill %s\n' "$*" >> "$MOCK_LOG"
}

procd_running() {
    printf 'procd_running %s\n' "$*" >> "$MOCK_LOG"
    return "${PROCD_RUNNING_STATUS:-1}"
}

procd_add_reload_trigger() {
    printf 'procd_add_reload_trigger %s\n' "$*" >> "$MOCK_LOG"
}
EOF

cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/sh
printf 'logger %s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$TEST_ROOT/bin/xray" <<'EOF'
#!/bin/sh
printf 'xray %s\n' "$*" >> "$MOCK_LOG"
exit "${XRAY_STATUS:-0}"
EOF

cat > "$TEST_ROOT/bin/tproxy" <<'EOF'
#!/bin/sh
printf 'tproxy %s\n' "$*" >> "$MOCK_LOG"
exit "${TPROXY_STATUS:-0}"
EOF

/bin/chmod +x "$TEST_ROOT/bin/logger" "$TEST_ROOT/bin/xray" "$TEST_ROOT/bin/tproxy"

assert_no_log() {
    text=$1
    if grep -F -q -e "$text" "$MOCK_LOG"; then
        printf '%s\n' "FAIL: unexpected log entry: $text" >&2
        exit 1
    fi
}

assert_log_order() {
    first=$1
    second=$2
    first_line=$(grep -n -F -e "$first" "$MOCK_LOG" | sed -n '1s/:.*//p')
    second_line=$(grep -n -F -e "$second" "$MOCK_LOG" | sed -n '1s/:.*//p')

    [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] || {
        printf '%s\n' "FAIL: expected '$first' before '$second'" >&2
        exit 1
    }
}

run_init() {
    action=$1
    XRAY_FUNCTIONS_PATH="$FUNCTIONS" \
    XRAY_PROCD_PATH="$PROCD" \
    XRAY_BINARY="$TEST_ROOT/bin/xray" \
    XRAY_CONFIG="$TEST_ROOT/etc/config.json" \
    XRAY_ASSETS="$TEST_ROOT/usr/share/xray" \
    XRAY_CA_CERT="$TEST_ROOT/etc/ca-certificates.crt" \
    XRAY_TPROXY_HELPER="$TEST_ROOT/bin/tproxy" \
    sh -c '. "$1"; "$2"' sh "$INIT_SCRIPT" "$action"
}

reset_mocks() {
    : > "$MOCK_LOG"
    cat > "$TEST_ROOT/bin/xray" <<'EOF'
#!/bin/sh
printf 'xray %s\n' "$*" >> "$MOCK_LOG"
exit "${XRAY_STATUS:-0}"
EOF
    /bin/chmod +x "$TEST_ROOT/bin/xray"
    : > "$TEST_ROOT/etc/config.json"
    : > "$TEST_ROOT/etc/ca-certificates.crt"
    UCI_ENABLED=1
    XRAY_STATUS=0
    TPROXY_STATUS=0
    PROCD_OPEN_STATUS=0
    PROCD_RUNNING_STATUS=1
    export UCI_ENABLED XRAY_STATUS TPROXY_STATUS PROCD_OPEN_STATUS \
        PROCD_RUNNING_STATUS
}

reset_mocks
UCI_ENABLED=0
export UCI_ENABLED
run_init start_service
assert_no_log 'xray '
assert_no_log 'tproxy '
assert_no_log 'procd_'

reset_mocks
rm "$TEST_ROOT/bin/xray"
if run_init start_service > "$TEST_ROOT/missing-binary.out" 2>&1; then
    printf '%s\n' 'FAIL: missing Xray binary must fail' >&2
    exit 1
fi
assert_file_contains "$TEST_ROOT/missing-binary.out" 'Xray executable not found'
assert_no_log 'tproxy '

reset_mocks
rm "$TEST_ROOT/etc/config.json"
if run_init start_service > "$TEST_ROOT/missing-config.out" 2>&1; then
    printf '%s\n' 'FAIL: missing Xray config must fail' >&2
    exit 1
fi
assert_file_contains "$TEST_ROOT/missing-config.out" 'Xray configuration not found'
assert_no_log 'tproxy '

reset_mocks
run_init start_service
assert_log_order 'xray run -test -config ' 'tproxy start'
assert_log_order 'tproxy start' 'procd_open_instance '
assert_file_contains "$MOCK_LOG" "xray run -test -config $TEST_ROOT/etc/config.json -format json"
assert_file_contains "$MOCK_LOG" "procd_set_param command $TEST_ROOT/bin/xray run -config $TEST_ROOT/etc/config.json -format json"
assert_file_contains "$MOCK_LOG" "procd_set_param env XRAY_LOCATION_ASSET=$TEST_ROOT/usr/share/xray"
assert_file_contains "$MOCK_LOG" 'procd_set_param user xray'
assert_file_contains "$MOCK_LOG" 'procd_set_param capabilities /etc/capabilities/xray.json'
assert_file_contains "$MOCK_LOG" 'procd_add_jail xray procfs log'
assert_file_contains "$MOCK_LOG" "procd_add_jail_mount $TEST_ROOT/etc/config.json"
assert_file_contains "$MOCK_LOG" "procd_add_jail_mount $TEST_ROOT/usr/share/xray"
assert_file_contains "$MOCK_LOG" "procd_add_jail_mount $TEST_ROOT/etc/ca-certificates.crt"
assert_file_contains "$MOCK_LOG" 'procd_set_param stdout 1'
assert_file_contains "$MOCK_LOG" 'procd_set_param stderr 1'
assert_file_contains "$MOCK_LOG" 'procd_set_param respawn'

reset_mocks
run_init stop_service
assert_log_order 'procd_kill ' 'tproxy stop'

reset_mocks
PROCD_OPEN_STATUS=1
export PROCD_OPEN_STATUS
if run_init start_service; then
    printf '%s\n' 'FAIL: failed runtime registration must fail full start' >&2
    exit 1
fi
assert_log_order 'tproxy start' 'procd_open_instance '
assert_log_order 'procd_open_instance ' 'tproxy stop'

reset_mocks
TPROXY_STATUS=1
export TPROXY_STATUS
if run_init start_service; then
    printf '%s\n' 'FAIL: failed TProxy start must fail full start' >&2
    exit 1
fi
assert_log_order 'tproxy start' 'tproxy stop'

reset_mocks
PROCD_RUNNING_STATUS=0
TPROXY_STATUS=1
export PROCD_RUNNING_STATUS TPROXY_STATUS
if run_init start_service; then
    printf '%s\n' 'FAIL: failed active TProxy restart must fail full start' >&2
    exit 1
fi
assert_file_contains "$MOCK_LOG" 'procd_running xray'
assert_no_log 'tproxy stop'

reset_mocks
PROCD_RUNNING_STATUS=0
PROCD_OPEN_STATUS=1
export PROCD_RUNNING_STATUS PROCD_OPEN_STATUS
if run_init start_service; then
    printf '%s\n' 'FAIL: failed registration must fail an active full start' >&2
    exit 1
fi
assert_file_contains "$MOCK_LOG" 'procd_running xray'
assert_no_log 'tproxy stop'

reset_mocks
run_init restart_runtime
assert_file_contains "$MOCK_LOG" 'procd_kill '
assert_file_contains "$MOCK_LOG" 'xray run -test -config '
assert_no_log 'tproxy '

reset_mocks
run_init reload_service
assert_log_order 'xray run -test -config ' 'procd_kill '
assert_file_contains "$MOCK_LOG" 'procd_kill '
assert_no_log 'tproxy '

reset_mocks
XRAY_STATUS=1
export XRAY_STATUS
if run_init reload_service; then
    printf '%s\n' 'FAIL: invalid reload config must fail' >&2
    exit 1
fi
assert_file_contains "$MOCK_LOG" 'xray run -test -config '
assert_no_log 'procd_kill '
assert_no_log 'tproxy '

reset_mocks
UCI_ENABLED=0
export UCI_ENABLED
run_init reload_service
assert_log_order 'procd_kill ' 'tproxy stop'

reset_mocks
run_init service_triggers
assert_file_contains "$MOCK_LOG" 'procd_add_reload_trigger xray'
assert_file_contains "$INIT_SCRIPT" 'EXTRA_COMMANDS="restart_runtime stop_runtime"'

printf '%s\n' 'PASS: init service'
