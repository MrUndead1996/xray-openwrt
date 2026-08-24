#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

BUILDER="$PWD/scripts/build-apk-repository"
RENDERER="$PWD/scripts/render-repository-installer"
PUBLIC_KEY="$PWD/keys/xray-openwrt-repository.pem"
PUBLIC_KEY_SHA256="$PWD/keys/xray-openwrt-repository.pem.sha256"
REPOSITORY="$TEST_ROOT/repository"
SIGNING_KEY="$TEST_ROOT/signing-key.pem"
MOCK_LOG="$TEST_ROOT/mock.log"
export MOCK_LOG

mkdir -p "$REPOSITORY"
printf '%s\n' 'private fixture' > "$SIGNING_KEY"
printf '%s\n' 'apk fixture' \
    > "$REPOSITORY/xray-openwrt-integration-1.0.0-r1.apk"

cat > "$TEST_ROOT/bin/apk" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"

case "$1" in
    mkndx)
        shift
        output=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --output)
                    shift
                    output=$1
                    ;;
            esac
            shift
        done
        [ -n "$output" ] || exit 1
        [ "${MKNDX_STATUS:-0}" -eq 0 ] || exit "$MKNDX_STATUS"
        printf '%s\n' 'signed index fixture' > "$output"
        ;;
    adbdump)
        [ "$2" = --format ]
        [ "$3" = json ]
        [ -s "$4" ]
        [ "${ADBDUMP_STATUS:-0}" -eq 0 ] || exit "$ADBDUMP_STATUS"
        printf '%s\n' '{}'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/apk"

if sh "$BUILDER" "$TEST_ROOT/missing-apk" "$SIGNING_KEY" "$REPOSITORY"; then
    printf '%s\n' 'FAIL: non-executable APK tool must be rejected' >&2
    exit 1
fi

if sh "$BUILDER" "$TEST_ROOT/bin/apk" "$TEST_ROOT/missing-key" "$REPOSITORY"; then
    printf '%s\n' 'FAIL: missing signing key must be rejected' >&2
    exit 1
fi

mkdir "$TEST_ROOT/empty-repository"
if sh "$BUILDER" "$TEST_ROOT/bin/apk" "$SIGNING_KEY" "$TEST_ROOT/empty-repository"; then
    printf '%s\n' 'FAIL: repository without APKs must be rejected' >&2
    exit 1
fi

mkdir "$TEST_ROOT/bad-repository"
printf '%s\n' bad > "$TEST_ROOT/bad-repository/unexpected.apk"
if sh "$BUILDER" "$TEST_ROOT/bin/apk" "$SIGNING_KEY" "$TEST_ROOT/bad-repository"; then
    printf '%s\n' 'FAIL: noncanonical APK filename must be rejected' >&2
    exit 1
fi

: > "$MOCK_LOG"
sh "$BUILDER" "$TEST_ROOT/bin/apk" "$SIGNING_KEY" "$REPOSITORY"
assert_file_exists "$REPOSITORY/packages.adb"
assert_file_contains "$MOCK_LOG" "mkndx --root $REPOSITORY --keys-dir $REPOSITORY --allow-untrusted --sign $SIGNING_KEY --output $REPOSITORY/packages.adb.tmp $REPOSITORY/xray-openwrt-integration-1.0.0-r1.apk"
assert_file_contains "$MOCK_LOG" "adbdump --format json $REPOSITORY/packages.adb.tmp"

printf '%s\n' 'previous index' > "$REPOSITORY/packages.adb"
if MKNDX_STATUS=9 sh "$BUILDER" "$TEST_ROOT/bin/apk" "$SIGNING_KEY" "$REPOSITORY"; then
    printf '%s\n' 'FAIL: failed mkndx must fail repository build' >&2
    exit 1
fi
assert_eq 'previous index' "$(cat "$REPOSITORY/packages.adb")"
assert_file_not_exists "$REPOSITORY/packages.adb.tmp"

printf '%s\n' 'public key fixture' > "$TEST_ROOT/public.pem"
cat > "$TEST_ROOT/installer.in" <<'EOF'
key='@KEY_SHA256@'
feed='@FEED_URL@'
EOF

output="$TEST_ROOT/install-apk-repository"
feed_url='https://example.invalid/packages/25.12/aarch64_cortex-a53/packages.adb'
sh "$RENDERER" "$TEST_ROOT/installer.in" "$TEST_ROOT/public.pem" \
    "$feed_url" "$output"

expected_sha=$(sha256sum "$TEST_ROOT/public.pem" | awk '{print $1}')
assert_file_contains "$output" "key='$expected_sha'"
assert_file_contains "$output" "feed='$feed_url'"
assert_file_not_contains "$output" '@KEY_SHA256@'
assert_file_not_contains "$output" '@FEED_URL@'
assert_eq 755 "$(stat -c '%a' "$output")"

if sh "$RENDERER" "$TEST_ROOT/installer.in" "$TEST_ROOT/public.pem" \
    'http://example.invalid/packages.adb' "$output"; then
    printf '%s\n' 'FAIL: renderer must reject non-HTTPS feed URL' >&2
    exit 1
fi

assert_file_exists "$PUBLIC_KEY"
assert_file_exists "$PUBLIC_KEY_SHA256"
assert_file_contains "$PUBLIC_KEY" '-----BEGIN PUBLIC KEY-----'
assert_file_not_contains "$PUBLIC_KEY" 'PRIVATE'
assert_eq "$(cat "$PUBLIC_KEY_SHA256")" "$(sha256sum "$PUBLIC_KEY" | awk '{print $1}')"
openssl ec -pubin -in "$PUBLIC_KEY" -text -noout > "$TEST_ROOT/public-key-details"
assert_file_contains "$TEST_ROOT/public-key-details" 'ASN1 OID: prime256v1'
assert_file_contains .gitignore 'keys/*.key'
assert_file_contains .gitignore 'keys/*private*.pem'

printf '%s\n' 'PASS: signed APK repository builder'
