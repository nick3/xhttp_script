#!/usr/bin/env bats

load helpers

setup() {
    source_install_script
    TEST_ROOT="$BATS_TEST_TMPDIR/root"
    PREFLIGHT_ROOT="$TEST_ROOT"
    PREFLIGHT_LISTENERS=""
    PREFLIGHT_SYSTEMD_UNITS=""
    mkdir -p "$TEST_ROOT"
}

write_install_state_fixture() {
    local profile="$1"
    mkdir -p "$TEST_ROOT/etc/xray-caddy"
    printf 'INSTALL_PROFILE=%s\n' "$profile" > "$TEST_ROOT/etc/xray-caddy/install_state.env"
}

write_legacy_xray_config_info() {
    mkdir -p "$TEST_ROOT/etc/xray"
    printf 'DOMAIN=example.com\n' > "$TEST_ROOT/etc/xray/config_info.txt"
}

write_systemd_unit_fixture() {
    local unit="$1"
    mkdir -p "$TEST_ROOT/etc/systemd/system"
    printf '[Unit]\nDescription=test\n' > "$TEST_ROOT/etc/systemd/system/$unit"
}

@test "preflight classifies fresh install when no known state exists" {
    parse_args --profile xraycaddy --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "fresh" ]
    [ "$PREFLIGHT_EXISTING_PROFILE" = "" ]
}

@test "preflight blocks same known existing profile" {
    write_install_state_fixture xraycaddy
    parse_args --profile xraycaddy --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "known_existing_profile" ]
    [ "$PREFLIGHT_EXISTING_PROFILE" = "xraycaddy" ]

    run run_existing_install_preflight

    [ "$status" -ne 0 ]
    [[ "$output" == *"known existing profile"* ]]
}

@test "preflight allows explicit xraycaddy to all extension" {
    write_install_state_fixture xraycaddy
    parse_args --profile all --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "extend_xraycaddy_to_all" ]
    [ "$PREFLIGHT_EXISTING_PROFILE" = "xraycaddy" ]

    run run_existing_install_preflight

    [ "$status" -eq 0 ]
    [[ "$output" == *"extend xraycaddy to all"* ]]
}

@test "preflight treats legacy xray config info as xraycaddy" {
    write_legacy_xray_config_info
    parse_args --profile all --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "extend_xraycaddy_to_all" ]
    [ "$PREFLIGHT_EXISTING_PROFILE" = "xraycaddy" ]
}

@test "preflight rejects xraycaddy to implicit hysteria2 install" {
    write_install_state_fixture xraycaddy
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "conflict_unknown" ]
    [[ "$PREFLIGHT_REASON" == *"不能静默安装 hysteria2"* ]]
}

@test "preflight rejects unknown state from systemd units without install state" {
    write_systemd_unit_fixture caddy.service
    parse_args --profile xraycaddy --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "conflict_unknown" ]
    [[ "$PREFLIGHT_REASON" == *"没有可识别的安装状态"* ]]
}

@test "preflight rejects invalid install state profile" {
    write_install_state_fixture invalid
    parse_args --profile xraycaddy --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "conflict_unknown" ]
    [[ "$PREFLIGHT_REASON" == *"profile 无效"* ]]
}

@test "preflight rejects stale xraycaddy state with hysteria2 listener" {
    write_install_state_fixture xraycaddy
    PREFLIGHT_LISTENERS="udp/8443"
    parse_args --profile all --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "conflict_unknown" ]
    [[ "$PREFLIGHT_REASON" == *"Hysteria2 服务或 UDP/8443 占用"* ]]
}

@test "preflight does not treat xraycaddy udp 443 as hysteria2" {
    write_install_state_fixture xraycaddy
    PREFLIGHT_LISTENERS="udp/443"
    parse_args --profile xraycaddy --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "known_existing_profile" ]
    [ "$PREFLIGHT_EXISTING_PROFILE" = "xraycaddy" ]
}

@test "preflight rejects listener only unknown state" {
    PREFLIGHT_LISTENERS="tcp/443"
    parse_args --profile xraycaddy --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "conflict_unknown" ]
    [[ "$PREFLIGHT_REASON" == *"没有可识别的安装状态"* ]]
}

@test "preflight blocks same known hysteria2 profile" {
    write_install_state_fixture hysteria2
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "known_existing_profile" ]
    [ "$PREFLIGHT_EXISTING_PROFILE" = "hysteria2" ]
}

@test "preflight rejects hysteria2 to xraycaddy rewrite" {
    write_install_state_fixture hysteria2
    parse_args --profile xraycaddy --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "conflict_unknown" ]
    [[ "$PREFLIGHT_REASON" == *"已有 hysteria2"* ]]
}

@test "preflight rejects stale hysteria2 state with xraycaddy signal" {
    write_install_state_fixture hysteria2
    write_systemd_unit_fixture caddy.service
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "conflict_unknown" ]
    [[ "$PREFLIGHT_REASON" == *"Xray/Caddy 服务"* ]]
}

@test "preflight blocks same known all profile" {
    write_install_state_fixture all
    parse_args --profile all --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "known_existing_profile" ]
    [ "$PREFLIGHT_EXISTING_PROFILE" = "all" ]
}

@test "preflight rejects all to xraycaddy rewrite" {
    write_install_state_fixture all
    parse_args --profile xraycaddy --domain example.com --kcp-seed seed123 --www-root /var/www/html || return 1

    classify_existing_install || return 1

    [ "$PREFLIGHT_STATUS" = "conflict_unknown" ]
    [[ "$PREFLIGHT_REASON" == *"已有 all profile"* ]]
}
