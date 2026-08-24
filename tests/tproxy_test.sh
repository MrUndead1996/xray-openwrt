#!/bin/sh

set -eu

. tests/lib/testlib.sh

new_test_root

MOCK_LOG="$TEST_ROOT/mock.log"
NFT_INPUT="$TEST_ROOT/nft-input.log"
NFT_STATE="$TEST_ROOT/nft-state"
IP_RULES_FILE="$TEST_ROOT/ip-rules"
IP_ROUTE_STATE="$TEST_ROOT/ip-route-state"
IP_ROUTE_TABLE="$TEST_ROOT/ip-route-table"
IP_ROUTE_SPEC="$TEST_ROOT/ip-route-spec"
NFT_PROFILE="$TEST_ROOT/nft-profile"
NFT_RULESET="$TEST_ROOT/nft-ruleset"
TPROXY_STATE="$TEST_ROOT/tproxy.state"
UCI_FUNCTIONS="$TEST_ROOT/functions.sh"
TPROXY="$PWD/files/usr/libexec/xray/tproxy"
IFACE_HOOK="$PWD/files/etc/hotplug.d/iface/99-xray"
FIREWALL_HOOK="$PWD/files/etc/hotplug.d/firewall/99-xray"
export MOCK_LOG NFT_INPUT NFT_STATE IP_RULES_FILE IP_ROUTE_STATE IP_ROUTE_TABLE \
    IP_ROUTE_SPEC NFT_PROFILE NFT_RULESET TPROXY_STATE

cat > "$TEST_ROOT/bin/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >> "$MOCK_LOG"

case "$*" in
    '-4 -o addr show scope global')
        printf '%s\n' "${IP_ADDRS:-}"
        ;;
    'rule show')
        cat "$IP_RULES_FILE"
        ;;
    'route replace local default dev lo table '*)
        [ "${IP_ROUTE_REPLACE_STATUS:-0}" -eq 0 ] || exit "$IP_ROUTE_REPLACE_STATUS"
        [ "${IP_ROUTE_REPLACE_FAIL_TABLE:-}" != "$8" ] || exit 1
        printf '%s\n' present > "$IP_ROUTE_STATE"
        printf '%s\n' "$8" > "$IP_ROUTE_TABLE"
        printf '%s\n' "$*" > "$IP_ROUTE_SPEC"
        ;;
    'route del local default dev lo table '*)
        printf '%s\n' absent > "$IP_ROUTE_STATE"
        printf 'deleted:%s\n' "$8" > "$IP_ROUTE_TABLE"
        printf '%s\n' "$*" > "$IP_ROUTE_SPEC"
        ;;
    'rule del pref '*)
        awk -v priority="$4:" -v rule_mark="$6" -v rule_table="$8" '
            $1 == priority && $2 == "from" && $3 == "all" &&
            $4 == "fwmark" && $5 == rule_mark && $6 == "lookup" &&
            $7 == rule_table && NF == 7 { next }
            { print }' "$IP_RULES_FILE" > "$IP_RULES_FILE.new"
        mv "$IP_RULES_FILE.new" "$IP_RULES_FILE"
        ;;
    'rule add pref '*)
        printf '%s\tfrom all fwmark %s lookup %s\n' "$4:" "$6" "$8" >> "$IP_RULES_FILE"
        ;;
esac
EOF

cat > "$TEST_ROOT/bin/nft" <<'EOF'
#!/bin/sh
printf 'nft %s\n' "$*" >> "$MOCK_LOG"

