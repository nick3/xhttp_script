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

# Check for dra program
DRA_CMD="./dra"
if [ ! -f "$DRA_CMD" ]; then
    log_error "\\"$DRA_CMD\\" not found. Please ensure 'dra' is in the same directory as this script (current dir: $(pwd))."
    exit 1
fi
if [ ! -x "$DRA_CMD" ]; then
    log_info "Attempting to make '$DRA_CMD' executable..."
    chmod +x "$DRA_CMD"
    if [ ! -x "$DRA_CMD" ]; then
        log_error "Failed to make '$DRA_CMD' executable. Please set execute permissions manually."
        exit 1
    fi
    log_info "'$DRA_CMD' is now executable."
fi

# Check for required commands
REQUIRED_CMDS=("tar" "unzip" "sed" "awk" "grep" "mkdir" "chmod" "nohup" "ps") # curl is no longer directly required by script
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd 命令未找到。请先安装 $cmd。"
        # Attempt to install common dependencies for Debian/Ubuntu
        if [[ "$cmd" == "unzip" || "$cmd" == "tar" ]] && command -v apt-get &> /dev/null; then # Removed curl from here
            log_info "正在尝试为 Debian/Ubuntu 安装 $cmd..."
            if apt-get update && apt-get install -y "$cmd"; then
                log_info "$cmd 安装成功。"
            else
                log_error "自动安装 $cmd 失败。请手动安装后重试。"
                exit 1
            fi
        else
             exit 1 # Exit if other essential commands are missing or auto-install fails
        fi
    fi
done


log_info "开始部署 Xray-core 和 Caddy 服务..."
log_info "域名 (Domain): $DOMAIN"
log_info "KCP 混淆种子 (KCP Seed): $KCP_SEED" # Be careful logging sensitive info
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
log_info "正在下载 Caddy 使用 dra..."
CADDY_REPO_NAME="lxhao61/integrated-examples"
CADDY_TMP_ARCHIVE="caddy-linux-amd64.tar.gz" # This is the asset name and local filename

log_info "使用 dra 从 ${CADDY_REPO_NAME} 下载 ${CADDY_TMP_ARCHIVE}..."
if "$DRA_CMD" download --select "${CADDY_TMP_ARCHIVE}" "${CADDY_REPO_NAME}"; then
    log_info "Caddy (${CADDY_TMP_ARCHIVE}) 使用 dra 下载成功。"
    if [ ! -f "${CADDY_TMP_ARCHIVE}" ]; then
        log_error "dra报告下载成功，但在当前目录未找到文件: ${CADDY_TMP_ARCHIVE}"
        exit 1
    fi
else
    log_error "使用 dra 下载 Caddy (${CADDY_TMP_ARCHIVE}) 失败。仓库: ${CADDY_REPO_NAME}"
    exit 1
fi

log_info "正在解压 Caddy 到 ./app/caddy..."
# Assuming the tarball contains the 'caddy' binary directly.
# If it extracts to a subdirectory (e.g., caddy-linux-amd64/caddy), --strip-components=1 might be needed
# or a move operation after extraction.
if tar -xzf "$CADDY_TMP_ARCHIVE" -C ./app/caddy; then
    log_info "Caddy 解压成功。"
else
    log_error "Caddy 解压失败。"
    rm "$CADDY_TMP_ARCHIVE"
    exit 1
fi

if [ ! -f "./app/caddy/caddy" ]; then
    log_error "./app/caddy/caddy 未找到。请检查归档文件的内容和解压路径。"
    # Attempt to find it if it was extracted into a common subdirectory pattern
    FOUND_CADDY=$(find ./app/caddy -name caddy -type f | head -n 1)
    if [ -n "$FOUND_CADDY" ] && [ "$FOUND_CADDY" != "./app/caddy/caddy" ]; then
        log_info "在 $FOUND_CADDY 找到 Caddy。正在移动到 ./app/caddy/caddy..."
        mv "$FOUND_CADDY" ./app/caddy/caddy
        # Clean up the directory it was in if it's now empty and not ./app/caddy itself
        CADDY_SUBDIR=$(dirname "$FOUND_CADDY")
        if [ "$CADDY_SUBDIR" != "./app/caddy" ] && [ -z "$(ls -A "$CADDY_SUBDIR")" ]; then
            rm -r "$CADDY_SUBDIR"
        fi
    else
        log_error "无法自动定位 Caddy 二进制文件。请手动将其放置在 ./app/caddy/caddy。"
        rm "$CADDY_TMP_ARCHIVE"
        exit 1
    fi
