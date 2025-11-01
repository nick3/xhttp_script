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

# --- Sanity Checks & Argument Parsing ---
if [[ $# -lt 3 ]]; then
    log_error "使用方法: $0 <domain> <kcp_seed> <www_root_path> [email]"
    log_error "例如: $0 example.com mysecretpassword /var/www/html user@example.com"
    exit 1
fi

DOMAIN="$1"
KCP_SEED="$2"
WWW_ROOT="$3"
# 使用默认邮箱或命令行提供的邮箱
EMAIL="${4:-admin@$DOMAIN}"

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
# 不在日志中显示敏感信息如KCP种子
log_info "网站根目录 (WWW Root): $WWW_ROOT"

# --- Prepare Directories ---
log_info "创建所需目录..."
mkdir -p ./app/caddy
mkdir -p ./app/xray
mkdir -p "$WWW_ROOT"
# 创建日志目录
mkdir -p /var/log/caddy
mkdir -p /var/log/xray
chmod 755 /var/log/caddy
chmod 755 /var/log/xray
log_info "目录 ./app/caddy, ./app/xray, $WWW_ROOT, /var/log/caddy, /var/log/xray 已准备就绪。"

# --- 1. Download Caddy ---
log_info "正在使用 download.sh 下载 Caddy..."
if ! bash "$DOWNLOAD_SCRIPT" caddy; then
    log_error "下载 Caddy 失败，请查看上面的错误信息。"
    exit 1
fi

# --- 2. Configure Caddy ---
log_info "正在配置 Caddy (caddy.json)..."
CADDY_CONFIG_TEMPLATE_PATH="./cfg_tpl/caddy_config.json"
CADDY_CONFIG_OUTPUT_PATH="./app/caddy/caddy.json"

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

log_info "使用以下参数生成Caddy配置: DOMAIN=$DOMAIN, WWW_ROOT=$WWW_ROOT, EMAIL=$EMAIL"

# 使用 # 作为 sed 分隔符以避免路径中的 / 符号引起的问题
sed "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" "$CADDY_CONFIG_TEMPLATE_PATH" | \
    sed "s#\${WWW_ROOT}#$ESCAPED_WWW_ROOT#g" | \
    sed "s#\${EMAIL}#$ESCAPED_EMAIL#g" > "$CADDY_CONFIG_OUTPUT_PATH"
log_info "Caddy 配置文件已生成: $CADDY_CONFIG_OUTPUT_PATH"

# --- 3. Download Xray-core ---
log_info "正在使用 download.sh 下载 Xray-core..."
if ! bash "$DOWNLOAD_SCRIPT" xray; then
    log_error "下载 Xray-core 失败，请查看上面的错误信息。"
    exit 1
fi

# 确认xray可执行文件存在
XRAY_EXE="./app/xray/xray"
if [ ! -f "$XRAY_EXE" ]; then
    log_error "Xray 可执行文件未找到: $XRAY_EXE。请检查下载是否成功。"
    exit 1
fi

# --- 4. Generate UUID for Xray ---
log_info "正在生成 Xray UUID..."
UUID=$("$XRAY_EXE" uuid)
if [ -z "$UUID" ]; then
    log_error "生成 Xray UUID 失败。"
    exit 1
fi
log_info "UUID 生成完成（将在安装完成后显示）"

# --- 5. Generate Private/Public Keys for Xray ---
log_info "正在生成 Xray X25519 密钥对..."
KEY_OUTPUT=$("$XRAY_EXE" x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key:" | awk '{print $3}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    log_error "生成 X25519 密钥对失败。"
    log_error "命令输出: $KEY_OUTPUT"
    exit 1
fi
log_info "X25519 密钥对生成完成（公钥将在安装完成后显示）"

# --- 6. Configure Xray-core ---
log_info "正在配置 Xray-core (config.json)..."
XRAY_CONFIG_TEMPLATE_PATH="./cfg_tpl/xray_config.json"
XRAY_CONFIG_OUTPUT_PATH="./app/xray/config.json"

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

log_info "使用以下参数生成Xray配置: DOMAIN=$DOMAIN, EMAIL=$EMAIL (其他参数为敏感信息，不在日志中显示)"

# 使用 # 作为 sed 分隔符以避免路径和特殊字符引起的问题
sed "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" "$XRAY_CONFIG_TEMPLATE_PATH" | \
    sed "s#\${UUID}#$UUID#g" | \
    sed "s#\${PRIVATE_KEY}#$PRIVATE_KEY#g" | \
    sed "s#\${KCP_SEED}#$ESCAPED_KCP_SEED#g" | \
    sed "s#\${EMAIL}#$ESCAPED_EMAIL#g" > "$XRAY_CONFIG_OUTPUT_PATH"
log_info "Xray-core 配置文件已生成: $XRAY_CONFIG_OUTPUT_PATH"

# 将配置信息保存到配置文件，便于服务启动脚本和客户端配置生成脚本使用
CONFIG_INFO_FILE="./app/config_info.txt"
log_info "正在保存配置信息到 $CONFIG_INFO_FILE..."
cat > "$CONFIG_INFO_FILE" << EOF
# Xray & Caddy 配置信息
DOMAIN=$DOMAIN
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
KCP_SEED=$KCP_SEED
EMAIL=$EMAIL
WWW_ROOT=$WWW_ROOT
EOF
chmod 600 "$CONFIG_INFO_FILE"  # 设置适当的文件权限，因为包含敏感信息
log_info "配置信息已保存到 $CONFIG_INFO_FILE"

log_info "---------------------------------------------------------------------"
log_info "安装和配置完成!"
log_info "---------------------------------------------------------------------"
log_info "Xray-core 和 Caddy 已下载并配置完成。"
log_info ""
log_info "重要客户端配置信息 (请妥善保管):"
log_info "  域名 (Address/Host):               $DOMAIN"
log_info "  用户 ID (UUID for VLESS/VMess):    $UUID"
log_info "  Xray 公钥 (PublicKey for Reality): $PUBLIC_KEY"
log_info "  KCP 混淆密码 (Seed for mKCP):      $KCP_SEED"
log_info "  (Xray 私钥已保存在服务器配置中，客户端无需使用)"
log_info ""
log_info "服务配置文件位置:"
log_info "  Caddy: $CADDY_CONFIG_OUTPUT_PATH"
log_info "  Xray:  $XRAY_CONFIG_OUTPUT_PATH"
log_info ""
log_info "请使用以下命令启动服务:"
log_info "  bash service.sh start"
log_info "---------------------------------------------------------------------"

# 将客户端配置参数保存到单独的文件中，供后续查看
CLIENT_CONFIG_INFO_FILE="./app/client_config_info.txt"
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

chmod 600 "$CLIENT_CONFIG_INFO_FILE"  # 设置适当的文件权限，因为包含敏感信息
exit 0
