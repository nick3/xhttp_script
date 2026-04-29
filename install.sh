#!/bin/bash

# Strict mode is enabled only when this file runs as a script.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
fi

# --- Configuration & Parameters ---
# These will be passed as arguments to the script
# DOMAIN=$1
# KCP_SEED=$2
# WWW_ROOT=$3
# CERT_TYPE=$4  # "acme" or "existing"
# CERT_PATH=$5  # Path to certificate file (for existing cert)
# KEY_PATH=$6   # Path to key file (for existing cert)
# EMAIL=$7      # Email for ACME (optional if using existing cert)

# --- Helper Functions ---
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warning() {
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

HEALTH_FAILURES=0
HEALTH_WARNINGS=0
HEALTH_REPORT_STARTED=0
declare -a REDACTION_SECRETS=()

start_health_report() {
    if [ "$HEALTH_REPORT_STARTED" -eq 0 ]; then
        echo "=== Xray-Caddy Install Health Report ==="
        HEALTH_REPORT_STARTED=1
    fi
}

report_pass() {
    start_health_report
    printf 'PASS  %-24s %s\n' "$1" "$2"
}

report_warn() {
    start_health_report
    HEALTH_WARNINGS=$((HEALTH_WARNINGS + 1))
    printf 'WARN  %-24s %s\n' "$1" "$2"
}

report_fail() {
    start_health_report
    HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    printf 'FAIL  %-24s %s\n' "$1" "$2"
}

report_info() {
    start_health_report
    printf 'INFO  %-24s %s\n' "$1" "$2"
}

emit_health_result() {
    start_health_report
    if [ "$HEALTH_FAILURES" -gt 0 ]; then
        echo "RESULT FAIL"
    else
        echo "RESULT PASS"
    fi
    echo "WARNINGS $HEALTH_WARNINGS"
}

add_secret_for_redaction() {
    local secret="${1:-}"
    local existing
    [ -n "$secret" ] || return 0

    for existing in "${REDACTION_SECRETS[@]+"${REDACTION_SECRETS[@]}"}"; do
        [ "$existing" = "$secret" ] && return 0
    done

    REDACTION_SECRETS+=("$secret")
}

register_known_secrets() {
    local secret
    for secret in \
        "${PRIVATE_KEY:-}" \
        "${PUBLIC_KEY:-}" \
        "${UUID:-}" \
        "${KCP_SEED:-}" \
        "${HYSTERIA_AUTH_PASSWORD:-}" \
        "${ACME_DNS_PROVIDER_TOKEN:-}"; do
        add_secret_for_redaction "$secret"
    done
}

redact_sensitive_output() {
    local text
    local secret
    text=$(cat)

    register_known_secrets
    for secret in "${REDACTION_SECRETS[@]+"${REDACTION_SECRETS[@]}"}"; do
        if [ -n "$secret" ]; then
            text="${text//"$secret"/<hidden>}"
        fi
    done

    printf '%s\n' "$text"
}

print_journal_summary() {
    local unit="$1"
    log_error "${unit} 最近日志（已脱敏）:"
    journalctl -u "$unit" -n 30 --no-pager 2>&1 | redact_sensitive_output | while IFS= read -r line; do
        log_error "  $line"
    done
}

require_executable() {
    local label="$1"
    local path="$2"
    if [ -x "$path" ]; then
        report_pass "binary:$label" "$path"
    else
        report_fail "binary:$label" "$path missing or not executable; reinstall or check permissions"
    fi
}

validate_xray_config() {
    local output
    if output=$("$XRAY_EXE" run -test -c "$XRAY_CONFIG_OUTPUT_PATH" 2>&1); then
        report_pass "config:xray" "$XRAY_CONFIG_OUTPUT_PATH"
    else
        report_fail "config:xray" "$XRAY_CONFIG_OUTPUT_PATH invalid; run xray run -test for details"
        printf '%s\n' "$output" | redact_sensitive_output | while IFS= read -r line; do
            log_error "  $line"
        done
    fi
}

validate_caddy_config() {
    local output
    if output=$(/usr/local/bin/caddy validate --config "$CADDY_CONFIG_OUTPUT_PATH" 2>&1); then
        report_pass "config:caddy" "$CADDY_CONFIG_OUTPUT_PATH"
    else
        report_fail "config:caddy" "$CADDY_CONFIG_OUTPUT_PATH invalid; run caddy validate for details"
        printf '%s\n' "$output" | redact_sensitive_output | while IFS= read -r line; do
            log_error "  $line"
        done
    fi
}

stop_pid_file_process() {
    local pid_file="$1"
    local expected="$2"
    local label="$3"
    local pid=""
    local cmdline=""

    [ -f "$pid_file" ] || return 0
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" >/dev/null 2>&1; then
        cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
        if [[ "$cmdline" == *"$expected"* ]]; then
            log_info "停止旧的 $label fallback 进程 (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$pid_file"
}

kill_matching_processes() {
    local expected="$1"
    local label="$2"
    local pid=""
    local cmdline=""

    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
        if [[ "$cmdline" == *"$expected"* ]]; then
            log_info "停止旧的 $label fallback 进程 (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        fi
    done < <(pgrep -f "$expected" 2>/dev/null || true)
}

stop_existing_runtime() {
    systemctl stop caddy.service xray.service 2>/dev/null || true
    mkdir -p /var/run/xray-caddy
    stop_pid_file_process "/var/run/xray-caddy/caddy.pid" "/usr/local/bin/caddy run --config /etc/caddy/caddy.json" "Caddy"
    stop_pid_file_process "/var/run/xray-caddy/xray.pid" "/usr/local/bin/xray run -c /etc/xray/config.json" "Xray"
    kill_matching_processes "/usr/local/bin/caddy run --config /etc/caddy/caddy.json" "Caddy"
    kill_matching_processes "/usr/local/bin/xray run -c /etc/xray/config.json" "Xray"
}

write_systemd_units() {
    cat > /etc/systemd/system/caddy.service << 'EOF'
[Unit]
Description=Caddy HTTP/2 web server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/caddy.json
ExecReload=/bin/kill -USR1 $MAINPID
Restart=always
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
Group=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

wait_for_unit() {
    local unit="$1"
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet "$unit"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

check_systemd_unit() {
    local label="$1"
    local unit="$2"
    local active=""
    local enabled=""

    wait_for_unit "$unit" || true
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)

    if [ "$active" = "active" ] && [ "$enabled" = "enabled" ]; then
        report_pass "systemd:$label" "$active $enabled"
    else
        report_fail "systemd:$label" "active=$active enabled=$enabled; inspect journalctl -u $unit"
        print_journal_summary "$unit"
    fi
}

configure_xraycaddy_systemd_services() {
    if ! command -v systemctl >/dev/null 2>&1; then
        report_fail "systemd" "systemctl missing; this installer requires a Debian/Ubuntu systemd VPS"
        return 1
    fi

    stop_existing_runtime
    write_systemd_units

    if ! systemctl daemon-reload; then
        report_fail "systemd:daemon" "daemon-reload failed; inspect systemctl status and unit files"
        return 1
    fi

    if ! systemctl enable caddy.service xray.service >/dev/null; then
        report_fail "systemd:enable" "enable failed; inspect systemctl status caddy.service xray.service"
        return 1
    fi

    if ! systemctl restart caddy.service xray.service; then
        log_warning "systemd restart 返回失败，健康报告将读取服务状态和日志。"
    fi

    check_systemd_unit "xray" "xray.service"
    check_systemd_unit "caddy" "caddy.service"
}

write_hysteria2_systemd_unit() {
    if [ ! -f "./cfg_tpl/hysteria2.service" ]; then
        report_fail "systemd:hysteria2" "./cfg_tpl/hysteria2.service template missing"
        return 1
    fi

    cp "./cfg_tpl/hysteria2.service" "/etc/systemd/system/hysteria2.service"
}

configure_hysteria2_systemd_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        report_fail "systemd" "systemctl missing; this installer requires a Debian/Ubuntu systemd VPS"
        return 1
    fi

    systemctl stop hysteria2.service 2>/dev/null || true
    write_hysteria2_systemd_unit || return 1

    if ! systemctl daemon-reload; then
        report_fail "systemd:daemon" "daemon-reload failed; inspect systemctl status and unit files"
        return 1
    fi

    if [ "$HYSTERIA_PORT_HOPPING_ENABLED" = "true" ]; then
        if ! systemctl enable --now hysteria2-port-hopping.service >/dev/null; then
            report_fail "firewall:port-hopping" "failed to apply UDP/${HYSTERIA_PORT_HOPPING_RANGE} -> UDP/${HYSTERIA_PORT} redirect rules"
            return 1
        fi
        check_systemd_unit "hysteria-hop" "hysteria2-port-hopping.service"
    fi

    if ! systemctl enable hysteria2.service >/dev/null; then
        report_fail "systemd:enable" "enable failed; inspect systemctl status hysteria2.service"
        return 1
    fi

    if ! systemctl restart hysteria2.service; then
        log_warning "Hysteria2 systemd restart 返回失败，健康报告将读取服务状态和日志。"
    fi

    check_systemd_unit "hysteria2" "hysteria2.service"
}

listener_lines() {
    local proto="$1"
    local port="$2"
    if [ "$proto" = "tcp" ]; then
        ss -H -lntp 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" {print}'
    else
        ss -H -lnup 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" {print}'
    fi
}

check_listener() {
    local proto="$1"
    local port="$2"
    local process="$3"
    local output=""

    if ! command -v ss >/dev/null 2>&1; then
        report_fail "listener:$proto/$port" "ss command missing; install iproute2 to verify local listeners"
        return
    fi

    output=$(listener_lines "$proto" "$port")
    if [ -n "$output" ] && printf '%s\n' "$output" | grep -qi "$process"; then
        report_pass "listener:$proto/$port" "$process"
    else
        report_fail "listener:$proto/$port" "expected $process listener missing; check service logs and port conflicts"
    fi
}

check_client_info_file() {
    local file="/etc/xray/client_config_info.txt"
    local mode=""

    if [ ! -f "$file" ]; then
        report_fail "client_info" "$file missing; rerun install to regenerate client parameters"
        return
    fi

    mode=$(stat -c '%a' "$file" 2>/dev/null || echo "")
    if [ -z "$mode" ] || [ $((8#$mode & 077)) -ne 0 ]; then
        report_fail "client_info" "$file permissions are ${mode:-unknown}; run chmod 600 $file"
        return
    fi

    if ! grep -q 'PublicKey' "$file"; then
        report_fail "client_info" "$file lacks PublicKey; rerun install and check x25519 output"
        return
    fi

    report_info "client_info:xray" "$file"
}

validate_hysteria2_config() {
    local file="${HYSTERIA_CONFIG_OUTPUT_PATH:-/etc/hysteria/config.yaml}"

    if [ ! -f "$file" ]; then
        report_fail "config:hysteria2" "$file missing; rerun install to regenerate Hysteria2 config"
        return
    fi

    if grep -q '\${[A-Za-z_][A-Za-z0-9_]*}' "$file"; then
        report_fail "config:hysteria2" "$file contains unresolved template variables"
        return
    fi

    report_pass "config:hysteria2" "$file"
}

check_hysteria2_client_info_file() {
    local file="${HYSTERIA_CLIENT_INFO_FILE:-/etc/hysteria/client_config_info.txt}"
    local mode=""

    if [ ! -f "$file" ]; then
        report_fail "client_info:hysteria2" "$file missing; rerun install to regenerate client parameters"
        return
    fi

    mode=$(stat -c '%a' "$file" 2>/dev/null || echo "")
    if [ -z "$mode" ] || [ $((8#$mode & 077)) -ne 0 ]; then
        report_fail "client_info:hysteria2" "$file permissions are ${mode:-unknown}; run chmod 600 $file"
        return
    fi

    if ! grep -q 'Hysteria2 URI' "$file"; then
        report_fail "client_info:hysteria2" "$file lacks Hysteria2 URI; rerun install and check template output"
        return
    fi

    report_info "client_info:hysteria2" "$file"
}

check_hysteria2_port_hopping_rules() {
    local script_path

    [ "$HYSTERIA_PORT_HOPPING_ENABLED" = "true" ] || return 0
    script_path=$(hysteria2_port_hopping_script_path)

    if [ ! -x "$script_path" ]; then
        report_fail "firewall:port-hopping" "$script_path missing or not executable"
        return
    fi

    if "$script_path" status; then
        report_pass "firewall:port-hopping" "UDP/${HYSTERIA_PORT_HOPPING_RANGE} redirects to UDP/${HYSTERIA_PORT}"
    else
        report_fail "firewall:port-hopping" "UDP/${HYSTERIA_PORT_HOPPING_RANGE} redirect rule missing"
    fi
}

check_external_https() {
    local output=""

    if ! command -v curl >/dev/null 2>&1; then
        report_warn "external:https" "curl missing, skipped; check DNS/firewall/security group manually"
        return
    fi

    if ! output=$(curl --location --max-time 5 --silent --show-error --output /dev/null --write-out '%{http_code}' "https://$DOMAIN/" 2>&1); then
        report_warn "external:https" "$output; check DNS/firewall/security group/certificate issuance"
        return
    fi

    case "$output" in
        2*|3*)
            report_pass "external:https" "HTTP $output"
            ;;
        *)
            report_warn "external:https" "HTTP $output; check DNS/firewall/security group/certificate issuance"
            ;;
    esac
}

run_install_health_checks() {
    log_info "正在执行安装健康检查..."
    HEALTH_FAILURES=0
    HEALTH_WARNINGS=0
    HEALTH_REPORT_STARTED=0

    if profile_includes_xraycaddy; then
        require_executable "xray" "$XRAY_EXE"
        require_executable "caddy" "/usr/local/bin/caddy"
        validate_xray_config
        validate_caddy_config
    fi

    if profile_includes_hysteria2; then
        require_executable "hysteria2" "${HYSTERIA_EXE:-/usr/local/bin/hysteria}"
        validate_hysteria2_config
    fi

    if [ "$HEALTH_FAILURES" -gt 0 ]; then
        emit_health_result
        return 1
    fi

    if profile_includes_xraycaddy; then
        configure_xraycaddy_systemd_services || true
        check_listener "tcp" "80" "caddy"
        check_listener "tcp" "443" "xray"
        check_listener "udp" "443" "caddy"
        check_listener "udp" "2052" "xray"
        check_external_https
        check_client_info_file
    fi

    if profile_includes_hysteria2; then
        configure_hysteria2_systemd_service || true
        check_listener "udp" "$HYSTERIA_PORT" "hysteria"
        check_hysteria2_client_info_file
        check_hysteria2_port_hopping_rules
    fi

    emit_health_result

    [ "$HEALTH_FAILURES" -eq 0 ]
}

print_usage() {
    log_error "使用方法: $0 <domain> <kcp_seed> <www_root_path> [cert_type] [cert_path] [key_path] [email]"
    log_error "或: $0 --profile <xraycaddy|hysteria2|all> --domain <domain> [named options]"
}

init_install_defaults() {
    INSTALL_PROFILE="xraycaddy"
    DOMAIN=""
    KCP_SEED=""
    WWW_ROOT=""
    CERT_TYPE="acme"
    CERT_PATH=""
    KEY_PATH=""
    EMAIL=""
    HYSTERIA_PORT=""
    HYSTERIA_AUTH_PASSWORD=""
    HYSTERIA_CERT_MODE=""
    HYSTERIA_SNI=""
    HYSTERIA_TLS_INSECURE="false"
    HYSTERIA_TLS_VERIFY_NOTE="public CA or trusted certificate"
    HYSTERIA_MASQUERADE_PROXY_URL=""
    HYSTERIA_CLIENT_SOCKS5_PORT="1080"
    HYSTERIA_PORT_HOPPING_ENABLED="false"
    HYSTERIA_PORT_HOPPING_RANGE=""
    HYSTERIA_PORT_HOPPING_INTERVAL="30s"
    HYSTERIA2_URI=""
    XRAY_EXE="/usr/local/bin/xray"
    XRAY_CONFIG_OUTPUT_PATH="/etc/xray/config.json"
    CADDY_CONFIG_OUTPUT_PATH="/etc/caddy/caddy.json"
    HYSTERIA_EXE="/usr/local/bin/hysteria"
    HYSTERIA_CONFIG_OUTPUT_PATH="/etc/hysteria/config.yaml"
    HYSTERIA_CLIENT_INFO_FILE="/etc/hysteria/client_config_info.txt"
    INSTALL_STATE_PATH="${INSTALL_STATE_PATH:-/etc/xray-caddy/install_state.env}"
}

require_option_value() {
    local option="${1:-}"
    local value="${2-}"

    if [ "$#" -lt 2 ] || [[ "$value" == --* ]]; then
        log_error "选项 $option 需要一个值"
        print_usage
        return 1
    fi

    return 0
}

apply_arg_defaults() {
    if [ -n "$DOMAIN" ]; then
        [ -n "$EMAIL" ] || EMAIL="admin@$DOMAIN"
        [ -n "$HYSTERIA_SNI" ] || HYSTERIA_SNI="$DOMAIN"
    fi

    [ -n "$HYSTERIA_CLIENT_SOCKS5_PORT" ] || HYSTERIA_CLIENT_SOCKS5_PORT="1080"
    [ -n "$HYSTERIA_CERT_MODE" ] || HYSTERIA_CERT_MODE="$CERT_TYPE"

    if [ -z "$HYSTERIA_PORT" ]; then
        HYSTERIA_PORT="8443"
    fi
}

parse_args() {
    init_install_defaults

    if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        if [[ $# -lt 3 ]]; then
            print_usage
            return 1
        fi

        DOMAIN="$1"
        KCP_SEED="$2"
        WWW_ROOT="$3"
        CERT_TYPE="${4:-acme}"
        CERT_PATH="${5:-}"
        KEY_PATH="${6:-}"
        EMAIL="${7:-}"
        INSTALL_PROFILE="xraycaddy"
        HYSTERIA_CERT_MODE="$CERT_TYPE"
        apply_arg_defaults
        return 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                require_option_value "$@" || return 1
                INSTALL_PROFILE="$2"
                shift 2
                ;;
            --domain)
                require_option_value "$@" || return 1
                DOMAIN="$2"
                shift 2
                ;;
            --kcp-seed)
                require_option_value "$@" || return 1
                KCP_SEED="$2"
                shift 2
                ;;
            --www-root)
                require_option_value "$@" || return 1
                WWW_ROOT="$2"
                shift 2
                ;;
            --cert-mode|--cert-type)
                require_option_value "$@" || return 1
                CERT_TYPE="$2"
                HYSTERIA_CERT_MODE="$CERT_TYPE"
                shift 2
                ;;
            --cert-path)
                require_option_value "$@" || return 1
                CERT_PATH="$2"
                shift 2
                ;;
            --key-path)
                require_option_value "$@" || return 1
                KEY_PATH="$2"
                shift 2
                ;;
            --email)
                require_option_value "$@" || return 1
                EMAIL="$2"
                shift 2
                ;;
            --hysteria-port)
                require_option_value "$@" || return 1
                HYSTERIA_PORT="$2"
                shift 2
                ;;
            --hysteria-auth|--hysteria-auth-password)
                require_option_value "$@" || return 1
                HYSTERIA_AUTH_PASSWORD="$2"
                shift 2
                ;;
            --hysteria-sni)
                require_option_value "$@" || return 1
                HYSTERIA_SNI="$2"
                shift 2
                ;;
            --hysteria-tls-insecure)
                require_option_value "$@" || return 1
                HYSTERIA_TLS_INSECURE="$2"
                shift 2
                ;;
            --hysteria-tls-verify-note)
                require_option_value "$@" || return 1
                HYSTERIA_TLS_VERIFY_NOTE="$2"
                shift 2
                ;;
            --hysteria-masquerade-proxy-url)
                require_option_value "$@" || return 1
                HYSTERIA_MASQUERADE_PROXY_URL="$2"
                shift 2
                ;;
            --hysteria-client-socks5-port)
                require_option_value "$@" || return 1
                HYSTERIA_CLIENT_SOCKS5_PORT="$2"
                shift 2
                ;;
            --hysteria-port-hopping)
                HYSTERIA_PORT_HOPPING_ENABLED="true"
                shift
                ;;
            --no-hysteria-port-hopping)
                HYSTERIA_PORT_HOPPING_ENABLED="false"
                shift
                ;;
            --hysteria-port-hopping-range)
                require_option_value "$@" || return 1
                HYSTERIA_PORT_HOPPING_RANGE="$2"
                shift 2
                ;;
            --hysteria-port-hopping-interval)
                require_option_value "$@" || return 1
                HYSTERIA_PORT_HOPPING_INTERVAL="$2"
                shift 2
                ;;
            --hysteria2-uri)
                require_option_value "$@" || return 1
                HYSTERIA2_URI="$2"
                shift 2
                ;;
            --install-state-path)
                require_option_value "$@" || return 1
                INSTALL_STATE_PATH="$2"
                shift 2
                ;;
            --help)
                print_usage
                return 1
                ;;
            *)
                log_error "未知选项或参数: $1"
                print_usage
                return 1
                ;;
        esac
    done

    apply_arg_defaults
    return 0
}

