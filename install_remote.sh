#!/bin/bash

# Xray-Caddy 自动部署工具一键安装脚本
# 项目地址：https://github.com/nick3/xhttp_script

# 设置错误时立即退出
set -e

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

# 显示欢迎信息
show_welcome() {
    echo ""
    echo "========================================================="
    echo -e "${GREEN}        Xray-Caddy 自动部署工具一键安装脚本         ${NC}"
    echo "========================================================="
    echo ""
    echo -e "本脚本将自动安装 ${BLUE}Xray-Caddy${NC} 自动部署工具"
    echo "该工具可以帮助您快速配置和管理 Xray 和 Caddy 服务"
    echo ""
    echo "脚本将执行以下操作："
    echo " 1. 检查系统环境和依赖"
    echo " 2. 下载安装项目文件"
    echo " 3. 配置执行权限"
    echo " 4. 自动运行安装向导"
    echo ""
    echo -e "${YELLOW}注意：本脚本需要 root 权限运行${NC}"
    echo "========================================================="
    echo ""
    
    # 5秒倒计时
    echo -n "安装将在 5 秒后开始"
    for i in {5..1}; do
        echo -n " $i"
        sleep 1
    done
    echo -e "\n"
}

# 检查系统环境
check_system() {
    log_info "正在检查系统环境..."
    
    # 检查系统架构
    arch=$(uname -m)
    if [[ $arch != "x86_64" ]]; then
        log_error "不支持的系统架构: $arch，请使用 x86_64 架构的系统"
        exit 1
    fi
    
    # 检查是否为 root 用户
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本"
        log_info "您可以使用 'sudo -i' 切换到 root 用户，然后再运行此脚本"
        exit 1
    fi
    
    # 检查系统类型
    if ! grep -q -E "Debian|Ubuntu" /etc/os-release &>/dev/null; then
        log_error "不支持的系统类型，请使用 Debian 或 Ubuntu 系统"
        exit 1
    fi
    
    log_success "系统环境检查通过"
}

# 检查并安装依赖
check_dependencies() {
    log_info "正在检查所需工具..."
    
    # 定义必要的命令
    local tools=("curl" "wget" "git" "unzip" "tar" "sed" "awk" "grep" "mkdir" "chmod")
    local missing_tools=()
    
    # 检查命令是否存在
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    # 如果有缺少的工具，尝试安装
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_warn "以下工具未找到: ${missing_tools[*]}"
        log_info "正在尝试安装缺少的工具..."
        
        # 更新软件包列表
        apt-get update -qq
        
        # 安装缺少的工具
        for tool in "${missing_tools[@]}"; do
            log_info "正在安装 $tool..."
            if ! apt-get install -y "$tool"; then
                log_error "安装 $tool 失败，请手动安装后重试"
                exit 1
            fi
        done
        
        log_success "所有依赖工具已安装"
    else
        log_success "所有必要工具均已安装"
    fi
}

