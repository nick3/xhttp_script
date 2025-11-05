[根目录](../CLAUDE.md) > **install.sh 模块**

# install.sh 模块文档

## 模块职责
安装和配置 Xray-core 和 Caddy 服务。负责下载二进制文件、生成配置文件、创建必要的密钥对和 UUID，并准备运行环境。

## 入口与启动
- **入口文件**: `install.sh`
- **调用方式**: 通过 main.sh 脚本调用或直接执行 `bash install.sh <domain> <kcp_seed> <www_root> [email]`
- **参数**: 域名、KCP混淆密码、网站根目录、可选邮箱

## 对外接口
命令行参数接口：
- `$1`: domain - 服务器域名
- `$2`: kcp_seed - KCP协议混淆密码
- `$3`: www_root - 网站文件根目录
- `$4`: email - 可选的邮箱地址(用于SSL证书)

## 关键依赖与配置
- 依赖: download.sh 脚本用于下载 Xray 和 Caddy
- 配置模板: ./cfg_tpl/caddy_config.json, ./cfg_tpl/xray_config.json
- 输出目录: ./app/caddy, ./app/xray, /var/log/caddy, /var/log/xray

## 数据模型
- 生成 UUID 使用 `xray uuid` 命令
- 生成 X25519 密钥对使用 `xray x25519` 命令
- 配置信息存储到 `./app/config_info.txt`

## 测试与质量
- 参数验证和错误处理
- 文件权限设置
- 日志记录功能

## 常见问题 (FAQ)
Q: 为什么需要生成密钥对？
A: Xray 的 Reality 协议需要私钥/公钥对来验证客户端连接。

Q: 如何处理配置文件中的变量替换？
A: 使用 sed 命令替换配置模板中的占位符，如 `${DOMAIN}`, `${UUID}` 等。

## 相关文件清单
- install.sh - 安装脚本
- ./download.sh - 下载工具
- ./cfg_tpl/caddy_config.json - Caddy 配置模板
- ./cfg_tpl/xray_config.json - Xray 配置模板
- ./app/config_info.txt - 保存配置信息

## 变更记录 (Changelog)
- 2025-11-01: 初始化文档