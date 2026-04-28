#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Prevent errors in a pipeline from being masked.
set -euo pipefail

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

redact_sensitive_output() {
    local text
    text=$(cat)
    for secret in "${PRIVATE_KEY:-}" "${PUBLIC_KEY:-}" "${UUID:-}" "${KCP_SEED:-}"; do
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

configure_systemd_services() {
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

    report_info "client_info" "$file"
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

    require_executable "xray" "$XRAY_EXE"
    require_executable "caddy" "/usr/local/bin/caddy"
    validate_xray_config
    validate_caddy_config

    if [ "$HEALTH_FAILURES" -gt 0 ]; then
        emit_health_result
        return 1
    fi

    configure_systemd_services || true
    check_listener "tcp" "80" "caddy"
    check_listener "tcp" "443" "xray"
    check_listener "udp" "443" "caddy"
    check_listener "udp" "2052" "xray"
    check_external_https
    check_client_info_file
    emit_health_result

    [ "$HEALTH_FAILURES" -eq 0 ]
}

# --- Cleanup function for temporary files ---
cleanup_temp_files() {
    if [ -d "./app/temp" ]; then
        log_warning "正在清理临时文件..."
        rm -rf ./app/temp
        log_info "临时文件已清理"
    fi
}

# Set up trap to ensure cleanup on script exit, error, or interrupt
trap cleanup_temp_files EXIT
trap cleanup_temp_files ERR
trap cleanup_temp_files INT TERM

# --- Sanity Checks & Argument Parsing ---
if [[ $# -lt 3 ]]; then
    log_error "使用方法: $0 <domain> <kcp_seed> <www_root_path> [cert_type] [cert_path] [key_path] [email]"
    log_error "例如: $0 example.com mysecretpassword /var/www/html acme '' '' user@example.com"
    log_error "例如: $0 example.com mysecretpassword /var/www/html existing /path/to/cert.pem /path/to/key.key user@example.com"
    exit 1
fi

DOMAIN="$1"
KCP_SEED="$2"
WWW_ROOT="$3"
CERT_TYPE="${4:-acme}"  # 默认使用 ACME
CERT_PATH="${5:-}"
KEY_PATH="${6:-}"
EMAIL="${7:-admin@$DOMAIN}"

# 如果证书类型是 existing，验证证书和密钥文件是否存在
if [[ "$CERT_TYPE" == "existing" ]]; then
    if [[ -z "$CERT_PATH" || -z "$KEY_PATH" ]]; then
        log_error "使用现有证书时，证书文件路径和私钥文件路径是必需的"
        exit 1
    fi

    if [[ ! -f "$CERT_PATH" ]]; then
        log_error "证书文件不存在: $CERT_PATH"
        exit 1
    fi

    if [[ ! -f "$KEY_PATH" ]]; then
        log_error "私钥文件不存在: $KEY_PATH"
        exit 1
    fi

    log_info "使用现有证书文件: $CERT_PATH 和 $KEY_PATH"
else
    log_info "使用 ACME 自动申请证书"
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

log_info "开始下载并配置 Xray-core 和 Caddy ..."
log_info "域名 (Domain): $DOMAIN"
log_info "网站根目录 (WWW Root): $WWW_ROOT"
log_info "证书类型: $CERT_TYPE"

# --- Prepare Directories ---
log_info "创建所需目录..."
# 创建系统目录
mkdir -p /usr/local/bin
mkdir -p /etc/xray
mkdir -p /etc/caddy
mkdir -p /var/log/caddy
mkdir -p /var/log/xray
mkdir -p "$WWW_ROOT"

# 设置权限
chmod 755 /usr/local/bin
chmod 755 /etc/xray
chmod 755 /etc/caddy
chmod 755 /var/log/caddy
chmod 755 /var/log/xray

# 创建项目目录（仅用于存放管理脚本和临时文件）
mkdir -p ./app/temp
log_info "目录已准备就绪："

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

# Replace placeholders in Caddy config
# Escape $WWW_ROOT for sed if it contains slashes or other special characters
ESCAPED_WWW_ROOT=$(echo "$WWW_ROOT" | sed 's/[&/\\$*^]/\\&/g')
ESCAPED_DOMAIN=$(echo "$DOMAIN" | sed 's/[&/\\$*^]/\\&/g')
ESCAPED_EMAIL=$(echo "$EMAIL" | sed 's/[&/\\$*^]/\\&/g')
ESCAPED_CERT_PATH=$(echo "$CERT_PATH" | sed 's/[&/\\$*^]/\\&/g')
ESCAPED_KEY_PATH=$(echo "$KEY_PATH" | sed 's/[&/\\$*^]/\\&/g')

log_info "使用以下参数生成Caddy配置: DOMAIN=$DOMAIN, WWW_ROOT=$WWW_ROOT, EMAIL=$EMAIL"

# 使用 # 作为 sed 分隔符以避免路径中的 / 符号引起的问题
if [[ "$CERT_TYPE" == "existing" ]]; then
    # 使用现有证书的模板，需要替换证书路径
    sed -e "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" \
        -e "s#\${WWW_ROOT}#$ESCAPED_WWW_ROOT#g" \
        -e "s#\${CERT_PATH}#$ESCAPED_CERT_PATH#g" \
        -e "s#\${KEY_PATH}#$ESCAPED_KEY_PATH#g" \
        "$CADDY_CONFIG_TEMPLATE_PATH" > "$CADDY_CONFIG_OUTPUT_PATH"
else
    # 使用ACME模板
    sed -e "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" \
        -e "s#\${WWW_ROOT}#$ESCAPED_WWW_ROOT#g" \
        -e "s#\${EMAIL}#$ESCAPED_EMAIL#g" \
        "$CADDY_CONFIG_TEMPLATE_PATH" > "$CADDY_CONFIG_OUTPUT_PATH"
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

# Replace placeholders in Xray config
# Escape special characters for sed if necessary. UUID, keys, domain, KCP_SEED are usually safe.
# However, KCP_SEED could contain anything.
ESCAPED_KCP_SEED=$(echo "$KCP_SEED" | sed 's/[&/\\$*^]/\\&/g')
# Domain already escaped as ESCAPED_DOMAIN
# Email already escaped as ESCAPED_EMAIL
# UUID and Keys are base64-like, typically safe for sed.

log_info "正在生成Xray配置文件（出于安全考虑不显示敏感参数）"

# 使用 # 作为 sed 分隔符以避免路径和特殊字符引起的问题
sed -e "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" \
    -e "s#\${UUID}#$UUID#g" \
    -e "s#\${PRIVATE_KEY}#$PRIVATE_KEY#g" \
    -e "s#\${KCP_SEED}#$ESCAPED_KCP_SEED#g" \
    -e "s#\${EMAIL}#$ESCAPED_EMAIL#g" \
    "$XRAY_CONFIG_TEMPLATE_PATH" > "$XRAY_CONFIG_OUTPUT_PATH"
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

# 注意：临时文件清理由 EXIT trap 自动处理

log_info "---------------------------------------------------------------------"
log_info "安装和配置完成!"
log_info "---------------------------------------------------------------------"
log_info "Xray-core 和 Caddy 已安装并配置完成。"
log_info ""
log_info "重要客户端配置信息 (请妥善保管):"
log_info "  域名 (Address/Host):               $DOMAIN"
log_info "  用户 ID (UUID for VLESS/VMess):    [已生成，出于安全考虑不显示]"
log_info "  Xray 公钥 (PublicKey for Reality): [已生成，出于安全考虑不显示]"
log_info "  KCP 混淆密码 (Seed for mKCP):      [已生成，出于安全考虑不显示]"
log_info "  (Xray 私钥和所有敏感信息已安全保存到 /etc/xray/ 目录)"
log_info ""
log_info "服务配置文件位置:"
log_info "  程序:   /usr/local/bin/{xray,caddy}"
log_info "  Caddy:  $CADDY_CONFIG_OUTPUT_PATH"
log_info "  Xray:   $XRAY_CONFIG_OUTPUT_PATH"
log_info "  配置信息: /etc/xray/config_info.txt"
log_info "  客户端信息: /etc/xray/client_config_info.txt"
log_info ""
log_info "快捷命令:"
log_info "  管理菜单: xraycaddy"
log_info "  systemd 状态: systemctl status caddy.service xray.service"
log_info ""
log_info "⚠️  重要提醒:"
log_info "  - 所有敏感配置信息已保存到 /etc/xray/ 目录"
log_info "  - 请妥善保管配置文件，避免泄露敏感信息"
log_info "  - 可使用 'xraycaddy' 查看完整配置信息"
log_info "---------------------------------------------------------------------"

exit 0