range_contains_port() {
    local range="$1"
    local port="$2"
    local start="${range%-*}"
    local end="${range#*-}"

    [ "$port" -ge "$start" ] && [ "$port" -le "$end" ]
}

validate_port_range() {
    local range="$1"
    local label="$2"
    local start
    local end

    if [[ ! "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
        log_error "$label 格式无效: $range，应为 start-end"
        return 1
    fi

    start="${range%-*}"
    end="${range#*-}"

    if [ "$start" -lt 1 ] || [ "$start" -gt 65535 ] || [ "$end" -lt 1 ] || [ "$end" -gt 65535 ] || [ "$start" -gt "$end" ]; then
        log_error "$label 端口范围无效: $range"
        return 1
    fi

    return 0
}

validate_duration_interval() {
    local value="$1"
    local label="$2"

    if [[ ! "$value" =~ ^([0-9]+(ms|s|m|h))+$ ]]; then
        log_error "$label 格式无效: $value，应为 30s、5m 或 1h"
        return 1
    fi

    return 0
}

profile_includes_xraycaddy() {
    [[ "$INSTALL_PROFILE" == "xraycaddy" || "$INSTALL_PROFILE" == "all" ]]
}

profile_includes_hysteria2() {
    [[ "$INSTALL_PROFILE" == "hysteria2" || "$INSTALL_PROFILE" == "all" ]]
}

validate_profile_inputs() {
    case "$INSTALL_PROFILE" in
        xraycaddy|hysteria2|all)
            ;;
        *)
            log_error "无效安装 profile: $INSTALL_PROFILE"
            return 1
            ;;
    esac

    if [ -z "$DOMAIN" ]; then
        log_error "缺少必需参数: domain"
        return 1
    fi

    if profile_includes_xraycaddy; then
        if [[ -z "$KCP_SEED" || -z "$WWW_ROOT" ]]; then
            log_error "profile $INSTALL_PROFILE 需要 kcp seed 和 www root"
            return 1
        fi
    fi

    if [[ "$CERT_TYPE" != "acme" && "$CERT_TYPE" != "existing" && "$CERT_TYPE" != "hysteria-acme" ]]; then
        log_error "无效证书模式: $CERT_TYPE"
        return 1
    fi

    if [ "$CERT_TYPE" = "existing" ] && [[ -z "$CERT_PATH" || -z "$KEY_PATH" ]]; then
        log_error "使用现有证书时，证书文件路径和私钥文件路径是必需的"
        return 1
    fi

    if profile_includes_xraycaddy && [ "$CERT_TYPE" = "hysteria-acme" ]; then
        log_error "hysteria-acme 证书模式仅支持 hysteria2 profile"
        return 1
    fi

    if [ "$INSTALL_PROFILE" = "all" ] && [ "$CERT_TYPE" != "existing" ]; then
        log_error "all profile 必须使用现有证书，避免 Caddy 与 Hysteria2 同时申请 ACME 证书"
        return 1
    fi

    if [ "$INSTALL_PROFILE" = "hysteria2" ] && [ "$CERT_TYPE" = "acme" ]; then
        log_error "Hysteria2 profile 如需自动证书请使用 --cert-mode hysteria-acme；或使用 existing 证书"
        return 1
    fi

    if profile_includes_hysteria2; then
        if [[ ! "$HYSTERIA_PORT" =~ ^[0-9]+$ ]] || [ "$HYSTERIA_PORT" -lt 1 ] || [ "$HYSTERIA_PORT" -gt 65535 ]; then
            log_error "Hysteria2 UDP 端口无效: $HYSTERIA_PORT"
            return 1
        fi

        if [ "$HYSTERIA_PORT" = "443" ]; then
            log_error "Hysteria2 不能使用 UDP/443；该端口保留给 XHTTP/Caddy，请改用 8443 或其他 UDP 端口"
            return 1
        fi

        case "$HYSTERIA_PORT_HOPPING_ENABLED" in
            true|false)
                ;;
            *)
                log_error "Hysteria2 端口跳跃开关无效: $HYSTERIA_PORT_HOPPING_ENABLED"
                return 1
                ;;
        esac

        if [ "$HYSTERIA_PORT_HOPPING_ENABLED" = "true" ]; then
            if [ -z "$HYSTERIA_PORT_HOPPING_RANGE" ]; then
                log_error "开启 Hysteria2 端口跳跃时必须提供端口范围"
                return 1
            fi

            validate_port_range "$HYSTERIA_PORT_HOPPING_RANGE" "Hysteria2 端口跳跃范围" || return 1

            if range_contains_port "$HYSTERIA_PORT_HOPPING_RANGE" 443; then
                log_error "Hysteria2 端口跳跃范围不能包含 UDP/443；该端口保留给 XHTTP/Caddy"
                return 1
            fi

            if [ "$INSTALL_PROFILE" = "all" ] && range_contains_port "$HYSTERIA_PORT_HOPPING_RANGE" 2052; then
                log_error "all profile 下 Hysteria2 端口跳跃范围不能包含 UDP/2052；该端口保留给 Xray KCP"
                return 1
            fi

            validate_duration_interval "$HYSTERIA_PORT_HOPPING_INTERVAL" "Hysteria2 端口跳跃间隔" || return 1
        fi

        if [ -z "$HYSTERIA_AUTH_PASSWORD" ]; then
            log_error "缺少 Hysteria2 auth password"
            return 1
        fi

        if [ -z "$HYSTERIA_MASQUERADE_PROXY_URL" ]; then
            log_error "缺少 Hysteria2 masquerade proxy URL"
            return 1
        fi
    fi

    return 0
}

