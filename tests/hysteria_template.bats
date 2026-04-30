#!/usr/bin/env bats

load helpers

setup() {
    REPO_ROOT=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
    TEMPLATE_DIR="$REPO_ROOT/cfg_tpl"
}

@test "server template renders selected UDP port tls fields auth and proxy masquerade" {
    rendered=$(render_template "$TEMPLATE_DIR/hysteria2_server.yaml" \
        HYSTERIA_PORT 8443 \
        HYSTERIA_CERT_PATH /etc/ssl/example/fullchain.pem \
        HYSTERIA_KEY_PATH /etc/ssl/example/privkey.pem \
        HYSTERIA_AUTH_PASSWORD test-password \
        HYSTERIA_MASQUERADE_PROXY_URL https://example.org)

    [[ "$rendered" == *"listen: :8443"* ]]
    [[ "$rendered" == *"tls:"* ]]
    [[ "$rendered" == *"cert: /etc/ssl/example/fullchain.pem"* ]]
    [[ "$rendered" == *"key: /etc/ssl/example/privkey.pem"* ]]
    [[ "$rendered" == *"type: password"* ]]
    [[ "$rendered" == *"password: test-password"* ]]
    [[ "$rendered" == *"type: proxy"* ]]
    [[ "$rendered" == *"url: https://example.org"* ]]
    [[ "$rendered" == *"rewriteHost: true"* ]]
    [[ "$rendered" != *"HYSTERIA_CERT_BLOCK"* ]]
}

@test "server template does not enable Hysteria2 TCP masquerade listeners" {
    template=$(<"$TEMPLATE_DIR/hysteria2_server.yaml")

    [[ "$template" != *"listenHTTP"* ]]
    [[ "$template" != *"listenHTTPS"* ]]
}

@test "server acme template renders domains email auth and proxy masquerade" {
    rendered=$(render_template "$TEMPLATE_DIR/hysteria2_server_acme.yaml" \
        DOMAIN example.com \
        EMAIL admin@example.com \
        HYSTERIA_PORT 8443 \
        HYSTERIA_AUTH_PASSWORD test-password \
        HYSTERIA_MASQUERADE_PROXY_URL https://example.org)

    [[ "$rendered" == *"listen: :8443"* ]]
    [[ "$rendered" == *"acme:"* ]]
    [[ "$rendered" == *"- example.com"* ]]
    [[ "$rendered" == *"email: admin@example.com"* ]]
    [[ "$rendered" == *"password: test-password"* ]]
    [[ "$rendered" == *"url: https://example.org"* ]]
    [[ "$rendered" != *"HYSTERIA_CERT_PATH"* ]]
}

@test "client template renders server auth tls and local socks5 fields" {
    rendered=$(render_template "$TEMPLATE_DIR/hysteria2_client.yaml" \
        HYSTERIA_CLIENT_SERVER example.com:8443 \
        HYSTERIA_AUTH_PASSWORD test-password \
        HYSTERIA_SNI example.com \
        HYSTERIA_TLS_INSECURE false \
        HYSTERIA_CLIENT_SOCKS5_PORT 1080)

    [[ "$rendered" == *"server: example.com:8443"* ]]
    [[ "$rendered" == *"auth: test-password"* ]]
    [[ "$rendered" == *"sni: example.com"* ]]
    [[ "$rendered" == *"insecure: false"* ]]
    [[ "$rendered" == *"socks5:"* ]]
    [[ "$rendered" == *"listen: 127.0.0.1:1080"* ]]
}

@test "client port hopping template renders range and hop interval" {
    rendered=$(render_template "$TEMPLATE_DIR/hysteria2_client_port_hopping.yaml" \
        HYSTERIA_CLIENT_SERVER example.com:20000-40000 \
        HYSTERIA_AUTH_PASSWORD test-password \
        HYSTERIA_SNI example.com \
        HYSTERIA_TLS_INSECURE false \
        HYSTERIA_CLIENT_SOCKS5_PORT 1080 \
        HYSTERIA_PORT_HOPPING_INTERVAL 30s)

    [[ "$rendered" == *"server: example.com:20000-40000"* ]]
    [[ "$rendered" == *"transport:"* ]]
    [[ "$rendered" == *"hopInterval: 30s"* ]]
    [[ "$rendered" == *"listen: 127.0.0.1:1080"* ]]
}

@test "client info template includes uri and firewall guidance" {
    rendered=$(render_template "$TEMPLATE_DIR/hysteria2_client_info.txt" \
        DOMAIN example.com \
        HYSTERIA_PORT 8443 \
        HYSTERIA_SNI example.com \
        HYSTERIA_AUTH_PASSWORD test-password \
        HYSTERIA_CERT_MODE existing \
        HYSTERIA_TLS_VERIFY_NOTE public-ca \
        HYSTERIA_PORT_HOPPING_STATUS disabled \
        HYSTERIA_PORT_HOPPING_RANGE_DISPLAY N/A \
        HYSTERIA_PORT_HOPPING_INTERVAL_DISPLAY N/A \
        HYSTERIA_CLIENT_CONFIG_PATH /etc/hysteria/client.yaml \
        HYSTERIA2_URI 'hysteria2://test-password@example.com:8443/?sni=example.com#example.com')

    [[ "$rendered" == *"服务器: example.com"* ]]
    [[ "$rendered" == *"端口: 8443"* ]]
    [[ "$rendered" == *"认证密码: test-password"* ]]
    [[ "$rendered" == *"端口跳跃: disabled"* ]]
    [[ "$rendered" == *"客户端配置文件: /etc/hysteria/client.yaml"* ]]
    [[ "$rendered" == *"Hysteria2 URI: hysteria2://test-password@example.com:8443/?sni=example.com#example.com"* ]]
    [[ "$rendered" == *"UDP/8443"* ]]
}

@test "systemd template starts hysteria server with managed config" {
    unit=$(<"$TEMPLATE_DIR/hysteria2.service")

    [[ "$unit" == *"Description=Hysteria2 Service"* ]]
    [[ "$unit" == *"After=network-online.target"* ]]
    [[ "$unit" == *"ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml"* ]]
    [[ "$unit" == *"Restart=on-failure"* ]]
    [[ "$unit" == *"CapabilityBoundingSet=CAP_NET_BIND_SERVICE"* ]]
    [[ "$unit" != *"CAP_NET_ADMIN"* ]]
    [[ "$unit" == *"WantedBy=multi-user.target"* ]]
}
