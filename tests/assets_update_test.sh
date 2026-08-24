#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

UPDATER="$PWD/files/usr/bin/update-xray-assets"
MOCK_LOG="$TEST_ROOT/mock.log"
DOWNLOADS="$TEST_ROOT/downloads"
ASSETS="$TEST_ROOT/usr/share/xray"
TMP_ROOT="$TEST_ROOT/tmp"
LOCK_ROOT="$TEST_ROOT/lock"
INIT_SCRIPT="$TEST_ROOT/bin/xray-init"
export MOCK_LOG DOWNLOADS

mkdir -p "$DOWNLOADS"
printf '%s\n' 'asset-content-geosite' > "$DOWNLOADS/geosite.dat"
printf '%s\n' 'asset-content-refilter-ip' > "$DOWNLOADS/refilter_ip.dat"
printf '%s\n' 'asset-content-refilter-site' > "$DOWNLOADS/refilter_site.dat"

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
        -O)
            output=$2
            shift 2
            ;;
        *)
            url=$1
            shift
            ;;
    esac
done
printf 'wget %s\n' "$url" >> "$MOCK_LOG"
case "$url" in
    *domain-list-community*) fixture=geosite.dat ;;
    *geoip.dat) fixture=refilter_ip.dat ;;
    *geosite.dat) fixture=refilter_site.dat ;;
esac
case "${WGET_FAIL:-}" in
    *"$fixture"*) exit 1 ;;
esac
if [ "${WGET_WAIT:-0}" = 1 ]; then
    printf '%s\n' "$$" > "${WGET_PID_FILE:?}"
    : > "${WGET_STARTED:?}"
    while :; do sleep 1; done
fi
if [ "${WGET_EMPTY:-}" = "$fixture" ]; then
    : > "$output"
else
    cp "$DOWNLOADS/$fixture" "$output"
fi
EOF

cat > "$TEST_ROOT/bin/chown" <<'EOF'
#!/bin/sh
printf 'chown %s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$TEST_ROOT/bin/mv" <<'EOF'
#!/bin/sh
printf 'mv %s\n' "$*" >> "$MOCK_LOG"
/bin/mv "$@"
EOF

cat > "$INIT_SCRIPT" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >> "$MOCK_LOG"
exit "${INIT_STATUS:-0}"
EOF

/bin/chmod +x "$TEST_ROOT/bin/logger" "$TEST_ROOT/bin/wget" \
    "$TEST_ROOT/bin/chown" "$TEST_ROOT/bin/mv" "$INIT_SCRIPT"

run_updater() {
    XRAY_COMMON="$PWD/files/usr/libexec/xray/common" \
    XRAY_ASSET_DIR="$ASSETS" \
    XRAY_ASSETS_TMP_ROOT="$TMP_ROOT" \
    XRAY_LOCK_ROOT="$LOCK_ROOT" \
    XRAY_INIT_SCRIPT="$INIT_SCRIPT" \
    sh "$UPDATER"
}

reset_state() {
    rm -rf "$ASSETS" "$TMP_ROOT" "$LOCK_ROOT"
    mkdir -p "$ASSETS" "$TMP_ROOT"
    : > "$MOCK_LOG"
    INIT_STATUS=0
    unset WGET_FAIL WGET_EMPTY WGET_WAIT WGET_STARTED WGET_PID_FILE
}

assert_no_temp_or_lock() {
    if find "$TMP_ROOT" -mindepth 1 -print -quit | grep -q .; then
        printf '%s\n' 'FAIL: updater temporary directory must be removed' >&2
        exit 1
    fi
    assert_file_not_exists "$LOCK_ROOT/assets-update"
}

assert_log_count() {
    expected=$1
    text=$2
    actual=$(grep -F -c -e "$text" "$MOCK_LOG" || :)
    assert_eq "$expected" "$actual" "expected $expected occurrences of: $text"
}

