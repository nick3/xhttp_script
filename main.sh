#!/bin/bash

# 获取脚本所在目录，用于支持xraycaddy快捷命令
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 检查当前系统是否符合脚本要求，必须为x86_64架构的Linux系统
if [[ $(uname -m) != "x86_64" ]]; then
    echo "当前系统不支持，请使用x86_64架构的Linux系统。"
    exit 1
fi
# 检查当前系统是否为root用户
if [[ $EUID -ne 0 ]]; then
    echo "请使用root用户运行此脚本。"
    exit 1
fi
# 检查当前系统是否为Debian或Ubuntu
if ! grep -q -E "Debian|Ubuntu" /etc/os-release; then
    echo "当前系统不支持，请使用Debian或Ubuntu系统。"
    exit 1
fi

# Check for required commands
REQUIRED_CMDS=("tar" "unzip" "sed" "awk" "grep" "mkdir" "chmod") # 移除了nohup和ps，因为不再需要启动服务

# Define logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warning() {
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# --- Secure configuration file parser ---
# This function safely parses the config file without executing arbitrary code
parse_config_file() {
    local config_file="/etc/xray/config_info.txt"

    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        return 1
    fi

    if [ ! -r "$config_file" ]; then
        log_error "配置文件不可读: $config_file"
        return 1
    fi

    # Reset global variables
    DOMAIN=""
    UUID=""
    PRIVATE_KEY=""
    PUBLIC_KEY=""
    KCP_SEED=""
    EMAIL=""
    WWW_ROOT=""
    CERT_TYPE=""
    CERT_PATH=""
    KEY_PATH=""
    XRAY_BIN=""
    CADDY_BIN=""
    XRAY_CONFIG=""
    CADDY_CONFIG=""

    # Parse file line by line to avoid code injection
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Extract key-value pairs safely
        if [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Set values based on key, with basic validation
            case $key in
                DOMAIN)
                    if [[ "$value" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                        DOMAIN="$value"
                    fi
                    ;;
                UUID)
                    if [[ "$value" =~ ^[a-fA-F0-9-]+$ ]]; then
                        UUID="$value"
                    fi
                    ;;
                PRIVATE_KEY|PUBLIC_KEY)
                    # Base64-like validation for keys
                    if [[ "$value" =~ ^[a-zA-Z0-9/+_=-]+$ ]]; then
                        case $key in
                            PRIVATE_KEY) PRIVATE_KEY="$value" ;;
                            PUBLIC_KEY)  PUBLIC_KEY="$value"  ;;
                        esac
                    fi
                    ;;
                KCP_SEED)
                    # KCP 种子可以是任何字符串，因此我们不进行严格验证。
                    # 在 install.sh 中，它在使用 sed 之前已经进行了转义。
                    KCP_SEED="$value"
                    ;;
                EMAIL)
                    if [[ "$value" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        EMAIL="$value"
                    fi
                    ;;
                WWW_ROOT)
                    # Path validation (avoid path traversal)
                    if [[ "$value" =~ ^/ ]] && [[ ! "$value" =~ \.\. ]]; then
                        WWW_ROOT="$value"
                    fi
                    ;;
                CERT_TYPE)
                    if [[ "$value" =~ ^(acme|existing)$ ]]; then
                        CERT_TYPE="$value"
                    fi
                    ;;
                CERT_PATH|KEY_PATH|XRAY_BIN|CADDY_BIN|XRAY_CONFIG|CADDY_CONFIG)
                    # Path validation for file paths
                    if [[ "$value" =~ ^/ ]] && [[ ! "$value" =~ \.\. ]]; then
                        case $key in
                            CERT_PATH)   CERT_PATH="$value" ;;
                            KEY_PATH)    KEY_PATH="$value" ;;
                            XRAY_BIN)    XRAY_BIN="$value" ;;
                            CADDY_BIN)   CADDY_BIN="$value" ;;
                            XRAY_CONFIG) XRAY_CONFIG="$value" ;;
                            CADDY_CONFIG) CADDY_CONFIG="$value" ;;
                        esac
                    fi
                    ;;
            esac
        fi
    done < "$config_file"

    log_info "配置文件解析完成"
    return 0
}

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

