# Xray-Caddy/Hysteria2 自动部署脚本

这是一个用于在 Linux 系统上自动部署和管理 Xray-core、Caddy 与 Hysteria2 的脚本工具。本工具通过交互式菜单帮助用户快速搭建代理服务器，支持 `xraycaddy`、`hysteria2`、`all` 三种安装 profile，覆盖 Reality/Vision、XHTTP、KCP 与 Hysteria2。

## 功能特性

- 按安装 profile 自动下载并部署 Xray-core、Caddy 和 Hysteria2
- 支持 `xraycaddy`、`hysteria2`、`all` 三种安装 profile
- 自动生成和配置各协议所需的证书、UUID、密钥和客户端参数
- Hysteria2 支持现有证书或 Hysteria2 ACME，`all` profile 要求使用现有证书以避免证书所有权冲突
- 自动配置 Caddy 作为前端网页服务器，提供伪装网站
- 安装后通过 systemd 托管服务并输出健康检查报告
- 支持 Hysteria2 默认 UDP 8443 和可选端口跳跃，禁止占用保留的 UDP/443
- 一键生成或查看客户端配置，方便连接

## 系统要求

- **操作系统**：Debian/Ubuntu Linux (x86_64 架构，systemd 环境)
- **用户权限**：需要 root 权限
- **必要软件**：tar, unzip, curl, sed, awk, grep, mkdir, chmod
- **可选软件**：开启 Hysteria2 端口跳跃时需要 iptables 或 ip6tables

## 一键安装

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/nick3/xhttp_script/main/install_remote.sh)"
```

或者：

```bash
wget -O install_remote.sh https://raw.githubusercontent.com/nick3/xhttp_script/main/install_remote.sh && bash install_remote.sh
```

## 手动安装与使用

1. 克隆或下载本仓库：
   ```bash
   git clone https://github.com/nick3/xhttp_script.git
   cd xhttp_script
   ```

2. 赋予脚本执行权限：
   ```bash
   chmod +x main.sh install.sh service.sh download.sh update.sh
   ```

3. 运行主脚本：
   ```bash
   ./main.sh
   ```

## 使用说明

运行主脚本 `main.sh` 后，您将看到以下选项：

1. **安装服务 (`xraycaddy` / `hysteria2` / `all`)**
   - `xraycaddy`：安装 Xray-core 与 Caddy，需要域名、KCP 混淆密码和网站根目录
   - `hysteria2`：安装 Hysteria2，需要域名、证书方式、认证密码、masquerade proxy URL 和 UDP 监听端口
   - `all`：同时安装 Xray-core、Caddy 与 Hysteria2，必须使用现有证书以避免 Caddy 与 Hysteria2 同时申请 ACME 证书
   - Hysteria2 默认监听 UDP 8443，监听端口和可选端口跳跃范围都不能包含 UDP/443；`all` profile 下端口跳跃范围还不能包含 Xray KCP 使用的 UDP/2052

2. **修改配置并重启服务**
   - 更新 Xray/Caddy 配置参数（域名、KCP 密码、网站根目录等）
   - 自动重启服务使配置生效

3. **重启服务**
   - 重启 Xray-core 和 Caddy 服务

4. **停止服务**
   - 停止正在运行的 Xray-core 和 Caddy 服务

5. **显示客户端连接配置**
   - 根据 Xray 客户端模板生成并显示 `./app/xray_client_config.json`

6. **查看客户端配置参数**
   - 显示 `/etc/xray/client_config_info.txt`
   - Hysteria2 客户端参数安装后位于 `/etc/hysteria/client_config_info.txt`，客户端 YAML 位于 `/etc/hysteria/client.yaml`

7. **更新 Xray 和 Caddy 到最新版**
   - 自动备份当前版本
   - 下载并更新 Xray 和 Caddy 到最新版本
   - 更新后自动重启服务

8. **恢复到备份版本**
   - 查看可用的备份版本
   - 恢复到之前的版本（如果更新后出现问题）

9. **设为开机自启服务**
   - 修复 Caddy 与 Xray 的 systemd 服务并重启

10. **卸载本服务**
    - 停止服务，删除配置文件和程序

11. **退出脚本**
    - 退出管理界面

## 部署过程

部署时会根据安装 profile 提供以下信息：

1. **域名**：用于连接服务的域名，必须已解析到当前服务器 IP
2. **KCP 协议混淆密码**：`xraycaddy` 和 `all` profile 需要，用于 KCP 协议混淆
3. **静态页面根目录**：`xraycaddy` 和 `all` profile 需要，用于 Caddy 伪装网站
4. **证书方式**：`xraycaddy` 支持 ACME 或现有证书；`hysteria2` 支持现有证书或 Hysteria2 ACME；`all` profile 只能使用现有证书
5. **Hysteria2 参数**：`hysteria2` 和 `all` profile 需要认证密码、masquerade proxy URL、UDP 监听端口和可选端口跳跃设置
6. **邮箱地址**：可选，用于 ACME 证书申请

部署完成后，脚本会自动：

1. 按 profile 下载并安装 Caddy、Xray-core 和/或 Hysteria2
2. 渲染 Xray、Caddy 和/或 Hysteria2 配置模板
3. 生成各协议所需的 UUID、密钥和客户端参数
4. 写入统一安装状态文件 `/etc/xray-caddy/install_state.env`
5. 配置 systemd 服务并执行安装健康检查
6. 生成客户端连接配置或参数文件

## 文件结构

- `main.sh` - 主脚本，提供交互式菜单和安装 profile 选择
- `install.sh` - 安装脚本，负责参数解析、模板渲染、服务配置和健康检查
- `service.sh` - 服务管理脚本，处理 Xray/Caddy 的启动、停止和状态检查
- `download.sh` - 下载工具脚本，自动获取最新版本的 Xray-core、Caddy 和 Hysteria2
- `update.sh` - 更新脚本，处理 Xray/Caddy 更新和备份恢复功能
- `cfg_tpl/` - 配置文件模板目录
  - `caddy_config.json` - Caddy 服务器配置模板
  - `xray_config.json` - Xray-core 配置模板
  - `xray_client.config.json` - Xray 客户端配置模板
  - `hysteria2.service` - Hysteria2 systemd 服务模板
  - `hysteria2_server.yaml` - Hysteria2 现有证书服务端配置模板
  - `hysteria2_server_acme.yaml` - Hysteria2 ACME 服务端配置模板
  - `hysteria2_client.yaml` - Hysteria2 客户端配置模板
  - `hysteria2_client_port_hopping.yaml` - Hysteria2 端口跳跃客户端配置模板
  - `hysteria2_client_info.txt` - Hysteria2 客户端参数说明模板
- `tests/` - Bats 测试目录，覆盖下载、参数解析、模板渲染和安装前检查
- `app/` - 应用程序和配置文件目录
- `www/` - 默认的网站根目录
- `backups/` - 备份文件目录（自动创建）

## 更新和备份功能

### 自动更新
- 脚本支持一键更新 Xray 和 Caddy 到最新版本
- 更新前会自动创建当前版本的备份
- 更新过程中如果失败，可以选择自动恢复到备份版本
- 更新完成后会自动重启服务

### 备份管理
- 每次更新前自动创建备份，备份文件包含时间戳
- 支持手动创建备份
- 可以查看所有可用的备份版本
- 支持恢复到任意备份版本

### 使用备份功能
```bash
# 手动创建备份
./update.sh backup