# 下载项目文件
download_project() {
    log_info "正在下载项目文件..."
    
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    log_info "创建临时目录: $TMP_DIR"
    
    # 确定安装目录
    INSTALL_DIR="/opt/xhttp_script"
    if [[ -d "$INSTALL_DIR" ]]; then
        BACKUP_DIR="${INSTALL_DIR}_backup_$(date +%Y%m%d%H%M%S)"
        log_warn "目标目录已存在，将备份到 $BACKUP_DIR"
        mv "$INSTALL_DIR" "$BACKUP_DIR"
    fi
    mkdir -p "$INSTALL_DIR"
    
    # 下载方式选择
    if command -v git &>/dev/null; then
        # 使用 git 克隆
        log_info "使用 git 克隆项目..."
        if ! git clone --depth=1 https://github.com/nick3/xhttp_script.git "$TMP_DIR"; then
            log_error "使用 git 下载项目文件失败，尝试使用备用方法..."
            download_with_wget_or_curl
        fi
    else
        # 使用 wget 或 curl 下载
        download_with_wget_or_curl
    fi
    
    # 复制文件到安装目录
    log_info "复制文件到安装目录 $INSTALL_DIR..."
    cp -r "$TMP_DIR"/* "$INSTALL_DIR"
    
    # 清理临时目录
    log_info "清理临时文件..."
    rm -rf "$TMP_DIR"
    
    log_success "项目文件已下载到 $INSTALL_DIR"
}

# 使用 wget 或 curl 下载项目文件
download_with_wget_or_curl() {
    local ZIP_URL="https://github.com/nick3/xhttp_script/archive/refs/heads/main.zip"
    local ZIP_FILE="$TMP_DIR/xhttp_script.zip"
    
    # 尝试使用 wget 下载
    if command -v wget &>/dev/null; then
        log_info "使用 wget 下载项目文件..."
        if ! wget -q --show-progress -O "$ZIP_FILE" "$ZIP_URL"; then
            log_error "使用 wget 下载项目文件失败，尝试使用 curl..."
            if ! command -v curl &>/dev/null; then
                log_error "下载失败，且系统中没有安装 curl。请手动安装 wget 或 curl 后重试。"
                exit 1
            fi
            
            log_info "使用 curl 下载项目文件..."
            if ! curl -L -o "$ZIP_FILE" "$ZIP_URL"; then
                log_error "下载项目文件失败，请检查网络连接或手动下载"
                exit 1
            fi
        fi
    elif command -v curl &>/dev/null; then
        # 使用 curl 下载
        log_info "使用 curl 下载项目文件..."
        if ! curl -L -o "$ZIP_FILE" "$ZIP_URL"; then
            log_error "下载项目文件失败，请检查网络连接或手动下载"
            exit 1
        fi
    else
        log_error "未找到 wget 或 curl 命令，无法下载项目文件"
        exit 1
    fi
    
    # 解压文件
    log_info "解压项目文件..."
    local EXTRACT_DIR="$TMP_DIR/extract"
    mkdir -p "$EXTRACT_DIR"
    
    if ! unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR"; then
        log_error "解压项目文件失败"
        exit 1
    fi
    
    # 移动文件（处理解压后可能有的子目录）
    mv "$EXTRACT_DIR"/*/* "$TMP_DIR"/ 2>/dev/null || mv "$EXTRACT_DIR"/* "$TMP_DIR"/ 2>/dev/null || true
    
    # 清理解压后的临时文件
    rm -rf "$EXTRACT_DIR" "$ZIP_FILE"
}

# 设置文件权限
setup_permissions() {
    log_info "正在设置文件权限..."
    
    # 主要脚本文件
    local script_files=("main.sh" "install.sh" "service.sh" "download.sh")
    
    for file in "${script_files[@]}"; do
        if [[ -f "$INSTALL_DIR/$file" ]]; then
            chmod +x "$INSTALL_DIR/$file"
            log_info "已设置 $file 为可执行"
        else
            log_warn "文件 $file 不存在，跳过设置权限"
        fi
    done
    
    log_success "文件权限设置完成"
}

# 运行主脚本
run_main_script() {
    log_info "准备运行主脚本..."
    
    # 切换到安装目录
    cd "$INSTALL_DIR"
    
    # 检查主脚本是否存在
    if [[ ! -f "./main.sh" ]]; then
        log_error "主脚本 main.sh 不存在，安装可能不完整"
        exit 1
    fi
    
    log_info "正在启动 Xray-Caddy 自动部署工具..."
    log_info "您将进入交互式安装界面，请按照提示完成配置"
    echo ""
    echo "========================================================="
    echo -e "${GREEN}        正在启动 Xray-Caddy 自动部署工具...        ${NC}"
    echo "========================================================="
    echo ""
    
    # 执行主脚本
    bash ./main.sh
}

# 创建快捷方式
create_shortcut() {
    log_info "创建全局命令快捷方式..."
    
    # 创建符号链接
    ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/xray-caddy
    chmod +x /usr/local/bin/xray-caddy
    
    log_success "快捷方式已创建，您可以在任何位置使用 'xray-caddy' 命令来管理服务"
}

# 主函数
main() {
    show_welcome
    check_system
    check_dependencies
    download_project
    setup_permissions
    create_shortcut
    run_main_script
}

# 执行主函数
main
