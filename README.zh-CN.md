# Palmhelm for Mac

[English](README.md) | 中文

Palmhelm for Mac 是 Palmhelm 的桌面端：它把 Bridge 作为子进程运行，并显示你 Mac 上 Herdr 窗格中运行的编码 agent（Claude Code、Codex 等）的对话、审批、窗格、配对与设备、用量和设置。它与 iPhone 应用共享 `PalmhelmKit` 包。

要求：Apple 芯片的 Mac，macOS 15 或更高版本，并安装 [Herdr](https://herdr.dev)，同时在其窗格中运行你想跟踪的 agent。Palmhelm 只支持在 Herdr 窗格里运行的 agent。

- 从 [Releases](https://github.com/forsakesoul/palmhelm/releases) 或[下载页](https://forsakesoul.github.io/palmhelm/)下载已签名、已公证的安装包。发行说明见[英文更新日志](https://github.com/forsakesoul/palmhelm/blob/main/CHANGELOG.md)和[中文更新日志](https://github.com/forsakesoul/palmhelm/blob/main/CHANGELOG.zh-CN.md)。
- 安全与隐私（数据存放位置、网络使用、权限边界、日志）：[docs/security-and-privacy.md](docs/security-and-privacy.md)。
- 外出时在局域网之外通过 Tailscale 连接 Mac：[docs/tailscale.md](docs/tailscale.md)。
- Tailscale 走中继、官方中继又离得远时，自建 DERP 中继：[docs/private-derp.md](docs/private-derp.md)。

## 远程模式

默认情况下 App 运行自己的 Bridge（本机模式）。远程模式下，一台 Mac（Mac A）像 iPhone 一样只作为另一台 Mac（Mac B）上 Bridge 的客户端：Herdr、agent 和 Bridge 都在 Mac B 上运行，Mac A 查看并操作 Mac B 的会话。两种模式二选一，Mac A 同一时间只连一台远程 Mac。

- 切换入口：设置 › 连接与设备 › 连接方式。切到远程会先停止本机 Bridge（包括退出后保留在后台的那个）并清空本机的会话视图；Bridge 停不下来就保持本机模式。切回本机会尝试把本机从 Mac B 的设备表中移除、清空远程会话，开启了「随 App 启动」时再启动本机 Bridge。
- 准备 Mac B（本机模式）：在设置 › 连接与设备中打开「https 直连」并勾选局域网或 Tailscale 地址；Bridge 已在运行时点「立即重启」使其生效。只走 Tailscale 时，配对链接还需要 MagicDNS 主机名，见 [docs/tailscale.md](docs/tailscale.md)。然后打开「配对新设备」，点「复制配对链接」。
- 配对 Mac A：在设置 › 连接与设备 › 远程 Mac 中，把链接粘贴到「配对链接」，点「使用配对链接」。也可以手动输入 Mac B 的地址、实际端口和 6 位配对码，再与 Mac B 设置 › 连接与设备中的证书短指纹核对。远程配对只接受 https 和完整的证书指纹。
- 新配对的设备默认只读。要在 Mac A 上发消息和审批，需要在 Mac B「配对新设备」窗口的设备表里把它改成「可控」。Mac A 上的「断开」会尝试把本机从 Mac B 移除，并保持远程模式。
- 远程模式下隐藏只对本机有意义的设置（引擎、钩子、飞书、日志、监听地址、账户额度与账户来源），图片不能粘贴、拖入或发送（文件只在 Mac A 上），用量页显示的是 Mac B 的记录。退出 Mac A 不影响 Mac B。Mac B 移除本机后，App 停止重连并提示重新配对。

## 从源码构建

本仓库只包含 Mac 应用源码，不是完整系统：Bridge 以单独的二进制分发，共享的客户端包位于另一个仓库。下面的步骤从干净的 checkout 构建应用。

1. 工具：带 Swift 6 工具链的 Xcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen)，以及 `shasum`/`curl`（两者随 macOS 提供）。
2. 获取 Bridge 二进制。`scripts/bridge.env` 固定了版本、下载地址以及 Apple 芯片版本的预期 SHA-256。如果校验值仍是占位值，脚本会拒绝运行。
   ```sh
   scripts/bundle-bridge.sh
   ```
   Bridge 的许可文件与第三方声明同样下载并校验（地址与校验值在 `scripts/bridge.env` 中）。自行构建 Bridge 的维护者也可以改为从本地 `palmhelm-bridge` 仓库复制二进制（使用 `scripts/build.sh` 生成的 `dist/`，并对照其 `SHA256SUMS` 校验）；许可文件仍从固定地址获取：
   ```sh
   scripts/bundle-bridge.sh --from-dist /path/to/palmhelm-bridge
   ```
   当设置了 `PALMHELM_BRIDGE_DIST=/path/to/palmhelm-bridge` 时，`scripts/build-release-mac.sh` 与 `scripts/package-mac.sh` 使用同一份本地副本。
3. 生成工程并构建。`PalmhelmKit` 从 [forsakesoul/palmhelm-kit](https://github.com/forsakesoul/palmhelm-kit) 的固定标签 `0.0.1` 解析。
   ```sh
   xcodegen generate
   xcodebuild build -project PalmhelmMac.xcodeproj -scheme PalmhelmMac -configuration Debug \
     -destination 'platform=macOS' -derivedDataPath build/dd \
     CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
   open build/dd/Build/Products/Debug/Palmhelm.app
   ```
   `CODE_SIGN_IDENTITY=-` 生成临时的本地签名（ad-hoc）。工程默认使用自动签名，身份为 `Apple Development`，团队写在 `project.yml` 中；若要使用你自己的团队，请改为设置 `DEVELOPMENT_TEAM=<你的 Team ID>` 与 `CODE_SIGN_STYLE=Automatic`。

与已安装的应用并存运行开发版：bundle identifier 决定数据目录、默认端口和钥匙串服务名，因此两者不共享状态。为你的构建修改 `PRODUCT_BUNDLE_IDENTIFIER` 即可得到独立的 identifier：

- 数据目录与端口（`PalmhelmMac/Engine/EngineSettings.swift`）：bundle identifier 为 `com.forsakesoul.palmhelm.mac` 的应用使用 `~/.palmhelm-bridge` 与端口 47821；其它 identifier 使用 `~/Library/Application Support/Palmhelm-dev/bridge` 与端口 47831。如果端口已被占用，可用 `defaults write <你的 bundle identifier> engine.port -int <端口>` 修改。
- 钥匙串服务名（`PalmhelmMac/Core/KeychainStore.swift`）：由 bundle identifier 派生，因此每个 identifier 有各自的凭据。

测试请使用 `scripts/test-mac.sh`，而不是启动一个构建，这样测试运行不会写入已安装应用的数据目录。

## 测试

通过脚本运行 Mac 测试。脚本会为测试宿主设置独立的 bundle identifier，因此不会与已安装的应用共享偏好设置：

```sh
scripts/test-mac.sh -derivedDataPath build/dd-test CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

部分测试需要正在运行的测试 Bridge；除非 `TEST_RUNNER_PALMHELM_E2E_SERVER` 指向它，否则这些测试会被跳过。承载真实窗口的测试要求测试宿主处于前台，在没有焦点的会话（后台、无界面或远程）里会跳过。共享的 `PalmhelmKit` 测试位于 Kit 仓库中。

## 目录结构

- `PalmhelmMac/Engine`：`BridgeEngine`（子进程生命周期、日志、端口文件）、`EngineSettings`（设置到环境变量的映射）、`HookClient`（回环上的钩子密钥：签发配对码、列出与撤销设备）。
- `PalmhelmMac/App`：`MacSession`（与内置 Bridge 配对，远程模式下与另一台 Mac 的 Bridge 配对；状态与事件流、审批、发送）、`ConnectionModeSwitcher`（本机与远程模式切换的唯一入口）、应用入口与菜单栏。本机模式下，退出时会询问确认，默认同时停止 Bridge；若启用「退出 Palmhelm 后 Bridge 继续在后台运行」，下次启动会接管正在运行的 Bridge（`BridgeEngine.takeOverRunningBridge`）。远程模式不运行本机 Bridge，退出不会停止任何一台 Mac 上的 Bridge。
- `PalmhelmMac/Features`：主窗口、配对面板与设备表、用量、设置。
- `PalmhelmMac/Notch`：位于顶部中央、不抢焦点的浮层，支持悬停审批。

## 版本

展示给用户的版本 1.0 来自 `PalmhelmMac/Info.plist` 中的 `CFBundleShortVersionString`。构建号来自 `project.yml` 中的 `CURRENT_PROJECT_VERSION`；打包脚本从那里读取，`PALMHELM_BUILD_NUMBER` 可以覆盖它。它不是由提交数推导的，因为公开仓库从单个提交开始。

## 许可与商标

本仓库的源码以 Apache License, Version 2.0 授权（见 [LICENSE](LICENSE)）。Palmhelm Bridge 二进制是独立组件，不适用该许可。它的许可是 [LICENSE-palmhelm-bridge.txt](https://github.com/forsakesoul/palmhelm/releases/download/bridge-0.3.16/LICENSE-palmhelm-bridge.txt)，相关第三方声明见 [THIRD_PARTY_NOTICES.txt](https://github.com/forsakesoul/palmhelm/releases/download/bridge-0.3.16/THIRD_PARTY_NOTICES.txt)；两者都随应用一起分发。Palmhelm 的名称和标识不在 Apache-2.0 授权范围内；将其用于其它产品需要取得许可。

## 安全

请通过 GitHub 的私密漏洞报告（private vulnerability reporting）报告漏洞，具体见 [SECURITY.md](SECURITY.md)。请勿为此开公开 issue。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。