edit_config() {
    # 此函数需要用户输入以下配置项：
    read -r -p "请输入域名: " domain
    read -r -p "请输入KCP协议的混淆密码: " kcp_seed
    read -r -p "请输入静态页面文件路径: " www_root

    # 询问用户证书选项
    echo "请选择证书申请方式:"
    echo "1. 使用 ACME 自动申请证书 (推荐)"
    echo "2. 使用现有证书文件"
    read -r -p "请输入选项 [1-2] (默认为1): " cert_choice
    cert_choice=${cert_choice:-1}

    if [[ $cert_choice == "2" ]]; then
        # 使用现有证书
        read -r -p "请输入证书文件路径 (.crt/.pem): " cert_file
        read -r -p "请输入私钥文件路径 (.key): " key_file

        # 验证证书文件是否存在
        if [[ ! -f "$cert_file" ]]; then
            echo "错误: 证书文件不存在: $cert_file"
            read -r -p "按回车键继续..."
            return 1
        fi
        if [[ ! -f "$key_file" ]]; then
            echo "错误: 私钥文件不存在: $key_file"
            read -r -p "按回车键继续..."
            return 1
        fi

        # 设置证书类型标记
        cert_type="existing"
        cert_path="$cert_file"
        key_path="$key_file"
        # 对于现有证书，邮箱不是必需的，但仍可以询问
        read -r -p "请输入邮箱地址(用于其他用途,可选): " email
    else
        # 使用 ACME 自动申请证书
        cert_type="acme"
        read -r -p "请输入邮箱地址(用于SSL证书申请,必需): " email
    fi

    # 验证输入的安全性
    validate_domain "$domain"
    validate_path "$www_root"

    # 如果email为空且使用ACME，则必须提供
    if [[ $cert_type == "acme" && -z "$email" ]]; then
        email="admin@$domain"
        echo "使用默认邮箱: $email"
    fi
}

select_install_profile() {
    echo "请选择安装 profile:"
    echo "1. xraycaddy - Xray + Caddy"
    echo "2. hysteria2 - Hysteria2"
    echo "3. all - Xray + Caddy + Hysteria2"
    read -r -p "请输入选项 [1-3] (默认为1): " profile_choice
    profile_choice=${profile_choice:-1}

    case "$profile_choice" in
        1) install_profile="xraycaddy" ;;
        2) install_profile="hysteria2" ;;
        3) install_profile="all" ;;
        *)
            echo "错误: 无效安装 profile 选项: $profile_choice"
            read -r -p "按回车键继续..."
            return 1
            ;;
    esac
}