case "$1 $2" in
    '-c -f')
        cat "$3" >> "$NFT_INPUT"
        printf '\n-- nft batch --\n' >> "$NFT_INPUT"
        exit "${NFT_CHECK_STATUS:-0}"
        ;;
    '-f '*)
        cat "$2" >> "$NFT_INPUT"
        printf '\n-- nft batch --\n' >> "$NFT_INPUT"
        if [ "${NFT_APPLY_STATUS:-0}" -eq 0 ] && \
            grep -F -q -e 'table inet xray {' "$2"; then
            printf '%s\n' present > "$NFT_STATE"
            sed -n 's/.*tproxy ip to 127.0.0.1:\([0-9][0-9]*\).*/\1/p' "$2" > "$NFT_PROFILE"
            cp "$2" "$NFT_RULESET"
        fi
        exit "${NFT_APPLY_STATUS:-0}"
        ;;
    'list table')
        [ "$(cat "$NFT_STATE")" = present ] || exit 1
        ;;
    'delete table')
        printf '%s\n' absent > "$NFT_STATE"
        : > "$NFT_PROFILE"
        : > "$NFT_RULESET"
        ;;
esac
EOF

cat > "$TEST_ROOT/bin/getent" <<'EOF'
#!/bin/sh
printf 'getent %s\n' "$*" >> "$MOCK_LOG"
printf 'xray:x:1234:\n'
EOF

cat > "$UCI_FUNCTIONS" <<'EOF'
config_load() {
    printf 'config_load %s\n' "$1" >> "$MOCK_LOG"
}

config_get() {
    variable=$1
    option=$3
    default=${4:-}
    case "$option" in
        enabled) value=${UCI_ENABLED:-1} ;;
        tproxy_port) value=${UCI_TPROXY_PORT:-52345} ;;
        mark) value=${UCI_MARK:-0x40} ;;
        mask) value=${UCI_MASK:-0xc0} ;;
        bypass_mark) value=${UCI_BYPASS_MARK:-0x80} ;;
        route_table) value=${UCI_ROUTE_TABLE:-100} ;;
        *) value=$default ;;
    esac
    eval "$variable=\$value"
}

config_list_foreach() {
    section=$1
    option=$2
    callback=$3
    [ "$option" = bypass_cidr ] || return 0
    old_ifs=$IFS
    IFS='|'
    set -- ${UCI_BYPASS_CIDRS:-}
    IFS=$old_ifs
    for value in "$@"; do
        [ -n "$value" ] && "$callback" "$value" || :
    done
    return 0
}
EOF

cat > "$TEST_ROOT/bin/tproxy" <<'EOF'
#!/bin/sh
printf 'tproxy %s\n' "$*" >> "$MOCK_LOG"
EOF

/bin/chmod +x "$TEST_ROOT/bin/ip" "$TEST_ROOT/bin/nft" "$TEST_ROOT/bin/getent" \
    "$TEST_ROOT/bin/tproxy"

run_tproxy() {
    XRAY_FUNCTIONS_PATH="$UCI_FUNCTIONS" \
    XRAY_TPROXY_RULESET="$PWD/files/etc/xray/tproxy.nft" \
    XRAY_TPROXY_TMPDIR="$TEST_ROOT/tmp" \
    XRAY_TPROXY_STATE="$TPROXY_STATE" \
    sh "$TPROXY" "$@"
}

reset_mocks() {
    : > "$MOCK_LOG"
    : > "$NFT_INPUT"
    : > "$NFT_PROFILE"
    rm -f "$TPROXY_STATE"
    printf '%s\n' present > "$NFT_STATE"
    printf '%s\n' absent > "$IP_ROUTE_STATE"
    : > "$IP_ROUTE_TABLE"
    : > "$IP_ROUTE_SPEC"
    : > "$NFT_RULESET"
    cat > "$IP_RULES_FILE" <<'EOF'
10000:	from all fwmark 0x40/0xc0 lookup 100
11000:	from 192.0.2.9 fwmark 0x40/0xc0 lookup 100
12000: from all fwmark 0x80/0xc0 lookup 100
EOF
    IP_ADDRS=''
    UCI_ENABLED=1
    UCI_TPROXY_PORT=52345
    UCI_MARK=0x40
    UCI_MASK=0xc0
    UCI_BYPASS_MARK=0x80
    UCI_ROUTE_TABLE=100
    UCI_BYPASS_CIDRS=''
    NFT_CHECK_STATUS=0
    NFT_APPLY_STATUS=0
    IP_ROUTE_REPLACE_STATUS=0
    IP_ROUTE_REPLACE_FAIL_TABLE=
    export IP_ADDRS UCI_ENABLED UCI_TPROXY_PORT UCI_MARK UCI_MASK \
        UCI_BYPASS_MARK UCI_ROUTE_TABLE UCI_BYPASS_CIDRS \
        NFT_CHECK_STATUS NFT_APPLY_STATUS IP_ROUTE_REPLACE_STATUS \
        IP_ROUTE_REPLACE_FAIL_TABLE
}

