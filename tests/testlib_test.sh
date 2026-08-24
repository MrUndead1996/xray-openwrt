#!/bin/sh

set -eu

. tests/lib/testlib.sh

external_root=$(mktemp -d "${TMPDIR:-/tmp}/xray-openwrt-external.XXXXXX")
printf '%s\n' external > "$external_root/sentinel"
TEST_ROOT=$external_root
export TEST_ROOT

new_test_root

assert_file_exists "$external_root/sentinel"
assert_file_exists "$TEST_ROOT/bin"
assert_file_exists "$TEST_ROOT/tmp"
assert_file_exists "$TEST_ROOT/etc"
assert_file_exists "$TEST_ROOT/usr/bin"
assert_file_exists "$TEST_ROOT/usr/share/xray"

rm -rf "$external_root"
printf '%s\n' 'PASS: test library'
