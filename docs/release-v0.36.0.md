## Download / 下载

**Apple Silicon Macs (M1 and later), macOS 14+.**

- **DMG**: open the disk image and drag **Harbor** into **Applications**.
- **ZIP**: extract and move **Harbor.app** into **Applications**.
- **SHA256SUMS.txt**: SHA-256 checksums for both downloads.
- **INSTALL.txt**: installation and first-launch instructions in English and Chinese.

Prebuilt app; Xcode and Swift are not required. The first Code-OSS workspace installs its verified editor runtime over the internet. Python 3 is required on the machine hosting the workspace (this Mac or the SSH server).

**First launch:** this build is ad-hoc signed and is not Apple Developer ID notarized. If macOS blocks it, first try opening Harbor, then use **System Settings → Privacy & Security → Open Anyway** for this official download.

## What's new

- Embedded Code-OSS editor with Open VSX extensions and integrated terminals.
- Multiple windows and folder workspaces; Option+Tab switches folders.
- SSH password storage in the macOS login keychain.
- Seven theme families, coordinated theme transitions and motion preferences.
- Persistent remote terminals, forwarding and remote displays.
- Public-release fixes for detached display ownership and CI fixtures.

## 安装

适用于 **Apple Silicon（M1 及更新）Mac、macOS 14 或更新系统**。下载 DMG 后打开，将 Harbor 拖入 Applications，即可安装。升级前先退出旧版。原有服务器设置和钥匙串密码会保留。

当前版本尚未经过 Apple 公证；首次启动如被拦截，请在尝试打开后，前往 **系统设置 → 隐私与安全性 → 仍要打开**。完整说明见附件 INSTALL.txt。

可选 NVIDIA Isaac Sim WebRTC 库需按其许可另行安装；普通 SSH 和编辑器功能不依赖该库。Intel Mac、Windows 和 Linux 不适用此安装包。