fi

chmod +x ./app/caddy/caddy
rm "$CADDY_TMP_ARCHIVE"
log_info "Caddy 安装并设置可执行权限完成。"

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
log_info "正在下载 Xray-core 使用 dra..."
XRAY_REPO_NAME="XTLS/Xray-core"
XRAY_ASSET_FILENAME="Xray-linux-64.zip"
XRAY_TMP_ARCHIVE="${XRAY_ASSET_FILENAME}" # Local filename where dra will save it

log_info "使用 dra 从 ${XRAY_REPO_NAME} 下载最新的 ${XRAY_ASSET_FILENAME}..."
if "$DRA_CMD" download --select "${XRAY_ASSET_FILENAME}" "${XRAY_REPO_NAME}"; then
    log_info "Xray-core (${XRAY_ASSET_FILENAME}) 使用 dra 下载成功。"
    if [ ! -f "${XRAY_ASSET_FILENAME}" ]; then
        log_error "dra报告下载成功，但在当前目录未找到文件: ${XRAY_ASSET_FILENAME}"
        exit 1
    fi
else
    log_error "使用 dra 下载 Xray-core (${XRAY_ASSET_FILENAME}) 失败。仓库: ${XRAY_REPO_NAME}"
    exit 1
fi

log_info "正在解压 Xray-core 到 ./app/xray..."
# -o option overwrites files without prompting
if unzip -o "$XRAY_TMP_ARCHIVE" -d ./app/xray; then
    log_info "Xray-core 解压成功。"
else
    log_error "Xray-core 解压失败。"
    rm "$XRAY_TMP_ARCHIVE"
    exit 1
fi

# Ensure xray binary exists and set permissions
XRAY_EXE="./app/xray/xray"
if [ ! -f "$XRAY_EXE" ]; then
    log_error "Xray 可执行文件未找到: $XRAY_EXE。请检查归档文件内容。"
    rm "$XRAY_TMP_ARCHIVE"
    exit 1
fi
chmod +x "$XRAY_EXE"
# Also set permissions for geosite.dat and geoip.dat if they exist
[ -f "./app/xray/geosite.dat" ] && chmod +r "./app/xray/geosite.dat"
[ -f "./app/xray/geoip.dat" ] && chmod +r "./app/xray/geoip.dat"

rm "$XRAY_TMP_ARCHIVE"
log_info "Xray-core 安装并设置可执行权限完成。"

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

# --- 6. Configure Xray-core ---
log_info "正在配置 Xray-core (config.json)..."
XRAY_CONFIG_TEMPLATE_PATH="./cfg_tpl/xray_config.json" # Corrected from xaryy_config.json in original prompt
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

log_info "使用以下参数生成Xray配置: DOMAIN=$DOMAIN, UUID=$UUID, EMAIL=$EMAIL, KCP_SEED=$KCP_SEED"

# 使用 # 作为 sed 分隔符以避免路径和特殊字符引起的问题
sed "s#\${DOMAIN}#$ESCAPED_DOMAIN#g" "$XRAY_CONFIG_TEMPLATE_PATH" | \
    sed "s#\${UUID}#$UUID#g" | \
    sed "s#\${PRIVATE_KEY}#$PRIVATE_KEY#g" | \
    sed "s#\${KCP_SEED}#$ESCAPED_KCP_SEED#g" | \
    sed "s#\${EMAIL}#$ESCAPED_EMAIL#g" > "$XRAY_CONFIG_OUTPUT_PATH"
log_info "Xray-core 配置文件已生成: $XRAY_CONFIG_OUTPUT_PATH"

# --- 7. Run Caddy ---
CADDY_LOG_FILE="/var/log/caddy.log"
log_info "正在启动 Caddy 服务... 日志将输出到 $CADDY_LOG_FILE"
# Create log file and set permissions if it doesn't exist, or ensure it's writable
touch "$CADDY_LOG_FILE"
chmod 644 "$CADDY_LOG_FILE" # Or appropriate permissions

