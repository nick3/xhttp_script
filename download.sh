#!/bin/bash
set -euo pipefail

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

# --- Function to download Caddy ---
download_caddy() {
    local force_download="${1:-false}"
    local output_dir="${2:-./app/caddy}"
    
    log_info "开始下载 Caddy..."
    
    # 创建输出目录（如果不存在）
    mkdir -p "$output_dir"
    
    # 检查是否需要强制下载
    if [ "$force_download" = "false" ] && [ -f "$output_dir/caddy" ]; then
        log_info "Caddy 已存在，跳过下载。使用 --force 参数强制重新下载。"
        return 0
    fi
    
    CADDY_REPO_NAME="lxhao61/integrated-examples"
    CADDY_TMP_ARCHIVE="caddy-linux-amd64.tar.gz"

    log_info "使用 dra 从 ${CADDY_REPO_NAME} 下载 ${CADDY_TMP_ARCHIVE}..."
    if "$DRA_CMD" download --select "${CADDY_TMP_ARCHIVE}" "${CADDY_REPO_NAME}"; then
        log_info "Caddy (${CADDY_TMP_ARCHIVE}) 使用 dra 下载成功。"
        if [ ! -f "${CADDY_TMP_ARCHIVE}" ]; then
            log_error "dra报告下载成功，但在当前目录未找到文件: ${CADDY_TMP_ARCHIVE}"
            return 1
        fi
    else
        log_error "使用 dra 下载 Caddy (${CADDY_TMP_ARCHIVE}) 失败。仓库: ${CADDY_REPO_NAME}"
        return 1
    fi

    log_info "正在解压 Caddy 到 $output_dir..."
    # Assuming the tarball contains the 'caddy' binary directly.
    if tar -xzf "$CADDY_TMP_ARCHIVE" -C "$output_dir"; then
        log_info "Caddy 解压成功。"
    else
        log_error "Caddy 解压失败。"
        rm "$CADDY_TMP_ARCHIVE"
        return 1
    fi

    if [ ! -f "$output_dir/caddy" ]; then
        log_error "$output_dir/caddy 未找到。请检查归档文件的内容和解压路径。"
        # Attempt to find it if it was extracted into a common subdirectory pattern
        FOUND_CADDY=$(find "$output_dir" -name caddy -type f | head -n 1)
        if [ -n "$FOUND_CADDY" ] && [ "$FOUND_CADDY" != "$output_dir/caddy" ]; then
            log_info "在 $FOUND_CADDY 找到 Caddy。正在移动到 $output_dir/caddy..."
            mv "$FOUND_CADDY" "$output_dir/caddy"
            # Clean up the directory it was in if it's now empty and not $output_dir itself
            CADDY_SUBDIR=$(dirname "$FOUND_CADDY")
            if [ "$CADDY_SUBDIR" != "$output_dir" ] && [ -z "$(ls -A "$CADDY_SUBDIR")" ]; then
                rm -r "$CADDY_SUBDIR"
            fi
        else
            log_error "无法自动定位 Caddy 二进制文件。请手动将其放置在 $output_dir/caddy。"
            rm "$CADDY_TMP_ARCHIVE"
            return 1
        fi
    fi

    chmod +x "$output_dir/caddy"
    rm "$CADDY_TMP_ARCHIVE"
    log_info "Caddy 安装并设置可执行权限完成。"
    return 0
}