validate_cert_files() {
    if [[ "$CERT_TYPE" != "existing" ]]; then
        log_info "使用 ACME 自动申请证书"
        return 0
    fi

    if [[ ! -f "$CERT_PATH" ]]; then
        log_error "证书文件不存在: $CERT_PATH"
        return 1
    fi

    if [[ ! -f "$KEY_PATH" ]]; then
        log_error "私钥文件不存在: $KEY_PATH"
        return 1
    fi

    log_info "使用现有证书文件: $CERT_PATH 和 $KEY_PATH"
    return 0
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&#]/\\&/g'
}

render_template_file() {
    local template_path="${1:-}"
    local output_path="${2:-}"

    if [ "$#" -lt 2 ]; then
        log_error "模板渲染缺少输入或输出路径"
        return 1
    fi

    shift 2

    if [ ! -f "$template_path" ]; then
        log_error "模板文件不存在: $template_path"
        return 1
    fi

    if [ $(( $# % 2 )) -ne 0 ]; then
        log_error "模板渲染参数必须按 key/value 成对传入"
        return 1
    fi

    local temp_output="${output_path}.tmp.$$"

    if [ "$#" -eq 0 ]; then
        if cp "$template_path" "$temp_output" && mv "$temp_output" "$output_path"; then
            return 0
        fi

        rm -f "$temp_output"
        log_error "模板渲染失败: $template_path"
        return 1
    fi

    local sed_args=()
    local key
    local value
    local escaped

    while [ "$#" -gt 0 ]; do
        key="$1"
        value="${2-}"
        shift 2

        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log_error "模板变量名无效: $key"
            return 1
        fi

        if [[ "$value" == *$'\n'* ]]; then
            log_error "模板变量 $key 的值不能包含换行"
            return 1
        fi

        escaped=$(escape_sed_replacement "$value")
        sed_args+=("-e" "s#\${${key}}#$escaped#g")
    done

    if sed "${sed_args[@]}" "$template_path" > "$temp_output" && mv "$temp_output" "$output_path"; then
        return 0
    fi

    rm -f "$temp_output"
    log_error "模板渲染失败: $template_path"
    return 1
}

hysteria2_client_server() {
    if [ "$HYSTERIA_PORT_HOPPING_ENABLED" = "true" ]; then
        printf '%s:%s\n' "$DOMAIN" "$HYSTERIA_PORT_HOPPING_RANGE"
    else
        printf '%s:%s\n' "$DOMAIN" "$HYSTERIA_PORT"
    fi
}

hysteria2_port_hopping_field() {
    local enabled_value="$1"
    local disabled_value="${2:-N/A}"
    if [ "$HYSTERIA_PORT_HOPPING_ENABLED" = "true" ]; then
        printf '%s\n' "$enabled_value"
    else
        printf '%s\n' "$disabled_value"
    fi
}

hysteria2_port_hopping_status() {
    hysteria2_port_hopping_field "enabled" "disabled"
}

hysteria2_port_hopping_range_display() {
    hysteria2_port_hopping_field "$HYSTERIA_PORT_HOPPING_RANGE"
}

hysteria2_port_hopping_interval_display() {
    hysteria2_port_hopping_field "$HYSTERIA_PORT_HOPPING_INTERVAL"
}

build_hysteria2_uri() {
    printf 'hysteria2://%s@%s/?sni=%s#%s\n' \
        "$HYSTERIA_AUTH_PASSWORD" \
        "$(hysteria2_client_server)" \
        "$HYSTERIA_SNI" \
        "$DOMAIN"
}

render_hysteria2_templates() {
    local template_dir="${1:-./cfg_tpl}"
    local output_dir="${2:-/etc/hysteria}"
    local server_template="$template_dir/hysteria2_server.yaml"
    local client_template="$template_dir/hysteria2_client.yaml"
    local client_server
    local uri="$HYSTERIA2_URI"

    if [ "$CERT_TYPE" = "hysteria-acme" ]; then
        server_template="$template_dir/hysteria2_server_acme.yaml"
    fi

    if [ "$HYSTERIA_PORT_HOPPING_ENABLED" = "true" ]; then
        client_template="$template_dir/hysteria2_client_port_hopping.yaml"
    fi

    client_server=$(hysteria2_client_server)
    [ -n "$uri" ] || uri=$(build_hysteria2_uri)
    mkdir -p "$output_dir"

    render_template_file "$server_template" "$output_dir/config.yaml" \
        DOMAIN "$DOMAIN" \
        EMAIL "$EMAIL" \
        HYSTERIA_PORT "$HYSTERIA_PORT" \
        HYSTERIA_CERT_PATH "$CERT_PATH" \
        HYSTERIA_KEY_PATH "$KEY_PATH" \
        HYSTERIA_AUTH_PASSWORD "$HYSTERIA_AUTH_PASSWORD" \
        HYSTERIA_MASQUERADE_PROXY_URL "$HYSTERIA_MASQUERADE_PROXY_URL"

    render_template_file "$client_template" "$output_dir/client.yaml" \
        HYSTERIA_CLIENT_SERVER "$client_server" \
        HYSTERIA_AUTH_PASSWORD "$HYSTERIA_AUTH_PASSWORD" \
        HYSTERIA_SNI "$HYSTERIA_SNI" \
        HYSTERIA_TLS_INSECURE "$HYSTERIA_TLS_INSECURE" \
        HYSTERIA_CLIENT_SOCKS5_PORT "$HYSTERIA_CLIENT_SOCKS5_PORT" \
        HYSTERIA_PORT_HOPPING_INTERVAL "$HYSTERIA_PORT_HOPPING_INTERVAL"

    render_template_file "$template_dir/hysteria2_client_info.txt" "$output_dir/client_config_info.txt" \
        DOMAIN "$DOMAIN" \
        HYSTERIA_PORT "$HYSTERIA_PORT" \
        HYSTERIA_SNI "$HYSTERIA_SNI" \
        HYSTERIA_AUTH_PASSWORD "$HYSTERIA_AUTH_PASSWORD" \
        HYSTERIA_CERT_MODE "$HYSTERIA_CERT_MODE" \
        HYSTERIA_TLS_VERIFY_NOTE "$HYSTERIA_TLS_VERIFY_NOTE" \
        HYSTERIA_PORT_HOPPING_STATUS "$(hysteria2_port_hopping_status)" \
        HYSTERIA_PORT_HOPPING_RANGE_DISPLAY "$(hysteria2_port_hopping_range_display)" \
        HYSTERIA_PORT_HOPPING_INTERVAL_DISPLAY "$(hysteria2_port_hopping_interval_display)" \
        HYSTERIA2_URI "$uri"

    chmod 600 "$output_dir/config.yaml" "$output_dir/client.yaml" "$output_dir/client_config_info.txt"
}

hysteria2_port_hopping_dport_range() {
    printf '%s:%s\n' "${HYSTERIA_PORT_HOPPING_RANGE%-*}" "${HYSTERIA_PORT_HOPPING_RANGE#*-}"
}

hysteria2_port_hopping_script_path() {
    printf '%s\n' "${HYSTERIA_PORT_HOPPING_SCRIPT_PATH:-/usr/local/bin/hysteria2-port-hopping-rules}"
}

hysteria2_port_hopping_unit_path() {
    printf '%s\n' "${HYSTERIA_PORT_HOPPING_UNIT_PATH:-/etc/systemd/system/hysteria2-port-hopping.service}"
}

write_hysteria2_port_hopping_rule_script() {
    local script_path
    local script_dir
    local dport_range
    script_path=$(hysteria2_port_hopping_script_path)
    script_dir=$(dirname "$script_path")
    dport_range=$(hysteria2_port_hopping_dport_range)

    mkdir -p "$script_dir" || return 1
    cat > "$script_path" <<EOF || return 1
#!/bin/sh
set -eu

listen_port="$HYSTERIA_PORT"
dport_range="$dport_range"
action="\${1:-apply}"

command_exists() {
    command -v "\$1" >/dev/null 2>&1
}

remove_rule_for() {
    bin="\$1"
    command_exists "\$bin" || return 0
    while "\$bin" -t nat -D PREROUTING -p udp --dport "\$dport_range" -j REDIRECT --to-ports "\$listen_port" 2>/dev/null; do
        :
    done
    return 0
}

apply_rule_for() {
    bin="\$1"
    command_exists "\$bin" || return 2
    if "\$bin" -t nat -C PREROUTING -p udp --dport "\$dport_range" -j REDIRECT --to-ports "\$listen_port" 2>/dev/null; then
        return 0
    fi
    "\$bin" -t nat -A PREROUTING -p udp --dport "\$dport_range" -j REDIRECT --to-ports "\$listen_port"
}

status_rule_for() {
    bin="\$1"
    command_exists "\$bin" || return 2
    "\$bin" -t nat -C PREROUTING -p udp --dport "\$dport_range" -j REDIRECT --to-ports "\$listen_port" 2>/dev/null
}

case "\$action" in
    apply)
        applied=0
        if apply_rule_for iptables; then
            applied=1
        fi
        if apply_rule_for ip6tables; then
            applied=1
        fi
        [ "\$applied" -eq 1 ] || { echo "iptables/ip6tables 不可用，无法配置 Hysteria2 端口跳跃" >&2; exit 1; }
        ;;
    remove)
        remove_rule_for iptables
        remove_rule_for ip6tables
        ;;
    status)
        status_rule_for iptables || status_rule_for ip6tables
        ;;
    *)
        echo "usage: \$0 {apply|remove|status}" >&2
        exit 2
        ;;
