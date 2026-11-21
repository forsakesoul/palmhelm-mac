import SwiftUI
import CoreImage.CIFilterBuiltins
import PalmhelmKit

// 配对新设备（独立窗口，不用 sheet：SwiftUI sheet 挂在主窗口上时整个 App 无法退出）。
// 本机 Hook 密钥签发 6 位码；按监听地址的可达性决定能否扫码；下方为已配对设备表（撤销）。
struct PairingWindow: View {
    @Environment(MacSession.self) private var session
    @Environment(BridgeEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var code: HookClient.PairCode?
    @State private var issuing = false
    @State private var error: LText?
    @State private var devices: [HookClient.Device] = []
    @State private var devicesError: LText?
    @State private var devicesLoaded = false
    @State private var removing: Set<String> = []
    @State private var showAll = false
    @State private var qrCache = QRImageCache()

    init() {}

    #if DEBUG
    private var usesFixture = false
    init(devicesForTesting: [HookClient.Device]) {
        _devices = State(initialValue: devicesForTesting)
        _devicesLoaded = State(initialValue: true)
        _showAll = State(initialValue: true)
        usesFixture = true
    }
    #endif

    private var hook: HookClient? { engine.portFile.map { HookClient(dataDir: engine.activeDataDir, hookPort: $0.hookPort) } }
    private var short: String? { (engine.portFile?.tls?.spkiSha256).flatMap { SPKI.shortFingerprint(spkiSha256: $0) } }
    /// 手机能不能用这个端点：回环只有本机能连，不给二维码。
    private var phoneReachable: Bool { engine.reach == .lan || (engine.reach == .tailscale && !(engine.portFile?.hostnames ?? []).isEmpty) }
    /// 与倒计时、过期文字用同一个时间点（O1-341 R2）：过期后码与二维码一起失效。
    private func qrPayload(at now: Date) -> String? {
        guard phoneReachable, let code, !PairingCodeClock.expired(code, at: now), let pf = engine.portFile else { return nil }
        // host/port 给旧客户端（取对手机最可达的一项）；ep 给新客户端：lan:<ip>:<port>,ts:<host>:<port>，一次扫码保存两个地址
        let binds = pf.allBinds
        let lan = binds.filter { EngineSettings.reachOne($0) == .lan }
        let ts = (pf.hostnames ?? []).filter { !$0.isEmpty }
        // 无局域网地址时主地址用 MagicDNS 主机名（手机不接受 100.x + https，A1-153 F8）；两者都没有就不生成手机可用的二维码
        guard let host = lan.first ?? ts.first else { return nil }
        var s = "palmhelm://pair?host=\(host)&port=\(pf.apiPort)&code=\(code.code)&tls=\(pf.transport == "https" ? 1 : 0)"
        if let fp = pf.tls?.spkiSha256 { s += "&fp=\(fp.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
        let eps = lan.map { "lan:\($0):\(pf.apiPort)" } + ts.map { "ts:\($0):\(pf.apiPort)" }
        if !eps.isEmpty { s += "&ep=\(eps.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=,"))) ?? "")" }
        return s
    }

    /// 设备表的定宽列（设备列吃剩余宽度）：总宽必须放得进窗口，否则整行居中溢出、左边被裁。
    private enum Col { static let status: CGFloat = 56, paired: CGFloat = 150, seen: CGFloat = 84, permission: CGFloat = 110, action: CGFloat = 64 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 倒计时、过期与二维码共用同一个时间快照（O1-341 R2）；只包顶部，设备表不随之每秒重绘
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = ctx.date
                let expired = code.map { PairingCodeClock.expired($0, at: now) } ?? false
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        PalmhelmAppIcon(size: 36)
                        VStack(alignment: .leading, spacing: 1) { Text("配对新设备").font(.title2.weight(.bold)); Text("手机上的 Palmhelm 会连到这台 Mac").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let code {
                            let r = PairingCodeClock.remaining(code, at: now)
                            Text(r == 0 ? String(localized: "已过期，请重新发码") : String(localized: "\(r / 60):\(String(format: "%02d", r % 60)) 后失效 · 一次有效")).font(.caption).foregroundStyle(r == 0 ? PalmhelmTheme.bad : .secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("6 位配对码").font(.caption).foregroundStyle(.secondary)
                                Text(code.map { "\($0.code.prefix(3)) \($0.code.suffix(3))" } ?? "— — —").font(.system(size: 40, weight: .bold, design: .monospaced)).textSelection(.enabled).opacity(expired ? 0.35 : 1)
                            }
                            reachNote
                            Text("1. 手机打开 Palmhelm → 我的 → 连接，选中「这台 Mac」或扫码。\n2. 核对短指纹一致，输入配对码。\n3. 成功后令牌只存在手机上，这里可随时移除。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if hook == nil { Text("Bridge 未运行：启动后这里会自动发码。").font(.caption).foregroundStyle(PalmhelmTheme.warn) }
                            if let error { Text(error.text).font(.caption).foregroundStyle(PalmhelmTheme.bad) }
                            HStack {
                                Button(issuing ? String(localized: "发码中…") : String(localized: "重新发码")) { Task { await issue() } }.disabled(hook == nil || issuing)
                                if engine.reach == .loopback { SettingsLink { Text("打开连接设置") } }
                                Button("关闭") { dismiss() }
                            }
                        }
                        if let payload = qrPayload(at: now), let img = qrCache.image(for: payload, make: qrImage) {
                            Image(nsImage: img).interpolation(.none).resizable().frame(width: 160, height: 160).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("已配对设备").font(.headline); Spacer()
                Button("刷新") { Task { await load() } }.controlSize(.small).disabled(hook == nil)
                Toggle("含已撤销", isOn: $showAll).toggleStyle(.checkbox).onChange(of: showAll) { _, _ in Task { await load() } }
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                    GridRow {
                        Text("设备").frame(maxWidth: .infinity, alignment: .leading)
                        Text("状态").frame(width: Col.status, alignment: .leading)
                        Text("配对时间").frame(width: Col.paired, alignment: .leading)
                        Text("最后在线").frame(width: Col.seen, alignment: .leading)
                        Text("权限").frame(width: Col.permission, alignment: .leading)
                        Color.clear.frame(width: Col.action, height: 1)
                    }
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                    Divider().gridCellColumns(6)
                    if let devicesError {
                        HStack { Text(devicesError.text).font(.caption).foregroundStyle(PalmhelmTheme.bad); Button("重试") { Task { await load() } }.controlSize(.small) }.padding(.vertical, 14).gridCellColumns(6)
                    } else if devices.isEmpty {
                        if hook != nil, !devicesLoaded { SkeletonRows(count: 2, label: String(localized: "正在读取已配对设备")).padding(.vertical, 10).gridCellColumns(6) }
                        else { Text(hook == nil ? String(localized: "Bridge 未运行") : String(localized: "还没有配对的设备")).font(.caption).foregroundStyle(.secondary).padding(.vertical, 14).gridCellColumns(6) }
                    }
                    ForEach(devices) { d in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).lineLimit(1).truncationMode(.middle)
                                Text(d.id).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("\(d.name)\n\(d.id)")
                            Text(d.revoked ? String(localized: "已撤销") : d.paused ? String(localized: "已暂停") : String(localized: "活跃")).foregroundStyle(d.revoked ? .secondary : d.paused ? PalmhelmTheme.warn : PalmhelmTheme.ok).frame(width: Col.status, alignment: .leading)
                            Text(Date(timeIntervalSince1970: Double(d.pairedT) / 1000).shown(date: .numeric, time: .shortened)).lineLimit(1).minimumScaleFactor(0.85).frame(width: Col.paired, alignment: .leading)
                            Text(d.lastSeenT.map { Date(timeIntervalSince1970: Double($0) / 1000).formatted(Date.relativeStyle(.named)) } ?? String(localized: "从未")).lineLimit(1).frame(width: Col.seen, alignment: .leading)
                            if !d.revoked, let p = d.permission {
                                Picker("权限", selection: Binding(get: { p }, set: { v in Task { await setPermission(d, v) } })) {
                                    Text("只读").tag(DevicePermission.readonly.rawValue)
                                    Text("可控").tag(DevicePermission.control.rawValue)
                                }
                                .pickerStyle(.segmented).labelsHidden().frame(width: Col.permission)
                                .help("只读：只能看。可控：还能审批、发消息、在 Herdr 中显示")
                            } else {
                                Color.clear.frame(width: Col.permission, height: 1)
                            }
                            Group {
                                if removing.contains(d.id) { Text("移除中…").font(.caption).foregroundStyle(.secondary) }
                                else if !d.revoked { Button("移除") { Task { await remove(d) } }.tint(PalmhelmTheme.bad).controlSize(.small) }
                                else { Color.clear.frame(height: 1) }
                            }
                            .frame(width: Col.action, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 6)
                        Divider().gridCellColumns(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            .scrollBounceBehavior(.basedOnSize)
            Text("新配对的设备默认只读；需要在手机上审批或发消息时，把它改成可控。").font(.caption).foregroundStyle(.secondary)
            Text("移除后该设备的令牌立即失效，事件流断开，排队任务不再受理；历史记录保留。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 840)
        .task(id: engine.portFile?.hookPort) { // Bridge 起停都会换钩子口：起来后自动发码，停了清空
            #if DEBUG
            if usesFixture { return }
            #endif
            guard hook != nil else { code = nil; devices = []; devicesLoaded = false; error = nil; devicesError = nil; return }
            await issue(); await load()
        }
    }

    @ViewBuilder private var reachNote: some View {
        switch engine.reach {
        case .loopback:
            Text("当前只监听本机回环：手机连不上这台 Mac。要让手机连接，在「设置 › 连接」改为局域网 https（同一 Wi‑Fi）或本机 Tailscale 地址，然后重启 Bridge。").font(.caption).foregroundStyle(PalmhelmTheme.warn).fixedSize(horizontal: false, vertical: true)
        case .tailscale, .lan:
            if let short {
                VStack(alignment: .leading, spacing: 4) {
                    Text("证书短指纹（手机上会显示同一串）").font(.caption).foregroundStyle(.secondary)
                    Text(short).font(.system(size: 20, weight: .semibold, design: .monospaced))
                    if engine.reach == .tailscale {
                        Text("手机加入同一 Tailscale 网络，地址填这台 Mac 的 .ts.net 域名并开启 https，不要填 100.x。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if engine.reach == .tailscale {
                Text("Tailscale 明文监听：iPhone 端要求 https。请在「设置 › 连接」开启 https 后重启 Bridge，手机上填这台 Mac 的 .ts.net 域名。").font(.caption).foregroundStyle(PalmhelmTheme.warn).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("局域网明文监听：iPhone 端要求 https，连不上。请在「设置 › 连接」开启 https 后重启 Bridge。").font(.caption).foregroundStyle(PalmhelmTheme.warn).fixedSize(horizontal: false, vertical: true)
            }
        case nil:
            EmptyView()
        }
    }

    private func issue() async {
        guard let hook, !issuing else { return }
        issuing = true; defer { issuing = false }
        let oldExpired = code.map { PairingCodeClock.expired($0, at: Date()) } ?? false
        do { code = try await hook.issuePairCode(); error = nil } catch { self.error = LText(String(localized: "发码失败：\(describe(error))（旧码\(oldExpired ? String(localized: "已过期") : String(localized: "仍可用到期"))）")) }
    }

    private func load() async {
        guard let hook else { return }
        do { devices = try await hook.devices(all: showAll); devicesError = nil; devicesLoaded = true }
        catch { devicesError = LText(String(localized: "设备列表读取失败：\(describe(error))")) }
    }

    private func setPermission(_ d: HookClient.Device, _ value: String) async {
        guard let hook, let p = DevicePermission(rawValue: value), p.rawValue != d.permission else { return }
        do { try await hook.setPermission(deviceId: d.id, p) } catch { devicesError = LText(String(localized: "修改「\(d.name)」的权限失败：\(describe(error))")); return }
        await load()
    }

    private func remove(_ d: HookClient.Device) async {
        guard let hook, !removing.contains(d.id) else { return }
        removing.insert(d.id); defer { removing.remove(d.id) }
        do { try await hook.remove(deviceId: d.id) } catch { devicesError = LText(String(localized: "移除「\(d.name)」失败：\(describe(error))")) ; return }
        await load()
    }

    private func describe(_ e: Error) -> String {
        if let h = e as? HookClient.HookError {
            switch h {
            case .bridgeNotRunning: return String(localized: "Bridge 未运行")
            case .unauthorized: return String(localized: "Hook 密钥不匹配")
            case .invalidResponse: return String(localized: "响应无法解析")
            case .http(let c): return String(localized: "钩子口返回 \(c)")
            }
        }
        return String(localized: "无法连接")
    }

    private func qrImage(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let ci = f.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}

/// 配对码的时间判断：倒计时、过期、二维码都从同一个时间点算（O1-341 R2）。
enum PairingCodeClock {
    static func remaining(_ code: HookClient.PairCode, at date: Date) -> Int { max(0, Int(Double(code.expiresT) / 1000 - date.timeIntervalSince1970)) }
    static func expired(_ code: HookClient.PairCode, at date: Date) -> Bool { remaining(code, at: date) == 0 }
}

/// 二维码图只在 payload 变化时重新生成：界面每秒求值，不能每秒画一次二维码。
final class QRImageCache {
    private var key: String?
    private var value: NSImage?
    func image(for s: String, make: (String) -> NSImage?) -> NSImage? {
        if s == key { return value }
        key = s; value = make(s)
        return value
    }
}
