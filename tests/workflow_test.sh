#!/bin/sh

set -eu

. tests/lib/testlib.sh

workflow=.github/workflows/build.yml
release_workflow=.github/workflows/release.yml
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
assert_file_contains "$workflow" '--allow-untrusted'
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

assert_file_exists "$release_workflow"
assert_file_contains "$release_workflow" 'name: Publish OpenWrt APK repository'
assert_file_contains "$release_workflow" 'tags:'
assert_file_contains "$release_workflow" "- 'v*'"
assert_file_not_contains "$release_workflow" 'pull_request:'
assert_file_contains "$release_workflow" 'contents: write'
assert_file_contains "$release_workflow" 'pages: write'
assert_file_contains "$release_workflow" 'id-token: write'
assert_file_contains "$release_workflow" 'environment:'
assert_file_contains "$release_workflow" 'name: github-pages'
assert_file_contains "$release_workflow" 'secrets.XRAY_APK_SIGNING_KEY'
assert_file_contains "$release_workflow" 'package_version=$(sed -n'
assert_file_contains "$release_workflow" 'tag_version=${GITHUB_REF_NAME#v}'
assert_file_contains "$release_workflow" 'sh tests/run.sh'
assert_file_contains "$release_workflow" "$sdk_url"
assert_file_contains "$release_workflow" "$sdk_sha256"
assert_file_contains "$release_workflow" 'scripts/build-apk-repository'
assert_file_contains "$release_workflow" 'scripts/render-repository-installer'
assert_file_contains "$release_workflow" 'keys/xray-openwrt-repository.pem'
assert_file_contains "$release_workflow" 'XRAY_APK_SIGNING_KEY'
assert_file_contains "$release_workflow" 'gh api'
assert_file_contains "$release_workflow" 'packages/25.12/aarch64_cortex-a53'
assert_file_contains "$release_workflow" 'packages.adb'
assert_file_contains "$release_workflow" 'SHA256SUMS'
assert_file_contains "$release_workflow" 'actions/configure-pages@'
assert_file_contains "$release_workflow" 'actions/upload-pages-artifact@'
assert_file_contains "$release_workflow" 'actions/deploy-pages@'
assert_file_contains "$release_workflow" 'softprops/action-gh-release@'
assert_file_contains "$release_workflow" 'cancel-in-progress: false'
assert_file_not_contains "$release_workflow" 'BEGIN EC PRIVATE KEY'
assert_file_not_contains "$release_workflow" 'BEGIN PRIVATE KEY'

printf '%s\n' 'PASS: release workflow contract'