assert_log_count() {
    expected=$1
    text=$2
    actual=$(grep -F -c -e "$text" "$MOCK_LOG" || :)
    assert_eq "$expected" "$actual" "expected $expected occurrences of: $text"
}

assert_no_log() {
    text=$1
    if grep -F -q -e "$text" "$MOCK_LOG"; then
        printf '%s\n' "FAIL: unexpected command: $text" >&2
        exit 1
    fi
}

assert_status_failure() {
    if "$@"; then
        printf '%s\n' 'FAIL: expected command to fail' >&2
        exit 1
    fi
}

reset_mocks
run_tproxy start
assert_eq present "$(cat "$NFT_STATE")"
assert_eq present "$(cat "$IP_ROUTE_STATE")"
assert_file_contains "$MOCK_LOG" 'ip route replace local default dev lo table 100'
assert_log_count 1 'ip rule del pref 10000 fwmark 0x40/0xc0 table 100'
assert_log_count 1 'ip rule add pref 10000 fwmark 0x40/0xc0 table 100'
assert_file_contains "$IP_RULES_FILE" '11000:'
assert_file_contains "$IP_RULES_FILE" 'from 192.0.2.9 fwmark 0x40/0xc0 lookup 100'
assert_file_contains "$MOCK_LOG" 'nft -c -f '
assert_file_contains "$MOCK_LOG" 'nft -f '
assert_no_log 'nft delete table inet xray'
check_line=$(grep -n -F -e 'nft -c -f ' "$MOCK_LOG" | sed -n '1s/:.*//p')
apply_line=$(grep -n -F -e 'nft -f ' "$MOCK_LOG" | sed -n '1s/:.*//p')
[ "$check_line" -lt "$apply_line" ] || {
    printf '%s\n' 'FAIL: nft input must be syntax-checked before application' >&2
    exit 1
}
assert_file_contains "$NFT_INPUT" 'destroy table inet xray'
assert_file_contains "$NFT_INPUT" 'tproxy ip to 127.0.0.1:52345'
assert_file_contains "$NFT_INPUT" 'skgid 1234 return'
assert_file_not_contains "$NFT_INPUT" 'elements = { }'

reset_mocks
run_tproxy start
run_tproxy start
assert_log_count 2 'ip route replace local default dev lo table 100'
assert_log_count 2 'ip rule del pref 10000 fwmark 0x40/0xc0 table 100'
assert_log_count 2 'ip rule add pref 10000 fwmark 0x40/0xc0 table 100'
assert_eq 1 "$(awk '$1 == "10000:" && $2 == "from" && $3 == "all" && $4 == "fwmark" && $5 == "0x40/0xc0" && $6 == "lookup" && $7 == "100" && NF == 7 { count++ } END { print count + 0 }' "$IP_RULES_FILE")"
assert_file_contains "$IP_RULES_FILE" '11000:'
assert_file_contains "$IP_RULES_FILE" 'from 192.0.2.9 fwmark 0x40/0xc0 lookup 100'

reset_mocks
NFT_CHECK_STATUS=1
export NFT_CHECK_STATUS
assert_status_failure run_tproxy start
assert_eq present "$(cat "$NFT_STATE")"
assert_eq absent "$(cat "$IP_ROUTE_STATE")"
assert_no_log 'nft -f '
assert_no_log 'ip route '
assert_no_log 'ip rule '

