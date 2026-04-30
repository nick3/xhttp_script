#!/usr/bin/env bats

load helpers

setup() {
    source_install_script
    TEST_WORKDIR="$BATS_TEST_TMPDIR/work"
    mkdir -p "$TEST_WORKDIR"
}

redact_sample() {
    printf '%s\n' 'auth=test-password' | redact_sensitive_output
}

@test "render_hysteria2_templates writes server client and info files" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /etc/ssl/example/fullchain.pem \
        --key-path /etc/ssl/example/privkey.pem \
        --hysteria-port 8443 \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-client-socks5-port 1081 || return 1

    render_hysteria2_templates "$REPO_ROOT/cfg_tpl" "$TEST_WORKDIR/hysteria" || return 1

    [ -f "$TEST_WORKDIR/hysteria/config.yaml" ]
    [ -f "$TEST_WORKDIR/hysteria/client.yaml" ]
    [ -f "$TEST_WORKDIR/hysteria/client_config_info.txt" ]
    [[ "$(<"$TEST_WORKDIR/hysteria/config.yaml")" == *"listen: :8443"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/config.yaml")" == *"cert: /etc/ssl/example/fullchain.pem"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/config.yaml")" == *"url: https://example.org"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/client.yaml")" == *"listen: 127.0.0.1:1081"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/client_config_info.txt")" == *"客户端配置文件: $TEST_WORKDIR/hysteria/client.yaml"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/client_config_info.txt")" == *"hysteria2://test-password@example.com:8443/?sni=example.com#example.com"* ]]
}

@test "build_hysteria2_uri encodes reserved characters" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /etc/ssl/example/fullchain.pem \
        --key-path /etc/ssl/example/privkey.pem \
        --hysteria-port 8443 \
        --hysteria-auth 'p@ss word#1' \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    [ "$(build_hysteria2_uri)" = 'hysteria2://p%40ss%20word%231@example.com:8443/?sni=example.com#example.com' ]
}

@test "render_hysteria2_templates writes port hopping client config" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /etc/ssl/example/fullchain.pem \
        --key-path /etc/ssl/example/privkey.pem \
        --hysteria-port 8443 \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-port-hopping \
        --hysteria-port-hopping-range 20000-40000 \
        --hysteria-port-hopping-interval 20s || return 1

    render_hysteria2_templates "$REPO_ROOT/cfg_tpl" "$TEST_WORKDIR/hysteria" || return 1

    [[ "$(<"$TEST_WORKDIR/hysteria/config.yaml")" == *"listen: :8443"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/client.yaml")" == *"server: example.com:20000-40000"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/client.yaml")" == *"hopInterval: 20s"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/client_config_info.txt")" == *"端口跳跃: enabled"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/client_config_info.txt")" == *"客户端配置文件: $TEST_WORKDIR/hysteria/client.yaml"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/client_config_info.txt")" == *"hysteria2://test-password@example.com:20000-40000/?sni=example.com#example.com"* ]]
}

@test "render_hysteria2_templates writes acme server config" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode hysteria-acme \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org || return 1

    render_hysteria2_templates "$REPO_ROOT/cfg_tpl" "$TEST_WORKDIR/hysteria" || return 1

    [[ "$(<"$TEST_WORKDIR/hysteria/config.yaml")" == *"acme:"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/config.yaml")" == *"- example.com"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/config.yaml")" == *"email: admin@example.com"* ]]
    [[ "$(<"$TEST_WORKDIR/hysteria/config.yaml")" != *"cert:"* ]]
}

@test "port hopping rule script applies UDP redirect with fake iptables" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-port 8443 \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-port-hopping \
        --hysteria-port-hopping-range 20000-40000 || return 1

    HYSTERIA_PORT_HOPPING_SCRIPT_PATH="$TEST_WORKDIR/bin/hysteria2-port-hopping-rules"
    write_hysteria2_port_hopping_rule_script || return 1

    mkdir -p "$TEST_WORKDIR/fakebin"
    cat > "$TEST_WORKDIR/fakebin/iptables" <<'FAKE_IPTABLES'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_IPTABLES_CALLS"
case " $* " in
    *" -C "*) exit 1 ;;
    *" -A "*) exit 0 ;;
    *" -D "*) exit 1 ;;
