[根目录](../CLAUDE.md) > **download.sh 模块**

# download.sh 模块文档

## 模块职责
下载 Xray-core 和 Caddy 二进制文件。使用 dra 工具从 GitHub 仓库下载最新版本的程序，并进行解压和权限设置。

## 入口与启动
- **入口文件**: `download.sh`
- **调用方式**: `bash download.sh [caddy|xray|all] [--force] [--dir <directory>]`
- **默认操作**: 下载 all (caddy 和 xray)

## 对外接口
命令行接口选项：
- `caddy`: 仅下载 Caddy
- `xray`: 仅下载 Xray-core
- `all`: 下载 Caddy 和 Xray-core (默认)
- `--force`: 强制重新下载，即使文件已存在
- `--dir`: 指定输出目录 (默认: ./app/[组件])
- `--help`: 显示帮助信息

## 关键依赖与配置
- 依赖工具: dra (GitHub 资源下载器)
- Caddy 仓库: lxhao61/integrated-examples
- Xray 仓库: XTLS/Xray-core
- 输出目录: ./app/caddy, ./app/xray

## 数据模型
- 下载的文件格式: Caddy (tar.gz), Xray (zip)
- 版本信息: 从 GitHub 仓库获取最新版本

## 测试与质量
- 文件完整性检查
- 解压验证
- 可执行权限设置
- 依赖命令检查

## 常见问题 (FAQ)
Q: 为什么使用 dra 工具下载？
A: dra 是一个用于下载 GitHub 资源的工具，可以方便地获取最新的发布版本。

Q: 如何处理下载失败？
A: 脚本会检查下载是否成功，并在失败时提供错误信息。

## 相关文件清单
- download.sh - 下载脚本
- ./dra - GitHub 资源下载工具
- ./app/caddy/caddy - Caddy 二进制文件
- ./app/xray/xray - Xray 二进制文件

## 变更记录 (Changelog)
- 2025-11-01: 初始化文档