#!/usr/bin/env bats

load helpers

setup() {
    source_install_script
}

@test "legacy positional args map to xraycaddy profile" {
    parse_args example.com seed123 /var/www/html acme "" "" user@example.com || return 1
    [ "$INSTALL_PROFILE" = "xraycaddy" ]
    [ "$DOMAIN" = "example.com" ]
    [ "$KCP_SEED" = "seed123" ]
    [ "$WWW_ROOT" = "/var/www/html" ]
    [ "$CERT_TYPE" = "acme" ]
    [ "$EMAIL" = "user@example.com" ]
}

@test "legacy positional args apply default email" {
    parse_args example.com seed123 /var/www/html || return 1

    [ "$INSTALL_PROFILE" = "xraycaddy" ]
    [ "$EMAIL" = "admin@example.com" ]
}

@test "legacy positional args require domain seed and www root" {
    run parse_args example.com seed123

    [ "$status" -ne 0 ]
    [[ "$output" == *"使用方法"* ]]
}

@test "named arg without value fails parse" {
    run parse_args --domain

    [ "$status" -ne 0 ]
    [[ "$output" == *"选项 --domain 需要一个值"* ]]
}

@test "named arg followed by another option fails parse" {
    run parse_args --domain --profile hysteria2

    [ "$status" -ne 0 ]
    [[ "$output" == *"选项 --domain 需要一个值"* ]]
}

@test "unknown named arg fails parse" {
    run parse_args --unknown-flag

    [ "$status" -ne 0 ]
    [[ "$output" == *"未知选项或参数: --unknown-flag"* ]]
}

@test "named arg accepts explicit empty value" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-tls-verify-note '' || return 1

    [ "$HYSTERIA_TLS_VERIFY_NOTE" = "" ]
}

@test "named args without domain do not derive invalid defaults" {
    parse_args \
        --profile hysteria2 \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    [ "$EMAIL" = "" ]
    [ "$HYSTERIA_SNI" = "" ]

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"缺少必需参数: domain"* ]]
}

@test "named args parse hysteria2 profile defaults" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1
    [ "$INSTALL_PROFILE" = "hysteria2" ]
    [ "$DOMAIN" = "example.com" ]
    [ "$HYSTERIA_PORT" = "8443" ]
    [ "$HYSTERIA_SNI" = "example.com" ]
    [ "$HYSTERIA_CLIENT_SOCKS5_PORT" = "1080" ]
}

@test "named args parse all profile Hysteria2 port default" {
    parse_args \
        --profile all \
        --domain example.com \
        --kcp-seed seed123 \
        --www-root /var/www/html \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1
    [ "$INSTALL_PROFILE" = "all" ]
    [ "$HYSTERIA_PORT" = "8443" ]
}

@test "invalid profile fails validation" {
    parse_args --profile invalid --domain example.com || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"无效安装 profile"* ]]
}

@test "hysteria2 rejects UDP 443 because it is reserved for XHTTP" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-port 443 \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"Hysteria2 不能使用 UDP/443"* ]]
}

@test "hysteria2 parses port hopping options" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-port-hopping \
        --hysteria-port-hopping-range 20000-40000 \
        --hysteria-port-hopping-interval 20s || return 1

    validate_profile_inputs || return 1

    [ "$HYSTERIA_PORT_HOPPING_ENABLED" = "true" ]
    [ "$HYSTERIA_PORT_HOPPING_RANGE" = "20000-40000" ]
    [ "$HYSTERIA_PORT_HOPPING_INTERVAL" = "20s" ]
}

@test "hysteria2 port hopping requires range" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-port-hopping || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"必须提供端口范围"* ]]
}

@test "hysteria2 port hopping rejects ranges containing UDP 443" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-port-hopping \
        --hysteria-port-hopping-range 400-500 || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"端口跳跃范围不能包含 UDP/443"* ]]
}

@test "all profile port hopping rejects ranges containing UDP 2052" {
    parse_args \
        --profile all \
        --domain example.com \
        --kcp-seed seed123 \
        --www-root /var/www/html \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-port-hopping \
        --hysteria-port-hopping-range 2000-3000 || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"UDP/2052"* ]]
}

@test "hysteria2 port hopping rejects invalid interval" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-port-hopping \
        --hysteria-port-hopping-range 20000-40000 \
        --hysteria-port-hopping-interval soon || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"端口跳跃间隔"* ]]
}

@test "all profile requires existing certificates" {
    parse_args \
        --profile all \
        --domain example.com \
        --kcp-seed seed123 \
        --www-root /var/www/html \
        --cert-mode acme \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"all profile 必须使用现有证书"* ]]
}

@test "xraycaddy profile rejects hysteria acme cert mode" {
    parse_args \
        --profile xraycaddy \
        --domain example.com \
        --kcp-seed seed123 \
        --www-root /var/www/html \
        --cert-mode hysteria-acme || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"hysteria-acme 证书模式仅支持 hysteria2 profile"* ]]
}

@test "hysteria2 profile accepts hysteria acme cert mode" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode hysteria-acme \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    validate_profile_inputs || return 1

    [ "$CERT_TYPE" = "hysteria-acme" ]
    [ "$EMAIL" = "admin@example.com" ]
}

@test "hysteria2 profile rejects generic acme cert mode" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode acme \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"--cert-mode hysteria-acme"* ]]
}

@test "hysteria2 requires auth password and masquerade url" {
    parse_args --profile hysteria2 --domain example.com --cert-mode existing --cert-path /cert.pem --key-path /key.pem || return 1

    run validate_profile_inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"缺少 Hysteria2 auth password"* ]]
}