esac
EOF
    chmod 755 "$script_path"
}

write_hysteria2_port_hopping_systemd_unit() {
    local unit_path
    local unit_dir
    local script_path
    unit_path=$(hysteria2_port_hopping_unit_path)
    unit_dir=$(dirname "$unit_path")
    script_path=$(hysteria2_port_hopping_script_path)

    mkdir -p "$unit_dir" || return 1
    cat > "$unit_path" <<EOF || return 1
[Unit]
Description=Hysteria2 Port Hopping Redirect Rules
After=network-online.target
Wants=network-online.target
Before=hysteria2.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script_path apply
ExecStop=$script_path remove

[Install]
WantedBy=multi-user.target
EOF
}

configure_hysteria2_port_hopping_files() {
    [ "$HYSTERIA_PORT_HOPPING_ENABLED" = "true" ] || return 0
    write_hysteria2_port_hopping_rule_script || return 1
    write_hysteria2_port_hopping_systemd_unit || return 1
}

install_hysteria2_components() {
    log_info "正在安装并配置 Hysteria2 ..."
    mkdir -p /usr/local/bin /etc/hysteria /var/log/hysteria ./app/temp
    chmod 755 /usr/local/bin /etc/hysteria /var/log/hysteria

    if ! bash "$DOWNLOAD_SCRIPT" hysteria2 --dir ./app/temp; then
        log_error "下载 Hysteria2 失败，请查看上面的错误信息。"
        exit 1
    fi

    if [ ! -f ./app/temp/hysteria ]; then
        log_error "Hysteria2 可执行文件未找到: ./app/temp/hysteria"
        exit 1
    fi

    cp ./app/temp/hysteria /usr/local/bin/hysteria
    chmod +x /usr/local/bin/hysteria
    HYSTERIA_EXE="/usr/local/bin/hysteria"
    HYSTERIA_CONFIG_OUTPUT_PATH="/etc/hysteria/config.yaml"
    HYSTERIA_CLIENT_INFO_FILE="/etc/hysteria/client_config_info.txt"

    render_hysteria2_templates "./cfg_tpl" "/etc/hysteria" || {
        log_error "生成 Hysteria2 配置失败"
        exit 1
    }

    configure_hysteria2_port_hopping_files || {
        log_error "生成 Hysteria2 端口跳跃转发规则失败"
        exit 1
    }

    log_info "Hysteria2 已安装到 /usr/local/bin/hysteria，配置已生成到 /etc/hysteria"
}

