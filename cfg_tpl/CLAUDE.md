[根目录](../CLAUDE.md) > **cfg_tpl 模块**

# cfg_tpl 模块文档

## 模块职责
提供 Xray 和 Caddy 服务的标准配置模板。包含服务器配置、客户端配置以及 Caddy 服务器的配置文件模板，使用变量占位符以便在安装过程中替换为实际值。

## 入口与启动
- **入口文件**: 配置模板文件
- **使用方式**: 通过 install.sh 脚本使用 sed 命令进行变量替换生成实际配置文件

## 对外接口
模板文件接口：
- `caddy_config.json`: Caddy 服务器配置模板
- `xray_config.json`: Xray 服务器配置模板
- `xray_client.config.json`: Xray 客户端配置模板

## 关键依赖与配置
- 服务器配置: 包含 VLESS/REALITY/XHTTP/KCP 多协议支持
- 客户端配置: 包含多种协议的连接配置
- 变量占位符: `${DOMAIN}`, `${UUID}`, `${PRIVATE_KEY}`, `${PUBLIC_KEY}`, `${KCP_SEED}`, `${EMAIL}`, `${WWW_ROOT}`

## 数据模型
配置文件使用 JSON 格式，包含以下主要部分：
- Xray 服务器配置：VLESS 协议在 443 端口支持 Reality 和 XHTTP，KCP 协议在 2052 端口
- Caddy 服务器配置：HTTP/HTTPS 重定向、证书自动化、流量路由
- 客户端配置：多种协议的连接参数

## 测试与质量
- JSON 格式验证
- 协议兼容性测试
- 现实协议安全性检查

## 常见问题 (FAQ)
Q: 为什么使用变量占位符？
A: 允许在安装过程中使用实际的配置值替换模板中的占位符。

Q: 支持哪些协议？
A: 支持 VLESS/REALITY/Vision、XHTTP 和 KCP 协议。

## 相关文件清单
- ./cfg_tpl/caddy_config.json - Caddy 配置模板
- ./cfg_tpl/xray_config.json - Xray 服务器配置模板
- ./cfg_tpl/xray_client.config.json - Xray 客户端配置模板

## 变更记录 (Changelog)
- 2025-11-01: 初始化文档