# 查看所有备份
./update.sh list-backups

# 交互式恢复
./update.sh restore

# 直接恢复指定备份
./update.sh restore caddy ./backups/caddy_20231225_143000
```

## 开发与测试

如果已安装 Bats，可运行：

```bash
bats tests
```

当前测试覆盖 Hysteria2 下载校验、安装参数解析、模板渲染、端口跳跃规则和安装前检查。

## 安全建议

- **定期更新**：使用脚本内置的更新功能定期更新 Xray 和 Caddy 到最新版本，获取最新的安全补丁
- 使用强密码作为 KCP 混淆密码和 Hysteria2 认证密码
- 定期更换 UUID、密钥和 Hysteria2 认证密码
- 在正式环境使用前先在测试环境验证配置
- **备份管理**：定期检查备份文件，确保在需要时可以快速恢复

## 日志文件位置

- Caddy 日志: `/var/log/caddy/error.log` 和 `/var/log/caddy/access.log`
- Xray 日志: `/var/log/xray/error.log` 和 `/var/log/xray/access.log`
- Xray/Caddy fallback 启动日志: `/var/log/caddy.log` 和 `/var/log/xray.log`
- Hysteria2 systemd 日志: `journalctl -u hysteria2.service --no-pager`
- Hysteria2 端口跳跃日志: `journalctl -u hysteria2-port-hopping.service --no-pager`

## 故障排除

如果遇到问题，请检查：

1. 域名是否正确解析到服务器 IP
2. 服务器防火墙是否允许 TCP 80/443、UDP 443 和 UDP 2052 访问
3. 如安装 Hysteria2，确认已放行 Hysteria2 UDP 监听端口（默认 8443）以及可选端口跳跃范围
4. 查看日志文件获取详细错误信息
5. 确保系统满足最低要求

如需帮助，请提交Issue或查阅Wiki获取更多信息。

## 许可证

请查看LICENSE文件获取完整的许可证信息。

## 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [lxhao61/integrated-examples](https://github.com/lxhao61/integrated-examples)
