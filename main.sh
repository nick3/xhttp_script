#!/bin/bash

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

# 主菜单函数
show_menu() {
    echo "----------------------------------------"
    echo " Xray & Caddy 服务管理脚本"
    echo "----------------------------------------"
    echo "请选择要执行的操作:"
    echo "1. 安装本服务 (xray 与 caddy)"
    echo "2. 修改配置并重启服务"
    echo "3. 重启服务"
    echo "4. 停止服务"
    echo "5. 显示客户端连接配置"
    echo "6. 查看客户端配置参数"
    echo "7. 更新 Xray 和 Caddy 到最新版"
    echo "8. 恢复到备份版本"
    echo "9. 设为开机自启服务"
    echo "10. 查看服务状态"
    echo "11. 卸载本服务"
    echo "12. 退出脚本"
    echo "----------------------------------------"
    read -r -p "请输入选项 [1-12]: " choice

    case $choice in
        1)
            echo "正在准备安装服务..."
            # 收集用户输入的配置项
            edit_config

            # 对用户输入进行验证
            if [ -z "$domain" ] || ! validate_domain "$domain"; then
                echo "错误: 域名验证失败。"
                return 1
            fi
            if [ -z "$www_root" ] || ! validate_path "$www_root"; then
                echo "错误: 路径验证失败。"
                return 1
            fi

            # 执行安装服务脚本 install.sh
            if [[ "$cert_type" == "existing" ]]; then
                bash install.sh "$domain" "$kcp_seed" "$www_root" "$cert_type" "$cert_path" "$key_path" "$email"
            else
                bash install.sh "$domain" "$kcp_seed" "$www_root" "$cert_type" "" "" "$email"
            fi

            # 询问是否立即启动服务
            read -r -p "安装已完成，是否立即启动服务? [Y/n]: " start_service
            start_service=${start_service:-Y}
            if [[ $start_service =~ ^[Yy]$ ]]; then
                echo "正在启动服务..."
                bash service.sh start
            else
                echo "服务未启动，您可以稍后使用 'bash service.sh start' 命令启动服务。"
            fi
            ;;
        2)
            # 收集用户输入的配置项
            edit_config

            # 检查配置信息文件是否存在
            if [ ! -f "./app/config_info.txt" ]; then
                echo "错误: 无法找到配置信息文件，请先安装服务。"
                return
            fi

            # 从配置文件中读取现有配置
            source "./app/config_info.txt"

            # 如果用户没有输入某个配置项，则使用配置文件中的值
            domain=${domain:-$DOMAIN}
            kcp_seed=${kcp_seed:-$KCP_SEED}
            www_root=${www_root:-$WWW_ROOT}
            email=${email:-$EMAIL}

            # 对使用配置文件中的值进行验证
            if [ -z "$domain" ] || ! validate_domain "$domain"; then
                echo "错误: 域名验证失败。"
                return 1
            fi
            if [ -z "$www_root" ] || ! validate_path "$www_root"; then
                echo "错误: 路径验证失败。"
                return 1
            fi

            # 询问用户是否要更新配置
            read -r -p "确认更新配置并重启服务？ [Y/n]: " confirm
            confirm=${confirm:-Y}
            if [[ $confirm =~ ^[Yy]$ ]]; then
                echo "正在更新配置并重启服务..."
                # 调用安装脚本进行配置更新
                if [[ "$cert_type" == "existing" ]]; then
                    bash install.sh "$domain" "$kcp_seed" "$www_root" "$cert_type" "$cert_path" "$key_path" "$email"
                else
                    bash install.sh "$domain" "$kcp_seed" "$www_root" "$cert_type" "" "" "$email"
                fi
                # 重启服务
                bash service.sh restart
                echo "配置已更新，服务已重启。"
            else
                echo "操作已取消。"
            fi
            ;;
        3)
            echo "正在重启服务..."
            # 调用service.sh脚本重启服务
            bash service.sh restart
            ;;
        4)
            echo "正在停止服务..."
            # 调用service.sh脚本停止服务
            bash service.sh stop
            ;;
        5)
            echo "正在准备生成客户端连接配置..."
            # 检查配置信息文件是否存在
            if [ ! -f "./app/config_info.txt" ]; then
                echo "错误: 无法找到配置信息文件，请先安装服务。"
                read -r -p "按回车键继续..."
                return
            fi
            
            # 读取配置信息
            source "./app/config_info.txt"
            
            # 生成客户端配置文件
            echo "正在根据模板生成客户端配置文件..."
            
            # 确保配置文件目录存在
            mkdir -p "./app"
            
            # 从模板生成配置文件，替换所有占位符
            if [ -f "./cfg_tpl/xray_client.config.json" ]; then
                # 使用sed替换配置文件中的所有变量
                sed -e "s|\${DOMAIN}|$DOMAIN|g" \
                    -e "s|\${UUID}|$UUID|g" \
                    -e "s|\${EMAIL}|${EMAIL:-admin@$DOMAIN}|g" \
                    -e "s|\${PUBLIC_KEY}|$PUBLIC_KEY|g" \
                    -e "s|\${KCP_SEED}|$KCP_SEED|g" \
                    ./cfg_tpl/xray_client.config.json > ./app/xray_client_config.json
                
                echo "客户端配置文件已生成: ./app/xray_client_config.json"
                echo
                echo "配置文件内容如下:"
                echo "----------------------------------------"
                cat ./app/xray_client_config.json
                echo "----------------------------------------"
                echo
            else
                echo "错误: 找不到客户端配置模板文件 ./cfg_tpl/xray_client.config.json"
            fi
            ;;
        6)
            echo "正在查看客户端配置参数..."
            # 检查客户端配置信息文件是否存在
            if [ ! -f "./app/client_config_info.txt" ]; then
                echo "错误: 无法找到客户端配置信息文件，请先安装服务。"
                read -r -p "按回车键继续..."
                return
            fi

            # 显示客户端配置信息
            echo "客户端配置参数如下:"
            echo "----------------------------------------"
            cat ./app/client_config_info.txt
            echo "----------------------------------------"
            read -r -p "按回车键继续..."
            ;;
        7)
            echo "正在准备更新 Xray 和 Caddy 到最新版..."

            # 检查是否已安装服务
            if [ ! -f "./app/xray/xray" ] && [ ! -f "./app/caddy/caddy" ]; then
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
                if bash update.sh update; then
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
                    bash update.sh list-backups
                    ;;
                2)
                    bash update.sh restore
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
            echo "正在准备设为开机自启服务..."

            # 确保systemd可用
            if ! command -v systemctl &> /dev/null; then
                echo "错误：systemd不可用，无法设置开机自启。"
                read -r -p "按回车键继续..."
                return
            fi

            # 检查当前工作目录，获取绝对路径
            CURRENT_DIR=$(pwd)

            # 创建caddy.service文件
            cat > /etc/systemd/system/caddy.service << EOF
