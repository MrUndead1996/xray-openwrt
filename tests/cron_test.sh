#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

INSTALLER="$PWD/files/etc/uci-defaults/99-xray-cron"
CRONTAB="$TEST_ROOT/etc/crontabs/root"
MOCK_LOG="$TEST_ROOT/mock.log"
export MOCK_LOG

mkdir -p "$(dirname "$CRONTAB")"
cat > "$TEST_ROOT/bin/killall" <<'EOF'
#!/bin/sh
printf 'killall %s\n' "$*" >> "$MOCK_LOG"
EOF
/bin/chmod +x "$TEST_ROOT/bin/killall"

run_installer() {
    XRAY_CRONTAB="$CRONTAB" sh "$INSTALLER"
}

assert_canonical_cron() {
    expected="$TEST_ROOT/expected-cron"
    cat > "$expected" <<'EOF'
MAILTO=root
5 1 * * * /usr/local/bin/user-job
17 4 * * 0 /usr/bin/update-xray-assets # xray-openwrt-integration
47 4 * * 0 /usr/bin/update-xray-core # xray-openwrt-integration
EOF
    cmp -s "$expected" "$CRONTAB" || {
        printf '%s\n' 'FAIL: cron installer must preserve user jobs and install exactly canonical tagged jobs' >&2
        exit 1
    }
}

cat > "$CRONTAB" <<'EOF'
MAILTO=root
5 1 * * * /usr/local/bin/user-job
0 0 * * * /obsolete # xray-openwrt-integration
17 4 * * 0 /old-assets # xray-openwrt-integration
EOF
: > "$MOCK_LOG"
run_installer
assert_canonical_cron
assert_file_contains "$MOCK_LOG" 'killall -HUP crond'

: > "$MOCK_LOG"
run_installer
assert_canonical_cron
if [ -s "$MOCK_LOG" ]; then
    printf '%s\n' 'FAIL: unchanged crontab must not signal cron' >&2
    exit 1
fi

printf '%s\n' 'PASS: cron installation'