esac
exit 0
FAKE_IPTABLES
    chmod +x "$TEST_WORKDIR/fakebin/iptables"

    FAKE_IPTABLES_CALLS="$TEST_WORKDIR/iptables.calls" \
        PATH="$TEST_WORKDIR/fakebin:/usr/bin:/bin" \
        "$HYSTERIA_PORT_HOPPING_SCRIPT_PATH" apply || return 1

    calls=$(<"$TEST_WORKDIR/iptables.calls")
    [[ "$calls" == *"-A PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 8443"* ]]
}

@test "port hopping systemd unit runs generated redirect script" {
    parse_args \
        --profile hysteria2 \
        --domain example.com \
        --cert-mode existing \
        --cert-path /cert.pem \
        --key-path /key.pem \
        --hysteria-port 8443 \
        --hysteria-auth test-password \
        --hysteria-masquerade-proxy-url https://example.org \
        --hysteria-port-hopping \
        --hysteria-port-hopping-range 20000-40000 || return 1

    HYSTERIA_PORT_HOPPING_SCRIPT_PATH="$TEST_WORKDIR/bin/hysteria2-port-hopping-rules"
    HYSTERIA_PORT_HOPPING_UNIT_PATH="$TEST_WORKDIR/systemd/hysteria2-port-hopping.service"

    write_hysteria2_port_hopping_rule_script || return 1
    write_hysteria2_port_hopping_systemd_unit || return 1

    [ -f "$HYSTERIA_PORT_HOPPING_UNIT_PATH" ]
    [[ "$(<"$HYSTERIA_PORT_HOPPING_UNIT_PATH")" == *"ExecStart=$HYSTERIA_PORT_HOPPING_SCRIPT_PATH apply"* ]]
    [[ "$(<"$HYSTERIA_PORT_HOPPING_UNIT_PATH")" == *"Before=hysteria2.service"* ]]
}

@test "render_template_file escapes sed replacement characters" {
    template="$TEST_WORKDIR/template.txt"
    output="$TEST_WORKDIR/output.txt"
    printf 'value=${VALUE}\n' > "$template"

    render_template_file "$template" "$output" VALUE 'a/b&c#done$now' || return 1

    [ "$(<"$output")" = 'value=a/b&c#done$now' ]
}

@test "render_template_file preserves empty values and backslashes" {
    template="$TEST_WORKDIR/template.txt"
    output="$TEST_WORKDIR/output.txt"
    printf 'path=${PATH_VALUE}\nempty=${EMPTY_VALUE}\n' > "$template"

    render_template_file "$template" "$output" PATH_VALUE 'C:\tmp\server#1&ok' EMPTY_VALUE '' || return 1

    [ "$(<"$output")" = $'path=C:\\tmp\\server#1&ok\nempty=' ]
}

@test "render_template_file rejects unmatched key value pairs" {
    template="$TEST_WORKDIR/template.txt"
    output="$TEST_WORKDIR/output.txt"
    printf 'value=${VALUE}\n' > "$template"

    run render_template_file "$template" "$output" VALUE

    [ "$status" -ne 0 ]
    [[ "$output" == *"模板渲染参数必须按 key/value 成对传入"* ]]
}

@test "render_template_file keeps existing output when template is missing" {
    output_file="$TEST_WORKDIR/output.txt"
    printf 'old-content\n' > "$output_file"

    run render_template_file "$TEST_WORKDIR/missing.txt" "$output_file" VALUE new

    [ "$status" -ne 0 ]
    [ "$(<"$output_file")" = 'old-content' ]
}

@test "write_install_state creates unified state file" {
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
        --install-state-path "$TEST_WORKDIR/state/install_state.env" || return 1

    write_install_state "$INSTALL_STATE_PATH" || return 1

    [ -f "$TEST_WORKDIR/state/install_state.env" ]
    [[ "$(<"$TEST_WORKDIR/state/install_state.env")" == *"INSTALL_PROFILE=all"* ]]
    [[ "$(<"$TEST_WORKDIR/state/install_state.env")" == *"INSTALLED_COMPONENTS=xray,caddy,hysteria2"* ]]
    [[ "$(<"$TEST_WORKDIR/state/install_state.env")" == *"HYSTERIA_PORT=8443"* ]]
    [[ "$(<"$TEST_WORKDIR/state/install_state.env")" == *"HYSTERIA_PORT_HOPPING_ENABLED=false"* ]]
}

@test "redact_sensitive_output hides registered Hysteria2 secrets" {
    add_secret_for_redaction test-password

    run redact_sample

    [ "$status" -eq 0 ]
    [ "$output" = "auth=<hidden>" ]
}