# --- Function to download Xray-core ---
download_xray() {
    local force_download="${1:-false}"
    local output_dir="${2:-./app/xray}"
    
    log_info "开始下载 Xray-core..."
    
    # 创建输出目录（如果不存在）
    mkdir -p "$output_dir"
    
    # 检查是否需要强制下载
    if [ "$force_download" = "false" ] && [ -f "$output_dir/xray" ]; then
        log_info "Xray-core 已存在，跳过下载。使用 --force 参数强制重新下载。"
        return 0
    fi
    
    XRAY_REPO_NAME="XTLS/Xray-core"
    XRAY_ASSET_FILENAME="Xray-linux-64.zip"

    log_info "使用 dra 从 ${XRAY_REPO_NAME} 下载最新的 ${XRAY_ASSET_FILENAME}..."
    if "$DRA_CMD" download --select "${XRAY_ASSET_FILENAME}" "${XRAY_REPO_NAME}"; then
        log_info "Xray-core (${XRAY_ASSET_FILENAME}) 使用 dra 下载成功。"
        if [ ! -f "${XRAY_ASSET_FILENAME}" ]; then
            log_error "dra报告下载成功，但在当前目录未找到文件: ${XRAY_ASSET_FILENAME}"
            return 1
        fi
    else
        log_error "使用 dra 下载 Xray-core (${XRAY_ASSET_FILENAME}) 失败。仓库: ${XRAY_REPO_NAME}"
        return 1
    fi

    log_info "正在解压 Xray-core 到 $output_dir..."
    if unzip -o "$XRAY_ASSET_FILENAME" -d "$output_dir"; then
        log_info "Xray-core 解压成功。"
    else
        log_error "Xray-core 解压失败。"
        rm "$XRAY_ASSET_FILENAME"
        return 1
    fi

    # Ensure xray binary exists and set permissions
    if [ ! -f "$output_dir/xray" ]; then
        log_error "Xray 可执行文件未找到: $output_dir/xray。请检查归档文件内容。"
        rm "$XRAY_ASSET_FILENAME"
        return 1
    fi
    chmod +x "$output_dir/xray"
    [ -f "$output_dir/geosite.dat" ] && chmod +r "$output_dir/geosite.dat"
    [ -f "$output_dir/geoip.dat" ] && chmod +r "$output_dir/geoip.dat"

    rm "$XRAY_ASSET_FILENAME"
    log_info "Xray-core 安装并设置可执行权限完成。"
    return 0
}

# --- Function to calculate sha256 ---
sha256_file() {
    local file="$1"
    local hash

    if command -v sha256sum &> /dev/null; then
        read -r hash _ < <(sha256sum "$file")
    elif command -v shasum &> /dev/null; then
        read -r hash _ < <(shasum -a 256 "$file")
    else
        log_error "sha256sum 或 shasum 命令未找到，无法校验 Hysteria2。"
        return 1
    fi

    printf '%s\n' "$hash"
}

# --- Function to download Hysteria2 ---
download_hysteria2() {
    local force_download="${1:-false}"
    local output_dir="${2:-./app/hysteria}"
    local repo_name="apernet/hysteria"
    local asset_filename="hysteria-linux-amd64"
    local hashes_filename="hashes.txt"
    local expected_hash=""
    local actual_hash
    local hash_value
    local hash_path

    log_info "开始下载 Hysteria2..."
    mkdir -p "$output_dir"

    if [ "$force_download" = "false" ] && [ -f "$output_dir/hysteria" ]; then
        log_info "Hysteria2 已存在，跳过下载。使用 --force 参数强制重新下载。"
        return 0
    fi

    rm -f "$asset_filename" "$hashes_filename"

    log_info "使用 dra 从 ${repo_name} 下载 ${asset_filename}..."
    if ! "$DRA_CMD" download --select "$asset_filename" "$repo_name"; then
        log_error "使用 dra 下载 Hysteria2 (${asset_filename}) 失败。仓库: ${repo_name}"
        rm -f "$asset_filename" "$hashes_filename"
        return 1
    fi

    if [ ! -f "$asset_filename" ]; then
        log_error "dra报告下载成功，但在当前目录未找到文件: ${asset_filename}"
        rm -f "$asset_filename" "$hashes_filename"
        return 1
    fi

    log_info "使用 dra 从 ${repo_name} 下载 ${hashes_filename}..."
    if ! "$DRA_CMD" download --select "$hashes_filename" "$repo_name"; then
        log_error "使用 dra 下载 Hysteria2 校验文件 (${hashes_filename}) 失败。"
        rm -f "$asset_filename" "$hashes_filename"
        return 1
    fi

    if [ ! -f "$hashes_filename" ]; then
        log_error "dra报告下载成功，但在当前目录未找到文件: ${hashes_filename}"
        rm -f "$asset_filename" "$hashes_filename"
        return 1
    fi

    while read -r hash_value hash_path _; do
        if [ "$hash_path" = "build/${asset_filename}" ] || [ "$hash_path" = "$asset_filename" ]; then
            expected_hash="$hash_value"
            break
        fi
    done < "$hashes_filename"

    if [ -z "$expected_hash" ]; then
        log_error "${hashes_filename} 中未找到 ${asset_filename} 的 sha256。"
        rm -f "$asset_filename" "$hashes_filename"
        return 1
    fi

    if ! actual_hash=$(sha256_file "$asset_filename"); then
        rm -f "$asset_filename" "$hashes_filename"
        return 1
    fi

    if [ "$actual_hash" != "$expected_hash" ]; then
        log_error "Hysteria2 sha256 校验失败：expected=${expected_hash}, actual=${actual_hash}。"
        rm -f "$asset_filename" "$hashes_filename"
        return 1
    fi

    mv "$asset_filename" "$output_dir/hysteria"
    chmod +x "$output_dir/hysteria"
    rm -f "$hashes_filename"
    log_info "Hysteria2 下载、校验并设置可执行权限完成。"
    return 0
}

