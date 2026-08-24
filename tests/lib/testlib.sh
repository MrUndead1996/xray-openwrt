#!/bin/sh

set -u

new_test_root() {
    if [ "${XRAY_TEST_ROOT_OWNED:-0}" = 1 ] && [ -n "${XRAY_TEST_ROOT:-}" ]; then
        rm -rf "$XRAY_TEST_ROOT"
    fi

    XRAY_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xray-openwrt-test.XXXXXX") || exit 1
    XRAY_TEST_ROOT_OWNED=1
    TEST_ROOT=$XRAY_TEST_ROOT
    export TEST_ROOT
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/tmp" "$TEST_ROOT/etc" \
        "$TEST_ROOT/usr/bin" "$TEST_ROOT/usr/share/xray"
    PATH="$TEST_ROOT/bin:$PATH"
    export PATH
    trap 'rm -rf "$XRAY_TEST_ROOT"' 0 1 2 3 15
}

assert_eq() {
    expected=$1
    actual=$2
    message=${3:-"expected '$expected', got '$actual'"}

    if [ "$expected" != "$actual" ]; then
        printf '%s\n' "FAIL: $message" >&2
        exit 1
    fi
}

assert_file_exists() {
    if [ ! -e "$1" ]; then
        printf '%s\n' "FAIL: expected file to exist: $1" >&2
        exit 1
    fi
}

assert_file_not_exists() {
    if [ -e "$1" ]; then
        printf '%s\n' "FAIL: expected file not to exist: $1" >&2
        exit 1
    fi
}

assert_file_contains() {
    file=$1
    text=$2

    assert_file_exists "$file"
    if ! grep -F -q -e "$text" "$file"; then
        printf '%s\n' "FAIL: expected $file to contain: $text" >&2
        exit 1
    fi
}

assert_file_not_contains() {
    file=$1
    text=$2

    assert_file_exists "$file"
    if grep -F -q -e "$text" "$file"; then
        printf '%s\n' "FAIL: expected $file not to contain: $text" >&2
        exit 1
    fi
}

assert_status() {
    expected=$1
    shift

    if "$@"; then
        actual=0
    else
        actual=$?
    fi

    assert_eq "$expected" "$actual" "expected status $expected, got $actual"
}
