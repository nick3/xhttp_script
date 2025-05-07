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
    read -r -p "请输入邮箱地址(用于SSL证书申请,可选): " email
    # 如果email为空，使用默认值
    email=${email:-admin@$domain}
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
    echo "6. 设为开机自启服务"
    echo "7. 卸载本服务"
    echo "8. 退出脚本"
    echo "----------------------------------------"
    read -r -p "请输入选项 [1-8]: " choice

    case $choice in
        1)
            echo "正在准备安装服务..."
            # 收集用户输入的配置项
            edit_config
            # 执行安装服务脚本 install.sh
            bash install.sh "$domain" "$kcp_seed" "$www_root" "$email"
            
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
            
            ;;
        5)
            echo "正在准备生成客户端连接配置..."
            # 检查配置信息文件是否存在
            if [ ! -f "./app/config_info.txt" ]; then
                echo "错误: 无法找到配置信息文件，请先安装服务。"
                continue
            fi
            
            # 读取配置信息
            source "./app/config_info.txt"
            echo "配置信息已读取，请选择要生成的客户端类型:"
            echo "1. 通用信息 (适用于手动配置)"
            echo "2. v2rayN 配置 (Windows)"
            echo "3. Qv2ray 配置 (跨平台)"
            echo "4. Shadowrocket 配置 (iOS)"
            echo "5. v2rayNG 配置 (Android)"
            echo "6. 返回上级菜单"
            
            read -r -p "请选择 [1-6]: " client_op
            case $client_op in
                1)
                    echo "---------- 通用连接信息 ----------"
                    echo "地址 (Address): $DOMAIN"
                    echo "端口 (Port): 443"
                    echo "用户ID (UUID): $UUID"
                    echo "传输协议 (Network): ws+tls 或 tcp+reality"
                    echo "Xray 公钥 (Public Key): $PUBLIC_KEY"
                    echo "KCP 混淆密码: $KCP_SEED"
                    echo "----------------------------------"
                    read -r -p "按回车键继续..."
                    ;;
                2|3|4|5)
                    echo "此功能尚未实现，将在未来版本中提供。"
                    read -r -p "按回车键继续..."
                    ;;
                6)
                    # 返回上级菜单
                    ;;
                *)
                    echo "无效选择，返回主菜单"
                    ;;
            esac
            ;;
        6)
            echo "正在准备设为开机自启服务..."
            # 此处将来会调用设为开机自启服务的函数
            ;;
        7)
            echo "正在准备卸载服务..."
            read -r -p "警告: 这将停止所有服务并删除所有配置文件。确定要继续吗? [y/N]: " confirm
            confirm=${confirm:-N}
            if [[ $confirm =~ ^[Yy]$ ]]; then
                # 先停止服务
                bash service.sh stop
                # 删除配置文件和程序
                echo "删除程序文件和配置..."
                rm -rf ./app/caddy ./app/xray
                echo "服务已卸载。"
            else
                echo "操作已取消。"
            fi
            ;;
        8)
            echo "正在退出脚本..."
            exit 0
            ;;
        *)
            echo "无效输入，请输入 1 到 8 之间的数字。"
            show_menu # 重新显示菜单
            ;;
    esac
}

# 显示主菜单
show_menu
