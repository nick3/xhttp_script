# 目标

你的目标是编写在Linux系统中运行的Shell脚本。该脚本将用友好的方式帮助其用户自动部署`xray-core`与`caddy`服务。

本脚本应实现下面的部署步骤：

# 准备工作

- 将域名解析到服务器IP，域名用`${DOMAIN}`表示。
- KCP协议的混淆密码（`${KCP_SEED}`）。
- 准备一个静态页面文件`index.html`，放在`${WWW_ROOT}`目录下。


# 部署步骤

## 1. 下载caddy

从`https://github.com/lxhao61/integrated-examples/releases`页面中查找并下载最新的编译好的caddy文件（如`https://github.com/lxhao61/integrated-examples/releases/download/20250108/caddy-linux-amd64.tar.gz`），将解压后的文件放在`./app/caddy`目录下。
将`./app/caddy/caddy`赋予可执行权限。


## 2. 编写caddy的配置文件`caddy.json`，放在`./app/caddy`目录下。

下面是此配置文件的模版，需要根据用户实际情况替换模板（`./cfg_tpl/caddy_config.json`）中的`${DOMAIN}`和`${WWW_ROOT}`。
将替换后的配置文件保存为`./app/caddy/caddy.json`。


## 3. 下载xray-core

从`https://github.com/XTLS/Xray-core/releases`页面中查找并下载最新的编译好的xray-core文件（如`https://github.com/XTLS/Xray-core/releases/download/v25.4.30/Xray-linux-64.zip`），将解压后的文件放在`./app/xray`目录下。
将`./app/xray/xray`赋予可执行权限。


## 4. 生成UUID

使用命令`./app/xray/xray uuid`生成一个UUID（`${UUID}`）。


## 5. 生成Private Key与Public Key

使用命令`./app/xray/xray x25519`生成一个Private Key与Public Key（`${PRIVATE_KEY}`与`${PUBLIC_KEY}`）。
此命令运行后的输出参考：

```bash
Private key: WDHTjPrTuOhWMFGkRSD1z_Qrm1ueO7PEnBe1GJeFhFk
Public key: rGpvFSUs_nPWTyeR5tI2LGmJDtJ_5d0vIvrdSArOsVo
```


## 6. 编写xray-core的配置文件`config.json`，放在`./app/xray`目录下。

下面是此配置文件的模版，需要根据用户实际情况替换模板（`./cfg_tpl/xray_config.json`）中的`${DOMAIN}`、`${UUID}`、`${PRIVATE_KEY}`和`${KCP_SEED}`。
将替换后的配置文件保存为`./app/xray/config.json`。


## 7. 运行caddy

使用命令`./app/caddy/caddy run --config ./app/caddy/caddy.json`运行caddy。


## 8. 运行xray-core

使用命令`./app/xray/xray run -c ./app/xray/config.json`运行xray-core。