# --- Main section ---
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
REQUIRED_CMDS=("tar" "unzip" "mkdir" "chmod")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd 命令未找到。请先安装 $cmd。"
        # Attempt to install common dependencies for Debian/Ubuntu
        if [[ "$cmd" == "unzip" || "$cmd" == "tar" ]] && command -v apt-get &> /dev/null; then
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

# Parse command line arguments
component=""
force_download=false
output_dir=""

# Display usage information
usage() {
    echo "用法: $0 [选项] <组件>"
    echo ""
    echo "组件:"
    echo "  caddy      下载 caddy"
    echo "  xray       下载 xray-core"
    echo "  xraycaddy  下载 caddy 和 xray-core（默认）"
    echo "  hysteria2  下载 Hysteria2"
    echo "  all        下载 caddy、xray-core 和 Hysteria2"
    echo ""
    echo "选项:"
    echo "  --force  强制重新下载，即使文件已存在"
    echo "  --dir    指定输出目录 (默认: ./app/[组件])"
    echo "  --help   显示此帮助信息"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        caddy|xray|xraycaddy|hysteria2|all)
            component="$1"
            shift
            ;;
        --force)
            force_download=true
            shift
            ;;
        --dir)
            if [[ -n "$2" && "$2" != --* ]]; then
                output_dir="$2"
                shift 2
            else
                log_error "选项 --dir 需要一个参数。"
                usage
            fi
            ;;
        --help)
            usage
            ;;
        *)
            log_error "未知选项或参数: $1"
            usage
            ;;
    esac
done

# Set default component if not specified
if [ -z "$component" ]; then
    component="xraycaddy"
fi

# Execute downloads based on component
case "$component" in
    caddy)
        download_caddy "$force_download" "${output_dir:-./app/caddy}"
        ;;
    xray)
        download_xray "$force_download" "${output_dir:-./app/xray}"
        ;;
    hysteria2)
        download_hysteria2 "$force_download" "${output_dir:-./app/hysteria}"
        ;;
    xraycaddy)
        [ -n "$output_dir" ] && log_warning "使用 'xraycaddy' 组件时，--dir 选项将被忽略。"
        download_caddy "$force_download"
        download_xray "$force_download"
        ;;
    all)
        [ -n "$output_dir" ] && log_warning "使用 'all' 组件时，--dir 选项将被忽略。"
        download_caddy "$force_download"
        download_xray "$force_download"
        download_hysteria2 "$force_download"
        ;;
esac

exit 0