profile_components() {
    case "$INSTALL_PROFILE" in
        xraycaddy) printf 'xray,caddy\n' ;;
        hysteria2) printf 'hysteria2\n' ;;
        all) printf 'xray,caddy,hysteria2\n' ;;
    esac
}

is_valid_install_profile() {
    case "$1" in
        xraycaddy|hysteria2|all) return 0 ;;
        *) return 1 ;;
    esac
}

preflight_path() {
    local path="$1"
    if [ -n "${PREFLIGHT_ROOT:-}" ] && [[ "$path" == /* ]]; then
        printf '%s%s\n' "$PREFLIGHT_ROOT" "$path"
    else
        printf '%s\n' "$path"
    fi
}

read_install_state_profile() {
    local state_path="$1"
    local key
    local value

    [ -f "$state_path" ] || return 1

    while IFS='=' read -r key value; do
        if [ "$key" = "INSTALL_PROFILE" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$state_path"

    return 1
}

preflight_unit_exists() {
    local unit="$1"
    local configured_unit

    # Space-delimited test hook, values must be simple unit names without spaces.
    for configured_unit in ${PREFLIGHT_SYSTEMD_UNITS:-}; do
        [ "$configured_unit" = "$unit" ] && return 0
    done

    [ -e "$(preflight_path "/etc/systemd/system/$unit")" ] && return 0
    [ -e "$(preflight_path "/lib/systemd/system/$unit")" ] && return 0
    [ -e "$(preflight_path "/usr/lib/systemd/system/$unit")" ] && return 0

    if [ -z "${PREFLIGHT_ROOT:-}" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q . && return 0
    fi

    return 1
}

preflight_listener_exists() {
    local proto="$1"
    local port="$2"
    local listener

    # Space-delimited test hook, values must use proto/port tokens such as tcp/443.
    for listener in ${PREFLIGHT_LISTENERS:-}; do
        [ "$listener" = "$proto/$port" ] && return 0
    done

    if [ -z "${PREFLIGHT_ROOT:-}" ] && command -v ss >/dev/null 2>&1; then
        [ -n "$(listener_lines "$proto" "$port")" ] && return 0
    fi

    return 1
}

preflight_xraycaddy_signal_present() {
    local legacy_info_path
    legacy_info_path=$(preflight_path "/etc/xray/config_info.txt")

    [ -f "$legacy_info_path" ] && return 0
    preflight_unit_exists "caddy.service" && return 0
    preflight_unit_exists "xray.service" && return 0
    preflight_listener_exists "tcp" "80" && return 0
    preflight_listener_exists "tcp" "443" && return 0
    preflight_listener_exists "udp" "443" && return 0
    preflight_listener_exists "udp" "2052" && return 0

    return 1
}

preflight_hysteria2_signal_present() {
    preflight_unit_exists "hysteria2.service" && return 0

    case "$HYSTERIA_PORT" in
        # Xray/Caddy already uses these ports, so listener-only evidence is ambiguous.
        80|443|2052)
            return 1
            ;;
    esac

    preflight_listener_exists "udp" "$HYSTERIA_PORT" && return 0

    return 1
}

classify_existing_install() {
    local requested_profile="${1:-$INSTALL_PROFILE}"
    local state_path="${2:-$INSTALL_STATE_PATH}"
    local existing_profile=""
    local state_profile=""
    local legacy_info_path

    PREFLIGHT_STATUS=""
    PREFLIGHT_REASON=""
    PREFLIGHT_EXISTING_PROFILE=""

    state_path=$(preflight_path "$state_path")
    legacy_info_path=$(preflight_path "/etc/xray/config_info.txt")

    if [ -f "$state_path" ]; then
        state_profile=$(read_install_state_profile "$state_path" || true)
        if ! is_valid_install_profile "$state_profile"; then
            PREFLIGHT_STATUS="conflict_unknown"
            PREFLIGHT_REASON="安装状态文件存在但 profile 无效: $state_path"
            return 0
        fi
        existing_profile="$state_profile"
    elif [ -f "$legacy_info_path" ]; then
        existing_profile="xraycaddy"
    fi

    if [ -z "$existing_profile" ]; then
        if preflight_xraycaddy_signal_present || preflight_hysteria2_signal_present; then
            PREFLIGHT_STATUS="conflict_unknown"
            PREFLIGHT_REASON="检测到已有服务、配置或端口占用，但没有可识别的安装状态"
        else
            PREFLIGHT_STATUS="fresh"
            PREFLIGHT_REASON="未检测到已有安装状态或相关端口占用"
        fi
        return 0
    fi

    PREFLIGHT_EXISTING_PROFILE="$existing_profile"

    case "$existing_profile" in
        xraycaddy)
            if preflight_hysteria2_signal_present; then
                PREFLIGHT_STATUS="conflict_unknown"
                PREFLIGHT_REASON="状态显示 xraycaddy，但检测到 Hysteria2 服务或 UDP/${HYSTERIA_PORT} 占用"
            elif [ "$requested_profile" = "all" ]; then
                PREFLIGHT_STATUS="extend_xraycaddy_to_all"
                PREFLIGHT_REASON="检测到现有 xraycaddy，可显式扩展到 all"
            elif [ "$requested_profile" = "xraycaddy" ]; then
                PREFLIGHT_STATUS="known_existing_profile"
                PREFLIGHT_REASON="检测到已安装 xraycaddy"
            else
                PREFLIGHT_STATUS="conflict_unknown"
                PREFLIGHT_REASON="已有 xraycaddy，不能静默安装 hysteria2；请显式选择 all 扩展或中止"
            fi
            ;;
        hysteria2)
            if preflight_xraycaddy_signal_present; then
                PREFLIGHT_STATUS="conflict_unknown"
                PREFLIGHT_REASON="状态显示 hysteria2，但检测到 Xray/Caddy 服务、配置或端口占用"
            elif [ "$requested_profile" = "hysteria2" ]; then
                PREFLIGHT_STATUS="known_existing_profile"
                PREFLIGHT_REASON="检测到已安装 hysteria2"
            else
                PREFLIGHT_STATUS="conflict_unknown"
                PREFLIGHT_REASON="已有 hysteria2，当前安装器不支持静默改写为 $requested_profile"
            fi
            ;;
        all)
            if [ "$requested_profile" = "all" ]; then
                PREFLIGHT_STATUS="known_existing_profile"
                PREFLIGHT_REASON="检测到已安装 all profile"
            else
                PREFLIGHT_STATUS="conflict_unknown"
                PREFLIGHT_REASON="已有 all profile，当前安装器不支持静默改写为 $requested_profile"
            fi
            ;;
    esac

    return 0
}

run_existing_install_preflight() {
    classify_existing_install "$INSTALL_PROFILE" "$INSTALL_STATE_PATH"

    case "$PREFLIGHT_STATUS" in
        fresh)
            log_info "安装前检查: fresh install。$PREFLIGHT_REASON"
            return 0
            ;;
        extend_xraycaddy_to_all)
            log_info "安装前检查: extend xraycaddy to all。$PREFLIGHT_REASON"
            return 0
            ;;
        known_existing_profile)
            log_error "安装前检查: known existing profile。$PREFLIGHT_REASON。为避免覆盖现有安装，请先卸载或使用后续迁移流程。"
            return 1
            ;;
        conflict_unknown|*)
            log_error "安装前检查: conflict or unknown state。$PREFLIGHT_REASON"
            return 1
            ;;
    esac
}

write_install_state() {
    local state_path="${1:-$INSTALL_STATE_PATH}"
    local state_dir
    state_dir=$(dirname "$state_path")

    mkdir -p "$state_dir" || return 1

    cat > "$state_path" <<EOF || return 1
INSTALL_PROFILE=$INSTALL_PROFILE
INSTALLED_COMPONENTS=$(profile_components)
DOMAIN=$DOMAIN
CERT_TYPE=$CERT_TYPE
HYSTERIA_PORT=$HYSTERIA_PORT
HYSTERIA_PORT_HOPPING_ENABLED=$HYSTERIA_PORT_HOPPING_ENABLED
HYSTERIA_PORT_HOPPING_RANGE=$HYSTERIA_PORT_HOPPING_RANGE
HYSTERIA_PORT_HOPPING_INTERVAL=$HYSTERIA_PORT_HOPPING_INTERVAL
XRAY_CONFIG=/etc/xray/config.json
CADDY_CONFIG=/etc/caddy/caddy.json
HYSTERIA_CONFIG=/etc/hysteria/config.yaml
EOF
    chmod 600 "$state_path"
}

# --- Cleanup function for temporary files ---
cleanup_temp_files() {
    if [ -d "./app/temp" ]; then
        log_warning "正在清理临时文件..."
        rm -rf ./app/temp
        log_info "临时文件已清理"
    fi
}

main() {
# Set up trap to ensure cleanup on script exit, error, or interrupt
trap cleanup_temp_files EXIT
trap cleanup_temp_files ERR
trap cleanup_temp_files INT TERM

# --- Sanity Checks & Argument Parsing ---
if ! parse_args "$@"; then
    exit 1
fi

if ! validate_profile_inputs; then
    exit 1
fi

if ! run_existing_install_preflight; then
    exit 1
fi

if ! validate_cert_files; then
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    log_error "请使用root用户运行此脚本。"
    exit 1
fi

# Check for download.sh script
DOWNLOAD_SCRIPT="./download.sh"
if [ ! -f "$DOWNLOAD_SCRIPT" ]; then
    log_error "下载脚本未找到: $DOWNLOAD_SCRIPT (当前工作目录: $(pwd))"
    exit 1
fi
if [ ! -x "$DOWNLOAD_SCRIPT" ]; then
    log_info "设置下载脚本可执行权限..."
    chmod +x "$DOWNLOAD_SCRIPT"
    if [ ! -x "$DOWNLOAD_SCRIPT" ]; then
        log_error "无法设置下载脚本可执行权限，请手动设置。"
        exit 1
    fi
    log_info "下载脚本已设置为可执行。"
fi

log_info "开始下载并配置 profile: $INSTALL_PROFILE ..."
log_info "域名 (Domain): $DOMAIN"
log_info "证书类型: $CERT_TYPE"
[ -n "$WWW_ROOT" ] && log_info "网站根目录 (WWW Root): $WWW_ROOT"

# --- Prepare Directories ---
log_info "创建所需目录..."
mkdir -p /usr/local/bin ./app/temp
chmod 755 /usr/local/bin
if profile_includes_xraycaddy; then
    mkdir -p /etc/xray /etc/caddy /var/log/caddy /var/log/xray "$WWW_ROOT"
    chmod 755 /etc/xray /etc/caddy /var/log/caddy /var/log/xray
fi
if profile_includes_hysteria2; then
    mkdir -p /etc/hysteria /var/log/hysteria
    chmod 755 /etc/hysteria /var/log/hysteria
fi
log_info "目录已准备就绪。"

if profile_includes_xraycaddy; then
# --- 2. Download Caddy executable to temp ---
log_info "正在下载 Caddy 到临时目录..."
if ! bash "$DOWNLOAD_SCRIPT" caddy --dir ./app/temp; then
    log_error "下载 Caddy 失败，请查看上面的错误信息。"
    exit 1
fi

# --- 3. Install Caddy to system ---
log_info "正在安装 Caddy 到 /usr/local/bin..."
cp ./app/temp/caddy /usr/local/bin/caddy
chmod +x /usr/local/bin/caddy
log_info "Caddy 已安装到 /usr/local/bin/caddy"

# --- 4. Configure Caddy ---
log_info "正在配置 Caddy (caddy.json)..."

# 根据证书类型选择配置模板
if [[ "$CERT_TYPE" == "existing" ]]; then
    log_info "使用现有证书配置: $CERT_PATH 和 $KEY_PATH"
    CADDY_CONFIG_TEMPLATE_PATH="./cfg_tpl/caddy_existing_cert_config.json"
else
    log_info "使用 ACME 自动申请证书配置"
    CADDY_CONFIG_TEMPLATE_PATH="./cfg_tpl/caddy_config.json"
fi

CADDY_CONFIG_OUTPUT_PATH="/etc/caddy/caddy.json"

if [ ! -f "$CADDY_CONFIG_TEMPLATE_PATH" ]; then
    log_error "Caddy 配置文件模板未找到: $CADDY_CONFIG_TEMPLATE_PATH (当前工作目录: $(pwd))"
    exit 1
fi

# Prepare a default index.html if it doesn't exist in the user-specified WWW_ROOT
DEFAULT_INDEX_HTML="${WWW_ROOT}/index.html"
if [ ! -f "$DEFAULT_INDEX_HTML" ]; then
    log_info "在 $DEFAULT_INDEX_HTML 创建一个默认的 index.html..."
    # Ensure the directory for index.html exists (WWW_ROOT should already be created)
    mkdir -p "$(dirname "$DEFAULT_INDEX_HTML")"
    echo "<!DOCTYPE html><html><head><title>Welcome to $DOMAIN</title><style>body{font-family: sans-serif; margin: 2em; text-align: center;}</style></head><body><h1>Success!</h1><p>Your site <strong>$DOMAIN</strong> is working.</p><p><small>This is a default page.</small></p></body></html>" > "$DEFAULT_INDEX_HTML"
    log_info "默认 index.html 创建成功。"
fi

log_info "使用以下参数生成Caddy配置: DOMAIN=$DOMAIN, WWW_ROOT=$WWW_ROOT, EMAIL=$EMAIL"

if [[ "$CERT_TYPE" == "existing" ]]; then
    render_template_file "$CADDY_CONFIG_TEMPLATE_PATH" "$CADDY_CONFIG_OUTPUT_PATH" \
        DOMAIN "$DOMAIN" \
        WWW_ROOT "$WWW_ROOT" \
        CERT_PATH "$CERT_PATH" \
        KEY_PATH "$KEY_PATH"
else
    render_template_file "$CADDY_CONFIG_TEMPLATE_PATH" "$CADDY_CONFIG_OUTPUT_PATH" \
        DOMAIN "$DOMAIN" \
        WWW_ROOT "$WWW_ROOT" \
        EMAIL "$EMAIL"
fi
log_info "Caddy 配置文件已生成: $CADDY_CONFIG_OUTPUT_PATH"

# --- 5. Download Xray-core to temp ---
log_info "正在下载 Xray-core 到临时目录..."
if ! bash "$DOWNLOAD_SCRIPT" xray --dir ./app/temp; then
    log_error "下载 Xray-core 失败，请查看上面的错误信息。"
    exit 1
fi

# 确认xray可执行文件存在
TEMP_XRAY="./app/temp/xray"
if [ ! -f "$TEMP_XRAY" ]; then
    log_error "Xray 可执行文件未找到: $TEMP_XRAY。请检查下载是否成功。"
    exit 1
fi

# --- 6. Install Xray to system ---
log_info "正在安装 Xray 到 /usr/local/bin..."
cp "$TEMP_XRAY" /usr/local/bin/xray
chmod +x /usr/local/bin/xray
log_info "Xray 已安装到 /usr/local/bin/xray"

# 确认安装成功
XRAY_EXE="/usr/local/bin/xray"
if [ ! -f "$XRAY_EXE" ]; then
    log_error "Xray 安装失败: $XRAY_EXE"
    exit 1
fi

# --- 4. Generate UUID for Xray ---
log_info "正在生成 Xray UUID..."
UUID=$("$XRAY_EXE" uuid)
if [ -z "$UUID" ]; then
    log_error "生成 Xray UUID 失败。"
    exit 1
fi
log_info "UUID 生成完成（出于安全考虑不显示具体值）"

# --- 5. Generate Private/Public Keys for Xray ---
log_info "正在生成 Xray X25519 密钥对..."
if KEY_OUTPUT=$("$XRAY_EXE" x25519 2>&1); then
    KEY_EXIT_CODE=0
else
    KEY_EXIT_CODE=$?
fi

if [ $KEY_EXIT_CODE -ne 0 ]; then
    log_error "Xray x25519 命令执行失败，退出码: $KEY_EXIT_CODE"
    log_error "Xray 可执行文件路径: $XRAY_EXE"
    log_error "检查 Xray 可执行文件是否存在和可执行:"
    ls -la "$XRAY_EXE" 2>&1 || true
    exit 1
fi

log_info "X25519 命令执行完成，正在解析输出..."

extract_x25519_value() {
    local key_type="$1"
    local raw_output="$2"
    printf '%s\n' "$raw_output" | awk -F ':' -v key_type="$key_type" '
        {
            label = tolower($1)
            gsub(/[[:space:]]+/, "", label)
        }
        key_type == "private" && label == "privatekey" {
            sub(/^[^:]*:[[:space:]]*/, "")
            print
            exit
        }
        key_type == "public" && (label == "publickey" || label == "password" || label == "password(publickey)") {
            sub(/^[^:]*:[[:space:]]*/, "")
            print
            exit
        }
    '
}

