#!/bin/sh

set -eu

. tests/lib/testlib.sh

workflow=.github/workflows/build.yml
sdk_url='https://downloads.openwrt.org/releases/25.12.0/targets/mediatek/filogic/openwrt-sdk-25.12.0-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst'
sdk_sha256='7e45a85b4af8af53ff17ca610ad6a7df312568cb52b730f93a21a91899f33139'

assert_file_exists "$workflow"
assert_file_contains "$workflow" 'pull_request:'
assert_file_not_contains "$workflow" '  push:'
assert_file_contains "$workflow" 'permissions:'
assert_file_contains "$workflow" 'contents: read'
assert_file_not_contains "$workflow" 'runner.temp'
assert_file_not_contains "$workflow" 'runner.'
assert_file_not_contains "$workflow" '    env:'
assert_file_contains "$workflow" 'actions/cache@'
assert_file_contains "$workflow" "$sdk_url"
assert_file_contains "$workflow" "$sdk_sha256"
assert_file_contains "$workflow" 'sha256sum -c'
assert_file_contains "$workflow" 'sudo apt-get update'
assert_file_contains "$workflow" 'sudo apt-get install -y rsync gawk zstd'
assert_file_contains "$workflow" 'set -eu'
assert_file_contains "$workflow" 'package/xray-openwrt-integration'
assert_file_contains "$workflow" 'make defconfig'
assert_file_contains "$workflow" 'make package/xray-openwrt-integration/compile V=s'
assert_file_contains "$workflow" 'find bin/packages -type f -name '\''xray-openwrt-integration-*.apk'\'''
assert_file_contains "$workflow" 'expected exactly one APK'
assert_file_contains "$workflow" 'apk_tool=$PWD/staging_dir/host/bin/apk'
assert_file_contains "$workflow" '"$apk_tool" extract'
assert_file_not_contains "$workflow" '"$sdk_dir/staging_dir/host/bin/apk" extract'
assert_file_contains "$workflow" 'find . -mindepth 1 -printf '\''%P\n'\'''
assert_file_not_contains "$workflow" 'tar --zstd -tf "$1"'
assert_file_not_contains "$workflow" 'tar --zstd -xf "$1"'
assert_file_contains "$workflow" 'usr/bin/xray'
assert_file_contains "$workflow" 'etc/xray/config.json'
assert_file_contains "$workflow" 'etc/init.d/xray'
assert_file_contains "$workflow" 'usr/bin/update-xray-core'
assert_file_contains "$workflow" 'usr/bin/update-xray-assets'
assert_file_contains "$workflow" 'usr/bin/rollback-xray-core'
assert_file_contains "$workflow" 'etc/xray/config.example.json'
assert_file_contains "$workflow" 'actions/upload-artifact@'
assert_file_contains "$workflow" 'retention-days:'

printf '%s\n' 'PASS: SDK workflow contract'