reset_mocks
NFT_APPLY_STATUS=1
export NFT_APPLY_STATUS
assert_status_failure run_tproxy start
assert_eq present "$(cat "$NFT_STATE")"
assert_eq absent "$(cat "$IP_ROUTE_STATE")"
assert_file_contains "$MOCK_LOG" 'nft -c -f '
assert_file_contains "$MOCK_LOG" 'nft -f '
assert_no_log 'nft delete table inet xray'
assert_no_log 'ip route '
assert_no_log 'ip rule '

reset_mocks
IP_ROUTE_REPLACE_STATUS=1
export IP_ROUTE_REPLACE_STATUS
assert_status_failure run_tproxy start
assert_eq absent "$(cat "$NFT_STATE")"
assert_eq absent "$(cat "$IP_ROUTE_STATE")"
assert_file_contains "$MOCK_LOG" 'nft delete table inet xray'

reset_mocks
UCI_BYPASS_CIDRS='192.0.2.0/24|not-an-ip'
export UCI_BYPASS_CIDRS
if run_tproxy start > "$TEST_ROOT/invalid-cidr.out" 2>&1; then
    printf '%s\n' 'FAIL: invalid bypass CIDR must fail' >&2
    exit 1
fi
assert_file_contains "$TEST_ROOT/invalid-cidr.out" 'invalid bypass_cidr'
assert_no_log 'nft '
assert_no_log 'ip route '
assert_no_log 'ip rule '

reset_mocks
IP_ADDRS='2: br-lan    inet 192.168.1.1/24 scope global br-lan
3: wan    inet 198.51.100.2/24 scope global wan'
export IP_ADDRS
run_tproxy update-interfaces
assert_file_contains "$NFT_INPUT" 'flush set inet xray interface'
assert_file_contains "$NFT_INPUT" 'add element inet xray interface { 192.168.1.1, 198.51.100.2 }'

reset_mocks
run_tproxy update-interfaces
assert_file_contains "$NFT_INPUT" 'flush set inet xray interface'
assert_file_not_contains "$NFT_INPUT" '{ , }'
assert_file_not_contains "$NFT_INPUT" 'add element inet xray interface'

reset_mocks
printf '%s\n' absent > "$NFT_STATE"
run_tproxy update-interfaces
assert_file_contains "$MOCK_LOG" 'nft list table inet xray'
assert_no_log 'nft -c -f '
assert_no_log 'nft -f '

reset_mocks
IP_ADDRS='2: br-lan    inet 192.168.1.1/24 scope global br-lan'
export IP_ADDRS
run_tproxy reload
assert_no_log 'ip rule '
assert_no_log 'ip route '
assert_file_contains "$MOCK_LOG" 'nft -c -f '
assert_file_contains "$NFT_INPUT" 'add element inet xray interface { 192.168.1.1 }'

reset_mocks
run_tproxy stop
assert_eq absent "$(cat "$NFT_STATE")"
assert_eq absent "$(cat "$IP_ROUTE_STATE")"
assert_log_count 1 'ip rule del pref 10000 fwmark 0x40/0xc0 table 100'
assert_file_contains "$IP_RULES_FILE" '11000:'
assert_file_contains "$IP_RULES_FILE" 'from 192.0.2.9 fwmark 0x40/0xc0 lookup 100'
assert_file_contains "$MOCK_LOG" 'ip route del local default dev lo table 100'

reset_mocks
UCI_MARK=0x41
UCI_MASK=0xc1
UCI_ROUTE_TABLE=101
export UCI_MARK UCI_MASK UCI_ROUTE_TABLE
run_tproxy start
assert_file_exists "$TPROXY_STATE"
assert_file_contains "$IP_RULES_FILE" 'fwmark 0x41/0xc1 lookup 101'
: > "$MOCK_LOG"
UCI_MARK=invalid
export UCI_MARK
run_tproxy stop
assert_no_log 'config_load xray'
assert_eq absent "$(cat "$NFT_STATE")"
assert_eq absent "$(cat "$IP_ROUTE_STATE")"
assert_file_not_contains "$IP_RULES_FILE" 'fwmark 0x41/0xc1 lookup 101'
assert_file_contains "$IP_RULES_FILE" '10000:'
assert_file_contains "$IP_RULES_FILE" 'from all fwmark 0x40/0xc0 lookup 100'
assert_file_contains "$IP_RULES_FILE" '11000:'
assert_file_contains "$IP_RULES_FILE" 'from 192.0.2.9 fwmark 0x40/0xc0 lookup 100'
assert_file_contains "$MOCK_LOG" 'ip route del local default dev lo table 101'
assert_file_not_exists "$TPROXY_STATE"

