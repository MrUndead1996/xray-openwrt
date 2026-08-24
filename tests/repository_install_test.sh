#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

TEMPLATE="$PWD/scripts/install-apk-repository.in"
RENDERER="$PWD/scripts/render-repository-installer"
ETC_ROOT="$TEST_ROOT/etc"
MOCK_LOG="$TEST_ROOT/mock.log"
FIXTURE_KEY="$TEST_ROOT/repository.pem"
FIXTURE_INDEX="$TEST_ROOT/packages.adb"
FEED_URL='https://example.invalid/packages/25.12/aarch64_cortex-a53/packages.adb'
export MOCK_LOG FIXTURE_KEY FIXTURE_INDEX

mkdir -p "$ETC_ROOT/apk/keys" "$ETC_ROOT/apk/repositories.d"
printf '%s\n' 'fixture repository public key' > "$FIXTURE_KEY"
printf '%s\n' 'fixture signed index' > "$FIXTURE_INDEX"

cat > "$TEST_ROOT/bin/uclient-fetch" <<'EOF'
#!/bin/sh
printf 'fetch %s\n' "$*" >> "$MOCK_LOG"
[ "${FETCH_STATUS:-0}" -eq 0 ] || exit "$FETCH_STATUS"

output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q) ;;
        -O) shift; output=$1 ;;
        *) url=$1 ;;
    esac
    shift
done

[ -n "$output" ] && [ -n "$url" ] || exit 1
case "$url" in
    *.pem) cp "$FIXTURE_KEY" "$output" ;;
    */packages.adb) cp "$FIXTURE_INDEX" "$output" ;;
    *) exit 1 ;;
esac
EOF

cat > "$TEST_ROOT/bin/apk" <<'EOF'
#!/bin/sh
printf 'apk %s\n' "$*" >> "$MOCK_LOG"
[ "$1" = --keys-dir ] || exit 1
[ -d "$2" ] || exit 1
[ -f "$2/xray-openwrt-repository.pem" ] || exit 1
[ "$3" = verify ] || exit 1
[ -f "$4" ] || exit 1
exit "${APK_VERIFY_STATUS:-0}"
EOF
chmod +x "$TEST_ROOT/bin/uclient-fetch" "$TEST_ROOT/bin/apk"

render_installer() {
    sh "$RENDERER" "$TEMPLATE" "$FIXTURE_KEY" "$FEED_URL" "$TEST_ROOT/install-repository"
}

reset_etc() {
    release=${1:-25.12.2}
    arch=${2:-aarch64_cortex-a53}
    cat > "$ETC_ROOT/openwrt_release" <<EOF
DISTRIB_RELEASE='$release'
EOF
    printf '%s\n' "$arch" > "$ETC_ROOT/apk/arch"
    printf '%s\n' 'previous key' > "$ETC_ROOT/apk/keys/xray-openwrt-repository.pem"
    cat > "$ETC_ROOT/apk/repositories.d/customfeeds.list" <<'EOF'
# existing custom feeds
https://packages.example.test/other/packages.adb
EOF
    : > "$MOCK_LOG"
}

run_installer() {
    XRAY_ETC_ROOT="$ETC_ROOT" \
    XRAY_FETCH="$TEST_ROOT/bin/uclient-fetch" \
    XRAY_APK="$TEST_ROOT/bin/apk" \
        sh "$TEST_ROOT/install-repository"
}

assert_prior_state() {
    assert_eq 'previous key' "$(cat "$ETC_ROOT/apk/keys/xray-openwrt-repository.pem")"
    assert_file_contains "$ETC_ROOT/apk/repositories.d/customfeeds.list" '# existing custom feeds'
    assert_file_not_contains "$ETC_ROOT/apk/repositories.d/customfeeds.list" "$FEED_URL"
}

render_installer

reset_etc 24.10.4
if run_installer; then
    printf '%s\n' 'FAIL: unsupported OpenWrt release must be rejected' >&2
    exit 1
fi
assert_prior_state
assert_eq '' "$(cat "$MOCK_LOG")"

reset_etc 25.12.2 x86_64
if run_installer; then
    printf '%s\n' 'FAIL: unsupported APK architecture must be rejected' >&2
    exit 1
fi
assert_prior_state
assert_eq '' "$(cat "$MOCK_LOG")"

reset_etc
printf '%s\n' 'wrong public key' > "$FIXTURE_KEY"
if run_installer; then
    printf '%s\n' 'FAIL: wrong public-key fingerprint must be rejected' >&2
    exit 1
fi
assert_prior_state
assert_file_not_contains "$MOCK_LOG" 'apk --keys-dir'

printf '%s\n' 'fixture repository public key' > "$FIXTURE_KEY"
reset_etc
if APK_VERIFY_STATUS=7 run_installer; then
    printf '%s\n' 'FAIL: invalid repository signature must be rejected' >&2
    exit 1
fi
assert_prior_state
assert_file_contains "$MOCK_LOG" 'apk --keys-dir '

reset_etc
run_installer
assert_eq "$(cat "$FIXTURE_KEY")" "$(cat "$ETC_ROOT/apk/keys/xray-openwrt-repository.pem")"
assert_eq 644 "$(stat -c '%a' "$ETC_ROOT/apk/keys/xray-openwrt-repository.pem")"
assert_file_contains "$ETC_ROOT/apk/repositories.d/customfeeds.list" '# existing custom feeds'
assert_file_contains "$ETC_ROOT/apk/repositories.d/customfeeds.list" 'https://packages.example.test/other/packages.adb'
assert_eq 1 "$(grep -F -c -e "$FEED_URL" "$ETC_ROOT/apk/repositories.d/customfeeds.list")"
assert_eq 644 "$(stat -c '%a' "$ETC_ROOT/apk/repositories.d/customfeeds.list")"

key_hash_before=$(sha256sum "$ETC_ROOT/apk/keys/xray-openwrt-repository.pem")
feed_hash_before=$(sha256sum "$ETC_ROOT/apk/repositories.d/customfeeds.list")
run_installer
assert_eq "$key_hash_before" "$(sha256sum "$ETC_ROOT/apk/keys/xray-openwrt-repository.pem")"
assert_eq "$feed_hash_before" "$(sha256sum "$ETC_ROOT/apk/repositories.d/customfeeds.list")"
assert_eq 1 "$(grep -F -c -e "$FEED_URL" "$ETC_ROOT/apk/repositories.d/customfeeds.list")"

printf '%s\n' 'PASS: trusted APK repository enrollment'
