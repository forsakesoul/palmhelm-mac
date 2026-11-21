# 安全与隐私说明

本文只记录已经实现的行为。代码位置使用仓库内相对路径。拿不准的事项标为「待确认」，不作推断。

## 1. 数据与存储

- **会话记录留在本机。** Bridge 只读读取 agent 的会话文件（Claude Code、Codex、Pi、Qoder），用于展示正文、回执与用量统计；不修改这些文件。读取范围见第 4 节。
- **数据目录**：默认 `~/.palmhelm-bridge`，可由 `BRIDGE_DATA_DIR` 覆盖。新建目录权限 0700；已有目录必须是本人所有且非符号链接，才收紧为 0700。私有文件（如 `hook.secret`）为 0600。
- **设备令牌只存哈希**：Bridge 库中只保存令牌 secret 的 SHA-256，鉴权时做常量时间比较。
- **钥匙串保存的内容类别**（只列类别，不记值）：
  - Mac：飞书 App Secret（仅在启用飞书通道时）、Bridge 设备令牌（`Core/KeychainStore.swift`；服务名 `com.forsakesoul.palmhelm.mac`）。
  - iPhone：设备令牌、设备名与 Bridge 端点（`Palmhelm/Core/Store/KeychainStore.swift`）。
- **Bridge 的 TLS 材料**：只在 `tls/` 不存在或为空时生成，权限 0600；已有内容必须通过完整校验，校验失败不会静默重新生成。

## 2. 网络

- **监听范围**：Bridge 的 `--bind` 只接受回环地址，或本机确实存在的 RFC 1918 / `100.64.0.0/10`（Tailscale）地址。Mac 设置中可分别开启局域网与 Tailscale 监听。
- **传输方式**：局域网与 Tailscale 监听必须启用 TLS（Mac 设置中两者不能在未开启 TLS 时启动）；启用 TLS 后，客户端按 SPKI 指纹固定，证书为自签，不校验主机名。仅回环、未启用 TLS 时为明文 http；iOS 客户端只允许回环明文。（`PalmhelmKit/Sources/PalmhelmKit/Pinning.swift`、`BridgeClient.swift`、`Accounts.swift`、`PalmhelmMac/Engine/EngineSettings.swift`）正式版经 Owner 实测为 TLS 开启：`local-api.json` 为 `transport=https`，`binds` 含回环、局域网与 Tailscale 地址；对回环、局域网 IP、Tailscale IP 与 MagicDNS 主机名的 https 请求均返回 401（握手成功，需设备令牌），http 请求被拒绝。
- **Bonjour**：只在 TLS 开启且存在 RFC 1918 绑定时发布服务，回环与 `100.64.0.0/10` 不广播。
- **配对**：配对码 6 位、有效期 5 分钟、单次使用；连续 5 次失败后锁定 10 分钟。重发码不清零失败计数。
- **可选飞书通道**：启用后，消息经飞书服务器中转。该通道只在带 `feishu` 构建标签的版本中可用。
- **iPhone 推送**：Bridge 用本机凭据直接向 Apple APNs 发送，不向安装包分发 provider 私钥。无凭据时推送被禁用。推送的标题是目标（agent）名称，正文为固定文案，不含会话内容或工具输入。
- **Tailscale 中继**：Tailscale 无法直连时，流量可能经 Tailscale 的加密中继（DERP）转发。这由 Tailscale 提供，Palmhelm 不运营中继。
- **Palmhelm 自有服务端**：代码中未发现 Palmhelm 自有的业务服务端地址。Mac 与 Kit 源码中的 HTTP 请求只访问本机回环地址。（已检索 Mac 与 Kit 源码中的 URL）
- **Claude 额度（可选，默认关闭）**：仅当 `engine.claudeOAuthQuotaEnabled` 为开启时，Bridge 才读取 Claude 的 OAuth 凭据并请求 `api.anthropic.com` 获取额度。凭据只在内存中使用，不落盘，不写日志。

## 3. 权限边界

- **设备权限**：设备分为只读与可控。只读设备的写请求（发送消息、审批、账户操作等）返回 403 `read_only`；其余写接口的权限矩阵待确认。撤销设备即时生效（设备撤销后，事件流立即关闭）。
- **终端输入**：需要控制权限；按设备与目标限流（每设备每目标 10 次/秒）；发送前复核身份，身份不一致则拒绝；键名只允许白名单。
- **插话与派发**：默认关闭，由环境变量 `BRIDGE_DISPATCH_ENABLED`、`BRIDGE_STEER_ENABLED` 开启。派发前检查目标身份、执行身份与输入框状态。
- **审批**：Claude Code 的权限请求经钩子交给 Bridge。默认拒绝；超时后交回终端，由 agent 自身处理。钩子口只接受本机回环连接，并要求 Hook 密钥。

## 4. 读取范围

- **只展示用户与助手正文。** 工具输入输出、思考内容、系统与开发者消息、子代理内容与元消息不会出现在展示结果中。
- **归属核验（#94）**：会话记录的起点目录必须与窗格的工作目录一致，否则不展示。会话中途切换目录是允许的。
- **敏感内容遮蔽**：发往飞书、推送与忙碌通知的文本，经过路径遮蔽与出站拒绝规则；命中拒绝规则时只返回固定说明，不返回原文。
- **搜索只在已展示的正文中匹配**，不读取原始记录。

## 5. 日志

- **Bridge 日志**：固定位置 `<数据目录>/logs/bridge.log`。单份上限 4 MiB，保留当前与 2 份轮转，总量约 12 MiB。单条超过 16 KiB 时只记固定类别，不截取正文。目录与文件权限分别为 0700 与 0600，且拒绝符号链接。
- **Bridge 日志的内容**：只记固定类别与固定原因码，如设备配对的结果类别、`hook_device_*` 的结果。不记配对码、令牌、设备 id、设备名、正文或 WebSocket 地址。
- **App 启动阶段日志**：`~/Library/Logs/Palmhelm/app-events.log`，两份轮转，每份 128 KiB。只记固定阶段名、固定结果与相对启动的毫秒数；不记路径、环境变量、钥匙串内容、令牌、配对码或系统错误原文。（`PalmhelmMac/Core/AppEventLog.swift`）
- **Mac 应用内的 Bridge 日志视图**：只读取上面的 `bridge.log` 尾部，不修改日志。（`PalmhelmMac/Engine/BridgeLogFile.swift`）
- **遥测**：未发现遥测或分析 SDK。已检索 Mac、Kit 与 Bridge 源码中的常见关键字。Palmhelm 不上传任何使用数据。
- **日志留存**：本机日志由上述上限自动轮转；Palmhelm 不会把日志发送到外部。

## 6. 撤销与重置

- **移除设备**：立即生效。
- **停止 Bridge**：Mac 退出时默认先停止 Bridge；可在设置中改为退出后继续在后台运行，下次打开时接管。（`PalmhelmMac/App/MacSession.swift` 与 README）
- **清除本机数据**：删除数据目录会移除 Bridge 的库、设备记录与日志。钥匙串中的条目需通过系统钥匙串删除。（待确认：产品内是否提供一键清除入口，以及删除钥匙串条目的操作路径）
- **分组排序重置**：「重置分组排序」是 #98 的设计项，尚未实现。

## 7. 问题反馈

- 普通问题与功能建议：通过 GitHub Issues 反馈。
- 涉及安全的问题：请勿在公开 Issue 中写出细节，请按 [SECURITY.md](../SECURITY.md) 通过 GitHub 私密漏洞报告提交。
