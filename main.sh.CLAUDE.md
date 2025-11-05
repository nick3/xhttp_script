[根目录](../CLAUDE.md) > **main.sh 模块**

# main.sh 模块文档

## 模块职责
提供交互式菜单系统，管理 Xray 和 Caddy 服务。这是用户与脚本交互的主要入口点，通过菜单界面提供各种服务管理功能。

## 入口与启动
- **入口文件**: `main.sh`
- **启动方式**: `sudo bash main.sh`
- **依赖检查**: 系统架构(x86_64)、操作系统类型(Debian/Ubuntu)、用户权限(root)

## 对外接口
脚本提供了菜单驱动的交互界面，包含以下主要选项：
1. 安装本服务 (xray 与 caddy)
2. 修改配置并重启服务
3. 重启服务
4. 停止服务
5. 显示客户端连接配置
6. 设为开机自启服务
7. 卸载本服务
8. 退出脚本

## 关键依赖与配置
- 必需命令: tar, unzip, sed, awk, grep, mkdir, chmod
- 内部调用: install.sh, service.sh, 以及 cfg_tpl/ 目录下的配置模板
- 配置文件: ./app/config_info.txt (存储服务配置信息)

## 数据模型
- 服务配置信息存储在 `./app/config_info.txt` 文件中
- 包含: DOMAIN, UUID, PRIVATE_KEY, PUBLIC_KEY, KCP_SEED, EMAIL, WWW_ROOT

## 测试与质量
- 包含系统兼容性检查（架构、操作系统、权限）
- 包含必要命令检查和自动安装机制

## 常见问题 (FAQ)
Q: 为什么需要 root 权限？
A: 脚本需要创建系统服务、修改网络配置和写入系统日志目录。

Q: 如何重新配置服务？
A: 选择菜单选项 2，可以修改配置并重启服务。

## 相关文件清单
- main.sh - 主脚本
- ./app/config_info.txt - 服务配置信息
- ./cfg_tpl/xray_client.config.json - 客户端配置模板

## 变更记录 (Changelog)
- 2025-11-01: 初始化文档