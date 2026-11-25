# 外出使用：经 Tailscale 连接 iPhone 与 Mac

同一 Wi‑Fi 下 iPhone 经 Bonjour 发现 Mac 并 https 直连；离开局域网时用 Tailscale 让两端互联。链路仍是手机直连 Mac 上的 Bridge，不经任何 Palmhelm 中转服务器。

## 一次性配置

1. **两端装 Tailscale 并登录同一账号**：Mac（App Store 或 `brew install --cask tailscale`）与 iPhone（App Store）。Tailscale 管理后台保持 MagicDNS 开启（默认开）。
2. **记下 Mac 的两个标识**（Mac 菜单栏 Tailscale 图标里可见，或 `/Applications/Tailscale.app/Contents/MacOS/Tailscale status --self`）：
   - Tailscale IPv4：`100.x.y.z`（Bridge 监听用）；
   - MagicDNS 名：`<主机名>.<tailnet>.ts.net`（手机填写用）。
3. **Palmhelm Mac「设置 › 连接」**：监听地址填 `100.x.y.z`，端口保持默认 47821，**打开「https 直连」**，然后重启 Bridge。
4. **iPhone Palmhelm「我的 › 连接」**：忘掉旧配对，手动填写：
   - 地址：`<主机名>.<tailnet>.ts.net`（**填域名，不要填 100.x**）；
   - 端口：47821；
   - **打开「https 直连」**；
   - 配对码：Mac 配对窗口里的 6 位码。
   出现证书短指纹时，与 Mac 配对窗口显示的一串核对一致再确认。
5. **验证**：手机关掉 Wi‑Fi，确认 Tailscale 仍为已连接，Palmhelm 顶栏显示「已连接 · …ts.net」。

连上之后如果明显偏慢：两端打不通直连时 Tailscale 会走中继，官方中继又离得远，可以在附近的服务器上自建 DERP 中继，见 [private-derp.md](private-derp.md)。

## 为什么必须用 ts.net 域名 + https

iOS 的 App Transport Security（ATS）对局域网私有地址（10/8、172.16/12、192.168/16）免系统证书信任，对 Tailscale 的 100.64/10 不免：

- `http://100.x` 会被直接拒绝（`-1022`）；
- `https://100.x` 的自签证书过不了系统信任（`-9802`），走不到 Palmhelm 自己的证书指纹校验。

Palmhelm（当前版本）只对 `*.ts.net` 放开 ATS（`project.yml` 的 `NSExceptionDomains`）。这个例外也允许明文，所以 App 在构造请求前拒绝一切非回环 http；https 先做不带秘密的探测、你确认指纹后才发配对码，之后只认这把公钥，指纹不符照样拒绝。`ts.net` 下也有 Funnel 的公网名，域名后缀本身不代表一定走你的 Tailnet。

## 当前限制

- Bridge 一次只监听一个地址：绑 Tailscale 地址后，局域网 Bonjour 发现停止。在家时手机走 Tailscale 也能连（Tailscale 会走局域网直连路径），只是不能自动发现。
- 换回局域网直连需要把监听地址改回局域网 IPv4 并重新配对；两种方式不能同时保留配对。
- App 在后台时事件流会被系统挂起，审批只在前台实时到达（后台推送尚未实现）。

## 待简化（记录，尚未实现）

当前步骤偏繁琐，后续可以考虑：

- Mac 设置里检测本机 Tailscale，一键填入 100.x 并自动打开 https，不必手抄地址。
- 配对窗口直接显示本机 MagicDNS 名（以及二维码），手机扫码即填好地址、端口、https 与配对码。
- Bridge 同时监听局域网与 Tailscale 两个地址；手机端保存两个端点，在家走 Bonjour、外出自动切到 ts.net，免重新配对。
- 手机端输入 100.x 时直接提示改填 ts.net 域名，而不是等握手失败。
- iOS 17 起 ATS 例外也支持 IP/CIDR，可评估改为只对 `100.64.0.0/10` 放开、直接用 100.x 连接（尚未实测）。
