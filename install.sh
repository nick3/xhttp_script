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
    sed "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" "$CADDY_CONFIG_TEMPLATE_PATH" | \
        sed "s#\${WWW_ROOT}#$ESCAPED_WWW_ROOT#g" | \
        sed "s#\${CERT_PATH}#$ESCAPED_CERT_PATH#g" | \
        sed "s#\${KEY_PATH}#$ESCAPED_KEY_PATH#g" > "$CADDY_CONFIG_OUTPUT_PATH"
else
    # 使用ACME模板
    sed "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" "$CADDY_CONFIG_TEMPLATE_PATH" | \
        sed "s#\${WWW_ROOT}#$ESCAPED_WWW_ROOT#g" | \
        sed "s#\${EMAIL}#$ESCAPED_EMAIL#g" > "$CADDY_CONFIG_OUTPUT_PATH"
fi
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
# 捕获命令执行的完整输出和错误信息
KEY_OUTPUT=$("$XRAY_EXE" x25519 2>&1)
KEY_EXIT_CODE=$?

if [ $KEY_EXIT_CODE -ne 0 ]; then
    log_error "Xray x25519 命令执行失败，退出码: $KEY_EXIT_CODE"
    log_error "命令输出: $KEY_OUTPUT"
    log_error "Xray 可执行文件路径: $XRAY_EXE"
    log_error "检查 Xray 可执行文件是否存在和可执行:"
    ls -la "$XRAY_EXE" 2>&1 || true
    exit 1
fi

log_info "Xray x25519 命令输出: $KEY_OUTPUT"

# Xray 不同版本的 x25519 命令输出格式可能不同
# 旧版本格式: "Private key:" 和 "Public key:"
# 新版本格式: "PrivateKey:" 和 "Password:" (其中 Password 是公钥)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -E "(Private key:|PrivateKey:)" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -E "(Public key:|Password:)" | awk '{print $NF}')

# 检查是否成功提取了密钥
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    log_error "无法从命令输出中提取密钥。"
    log_error "命令输出: $KEY_OUTPUT"
    log_error "尝试直接执行命令以查看详细输出:"
    "$XRAY_EXE" x25519
    exit 1
fi

log_info "X25519 密钥对生成完成（公钥将在安装完成后显示）"

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
