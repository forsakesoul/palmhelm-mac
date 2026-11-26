# Palmhelm for Mac

English | [中文](README.zh-CN.md)

Palmhelm for Mac is the desktop side of Palmhelm. It runs the Palmhelm Bridge as a child process and shows the conversations, approval requests, Herdr panes, pairing and devices, usage, and settings for the coding agents (Claude Code, Codex and others) that run in Herdr panes on your Mac. It shares the `PalmhelmKit` package with the iPhone app.

Requirements: an Apple silicon Mac running macOS 15 or later, and [Herdr](https://herdr.dev) with the agents you want to follow running in its panes. Palmhelm only supports agents running in Herdr panes.

- Download the signed, notarized installer from [Releases](https://github.com/forsakesoul/palmhelm/releases) or the [download page](https://forsakesoul.github.io/palmhelm/). The release notes are in the [English changelog](https://github.com/forsakesoul/palmhelm/blob/main/CHANGELOG.md) and the [中文更新日志](https://github.com/forsakesoul/palmhelm/blob/main/CHANGELOG.zh-CN.md).
- Security and privacy (where data is stored, network use, permission boundaries, logging): [docs/security-and-privacy.md](docs/security-and-privacy.md).
- Reaching the Mac from an iPhone away from the local network with Tailscale: [docs/tailscale.md](docs/tailscale.md).
- Running your own Tailscale DERP relay when Tailscale has to relay and its relays are far away (in Chinese): [docs/private-derp.md](docs/private-derp.md).

Palmhelm for Mac 是 Palmhelm 的桌面端：它把 Bridge 作为子进程运行，并显示 Herdr 窗格中 Claude Code、Codex 等编码 agent 的对话、审批、窗格、配对与设备、用量和设置。要求 Apple 芯片、macOS 15 及以上，并安装 Herdr。只支持在 Herdr 窗格里运行的 agent。

## Remote mode

By default the app runs its own Bridge (local mode). In remote mode, a Mac (Mac A) only acts as a client of the Bridge on another Mac (Mac B), the way the iPhone app does: Mac B runs Herdr, the agents and the Bridge, and Mac A shows and controls Mac B's sessions. The two modes are exclusive, and Mac A connects to one remote Mac at a time.

- Switch in Settings › Connection and devices › Connection mode. Switching to remote stops the local Bridge first (including one kept running after quit) and clears the local session view; if the Bridge does not stop, the app stays in local mode. Switching back to local tries to remove this Mac from Mac B's device list, clears the remote session, and starts the local Bridge if "Starts with the app" is on.
- Prepare Mac B (local mode): in Settings › Connection and devices, turn on "Direct https" and turn on listening on the local network or Tailscale. If its Bridge is already running, click "Restart now" so the change takes effect. Over Tailscale only, the pairing link also needs a MagicDNS hostname, see [docs/tailscale.md](docs/tailscale.md). Then open "Pair new device" and click "Copy pairing link".
- Pair Mac A: in Settings › Connection and devices › Remote Mac, paste the link into "Pairing link" and click "Use pairing link". You can also type Mac B's address, its actual port and the 6-digit code, then check the short fingerprint against the certificate fingerprint in Settings › Connection and devices on Mac B. Remote pairing only accepts https with a full certificate pin.
- A newly paired device is read-only. To send messages and answer approvals from Mac A, set it to "Can control" in the device table of Mac B's "Pair new device" window. "Disconnect" on Mac A tries to remove this Mac from Mac B and stays in remote mode.
- In remote mode the local-only settings (engine, hooks, Feishu, logs, listen addresses, account quota and sources) are hidden, images cannot be pasted, dropped or sent (the file would stay on Mac A), and the usage page shows Mac B's records. Quitting Mac A does not affect Mac B. If Mac B removes this Mac, the app stops reconnecting and asks you to pair again.

## Building from source

This repository contains the Mac app source. It is not the whole system: the Bridge is distributed as a separate binary, and the shared client package is a separate repository. The steps below build the app from a clean checkout.

1. Tools: Xcode with the Swift 6 toolchain, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and `shasum`/`curl` (both ship with macOS).
2. Fetch the Bridge binary. `scripts/bridge.env` pins the version, the download URL, and the expected SHA-256 of the Apple silicon build. The script refuses to run while the checksum is still a placeholder.
   ```sh
   scripts/bundle-bridge.sh
   ```
   The Bridge licence and third-party notices are fetched and checked the same way (the URLs and checksums are in `scripts/bridge.env`). Maintainers who build the Bridge themselves can instead copy the binary from a local `palmhelm-bridge` checkout (`dist/` produced by `scripts/build.sh`, checked against its `SHA256SUMS`); the licence files are still fetched from the pinned URLs:
   ```sh
   scripts/bundle-bridge.sh --from-dist /path/to/palmhelm-bridge
   ```
   `scripts/build-release-mac.sh` and `scripts/package-mac.sh` use the same local copy when `PALMHELM_BRIDGE_DIST=/path/to/palmhelm-bridge` is set.
3. Generate the project and build. `PalmhelmKit` is resolved from the pinned tag `0.0.1` of [forsakesoul/palmhelm-kit](https://github.com/forsakesoul/palmhelm-kit).
   ```sh
   xcodegen generate
   xcodebuild build -project PalmhelmMac.xcodeproj -scheme PalmhelmMac -configuration Debug \
     -destination 'platform=macOS' -derivedDataPath build/dd \
     CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
   open build/dd/Build/Products/Debug/Palmhelm.app
   ```
   `CODE_SIGN_IDENTITY=-` makes an ad-hoc local signature. The project's default is Automatic signing with the `Apple Development` identity and the team in `project.yml`; to use your own team, set `DEVELOPMENT_TEAM=<your Team ID>` and `CODE_SIGN_STYLE=Automatic` instead.

Running a development build next to the installed app: the bundle identifier selects the data directory, the default port, and the Keychain service name, so the two do not share state. Change `PRODUCT_BUNDLE_IDENTIFIER` for your build to get a separate identifier:

- Data directory and port (`PalmhelmMac/Engine/EngineSettings.swift`): the app with bundle identifier `com.forsakesoul.palmhelm.mac` uses `~/.palmhelm-bridge` and port 47821; any other identifier uses `~/Library/Application Support/Palmhelm-dev/bridge` and port 47831. A port that is already in use can be changed with `defaults write <your bundle identifier> engine.port -int <port>`.
- Keychain service name (`PalmhelmMac/Core/KeychainStore.swift`): derived from the bundle identifier, so each identifier has its own secrets.

Use `scripts/test-mac.sh` for tests rather than launching a build, so test runs never write to the installed app's data directory.

## Tests

Run the Mac tests through the script, which gives the test host its own bundle identifier so it never shares preferences with the installed app:

```sh
scripts/test-mac.sh -derivedDataPath build/dd-test CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Some tests need a running test Bridge and are skipped unless `TEST_RUNNER_PALMHELM_E2E_SERVER` points to one. Tests that host a real window need the test host to be the frontmost app, so they skip in a session without focus (background, headless or remote). The shared `PalmhelmKit` tests live in the Kit repository.

## Layout

- `PalmhelmMac/Engine`: `BridgeEngine` (child-process lifecycle, logs, port file), `EngineSettings` (settings to environment variables), `HookClient` (hook key on loopback: issue codes, list and revoke devices).
- `PalmhelmMac/App`: `MacSession` (pairs with the bundled Bridge or, in remote mode, another Mac's Bridge; state and event streams, approvals, sending), `ConnectionModeSwitcher` (the single entry for switching between local and remote mode), app entry and menu bar. In local mode, quitting asks for confirmation and stops the Bridge by default; with "The Bridge keeps running in the background after Palmhelm quits" enabled, the next launch takes over the running Bridge (`BridgeEngine.takeOverRunningBridge`). Remote mode runs no local Bridge, so quitting does not stop a Bridge on either Mac.
- `PalmhelmMac/Features`: main window, pairing sheet and device table, usage, settings.
- `PalmhelmMac/Notch`: non-activating overlay at the top centre with hover approvals.

## Versions

The version shown to users, 1.0, is `CFBundleShortVersionString` in `PalmhelmMac/Info.plist`. The build number is `CURRENT_PROJECT_VERSION` in `project.yml`; the packaging scripts read it from there, and `PALMHELM_BUILD_NUMBER` overrides it. It is not derived from the commit count, because the public repository starts from a single commit.

## Licence and trademarks

The source code in this repository is licensed under the Apache License, Version 2.0 (see [LICENSE](LICENSE)). The Palmhelm Bridge binary is a separate component and is not covered by that licence. Its licence is [LICENSE-palmhelm-bridge.txt](https://github.com/forsakesoul/palmhelm/releases/download/bridge-0.3.16/LICENSE-palmhelm-bridge.txt), and the third-party notices for it are in [THIRD_PARTY_NOTICES.txt](https://github.com/forsakesoul/palmhelm/releases/download/bridge-0.3.16/THIRD_PARTY_NOTICES.txt); both are shipped inside the app. The Palmhelm name and logo are not licensed under Apache-2.0; using them for a different product needs permission.

## Security

Report vulnerabilities privately through GitHub's private vulnerability reporting, as described in [SECURITY.md](SECURITY.md). Do not open a public issue for them.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