PRIVATE_KEY=$(extract_x25519_value private "$KEY_OUTPUT" || true)
PUBLIC_KEY=$(extract_x25519_value public "$KEY_OUTPUT" || true)

# 检查是否成功提取了密钥
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    log_error "无法从命令输出中提取密钥。"
    log_error "命令输出标签如下（已隐藏密钥值）:"
    printf '%s\n' "$KEY_OUTPUT" | while IFS= read -r line; do
        if [[ "$line" == *:* ]]; then
            log_error "  ${line%%:*}: <hidden>"
        else
            log_error "  <non key-value output hidden>"
        fi
    done
    exit 1
fi

log_info "X25519 密钥对生成完成，客户端参数将保存到 /etc/xray/client_config_info.txt"

# --- 7. Configure Xray-core ---
log_info "正在配置 Xray-core (config.json)..."
XRAY_CONFIG_TEMPLATE_PATH="./cfg_tpl/xray_config.json"
XRAY_CONFIG_OUTPUT_PATH="/etc/xray/config.json"

if [ ! -f "$XRAY_CONFIG_TEMPLATE_PATH" ]; then
    log_error "Xray 配置文件模板未找到: $XRAY_CONFIG_TEMPLATE_PATH (当前工作目录: $(pwd))"
    exit 1
