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

# 安装必要的依赖，`dra`
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/devmatteini/dra/refs/heads/main/install.sh | bash -s -- --to /usr/local/bin

# 主菜单函数
show_menu() {
    echo "----------------------------------------"
    echo " Xray & Caddy 服务管理脚本"
    echo "----------------------------------------"
    echo "请选择要执行的操作:"
    echo "1. 安装本服务 (xray 与 caddy)"
    echo "2. 卸载本服务"
    echo "3. 退出脚本"
    echo "----------------------------------------"
    read -r -p "请输入选项 [1-3]: " choice

    case $choice in
        1)
            echo "正在准备安装服务..."
            # 此处将来会调用安装服务的函数
            ;;
        2)
            echo "正在准备卸载服务..."
            # 此处将来会调用卸载服务的函数
            ;;
        3)
            echo "正在退出脚本..."
            exit 0
            ;;
        *)
            echo "无效输入，请输入 1 到 3 之间的数字。"
            show_menu # 重新显示菜单
            ;;
    esac
}

# 显示主菜单
show_menu