reset_mocks
UCI_TPROXY_PORT=52345
UCI_MARK=0x41
UCI_MASK=0xc1
UCI_ROUTE_TABLE=101
export UCI_TPROXY_PORT UCI_MARK UCI_MASK UCI_ROUTE_TABLE
run_tproxy start
cp "$TPROXY_STATE" "$TEST_ROOT/prior-tproxy.state"
cp "$NFT_RULESET" "$TEST_ROOT/prior-nft.ruleset"
UCI_TPROXY_PORT=52346
UCI_MARK=0x42
UCI_MASK=0xc2
UCI_ROUTE_TABLE=102
IP_ROUTE_REPLACE_FAIL_TABLE=102
export UCI_TPROXY_PORT UCI_MARK UCI_MASK UCI_ROUTE_TABLE IP_ROUTE_REPLACE_FAIL_TABLE
assert_status_failure run_tproxy start
assert_eq present "$(cat "$NFT_STATE")"
assert_eq 52345 "$(cat "$NFT_PROFILE")"
assert_eq present "$(cat "$IP_ROUTE_STATE")"
assert_eq 101 "$(cat "$IP_ROUTE_TABLE")"
assert_eq 'route replace local default dev lo table 101' "$(cat "$IP_ROUTE_SPEC")"
cmp -s "$TEST_ROOT/prior-nft.ruleset" "$NFT_RULESET" || {
    printf '%s\n' 'FAIL: rollback must restore the complete prior applied nft batch' >&2
    exit 1
}
assert_eq 1 "$(awk '$1 == "10000:" && $2 == "from" && $3 == "all" && $4 == "fwmark" && $5 == "0x41/0xc1" && $6 == "lookup" && $7 == "101" && NF == 7 { count++ } END { print count + 0 }' "$IP_RULES_FILE")"
assert_file_not_contains "$IP_RULES_FILE" 'fwmark 0x42/0xc2 lookup 102'
cmp -s "$TEST_ROOT/prior-tproxy.state" "$TPROXY_STATE" || {
    printf '%s\n' 'FAIL: rollback must retain the complete prior TProxy snapshot' >&2
    exit 1
}

reset_mocks
if run_tproxy unexpected > "$TEST_ROOT/unknown.out" 2>&1; then
    printf '%s\n' 'FAIL: unknown command must fail' >&2
    exit 1
else
    status=$?
fi
assert_eq 2 "$status"
assert_file_contains "$TEST_ROOT/unknown.out" 'Usage:'

reset_mocks
ACTION=ifup XRAY_TPROXY_HELPER="$TEST_ROOT/bin/tproxy" sh "$IFACE_HOOK"
assert_log_count 1 'tproxy update-interfaces'
assert_log_count 0 'tproxy reload'

reset_mocks
ACTION=ifupdate XRAY_TPROXY_HELPER="$TEST_ROOT/bin/tproxy" sh "$IFACE_HOOK"
assert_log_count 1 'tproxy update-interfaces'
assert_log_count 0 'tproxy reload'

reset_mocks
ACTION=ifdown XRAY_TPROXY_HELPER="$TEST_ROOT/bin/tproxy" sh "$IFACE_HOOK"
assert_log_count 1 'tproxy update-interfaces'
assert_log_count 0 'tproxy reload'

reset_mocks
ACTION=reload XRAY_TPROXY_HELPER="$TEST_ROOT/bin/tproxy" sh "$FIREWALL_HOOK"
assert_log_count 1 'tproxy reload'
assert_log_count 0 'tproxy update-interfaces'

printf '%s\n' 'PASS: TProxy lifecycle'
