#!/bin/sh

set -eu

. tests/lib/testlib.sh

assert_file_contains Makefile 'PKG_NAME:=xray-openwrt-integration'
assert_file_contains Makefile 'files/etc/init.d/xray'
assert_file_contains Makefile 'files/etc/xray/tproxy.nft'
assert_file_contains Makefile 'files/etc/hotplug.d/iface/99-xray'
assert_file_contains Makefile 'files/etc/hotplug.d/firewall/99-xray'
assert_file_contains Makefile 'files/etc/uci-defaults/99-xray-cron'
assert_file_contains Makefile 'files/usr/libexec/xray/common'
assert_file_contains Makefile 'files/usr/libexec/xray/tproxy'
assert_file_contains Makefile 'files/usr/bin/update-xray-assets'
assert_file_contains Makefile 'files/usr/bin/update-xray-core'
assert_file_contains Makefile 'files/usr/bin/rollback-xray-core'
assert_file_not_contains Makefile 'files/usr/bin/xray'
assert_file_contains Makefile '/etc/config/xray'
assert_file_exists files/etc/xray/config.example.json
assert_file_not_exists files/etc/xray/config.json
assert_file_exists files/etc/capabilities/xray.json
assert_file_contains files/etc/capabilities/xray.json 'net_admin'
assert_file_contains files/etc/capabilities/xray.json 'net_raw'
assert_file_contains Makefile 'files/etc/capabilities/xray.json'
assert_file_contains Makefile '$(1)/usr/share/xray'

if sed -n '/define Package\/xray-openwrt-integration\/install/,/^endef/p' Makefile | \
    grep -F -q -e '/etc/xray/config.json'; then
    printf '%s\n' 'FAIL: package install commands must not include config.json' >&2
    exit 1
fi

if sed -n '/define Package\/xray-openwrt-integration\/conffiles/,/^endef/p' Makefile | \
    grep -F -q -e '/etc/xray/config.json'; then
    printf '%s\n' 'FAIL: package conffiles must not include config.json' >&2
    exit 1
fi

if awk '
/define Package\/xray-openwrt-integration\/install/, /^endef/ {
    if ($0 ~ /current\//) {
        found = 1
    }
}
END { exit found ? 0 : 1 }
' Makefile; then
    printf '%s\n' 'FAIL: package install commands must not reference current/' >&2
    exit 1
fi

printf '%s\n' 'PASS: package composition'
