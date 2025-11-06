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
log_info "KCP 混淆种子 (KCP Seed): $KCP_SEED" # Be careful logging sensitive info
log_info "网站根目录 (WWW Root): $WWW_ROOT"

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

# --- 1. Download Caddy ---
log_info "正在使用 download.sh 下载 Caddy..."
if ! bash "$DOWNLOAD_SCRIPT" caddy; then
    log_error "下载 Caddy 失败，请查看上面的错误信息。"
    exit 1
fi

# --- 2. Download Caddy executable to temp ---
log_info "正在下载 Caddy 到临时目录..."
if ! bash "$DOWNLOAD_SCRIPT" caddy; then
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
CADDY_CONFIG_TEMPLATE_PATH="./cfg_tpl/caddy_config.json"
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

log_info "使用以下参数生成Caddy配置: DOMAIN=$DOMAIN, WWW_ROOT=$WWW_ROOT, EMAIL=$EMAIL"

# 使用 # 作为 sed 分隔符以避免路径中的 / 符号引起的问题
sed "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" "$CADDY_CONFIG_TEMPLATE_PATH" | \
    sed "s#\${WWW_ROOT}#$ESCAPED_WWW_ROOT#g" | \
    sed "s#\${EMAIL}#$ESCAPED_EMAIL#g" > "$CADDY_CONFIG_OUTPUT_PATH"
log_info "Caddy 配置文件已生成: $CADDY_CONFIG_OUTPUT_PATH"

# --- 5. Download Xray-core to temp ---
log_info "正在下载 Xray-core 到临时目录..."
if ! bash "$DOWNLOAD_SCRIPT" xray; then
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
log_info "生成的 UUID: $UUID"

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
log_info "生成的 Private Key: $PRIVATE_KEY"
log_info "生成的 Public Key: $PUBLIC_KEY (此公钥通常用于客户端配置)"

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

log_info "使用以下参数生成Xray配置: DOMAIN=$DOMAIN, UUID=$UUID, EMAIL=$EMAIL, KCP_SEED=$KCP_SEED"

# 使用 # 作为 sed 分隔符以避免路径和特殊字符引起的问题
sed "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" "$XRAY_CONFIG_TEMPLATE_PATH" | \
    sed "s#\${UUID}#$UUID#g" | \
    sed "s#\${PRIVATE_KEY}#$PRIVATE_KEY#g" | \
    sed "s#\${KCP_SEED}#$ESCAPED_KCP_SEED#g" | \
    sed "s#\${EMAIL}#$ESCAPED_EMAIL#g" > "$XRAY_CONFIG_OUTPUT_PATH"
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
XRAY_BIN=/usr/local/bin/xray
CADDY_BIN=/usr/local/bin/caddy
XRAY_CONFIG=/etc/xray/config.json
CADDY_CONFIG=/etc/caddy/caddy.json
EOF
chmod 600 "/etc/xray/config_info.txt"  # 设置适当的文件权限，因为包含敏感信息
log_info "配置信息已保存到 /etc/xray/config_info.txt"

# --- 9. Create xraycaddy command shortcut ---
log_info "正在创建 xraycaddy 全局命令..."
CURRENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ln -sf "$CURRENT_SCRIPT_DIR/main.sh" /usr/local/bin/xraycaddy
chmod +x /usr/local/bin/xraycaddy
log_info "快捷命令 'xraycaddy' 已创建完成"

# --- 10. Cleanup temporary files ---
log_info "清理临时文件..."
rm -rf ./app/temp
log_info "临时文件已清理"

log_info "---------------------------------------------------------------------"
log_info "安装和配置完成!"
log_info "---------------------------------------------------------------------"
log_info "Xray-core 和 Caddy 已安装并配置完成。"
log_info ""
log_info "重要客户端配置信息 (请妥善保管):"
log_info "  域名 (Address/Host):               $DOMAIN"
log_info "  用户 ID (UUID for VLESS/VMess):    $UUID"
log_info "  Xray 公钥 (PublicKey for Reality): $PUBLIC_KEY"
log_info "  KCP 混淆密码 (Seed for mKCP):      $KCP_SEED"
log_info "  (Xray 私钥位于服务器配置中，请勿泄露: $PRIVATE_KEY)"
log_info ""
log_info "服务配置文件位置:"
log_info "  程序:   /usr/local/bin/{xray,caddy}"
log_info "  Caddy:  $CADDY_CONFIG_OUTPUT_PATH"
log_info "  Xray:   $XRAY_CONFIG_OUTPUT_PATH"
log_info "  配置信息: /etc/xray/config_info.txt"
log_info ""
log_info "快捷命令:"
log_info "  管理服务: xraycaddy"
log_info "  直接启动: xraycaddy"
log_info "---------------------------------------------------------------------"

exit 0
