# Xray-Caddy 自动部署脚本

这是一个用于在Linux系统上自动部署和管理 Xray-core 与 Caddy 服务的脚本工具。本工具通过友好的界面帮助用户快速搭建代理服务器，支持多种协议(Reality-vision, xhttp-reality, kcp)。

## 功能特性

- 自动下载并部署最新版本的 Xray-core 和 Caddy
- 自动生成和配置各协议所需的证书和密钥等配置参数
- 自动配置 Caddy 作为前端网页服务器，提供伪装网站
- 提供完善的服务管理功能（启动、停止、重启）
- 支持开机自启动服务
- 一键生成客户端配置，方便连接

## 系统要求

- **操作系统**：Debian/Ubuntu Linux (x86_64 架构)
- **用户权限**：需要 root 权限
- **必要软件**：tar, unzip, sed, awk, grep, mkdir, chmod

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

1. **安装本服务 (xray 与 caddy)**
   - 输入域名、KCP混淆密码和网站根目录
   - 脚本将自动下载并配置 Xray-core 和 Caddy
   
2. **修改配置并重启服务**
   - 更新配置参数（域名、KCP密码、网站根目录等）
   - 自动重启服务使配置生效
   
3. **重启服务**
   - 重启 Xray-core 和 Caddy 服务
   
4. **停止服务**
   - 停止正在运行的 Xray-core 和 Caddy 服务
   
5. **显示客户端连接配置**
   - 生成并显示客户端连接所需的配置文件
   
6. **设为开机自启服务**
   - 配置 systemd 服务，实现开机自启
   
7. **更新 Xray 和 Caddy 到最新版**
   - 自动备份当前版本
   - 下载并更新 Xray 和 Caddy 到最新版本
   - 更新后自动重启服务

8. **恢复到备份版本**
   - 查看可用的备份版本
   - 恢复到之前的版本（如果更新后出现问题）

9. **卸载本服务**
   - 停止服务，删除配置文件和程序

10. **退出脚本**
    - 退出管理界面

## 部署过程

部署时需要提供以下信息：

1. **域名**：您用于连接服务的域名，必须已解析到当前服务器IP
2. **KCP协议混淆密码**：用于KCP协议的混淆，提高连接稳定性
3. **静态页面根目录**：服务器上存放网站文件的目录，用于伪装网站
4. **邮箱地址**：可选，用于SSL证书申请

部署完成后，脚本会自动：

1. 下载并配置 Caddy 服务器
2. 下载并配置 Xray-core
3. 生成各协议所需的UUID和密钥
4. 配置并启动服务
5. 显示客户端连接所需的配置

## 文件结构

- `main.sh` - 主脚本，提供交互式菜单
- `install.sh` - 安装脚本，负责下载和配置服务
- `service.sh` - 服务管理脚本，处理服务的启动、停止和状态检查
- `download.sh` - 下载工具脚本，自动获取最新版本的 Xray-core 和 Caddy
- `update.sh` - 更新脚本，处理服务更新和备份恢复功能
- `cfg_tpl/` - 配置文件模板目录
  - `caddy_config.json` - Caddy 服务器配置模板
  - `xray_config.json` - Xray-core 配置模板
  - `xray_client.config.json` - 客户端配置模板
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

## 安全建议

- **定期更新**：使用脚本内置的更新功能定期更新 Xray 和 Caddy 到最新版本，获取最新的安全补丁
- 使用强密码作为KCP混淆密码
- 定期更换UUID和密钥
- 在正式环境使用前先在测试环境验证配置
- **备份管理**：定期检查备份文件，确保在需要时可以快速恢复

## 日志文件位置

- Caddy日志: `/var/log/caddy/error.log` 和 `/var/log/caddy/access.log`
- Xray日志: `/var/log/xray/error.log` 和 `/var/log/xray/access.log`
- 服务启动日志: `/var/log/caddy.log` 和 `/var/log/xray.log`

## 故障排除

如果遇到问题，请检查：

1. 域名是否正确解析到服务器IP
2. 服务器防火墙是否允许 443 端口和 2502 端口访问
3. 查看日志文件获取详细错误信息
4. 确保系统满足最低要求

如需帮助，请提交Issue或查阅Wiki获取更多信息。

## 许可证

请查看LICENSE文件获取完整的许可证信息。

## 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [lxhao61/integrated-examples](https://github.com/lxhao61/integrated-examples)
