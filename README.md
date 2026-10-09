<div align="center">

<img src="assets/readme-badge.png" alt="MacDashboard项目横幅" />

# MacDashboard

*在浏览器中查看Mac状态，管理本机软件、服务与文件*

<img src="https://img.shields.io/badge/平台-macOS%2014%2B-blue.svg?style=flat-square" alt="平台" />
<img src="https://img.shields.io/badge/语言-Swift-orange.svg?style=flat-square" alt="语言" />
<img src="https://img.shields.io/badge/界面-React-green.svg?style=flat-square" alt="界面" />

</div>

---

MacDashboard把系统监控和日常管理集中到一个本机面板。安装后打开应用即可访问浏览器界面，查看资源使用情况，管理Homebrew软件、服务、Docker容器和文件，并保存操作记录与备份。

## 快速开始

将以下指令发给具备终端执行能力的编程助手：

```text
帮我安装这个仓库：https://github.com/yourpapayouknow/MacDashboard。检查macOS、Swift和Node.js环境，从源码构建应用与安装包；需要Apple签名身份或系统授权时提示我。
```

---

## 传统开始

需要macOS14及以上、Swift6.4、Node.js22.12及以上、npm，以及本机可用的Apple签名身份。

```zsh
git clone https://github.com/yourpapayouknow/MacDashboard.git
cd MacDashboard
npm --prefix WebUI --script-shell=/bin/zsh ci --ignore-scripts
security find-identity -v -p codesigning
```

将下方占位内容替换为上一步列出的签名身份SHA1，再构建并安装：

```zsh
PANEL_SIGN_IDENTITY='<Apple签名身份SHA1>' /bin/zsh Scripts/build-app.zsh
/bin/zsh Scripts/build-pkg.zsh
open dist/MacDashboard.pkg
```

安装完成后打开应用：

```zsh
open '/Library/Application Support/iwmei/MacDashboard.app'
```

---

## 功能

| 功能 | 用途 |
|---|---|
| 系统监控 | 查看CPU、内存、磁盘、进程、网络、端口和历史读数 |
| 软件环境 | 管理Homebrew软件、软件源与固定状态，查看已安装语言环境 |
| 服务管理 | 查看本机服务与launchd任务，确认后执行启停或重启 |
| 容器管理 | 查看Docker容器，执行启停、重启与已停止容器移除 |
| 文件管理 | 在指定目录内浏览、编辑、创建、移动和回收文件 |
| 数据备份 | 创建、下载与恢复快照，查看操作记录并撤销支持的操作 |
| 系统工具 | 查看计划任务、公开证书和防火墙状态 |

---

## 使用

1. 打开MacDashboard，在浏览器访问`http://127.0.0.1:18761`，进入本机面板。
2. 从导航选择监控、环境、服务、容器或文件，查看状态并选择所需操作。
3. 执行写入操作前核对确认内容；需要系统权限时，在本机完成授权。
4. 数据默认保存在`~/Library/Application Support/MacDashboard`，升级时保留该目录。
5. 默认仅允许本机访问；如需局域网使用，只绑定可信地址。面板不提供账号登录，不应直接暴露到公网。
