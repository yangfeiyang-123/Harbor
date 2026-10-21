# Harbor

原生 macOS 本地与 SSH 开发工作台，使用 SwiftUI、AppKit、OpenSSH、SwiftTerm 和按需安装的 Code-OSS 编辑器。

**当前源码：0.36.0（build 78）。** [English](README.md) · [发布记录与下载](https://github.com/yangfeiyang-123/Harbor/releases)

## 下载与安装

[**下载 Harbor 0.36.0：Apple Silicon Mac**](https://github.com/yangfeiyang-123/Harbor/releases/tag/v0.36.0)

支持 macOS 14 或更新系统、M1 及更新芯片。打开 DMG，把 Harbor 拖入 Applications；也可解压 ZIP 后移入“应用程序”。升级前请先退出旧版。

当前采用 ad-hoc 签名，尚未经过 Apple 公证。首次启动如被 macOS 拦截，尝试打开后前往 **系统设置 → 隐私与安全性 → 仍要打开**。详见[安装说明](docs/install-release.txt)。首次打开 Code-OSS 工作区需要联网安装并校验运行时，本地工作区需要 Mac 提供 Python 3，远程工作区需要服务器提供 Python 3。

## 主要功能

- **Code-OSS 编辑器**：项目文件、搜索、扩展和集成终端；扩展来自 Open VSX。首次打开工作区时按需安装并校验运行时。
- **多个窗口与文件夹**：每个窗口可以保留多个本地或远程文件夹；Option+Tab 切换，Folders in Windows 管理归属。
- **原生终端**：拆分、标签、拖动排列和重命名；远程终端通过独立的 Python PTY 服务保留会话，断线后可以恢复仍在运行的进程。
- **SSH 密码钥匙串**：首次输入的服务器密码保存在 macOS 登录钥匙串中，后续连接复用；服务器设置可以移除。主机密钥、私钥口令和一次性验证码分别处理。
- **外观与动效**：Claude、Standard、Tide、Kelp、Dusk、Fog、Lighthouse 七个主题系列，支持系统、浅色、深色模式和减少动效。
- **连接工具**：本地、远程、SOCKS5 转发，以及网页、noVNC、VNC 和可选的 Isaac Sim WebRTC 远程显示。

软件界面为英文，服务器名、路径、文件内容和终端输出保留原文。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建工作台窗口 | Shift+Command+N |
| 开始页 | Shift+Command+H |
| 切换当前窗口的文件夹 | Option+Tab |
| 管理窗口和文件夹 | Option+Shift+Command+W |
| 打开本地文件夹 / 文件 | Command+Option+O / Command+O |
| 新建独立终端窗口 | Command+N |
| 切换文件与终端模式 | Option+Z |
| 显示 / 隐藏编辑器终端 | Command+J |
| 原生终端左右拆分 | Command+D |
| 终端页面上下拆分 | Shift+Command+D |
| 独立终端窗口上下拆分 | Command+H |
| 设置 | Command+, |

## 构建与验证

运行需要 macOS 14 或更新系统。构建需要 Swift 6 和 macOS 26 或更新 SDK；安装包面向构建所在 Mac 的架构。

```sh
git clone https://github.com/yangfeiyang-123/Harbor.git
cd Harbor
swift test --disable-sandbox --build-system native
python3 Tests/terminal_host_test.py
python3 scripts/test-workspace-runtime.py
bash scripts/test-code-workbench.sh
bash scripts/build-app.sh release
open .build/Harbor.app
```

可用 `bash scripts/package-release.sh` 生成带 SHA-256 校验文件的安装包。本地构建采用 ad-hoc 签名，未经过 Apple notarization。

开发和手动验证请设置独立的 `HARBOR_DATA_DIR`，并用 `HARBOR_NO_IMPORT=1` 禁止导入个人 SSH 配置。默认测试不会连接真实服务器；相关集成测试需要显式启用。

## 连接与数据

远程文件与终端服务需要 Python 3。服务器重启、进程结束或会话到期后，无法恢复原进程；恢复连接不会重新执行原有命令。

配置位于 `~/Library/Application Support/HarborSSH/`，密码保存在登录钥匙串。仓库不包含个人服务器配置、终端记录或性能采样。可选托管代理使用示例主机，使用前需要[配置自己的连接环境](docs/reverse-proxy-tuning.md)。

[入门说明](docs/getting-started.md) · [编辑器](docs/code-workbench.md) · [终端恢复](docs/terminal-recovery.md) · [远程显示](docs/remote-display.md) · [验证记录](docs/validation.md)

Harbor 原创代码采用 [MIT License](LICENSE)。[第三方组件](THIRD_PARTY_NOTICES.md) 保留各自许可；NVIDIA WebRTC 库单独授权，不随本仓库或标准安装包分发。
