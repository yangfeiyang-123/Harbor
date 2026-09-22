# Harbor

一个原生 macOS SSH 工作台，把远程终端、文件管理、代码编辑和仿真显示放在同一个窗口里。

**[下载最新版](https://github.com/yangfeiyang-123/Harbor/releases/latest)** · [English](README.md)

需要 macOS 14 或更新系统。当前安装包支持 Apple silicon（M1 及以后）；Intel Mac 暂无预编译包。
解压后将 Harbor.app 拖入 Applications。

首个公开版本采用 ad-hoc 签名，尚未通过 Apple notarization。如果首次打开被 macOS 拦截，
确认下载来自本仓库后，到「系统设置 → 隐私与安全 → 仍要打开」允许这一个应用。
不要全局关闭 Gatekeeper。发布页同时提供 SHA-256 校验文件。

## 主要功能

- 导入 SSH 配置、跳板机、多服务器和多个目录工作区。
- 终端拆分、分组、排序、重命名，以及断线后恢复仍存活的远程会话，无需 tmux。
- 远程文件浏览、代码编辑、搜索、多选、Markdown / 图片 / 视频 / PDF 预览。
- 文件上传下载进度、拖拽移动、直接拖入 macOS 截屏缩略图上传。
- 本地、远程和 SOCKS5 端口转发。
- 远程网页、noVNC、VNC 和可选的 Isaac Sim WebRTC 仿真显示。

软件界面为英文。Option+Z 切换终端和文件代码模式，Option+X 最大化或还原文件区内的终端。
Command+D 左右拆分，Command+H 上下拆分，Control+Shift+反引号创建新的终端工作区。

远程文件和会话保持功能需要服务器安装 Python 3。服务器重启、进程被杀死等情况无法继续原进程。
主动关闭终端会结束会话；仅断开连接不会。

## 开发与说明

使用 Xcode 26 / Command Line Tools 26 或更新版本、Swift 6.2+：

```sh
git clone https://github.com/yangfeiyang-123/Harbor.git
cd Harbor
bash scripts/build-app.sh release
open .build/Harbor.app
```

[使用说明](docs/getting-started.md) · [远程显示设置](docs/remote-display.md) · [第三方许可](THIRD_PARTY_NOTICES.md)

公开版不包含开发者的个人服务器、VPN 路由、密码和终端记录。NVIDIA WebRTC 库采用单独许可，
不随本仓库或安装包分发；需要 Isaac Sim 画面的用户可按照远程显示说明单独安装。

Harbor 原创代码采用 [MIT License](LICENSE)，允许保留署名的使用、修改和分发。
