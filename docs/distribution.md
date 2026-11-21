# Mac App 分发与后台推送

## 现在就能做：DMG（Apple Development 签名）

```sh
scripts/package-mac.sh            # → build/dist/Palmhelm-<版本>.dmg
```

- 内含 Release 版 Palmhelm.app，Bridge 单文件已打进资源（`bundle-bridge.sh`）。
- Apple Development 签名（沿用 project.yml 的 Team，没有可用身份即失败，不回退 ad-hoc）：designated requirement 跨构建稳定，本机钥匙串授权可跨版本保留；未公证，他机首次打开仍会被 Gatekeeper 拦下（「系统设置 › 隐私与安全性」点「仍要打开」）。适合自用与小范围试用，不适合公开下载。

## Developer ID 公证

脚本 `scripts/notarize-mac.sh` 把 Release 版 Palmhelm.app 签成 Developer ID 并公证，产出已 staple 的 DMG。

**输入 App 必须由 `scripts/build-release-mac.sh` 构建**（与 `package-mac.sh` 共用 `scripts/distribution-flags.sh` 的发行编译条件 `PALMHELM_DISTRIBUTION`）：非发行构建不修改共享的 Claude 审批钩子，直接 `xcodebuild -configuration Release` 的产物不带该条件，公证 / 重签都无法补回，正式 App 会禁用钩子的安装与修复。普通 Release、Debug 与测试构建保持默认关闭，不在 project.yml 全局打开。

前置（用户需亲自完成，脚本不代为创建或保存）：

1. 在 Apple Developer 账号中创建 **Developer ID Application** 证书，安装到登录钥匙串（Xcode › Settings › Accounts › Manage Certificates，或证书助理）。
2. 在终端一次性保存公证凭据（会交互式提示 Apple ID、Team ID 与 App 专用密码，不要把密码写进命令行）：
   ```sh
   xcrun notarytool store-credentials "palmhelm"
   ```

使用：

```sh
scripts/build-release-mac.sh                                   # 打印发行 Release 的 Palmhelm.app 路径
scripts/notarize-mac.sh --app <Palmhelm.app> --dry-run          # 只检查前置条件，不签名不上传
scripts/notarize-mac.sh --app <Palmhelm.app> [--out <DMG>]      # 签名 → 公证 → staple → Gatekeeper 校验
```

- 参数：`--identity` 默认 `Developer ID Application`，匹配不唯一即失败；`--profile` 默认 `palmhelm`；`--out` 默认 `build/notarize/Palmhelm.dmg`。找不到证书或凭据时直接失败并给出上面的命令，不回退到其他身份。
- 顺序：先签内置 Bridge（hardened runtime，无 entitlements），再签外层 App（仓库内的 `PalmhelmMac.entitlements`，不用 `--deep`），校验后不得含 `get-task-allow`；再生成并签 DMG，`notarytool submit --wait`，未 Accepted 时保留日志路径并失败；最后 `stapler` 与 `spctl` 校验。
- 输入 App 不会被原地修改。脚本不调用 `package-mac.sh`（它仍是 Apple Development 构建）。
- 安装闭环（人工）：拷入 /Applications，确认 `com.apple.quarantine` 存在，首次打开不出现「无法验证」提示。

## 付费开发者账号相关待办（账号已开通，相关资源待核；本仓库未做，记在验证账本「阻塞项」）

1. **Developer ID 签名 + 公证**：见下节「Developer ID 公证」，由 `scripts/notarize-mac.sh` 执行。不进 Mac App Store（沙盒不允许调 herdr 与读会话记录）。
2. **iPhone 正式签名**：Xcode 直装/TestFlight；灵动岛直接批准需要 App Group + Keychain 共享（正式签名后才可用）。
3. **APNs 后台推送**：推送只带类型与编号，手机再回 Bridge 拉详情。现状：Bridge 已实现本机直发（用本机凭据直连 APNs，无凭据时禁用）；手机侧授权与 token 上传以 iPhone 端的实现为准，本机直发已在真机上验收。官方推送（provider 分发）方案待定，安装包不分发 provider 私钥。