validate_port_range_input() {
    local range="$1"
    local profile="${2:-${install_profile:-}}"
    local start
    local end

    if [[ ! "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
        echo "错误: 端口范围格式无效，应为 start-end，例如 20000-40000"
        return 1
    fi

    start="${range%-*}"
    end="${range#*-}"

    if [ "$start" -lt 1 ] || [ "$start" -gt 65535 ] || [ "$end" -lt 1 ] || [ "$end" -gt 65535 ] || [ "$start" -gt "$end" ]; then
        echo "错误: 端口范围无效: $range"
        return 1
    fi

    if [ "$start" -le 443 ] && [ "$end" -ge 443 ]; then
        echo "错误: 端口跳跃范围不能包含 UDP/443，该端口保留给 XHTTP/Caddy。"
        return 1
    fi

    if [ "$profile" = "all" ] && [ "$start" -le 2052 ] && [ "$end" -ge 2052 ]; then
        echo "错误: all profile 的端口跳跃范围不能包含 UDP/2052，该端口保留给 Xray KCP。"
        return 1
    fi

    return 0
}

validate_duration_interval_input() {
    local value="$1"

    if [[ ! "$value" =~ ^([0-9]+(ms|s|m|h))+$ ]]; then
        echo "错误: 端口跳跃间隔格式无效，应为 30s、5m 或 1h"
        return 1
    fi

    return 0
}

edit_hysteria2_base_config() {
    read -r -p "请输入域名: " domain
    echo "请选择证书方式:"
    echo "1. 使用现有证书文件 (推荐)"
    echo "2. 使用 Hysteria2 ACME 自动申请证书"
    read -r -p "请输入选项 [1-2] (默认为1): " cert_choice
    cert_choice=${cert_choice:-1}

    if [[ "$cert_choice" == "2" ]]; then
        cert_type="hysteria-acme"
        cert_path=""
        key_path=""
        read -r -p "请输入邮箱地址(用于 ACME，可选): " email
    else
        cert_type="existing"
        read -r -p "请输入证书文件路径 (.crt/.pem): " cert_path
        read -r -p "请输入私钥文件路径 (.key): " key_path
    fi
}

edit_hysteria2_config() {
    read -r -p "请输入 Hysteria2 认证密码: " hysteria_auth
    read -r -p "请输入 Hysteria2 masquerade proxy URL: " hysteria_masquerade_proxy_url
    read -r -p "请输入 Hysteria2 UDP 监听端口 (默认 8443，不能为 443): " hysteria_port
    hysteria_port=${hysteria_port:-8443}

    if [ "$hysteria_port" = "443" ]; then
        echo "错误: Hysteria2 不能使用 UDP/443，该端口保留给 XHTTP/Caddy。"
        read -r -p "按回车键继续..."
        return 1
    fi

    read -r -p "是否开启 Hysteria2 端口跳跃？ [y/N]: " hysteria_port_hopping_choice
    hysteria_port_hopping_choice=${hysteria_port_hopping_choice:-N}
    hysteria_port_hopping_enabled="false"
    hysteria_port_hopping_range=""
    hysteria_port_hopping_interval="30s"

    if [[ "$hysteria_port_hopping_choice" =~ ^[Yy]$ ]]; then
        hysteria_port_hopping_enabled="true"
        read -r -p "请输入端口跳跃范围 (例如 20000-40000，不能包含 443): " hysteria_port_hopping_range
        validate_port_range_input "$hysteria_port_hopping_range" "$install_profile" || {
            read -r -p "按回车键继续..."
            return 1
        }
        read -r -p "请输入端口跳跃间隔 (默认 30s): " hysteria_port_hopping_interval
        hysteria_port_hopping_interval=${hysteria_port_hopping_interval:-30s}
        validate_duration_interval_input "$hysteria_port_hopping_interval" || {
            read -r -p "按回车键继续..."
            return 1
        }
    fi
}

run_install_from_wizard() {
    local install_args=(--profile "$install_profile" --domain "$domain")

    if [[ "$install_profile" == "xraycaddy" || "$install_profile" == "all" ]]; then
        install_args+=(--kcp-seed "$kcp_seed" --www-root "$www_root")
    fi

    install_args+=(--cert-mode "$cert_type")
    if [[ "$cert_type" == "existing" ]]; then
        install_args+=(--cert-path "$cert_path" --key-path "$key_path")
    fi
    [ -n "${email:-}" ] && install_args+=(--email "$email")

    if [[ "$install_profile" == "hysteria2" || "$install_profile" == "all" ]]; then
        install_args+=(
            --hysteria-port "$hysteria_port"
            --hysteria-auth "$hysteria_auth"
            --hysteria-masquerade-proxy-url "$hysteria_masquerade_proxy_url"
        )

        if [ "$hysteria_port_hopping_enabled" = "true" ]; then
            install_args+=(
                --hysteria-port-hopping
                --hysteria-port-hopping-range "$hysteria_port_hopping_range"
                --hysteria-port-hopping-interval "$hysteria_port_hopping_interval"
            )
        fi
    fi

    bash "$SCRIPT_DIR/install.sh" "${install_args[@]}"
}

# 验证域名格式
validate_domain() {
    local domain="$1"
    if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        echo "错误: 无效的域名格式: $domain"
        read -r -p "按回车键继续..."
        return 1
    fi
}

# 验证路径安全，防止路径遍历
validate_path() {
    local path="$1"
    if [[ $path == *".."* ]] || [[ $path == *"/../"* ]]; then
        echo "错误: 路径中包含不安全的 '..' 组件: $path"
        read -r -p "按回车键继续..."
        return 1
    fi
    # 规范化路径并验证
    local normalized_path=$(realpath -m -- "$path" 2>/dev/null) || {
        echo "错误: 无法规范化路径: $path"
        read -r -p "按回车键继续..."
        return 1
    }
    if [[ ! "$normalized_path" =~ ^/ ]]; then
        echo "错误: 路径必须是绝对路径或以正常方式解析: $path"
        read -r -p "按回车键继续..."
        return 1
    fi
}

systemd_units_ready() {
    command -v systemctl >/dev/null 2>&1 \
        && [ -f "/etc/systemd/system/caddy.service" ] \
        && [ -f "/etc/systemd/system/xray.service" ]
}

manage_services() {
    local action="$1"
    if systemd_units_ready; then
        systemctl "$action" caddy.service xray.service
    else
        log_warning "未找到 systemd unit，使用 service.sh 手动 fallback。"
        bash "$SCRIPT_DIR/service.sh" "$action"
    fi
}

show_systemd_status() {
    systemctl status caddy.service xray.service --no-pager || true
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# 主菜单函数
show_menu() {
    echo "----------------------------------------"
    echo " Xray & Caddy 服务管理脚本"
    echo "----------------------------------------"
    echo "请选择要执行的操作:"
    echo "1. 安装服务 (xraycaddy / hysteria2 / all)"
    echo "2. 修改配置并重启服务"
    echo "3. 重启服务"
    echo "4. 停止服务"
    echo "5. 显示客户端连接配置"
    echo "6. 查看客户端配置参数"
    echo "7. 更新 Xray 和 Caddy 到最新版"
    echo "8. 恢复到备份版本"
    echo "9. 设为开机自启服务"
    echo "10. 卸载本服务"
    echo "11. 退出脚本"
    echo "----------------------------------------"
    read -r -p "请输入选项 [1-11]: " choice

    case $choice in
        1)
            echo "正在准备安装服务..."
            select_install_profile || return 1

            if [[ "$install_profile" == "hysteria2" ]]; then
                edit_hysteria2_base_config || return 1
            else
                edit_config || return 1
                if [[ "$install_profile" == "all" && "$cert_type" != "existing" ]]; then
                    echo "错误: all profile 必须使用现有证书，避免 Caddy 与 Hysteria2 同时申请 ACME 证书。"
                    read -r -p "按回车键继续..."
                    return 1
                fi
            fi

            if [[ "$install_profile" == "hysteria2" || "$install_profile" == "all" ]]; then
                edit_hysteria2_config || return 1
            fi

            # 对用户输入进行验证
            if [ -z "$domain" ] || ! validate_domain "$domain"; then
                echo "错误: 域名验证失败。"
                read -r -p "按回车键继续..."
                return 1
            fi
            if [[ "$install_profile" == "xraycaddy" || "$install_profile" == "all" ]]; then
                if [ -z "$www_root" ] || ! validate_path "$www_root"; then
                    echo "错误: 路径验证失败。"
                    read -r -p "按回车键继续..."
                    return 1
                fi
            fi

            if ! run_install_from_wizard; then
                log_error "安装过程失败，请检查上述错误信息。"
                read -r -p "按回车键继续..."
                return 1
            fi

            echo "安装已完成，服务已由 systemd 托管并完成健康检查。"
            echo "客户端参数: xraycaddy -> 6，或查看 /etc/xray/client_config_info.txt"
            read -r -p "按回车键继续..."
            ;;
        2)
            # 收集用户输入的配置项
            edit_config

            # 检查配置信息文件是否存在
            if [ ! -f "/etc/xray/config_info.txt" ]; then
                echo "错误: 无法找到配置信息文件，请先安装服务。"
                read -r -p "按回车键继续..."
                return
            fi

            # 从配置文件中读取现有配置
            parse_config_file

            # 如果用户没有输入某个配置项，则使用配置文件中的值
            domain=${domain:-$DOMAIN}
            kcp_seed=${kcp_seed:-$KCP_SEED}
            www_root=${www_root:-$WWW_ROOT}
            email=${email:-$EMAIL}
            cert_type=${cert_type:-$CERT_TYPE}
            cert_path=${cert_path:-$CERT_PATH}
            key_path=${key_path:-$KEY_PATH}

            # 对使用配置文件中的值进行验证
            if [ -z "$domain" ] || ! validate_domain "$domain"; then
                echo "错误: 域名验证失败。"
                read -r -p "按回车键继续..."
                return 1
            fi
            if [ -z "$www_root" ] || ! validate_path "$www_root"; then
                echo "错误: 路径验证失败。"
                read -r -p "按回车键继续..."
                return 1
            fi

            # 询问用户是否要更新配置
            read -r -p "确认更新配置并重启服务？ [Y/n]: " confirm
            confirm=${confirm:-Y}
            if [[ $confirm =~ ^[Yy]$ ]]; then
                echo "正在更新配置并重启服务..."
                # 调用安装脚本进行配置更新
                if [[ "$cert_type" == "existing" ]]; then
                    if ! bash "$SCRIPT_DIR/install.sh" "$domain" "$kcp_seed" "$www_root" "$cert_type" "$cert_path" "$key_path" "$email"; then
                        log_error "配置更新失败，请检查上述错误信息。"
                        read -r -p "按回车键继续..."
                        return 1
                    fi
                else
                    if ! bash "$SCRIPT_DIR/install.sh" "$domain" "$kcp_seed" "$www_root" "$cert_type" "" "" "$email"; then
                        log_error "配置更新失败，请检查上述错误信息。"
                        read -r -p "按回车键继续..."
                        return 1
                    fi
                fi
                echo "配置已更新，服务已由 systemd 重启并完成健康检查。"
                echo "客户端参数: xraycaddy -> 6，或查看 /etc/xray/client_config_info.txt"
            else
                echo "操作已取消。"
            fi
            read -r -p "按回车键继续..."
            ;;
        3)
            echo "正在重启服务..."
            if manage_services restart; then
                echo "服务已重启。"
            else
                echo "服务重启失败，请检查上方错误信息。"
            fi
            read -r -p "按回车键继续..."
            ;;
        4)
            echo "正在停止服务..."
            if manage_services stop; then
                echo "服务已停止。"
            else
                echo "服务停止失败，请检查上方错误信息。"
            fi
            read -r -p "按回车键继续..."
            ;;
        5)
            echo "正在准备生成客户端连接配置..."
            # 检查配置信息文件是否存在
            if [ ! -f "/etc/xray/config_info.txt" ]; then
                echo "错误: 无法找到配置信息文件，请先安装服务。"
                read -r -p "按回车键继续..."
                return
            fi

            # 读取配置信息
            parse_config_file

            # 生成客户端配置文件
            echo "正在根据模板生成客户端配置文件..."

            # 获取当前脚本所在目录
            CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

            # 确保配置文件目录存在
            mkdir -p "./app"

            # 从模板生成配置文件，替换所有占位符
            if [ -f "$CURRENT_DIR/cfg_tpl/xray_client.config.json" ]; then
                escaped_domain=$(escape_sed_replacement "$DOMAIN")
                escaped_uuid=$(escape_sed_replacement "$UUID")
                escaped_email=$(escape_sed_replacement "${EMAIL:-admin@$DOMAIN}")
                escaped_public_key=$(escape_sed_replacement "$PUBLIC_KEY")
                escaped_kcp_seed=$(escape_sed_replacement "$KCP_SEED")

                sed -e "s|\${DOMAIN}|$escaped_domain|g" \
                    -e "s|\${UUID}|$escaped_uuid|g" \
                    -e "s|\${EMAIL}|$escaped_email|g" \
                    -e "s|\${PUBLIC_KEY}|$escaped_public_key|g" \
                    -e "s|\${KCP_SEED}|$escaped_kcp_seed|g" \
                    "$CURRENT_DIR/cfg_tpl/xray_client.config.json" > "./app/xray_client_config.json"

                echo "客户端配置文件已生成: ./app/xray_client_config.json"
                echo
                echo "配置文件内容如下:"
                echo "----------------------------------------"
                cat ./app/xray_client_config.json
                echo "----------------------------------------"
                echo
            else
                echo "错误: 找不到客户端配置模板文件 $CURRENT_DIR/cfg_tpl/xray_client.config.json"
            fi
            read -r -p "按回车键继续..."
            ;;
        6)
            echo "正在查看客户端配置参数..."
            # 检查客户端配置信息文件是否存在
            if [ ! -f "/etc/xray/client_config_info.txt" ]; then
                echo "错误: 无法找到客户端配置信息文件，请先安装服务。"
                read -r -p "按回车键继续..."
                return
            fi

            # 显示客户端配置信息
            echo "客户端配置参数如下:"
            echo "----------------------------------------"
            cat /etc/xray/client_config_info.txt
            echo "----------------------------------------"
            read -r -p "按回车键继续..."
            ;;
        7)
            echo "正在准备更新 Xray 和 Caddy 到最新版..."

            # 检查是否已安装服务
            if [ ! -f "/usr/local/bin/xray" ] && [ ! -f "/usr/local/bin/caddy" ]; then
                echo "错误: 未找到已安装的服务，请先安装服务。"
                read -r -p "按回车键继续..."
                return
            fi

            echo "这将更新 Xray 和 Caddy 到最新版本。"
            echo "更新前会自动创建当前版本的备份。"
            echo "如果更新过程中出现问题，您可以使用恢复功能回到之前的版本。"
            echo ""

            read -r -p "确认继续更新？ [Y/n]: " confirm
            confirm=${confirm:-Y}
            if [[ $confirm =~ ^[Yy]$ ]]; then
                echo "正在更新服务..."
                if bash "$SCRIPT_DIR/update.sh" update; then
                    echo "更新完成！"
                else
                    echo "更新过程中出现问题，请检查上述错误信息。"
                fi
            else
                echo "更新已取消。"
            fi
            read -r -p "按回车键继续..."
            ;;
        8)
            echo "正在准备恢复服务到备份版本..."

            # 检查是否有备份
            if [ ! -d "./backups" ] || [ -z "$(ls -A "./backups" 2>/dev/null)" ]; then
                echo "没有找到备份文件。"
                read -r -p "按回车键继续..."
                return
            fi

            echo "可用操作:"
            echo "1. 查看所有备份"
            echo "2. 恢复备份"
            echo "3. 返回主菜单"

            read -r -p "请选择操作 [1-3]: " restore_choice
            case $restore_choice in
                1)
                    bash "$SCRIPT_DIR/update.sh" list-backups
                    ;;
                2)
                    bash "$SCRIPT_DIR/update.sh" restore
                    ;;
                3)
                    return
                    ;;
                *)
                    echo "无效选项。"
                    ;;
            esac
            read -r -p "按回车键继续..."
            ;;
        9)
            echo "正在修复 systemd 开机自启服务..."

            if ! command -v systemctl &> /dev/null; then
                echo "错误：systemd 不可用，当前安装闭环仅支持常规 Debian/Ubuntu systemd VPS。"
                read -r -p "按回车键继续..."
                return
            fi

            if [ ! -f "/usr/local/bin/caddy" ] || [ ! -f "/usr/local/bin/xray" ]; then
                echo "错误：Xray 或 Caddy 未安装，请先安装服务。"
                read -r -p "按回车键继续..."
                return
            fi

            if ! systemd_units_ready; then
                echo "错误：未找到 systemd unit，请重新运行安装流程生成并验证服务配置。"
                read -r -p "按回车键继续..."
                return
            fi

            if ! systemctl daemon-reload; then
                echo "错误：systemd 配置重载失败，请检查 unit 文件。"
                read -r -p "按回车键继续..."
                return 1
            fi
            if ! systemctl enable caddy.service xray.service; then
                echo "错误：设置开机自启失败，请检查 systemd 状态。"
                read -r -p "按回车键继续..."
                return 1
            fi
            if systemctl restart caddy.service xray.service; then
                echo "服务已设置为开机自启并重新启动。"
            else
                echo "服务启动失败，请查看 systemd 状态和日志。"
            fi

            show_systemd_status
            echo "你可以使用以下命令管理服务："
            echo "  启动服务: systemctl start caddy.service xray.service"
            echo "  停止服务: systemctl stop caddy.service xray.service"
            echo "  重启服务: systemctl restart caddy.service xray.service"
            echo "  查看状态: systemctl status caddy.service xray.service"
            read -r -p "按回车键继续..."
            ;;
        10)
            echo "正在准备卸载服务..."
            read -r -p "警告: 这将停止所有服务并删除所有配置文件。确定要继续吗? [y/N]: " confirm
            confirm=${confirm:-N}
            if [[ $confirm =~ ^[Yy]$ ]]; then
                # 先停止服务
                bash "$SCRIPT_DIR/service.sh" stop

                # 检查并删除systemd服务（如果存在）
                if command -v systemctl &> /dev/null; then
                    # 先停止并禁用服务，然后再删除服务文件
                    if systemctl list-unit-files | grep -q "caddy.service"; then
                        echo "正在停止并禁用Caddy系统服务..."
                        systemctl stop caddy.service || true
                        systemctl disable caddy.service || true
                        rm -f /etc/systemd/system/caddy.service
                    fi

                    if systemctl list-unit-files | grep -q "xray.service"; then
                        echo "正在停止并禁用Xray系统服务..."
                        systemctl stop xray.service || true
                        systemctl disable xray.service || true
                        rm -f /etc/systemd/system/xray.service
                    fi

                    # 重新加载systemd配置
                    systemctl daemon-reload
                    echo "系统服务已成功移除。"
                fi

                # 删除程序文件
                echo "删除程序文件..."
                rm -f /usr/local/bin/xray
                rm -f /usr/local/bin/caddy

                # 删除配置文件
                echo "删除配置文件..."
                rm -rf /etc/xray
                rm -rf /etc/caddy

                # 删除日志文件
                echo "删除日志文件..."
                rm -f /var/log/xray.log
                rm -f /var/log/caddy.log

                # 删除PID文件
                echo "删除PID文件..."
                rm -rf /var/run/xray-caddy

                # 删除快捷命令
                echo "删除快捷命令..."
                rm -f /usr/local/bin/xraycaddy

                echo "服务已完全卸载。"
                SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                echo "注意：脚本目录 '$SCRIPT_DIR' 未被删除，您可以手动删除它。"
            else
                echo "操作已取消。"
            fi
            read -r -p "按回车键继续..."
            ;;
        11)
            echo "正在退出脚本..."
            exit 0
            ;;
        *)
            echo "无效输入，请输入 1 到 11 之间的数字。"
            show_menu # 重新显示菜单
            ;;
    esac
}

# 显示主菜单
show_menu