reset_state
cp "$DOWNLOADS/geosite.dat" "$ASSETS/geosite.dat"
cp "$DOWNLOADS/refilter_ip.dat" "$ASSETS/refilter_ip.dat"
cp "$DOWNLOADS/refilter_site.dat" "$ASSETS/refilter_site.dat"
run_updater
assert_log_count 3 'wget https://'
assert_log_count 0 "mv $ASSETS/"
assert_log_count 0 'init restart_runtime'
assert_no_temp_or_lock

reset_state
printf '%s\n' old > "$ASSETS/geosite.dat"
cp "$DOWNLOADS/refilter_ip.dat" "$ASSETS/refilter_ip.dat"
cp "$DOWNLOADS/refilter_site.dat" "$ASSETS/refilter_site.dat"
run_updater
assert_eq 'asset-content-geosite' "$(cat "$ASSETS/geosite.dat")"
assert_log_count 1 "mv $ASSETS/geosite.dat.new."
assert_log_count 1 'init restart_runtime'
assert_no_temp_or_lock

reset_state
printf '%s\n' keep > "$ASSETS/geosite.dat"
cp "$DOWNLOADS/refilter_ip.dat" "$ASSETS/refilter_ip.dat"
cp "$DOWNLOADS/refilter_site.dat" "$ASSETS/refilter_site.dat"
WGET_EMPTY=geosite.dat
export WGET_EMPTY
if run_updater; then
    printf '%s\n' 'FAIL: empty download must fail the updater' >&2
    exit 1
fi
assert_eq keep "$(cat "$ASSETS/geosite.dat")"
assert_log_count 0 'init restart_runtime'
assert_no_temp_or_lock

reset_state
WGET_FAIL=geosite.dat
export WGET_FAIL
if run_updater; then
    printf '%s\n' 'FAIL: failed download must fail the updater' >&2
    exit 1
fi
assert_file_exists "$ASSETS/refilter_ip.dat"
assert_file_exists "$ASSETS/refilter_site.dat"
assert_log_count 3 'wget https://'
assert_log_count 1 'init restart_runtime'
assert_no_temp_or_lock

reset_state
INIT_STATUS=1
export INIT_STATUS
if run_updater; then
    printf '%s\n' 'FAIL: failed runtime restart must fail the updater' >&2
    exit 1
fi
assert_log_count 1 'init restart_runtime'
assert_no_temp_or_lock

reset_state
mkdir -p "$LOCK_ROOT/assets-update"
printf '%s\n' "$$" > "$LOCK_ROOT/assets-update/pid"
if run_updater; then
    printf '%s\n' 'FAIL: simultaneous updater invocation must fail' >&2
    exit 1
fi
assert_log_count 0 'wget https://'
assert_file_contains "$MOCK_LOG" 'logger -t xray-lock -- busy lock: assets-update'
rm -rf "$LOCK_ROOT/assets-update"

reset_state
WGET_WAIT=1
WGET_STARTED="$TEST_ROOT/wget-started"
WGET_PID_FILE="$TEST_ROOT/wget-pid"
export WGET_WAIT WGET_STARTED WGET_PID_FILE
XRAY_COMMON="$PWD/files/usr/libexec/xray/common" \
XRAY_ASSET_DIR="$ASSETS" \
XRAY_ASSETS_TMP_ROOT="$TMP_ROOT" \
XRAY_LOCK_ROOT="$LOCK_ROOT" \
XRAY_INIT_SCRIPT="$INIT_SCRIPT" \
sh "$UPDATER" > "$TEST_ROOT/interrupted.out" 2>&1 &
pid=$!
while [ ! -e "$WGET_STARTED" ]; do sleep 1; done
kill -TERM "$(cat "$WGET_PID_FILE")"
kill -TERM "$pid" 2>/dev/null || :
if wait "$pid"; then
    printf '%s\n' 'FAIL: interrupted updater must fail' >&2
    exit 1
fi
assert_no_temp_or_lock

if grep -F -q -e asset-content-geosite -e asset-content-refilter-ip -e asset-content-refilter-site "$MOCK_LOG"; then
    printf '%s\n' 'FAIL: logs must not contain asset file contents' >&2
    exit 1
fi
assert_file_contains "$MOCK_LOG" 'logger -t xray-assets --'

printf '%s\n' 'PASS: asset updater'