fi

# Replace placeholders in Xray config via render_template_file (handles escaping uniformly)
log_info "正在生成Xray配置文件（出于安全考虑不显示敏感参数）"

render_template_file "$XRAY_CONFIG_TEMPLATE_PATH" "$XRAY_CONFIG_OUTPUT_PATH" \
    DOMAIN "$DOMAIN" \
    UUID "$UUID" \
    PRIVATE_KEY "$PRIVATE_KEY" \
    KCP_SEED "$KCP_SEED" \
    EMAIL "$EMAIL"
log_info "Xray-core 配置文件已生成: $XRAY_CONFIG_OUTPUT_PATH"

# --- 8. Save Configuration Info ---
log_info "正在保存配置信息到 /etc/xray/config_info.txt..."
cat > "/etc/xray/config_info.txt" << EOF
# Xray & Caddy 配置信息
DOMAIN=$DOMAIN
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
KCP_SEED=$KCP_SEED
EMAIL=$EMAIL
WWW_ROOT=$WWW_ROOT
CERT_TYPE=$CERT_TYPE
CERT_PATH=$CERT_PATH
KEY_PATH=$KEY_PATH
XRAY_BIN=/usr/local/bin/xray
CADDY_BIN=/usr/local/bin/caddy
XRAY_CONFIG=/etc/xray/config.json
CADDY_CONFIG=/etc/caddy/caddy.json
EOF
chmod 600 "/etc/xray/config_info.txt"  # 设置适当的文件权限，因为包含敏感信息
log_info "配置信息已保存到 /etc/xray/config_info.txt"