[Unit]
Description=Caddy HTTP/2 web server
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$CURRENT_DIR
ExecStart=$CURRENT_DIR/app/caddy/caddy run --config $CURRENT_DIR/app/caddy/caddy.json
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=always
RestartSec=10s
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

            # 创建xray.service文件
            cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
Group=root
WorkingDirectory=$CURRENT_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$CURRENT_DIR/app/xray/xray run -c $CURRENT_DIR/app/xray/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

            # 重新加载systemd配置
            systemctl daemon-reload

            # 启用服务开机自启
            systemctl enable caddy.service
            systemctl enable xray.service

            # 确认系统服务已创建并启动
            echo "系统服务已创建完成。"
            echo "Caddy 服务状态："
            systemctl status caddy.service --no-pager || true
            echo "Xray 服务状态："
            systemctl status xray.service --no-pager || true

            echo "服务已设置为开机自启，并已启动。"
            echo "你可以使用以下命令管理服务："
            echo "  启动服务: systemctl start caddy.service xray.service"
            echo "  停止服务: systemctl stop caddy.service xray.service"
            echo "  重启服务: systemctl restart caddy.service xray.service"
            echo "  查看状态: systemctl status caddy.service xray.service"
            read -r -p "按回车键继续..."
            ;;
        10)
            echo "正在查看服务状态..."
            # 调用service.sh脚本查看服务状态
            bash service.sh status
            read -r -p "按回车键继续..."
            ;;
        11)
            echo "正在准备卸载服务..."
            read -r -p "警告: 这将停止所有服务并删除所有配置文件。确定要继续吗? [y/N]: " confirm
            confirm=${confirm:-N}
            if [[ $confirm =~ ^[Yy]$ ]]; then
                # 先停止服务
                bash service.sh stop

                # 检查并删除systemd服务（如果存在）
                if command -v systemctl &> /dev/null; then
                    # 检查服务是否存在
                    if systemctl list-unit-files | grep -q "caddy.service"; then
                        echo "正在禁用并删除Caddy系统服务..."
                        systemctl disable caddy.service
                        rm -f /etc/systemd/system/caddy.service
                    fi

                    if systemctl list-unit-files | grep -q "xray.service"; then
                        echo "正在禁用并删除Xray系统服务..."
                        systemctl disable xray.service
                        rm -f /etc/systemd/system/xray.service
                    fi

                    # 重新加载systemd配置
                    systemctl daemon-reload
                    echo "系统服务已成功移除。"
                fi

                # 删除配置文件和程序
                echo "删除程序文件和配置..."
                rm -rf ./app/caddy ./app/xray
                echo "服务已卸载。"
            else
                echo "操作已取消。"
            fi
            ;;
        12)
            echo "正在退出脚本..."
            exit 0
            ;;
        *)
            echo "无效输入，请输入 1 到 12 之间的数字。"
            show_menu # 重新显示菜单
            ;;
    esac
}

# 显示主菜单
show_menu
