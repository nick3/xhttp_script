[根目录](../CLAUDE.md) > **service.sh 模块**

# service.sh 模块文档

## 模块职责
管理 Xray 和 Caddy 服务的运行状态。提供启动、停止、重启和状态检查功能，通过 nohup 命令在后台运行服务。

## 入口与启动
- **入口文件**: `service.sh`
- **调用方式**: `bash service.sh [start|stop|restart|status]`
- **默认操作**: 无参数时执行 start

## 对外接口
命令行接口选项：
- `start`: 启动 Caddy 和 Xray-core 服务
- `stop`: 停止 Caddy 和 Xray-core 服务
- `restart`: 重启 Caddy 和 Xray-core 服务
- `status`: 显示 Caddy 和 Xray-core 服务的状态

## 关键依赖与配置
- 服务二进制文件: ./app/xray/xray, ./app/caddy/caddy
- 配置文件: ./app/xray/config.json, ./app/caddy/caddy.json
- PID 文件: ./app/xray/xray.pid, ./app/caddy/caddy.pid
- 日志文件: /var/log/xray.log, /var/log/caddy.log

## 数据模型
- PID 存储: 服务进程 ID 存储在 PID 文件中用于后续管理
- 日志管理: 服务输出重定向到日志文件

## 测试与质量
- 进程状态检查 (使用 ps 命令验证服务是否正常启动)
- PID 文件管理
- 错误日志输出

## 常见问题 (FAQ)
Q: 服务启动失败如何排查？
A: 检查日志文件 /var/log/xray.log 或 /var/log/caddy.log 的尾部内容。

Q: 如何确认服务正在运行？
A: 使用 `bash service.sh status` 或检查 PID 文件是否存在且对应的进程在运行。

## 相关文件清单
- service.sh - 服务管理脚本
- ./app/xray/xray - Xray 二进制文件
- ./app/caddy/caddy - Caddy 二进制文件
- ./app/xray/config.json - Xray 配置文件
- ./app/caddy/caddy.json - Caddy 配置文件
- ./app/xray/xray.pid - Xray 进程 ID
- ./app/caddy/caddy.pid - Caddy 进程 ID

## 变更记录 (Changelog)
- 2025-11-01: 初始化文档