# 将客户端配置参数保存到单独的文件中，供后续查看
CLIENT_CONFIG_INFO_FILE="/etc/xray/client_config_info.txt"
log_info "正在保存客户端配置信息到 $CLIENT_CONFIG_INFO_FILE..."
cat > "$CLIENT_CONFIG_INFO_FILE" << EOF
=======================================
客户端连接配置参数
=======================================
域名 (Address/Host): $DOMAIN
用户 ID (UUID): $UUID
Xray 公钥 (PublicKey): $PUBLIC_KEY
KCP 混淆密码 (Seed): $KCP_SEED
邮箱: $EMAIL
=======================================
EOF

chmod 600 "$CLIENT_CONFIG_INFO_FILE"  # 设置适当的文件权限，因为包含敏感信息
log_info "客户端配置信息已保存到 $CLIENT_CONFIG_INFO_FILE"
fi

if profile_includes_hysteria2; then
    install_hysteria2_components
fi

# --- 9. Create xraycaddy command shortcut ---
log_info "正在创建 xraycaddy 全局命令..."
CURRENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ln -sf "$CURRENT_SCRIPT_DIR/main.sh" /usr/local/bin/xraycaddy
chmod +x /usr/local/bin/xraycaddy
log_info "快捷命令 'xraycaddy' 已创建完成"

if ! run_install_health_checks; then
    log_error "安装健康检查失败，请按报告中的 FAIL 项处理。"
    exit 1
fi

if ! write_install_state "$INSTALL_STATE_PATH"; then
    log_error "写入安装状态文件失败: $INSTALL_STATE_PATH"
    exit 1
fi
log_info "安装状态已保存到 $INSTALL_STATE_PATH"

# 注意：临时文件清理由 EXIT trap 自动处理

log_info "---------------------------------------------------------------------"
log_info "安装和配置完成!"
log_info "---------------------------------------------------------------------"
if profile_includes_xraycaddy; then
    log_info "Xray-core 和 Caddy 已安装并配置完成。"
fi
if profile_includes_hysteria2; then
    log_info "Hysteria2 已安装并配置完成。"
fi
log_info ""
log_info "重要客户端配置信息 (请妥善保管):"
log_info "  域名 (Address/Host):               $DOMAIN"
if profile_includes_xraycaddy; then
    log_info "  用户 ID (UUID for VLESS/VMess):    [已生成，出于安全考虑不显示]"
    log_info "  Xray 公钥 (PublicKey for Reality): [已生成，出于安全考虑不显示]"
    log_info "  KCP 混淆密码 (Seed for mKCP):      [已生成，出于安全考虑不显示]"
    log_info "  Xray 敏感信息已安全保存到 /etc/xray/ 目录"
fi
if profile_includes_hysteria2; then
    log_info "  Hysteria2 认证密码:                [已保存，出于安全考虑不显示]"
    log_info "  Hysteria2 客户端信息:              /etc/hysteria/client_config_info.txt"
fi
log_info ""
log_info "服务配置文件位置:"
if profile_includes_xraycaddy; then
    log_info "  Xray 程序:   /usr/local/bin/xray"
    log_info "  Caddy 程序:  /usr/local/bin/caddy"
    log_info "  Caddy:       $CADDY_CONFIG_OUTPUT_PATH"
    log_info "  Xray:        $XRAY_CONFIG_OUTPUT_PATH"
    log_info "  Xray 信息:   /etc/xray/config_info.txt"
    log_info "  Xray 客户端: /etc/xray/client_config_info.txt"
fi
if profile_includes_hysteria2; then
    log_info "  Hysteria2 程序:   /usr/local/bin/hysteria"
    log_info "  Hysteria2 配置:   /etc/hysteria/config.yaml"
    log_info "  Hysteria2 客户端: /etc/hysteria/client_config_info.txt"
fi
log_info ""
log_info "快捷命令:"
log_info "  管理菜单: xraycaddy"
if profile_includes_xraycaddy && profile_includes_hysteria2; then
    log_info "  systemd 状态: systemctl status caddy.service xray.service hysteria2.service"
elif profile_includes_xraycaddy; then
    log_info "  systemd 状态: systemctl status caddy.service xray.service"
else
    log_info "  systemd 状态: systemctl status hysteria2.service"
fi
log_info ""
log_info "重要提醒:"
log_info "  - 所有敏感配置信息已保存到 /etc/xray 或 /etc/hysteria 目录"
log_info "  - 请妥善保管配置文件，避免泄露敏感信息"
log_info "  - 可使用 'xraycaddy' 查看完整配置信息"
log_info "---------------------------------------------------------------------"}.TODO? Wait Edit new_string includes no emoji? It removed emoji. But maybe syntax? I accidentally included stray? Let's verify JSON string valid. It has no closing quote? Let's see tool call failed? It did not show result. Actually I inserted huge string with Chinese but at end I included `}`? Let's wait. It may have failed? The message maybe malformed. It hasn't returned? Hmm output not shown. The call maybe still? I see final `}.TODO?` in analysis due my compose? Actually in commentary to functions.Edit, JSON ended after new_string... It includes

return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