# Check if Caddy is already running from a previous attempt (e.g. by checking for a pid file or process)
# For simplicity, this script doesn't manage existing processes robustly.
# It assumes it's a fresh start or the user handles prior instances.

nohup ./app/caddy/caddy run --config "$CADDY_CONFIG_OUTPUT_PATH" >> "$CADDY_LOG_FILE" 2>&1 &
CADDY_PID=$!
sleep 3 # Give it a moment to start or fail

if ps -p $CADDY_PID > /dev/null; then
   log_info "Caddy 服务已启动 (PID: $CADDY_PID)。日志文件: $CADDY_LOG_FILE"
else
   log_error "Caddy 服务启动失败。请检查日志: $CADDY_LOG_FILE"
   log_error "尝试查看 Caddy 日志尾部:"
   tail -n 20 "$CADDY_LOG_FILE" || true
   # Decide if to exit. If Caddy fails, Xray might still be useful for non-HTTP traffic,
   # but typically they are used together for the described setup.
   # exit 1
fi

# --- 8. Run Xray-core ---
XRAY_LOG_FILE="/var/log/xray.log"
log_info "正在启动 Xray-core 服务... 日志将输出到 $XRAY_LOG_FILE"
touch "$XRAY_LOG_FILE"
chmod 644 "$XRAY_LOG_FILE"

nohup "$XRAY_EXE" run -c "$XRAY_CONFIG_OUTPUT_PATH" >> "$XRAY_LOG_FILE" 2>&1 &
XRAY_PID=$!
sleep 3 # Give it a moment to start or fail

if ps -p $XRAY_PID > /dev/null; then
   log_info "Xray-core 服务已启动 (PID: $XRAY_PID)。日志文件: $XRAY_LOG_FILE"
else
   log_error "Xray-core 服务启动失败。请检查日志: $XRAY_LOG_FILE"
   log_error "尝试查看 Xray 日志尾部:"
   tail -n 20 "$XRAY_LOG_FILE" || true
   # If Caddy started but Xray failed, Caddy might still be running.
   # exit 1
fi

log_info "---------------------------------------------------------------------"
log_info "部署完成!"
log_info "---------------------------------------------------------------------"
if ps -p $CADDY_PID > /dev/null && ps -p $XRAY_PID > /dev/null; then
    log_info "Caddy 和 Xray-core 服务应正在后台运行。"
elif ps -p $CADDY_PID > /dev/null; then
    log_warning "Caddy 服务正在运行 (PID: $CADDY_PID)，但 Xray-core 可能启动失败。"
elif ps -p $XRAY_PID > /dev/null; then
    log_warning "Xray-core 服务正在运行 (PID: $XRAY_PID)，但 Caddy 可能启动失败。"
else
    log_error "Caddy 和 Xray-core 服务似乎都启动失败了。请检查上面的日志。"
fi
log_info ""
log_info "重要客户端配置信息 (请妥善保管):"
log_info "  域名 (Address/Host):               $DOMAIN"
log_info "  用户 ID (UUID for VLESS/VMess):    $UUID"
log_info "  Xray 公钥 (PublicKey for Reality): $PUBLIC_KEY"
log_info "  KCP 混淆密码 (Seed for mKCP):    $KCP_SEED"
log_info "  (Xray 私钥位于服务器配置中，请勿泄露: $PRIVATE_KEY)"
log_info ""
log_info "服务日志:"
log_info "  Caddy: $CADDY_LOG_FILE"
log_info "  Xray:  $XRAY_LOG_FILE"
log_info ""
log_info "管理服务 (示例):"
if ps -p $CADDY_PID > /dev/null; then
    log_info "  要停止 Caddy: kill $CADDY_PID"
fi
if ps -p $XRAY_PID > /dev/null; then
    log_info "  要停止 Xray:  kill $XRAY_PID"
fi
log_info "  为确保服务稳定运行和开机自启，强烈建议将它们配置为 systemd 服务。"
log_info "---------------------------------------------------------------------"

exit 0
