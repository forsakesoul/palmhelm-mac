import Foundation
import Darwin

// 监听地址自适应（h8）：保存「意图」（回环恒开、局域网、Tailscale），具体 IP 每次启动时从当前网卡解析；
// 网络变化时用纯函数决定是否重启。本文件只含无副作用的规则（解析、迁移、重启决策），便于单测；系统调用只有 currentInterfaces()。

struct NetInterface: Equatable, Sendable {
    let name: String
    let ip: String
    var up = true
}

struct ListenIntent: Equatable, Sendable {
    var lan: Bool
    var tailscale: Bool
}

/// 一次解析的结果：按意图取到的地址（没有就是 nil，**不**退化成 0.0.0.0，也不启用未勾选的渠道）。
struct ListenResolution: Equatable, Sendable {
    var lan: String?
    var tailscale: String?
    var intent: ListenIntent

    /// 传给 Bridge 的监听列表：回环恒在最前。
    var bindList: [String] { ["127.0.0.1"] + [lan, tailscale].compactMap { $0 } }
    var bind: String { bindList.joined(separator: ",") }
    var lanUnavailable: Bool { intent.lan && lan == nil }
    var tailscaleUnavailable: Bool { intent.tailscale && tailscale == nil }
}

enum ListenResolver {
    /// 虚拟 / 隧道 / 点对点接口：不当作「同一 Wi‑Fi 的局域网」。utun 是 VPN / Tailscale 的隧道口（Tailscale 在下面单独取）。
    static let virtualPrefixes = ["lo", "utun", "bridge", "vmnet", "docker", "awdl", "llw", "veth", "vboxnet", "gif", "stf", "ap", "anpi", "pdp_ip", "ipsec", "ppp", "feth"]

    static func isVirtual(_ name: String) -> Bool { virtualPrefixes.contains { name.hasPrefix($0) } }

    /// 局域网：RFC1918 IPv4，接口在线且不是虚拟口；en0 优先，其次其余 en*，再按名字排序（结果与枚举顺序无关）。
    static func lan(_ ifaces: [NetInterface]) -> String? {
        let candidates = ifaces.filter { $0.up && !isVirtual($0.name) && EngineSettings.isRfc1918($0.ip) }
        return candidates.sorted { rank($0.name) != rank($1.name) ? rank($0.name) < rank($1.name) : ($0.name, $0.ip) < ($1.name, $1.ip) }.first?.ip
    }
    private static func rank(_ name: String) -> Int { name == "en0" ? 0 : name.hasPrefix("en") ? 1 : 2 }

    /// Tailscale：100.64/10 且在 utun 隧道口上（别处出现的 100.x 不算）。
    static func tailscale(_ ifaces: [NetInterface]) -> String? {
        ifaces.filter { $0.up && $0.name.hasPrefix("utun") && EngineSettings.isTailscale($0.ip) }.sorted { ($0.name, $0.ip) < ($1.name, $1.ip) }.first?.ip
    }

    static func resolve(intent: ListenIntent, _ ifaces: [NetInterface]) -> ListenResolution {
        ListenResolution(lan: intent.lan ? lan(ifaces) : nil, tailscale: intent.tailscale ? tailscale(ifaces) : nil, intent: intent)
    }

    /// 当前所有 IPv4 接口（不含回环）。IFF_UP 与 IFF_RUNNING 都为真才算在线。
    static func currentInterfaces() -> [NetInterface] {
        var out: [NetInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("127.") { continue }
            let flags = Int32(p.pointee.ifa_flags)
            out.append(NetInterface(name: String(cString: p.pointee.ifa_name), ip: ip, up: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0))
        }
        return out
    }
}

enum ListenMigration {
    /// 旧 `engine.bind`（逗号分隔的具体 IP）→ 意图：含 RFC1918 → 局域网；含 100.64/10 → Tailscale。其余（回环、公网、0.0.0.0）不产生意图。
    static func intent(fromLegacyBind bind: String) -> ListenIntent {
        let items = EngineSettings.binds(bind)
        return ListenIntent(lan: items.contains(where: EngineSettings.isRfc1918), tailscale: items.contains(where: EngineSettings.isTailscale))
    }
}

/// 运行中的重启决策（纯函数）：只比较「Bridge 当前绑定的地址」与「按启动时的意图重新解析到的地址」。
/// - 某个启动时已勾选的渠道此刻解析不到地址（断网、睡眠唤醒中）→ 视为暂空，沿用已绑定值，不触发重启；
/// - 地址集合实际变化后要等 3 秒防抖（期间集合再变就重新计时），到点才重启；
/// - 距上次启动 30 秒内最多再重启 1 次（到点前一直等待）；
/// - 用户在设置里改勾选不由这里处理（走「设置有更改，重启后生效」）。
struct ListenWatch {
    struct Bound: Equatable { var lan: String?; var tailscale: String? }
    enum Action: Equatable { case none, wait(until: Date), restart }

    static let debounce: TimeInterval = 3
    static let minInterval: TimeInterval = 30

    private(set) var bound: Bound
    let intent: ListenIntent // 启动时冻结的意图
    private(set) var lastStart: Date
    private var pending: (set: Bound, since: Date)?

    init(started resolution: ListenResolution, at now: Date) {
        bound = Bound(lan: resolution.lan, tailscale: resolution.tailscale)
        intent = resolution.intent
        lastStart = now
    }

    /// 把此刻的解析结果折算成「有效地址」：已勾选渠道解析不到 → 沿用已绑定值；未勾选渠道恒为 nil。
    func effective(_ resolved: ListenResolution) -> Bound {
        Bound(lan: intent.lan ? (resolved.lan ?? bound.lan) : nil, tailscale: intent.tailscale ? (resolved.tailscale ?? bound.tailscale) : nil)
    }

    mutating func observe(_ resolved: ListenResolution, now: Date) -> Action {
        let eff = effective(resolved)
        guard eff != bound else { pending = nil; return .none }
        if pending?.set != eff { pending = (eff, now) } // 集合变了：重新计时
        let debounced = pending!.since.addingTimeInterval(Self.debounce)
        if now < debounced { return .wait(until: debounced) }
        let allowed = lastStart.addingTimeInterval(Self.minInterval)
        if now < allowed { return .wait(until: allowed) }
        return .restart
    }
}
