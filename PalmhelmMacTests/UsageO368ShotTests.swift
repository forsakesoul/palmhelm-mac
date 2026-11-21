import XCTest
import SwiftUI
import PalmhelmKit
@testable import PalmhelmMac

// O1-368 证据矩阵（默认跳过）：REINS_O368_SHOTS=1 时把截图与每张卡的 frame 写入 $REINS_CAPTURE_DIR（缺省为系统临时目录下的 palmhelm-o368）。
// 宽窗 1260 下：九态 + 加载 + 首次无数据，多账户 2/4，清蓝深色，低窗口高度，切走再切回；每个必需卡位缺失即失败，不跳过。
@MainActor
final class UsageO368ShotTests: XCTestCase {
    enum Kind: String {
        case normal, complete, rebuilding, stale, uncovered, allZero, longNames, offlineCache, refreshFailedCache
        case loading, failed, disconnected, empty, cachedReturn
    }
    enum AccountsKind { case two, four, six, apiOnly }
    static let requiredCards = ["trend", "account", "working", "activity", "sources", "modelTable"]

    private struct Shot { let window: NSWindow; let host: NSHostingView<AnyView>; let session: MacSession; let frames: UsageCardFrames }

    /// 六个账户：Codex Pro 100（正常）、Claude Max 5x（正常 + Fable）、Codex Plus（失败）、Claude Pro（旧快照）、Codex API（无窗口）、Claude Max 5x（窗口已重置、无 Fable）；两个同名「研究」。
    nonisolated private static func sixAccounts() -> AccountsResponse {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return UsageShotFixture.decode(#"""
        {"accounts":[
          {"provider":"codex","accountId":"acct_a","label":"研究","billingMode":"subscription","plan":"prolite","source":"codex_app_server","observedAt":\#(now - 60_000),"status":"ok","windows":[{"id":"bucket0:primary","usedPercent":42,"windowMins":300,"resetAt":\#(now + 3_540_000)},{"id":"bucket1:primary","usedPercent":12,"windowMins":10080,"resetAt":\#(now + 82_800_000)}]},
          {"provider":"claude","accountId":"acct_b","label":"研究","billingMode":"subscription","plan":"max_5x","source":"claude_statusline","observedAt":\#(now - 180_000),"status":"ok","windows":[{"id":"five_hour:primary","usedPercent":18,"windowMins":300,"resetAt":\#(now + 7_200_000)},{"id":"seven_day:primary","usedPercent":35,"windowMins":10080,"resetAt":\#(now + 259_200_000)},{"id":"seven_day:fable","label":"Fable","usedPercent":61,"windowMins":10080,"resetAt":\#(now + 259_200_000)}]},
          {"provider":"codex","accountId":"acct_c","billingMode":"subscription","plan":"plus","source":"codex_app_server","observedAt":\#(now - 900_000),"status":"error","errorCode":"app_server_failed","windows":[{"id":"bucket0:primary","usedPercent":90,"windowMins":300,"resetAt":\#(now + 3_000_000)}]},
          {"provider":"claude","accountId":"acct_d","billingMode":"subscription","plan":"pro","source":"claude_statusline","observedAt":\#(now - 4_000_000),"status":"stale","windows":[{"id":"five_hour:primary","usedPercent":5,"windowMins":300,"resetAt":\#(now + 1_000_000)}]},
          {"provider":"codex","accountId":"acct_e","billingMode":"api","source":"codex_app_server","observedAt":\#(now - 60_000),"status":"ok"},
          {"provider":"claude","accountId":"acct_f","billingMode":"subscription","plan":"max_5x","source":"claude_statusline","observedAt":\#(now - 60_000),"status":"ok","windows":[{"id":"five_hour:primary","usedPercent":70,"windowMins":300,"resetAt":\#(now - 600_000)}]}
        ]}
        """#)
    }
    nonisolated private static func apiOnlyAccounts() -> AccountsResponse {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return UsageShotFixture.decode(#"""
        {"accounts":[{"provider":"codex","accountId":"acct_e","billingMode":"api","source":"codex_app_server","observedAt":\#(now - 60_000),"status":"ok"},{"provider":"claude","accountId":"acct_g","billingMode":"api","source":"claude_statusline","observedAt":\#(now - 60_000),"status":"ok"}]}
        """#)
    }
    nonisolated private static func fourAccounts() -> AccountsResponse {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return UsageShotFixture.decode(#"""
        {"accounts":[
          {"provider":"codex","accountId":"acct_a","billingMode":"subscription","plan":"prolite","source":"codex_app_server","observedAt":\#(now - 60_000),"status":"ok","windows":[{"id":"bucket0:primary","usedPercent":42,"windowMins":300,"resetAt":\#(now + 3_540_000)},{"id":"bucket1:primary","usedPercent":12,"windowMins":10080,"resetAt":\#(now + 82_800_000)}]},
          {"provider":"claude","accountId":"acct_b","billingMode":"subscription","plan":"max_5x","source":"claude_statusline","observedAt":\#(now - 180_000),"status":"ok","windows":[{"id":"five_hour:primary","usedPercent":18,"windowMins":300,"resetAt":\#(now + 7_200_000)},{"id":"seven_day:primary","usedPercent":35,"windowMins":10080,"resetAt":\#(now + 259_200_000)},{"id":"seven_day:fable","label":"Fable","usedPercent":61,"windowMins":10080,"resetAt":\#(now + 259_200_000)}]},
          {"provider":"codex","accountId":"acct_c","billingMode":"subscription","plan":"plus","source":"codex_app_server","observedAt":\#(now - 900_000),"status":"error","errorCode":"app_server_failed","windows":[{"id":"bucket0:primary","usedPercent":90,"windowMins":300,"resetAt":\#(now + 3_000_000)}]},
          {"provider":"claude","accountId":"acct_d","billingMode":"subscription","plan":"pro","source":"claude_statusline","observedAt":\#(now - 4_000_000),"status":"stale","windows":[{"id":"five_hour:primary","usedPercent":5,"windowMins":300,"resetAt":\#(now + 1_000_000)}]}
        ]}
        """#)
    }

    private func make(width: CGFloat, height: CGFloat, dark: Bool, kind: Kind, segment: UsageSegment, accounts: AccountsKind = .two, popover: Bool = false) -> Shot {
        let session = MacSession()
        session.device = UsageShotFixture.decode(#"{"id":"d","name":"mac","paused":false}"#)
        session.state = UsageShotFixture.state()
        session.accountsOverride = { _ in
            switch accounts {
            case .two: UsageShotFixture.accounts()
            case .four: Self.fourAccounts()
            case .six: Self.sixAccounts()
            case .apiOnly: Self.apiOnlyAccounts()
            }
        }
        switch kind {
        case .normal, .complete, .rebuilding, .stale, .uncovered, .allZero, .longNames, .cachedReturn, .offlineCache, .refreshFailedCache:
            session.link = .connected
            let variant: UsageShotVariant = {
                switch kind {
                case .stale: .stale; case .uncovered: .uncovered; case .allZero: .allZero; case .longNames: .longNames
                case .complete: .complete; case .rebuilding: .rebuilding; default: .normal
                }
            }()
            session.usageOverride = { w in UsageShotFixture.usage(w, variant) }
        case .loading:
            session.link = .connected
            session.usageOverride = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000); throw URLError(.timedOut) }
        case .failed:
            session.link = .connected
            session.usageOverride = { _ in throw URLError(.timedOut) }
        case .disconnected:
            session.link = .offline("连接中断")
        case .empty:
            // 请求完成但没有可用快照：返回的是别的范围，没有错误（首次无数据）
            session.link = .connected
            session.usageOverride = { _ in UsageShotFixture.usage(.d7, .normal) }
        }
        let frames = UsageCardFrames()
        let defaults = UserDefaults(suiteName: "palmhelm.o368.matrix.\(kind.rawValue).\(Int(width)).\(dark).\(accounts)")!
        let settings = EngineSettings(defaults: defaults)
        let engine = BridgeEngine(settings: settings)
        let root = AnyView(MacStatsView(initialSegment: segment).environment(session).environment(engine).environment(settings)
            .environment(\.usageNow, UsageShotFixture.fixedNow).environment(\.usageCardFrames, frames)
            .environment(\.pricingInitiallyExpanded, popover))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let container = NSView(frame: host.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)).cgColor
        container.addSubview(host)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        return Shot(window: window, host: host, session: session, frames: frames)
    }

    private func settle(_ r: Shot, kind: Kind, segment: UsageSegment) async {
        switch kind {
        case .loading, .disconnected, .offlineCache, .refreshFailedCache: break
        default: await r.session.loadUsage(segment.window)
        }
        await r.session.loadAccounts()
        for _ in 0..<8 { try? await Task.sleep(nanoseconds: 200_000_000); r.host.layoutSubtreeIfNeeded() }
    }

    private func png(_ r: Shot) -> Data? {
        guard let container = r.window.contentView, let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func captureDir() throws -> URL {
        let base = ProcessInfo.processInfo.environment["REINS_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("palmhelm-o368", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 同一会话的用量页根视图（离开再回到页面时用新宿主 + 新卡位记录，模拟重新挂载）。
    private func page(_ session: MacSession, _ segment: UsageSegment, _ frames: UsageCardFrames) -> AnyView {
        let defaults = UserDefaults(suiteName: "palmhelm.o368.matrix.cachedReturn")!
        return AnyView(MacStatsView(initialSegment: segment).environment(session)
            .environment(EngineSettings(defaults: defaults))
            .environment(BridgeEngine(settings: EngineSettings(defaults: defaults)))
            .environment(\.usageNow, UsageShotFixture.fixedNow).environment(\.usageCardFrames, frames))
    }

    /// 在同一窗口与同一会话上重新挂载用量页，卡位记录从空开始。
    private func rehost(_ r: Shot, _ segment: UsageSegment) -> Shot {
        let frames = UsageCardFrames()
        let host = NSHostingView(rootView: page(r.session, segment, frames))
        host.frame = r.host.frame
        r.window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        r.window.contentView?.addSubview(host)
        return Shot(window: r.window, host: host, session: r.session, frames: frames)
    }

    /// 必需卡位缺失直接失败（不跳过）。
    private func assertAllCards(_ frames: [String: CGRect], _ label: String) {
        for card in Self.requiredCards {
            XCTAssertNotNil(frames[card], "\(label)：缺少 \(card) 卡位")
        }
    }

    private func write(_ r: Shot, name: String, dir: URL, frames store: inout [String: [String: CGRect]]) throws {
        guard let data = png(r) else { return XCTFail("no png for \(name)") }
        try data.write(to: dir.appendingPathComponent("o368-\(name).png"))
        let json = r.frames.frames.mapValues { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] }
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: dir.appendingPathComponent("frames-\(name).json"))
        store[name] = r.frames.frames
    }

    /// 等待一段时间并让布局稳定（不触发新的网络请求）。
    private func idle(_ r: Shot, rounds: Int = 8) async {
        for _ in 0..<rounds { try? await Task.sleep(nanoseconds: 200_000_000); r.host.layoutSubtreeIfNeeded() }
    }

    func testEvidenceMatrix() async throws {
        guard ProcessInfo.processInfo.environment["REINS_O368_SHOTS"] == "1" else { throw XCTSkip("set REINS_O368_SHOTS=1") }
        let dir = try captureDir()
        var store: [String: [String: CGRect]] = [:]
        let theme = PalmhelmThemeStore.shared
        let originalFamily = theme.family
        defer { theme.family = originalFamily }
        // 状态（1260 宽，浅色，清蓝）：原规格的各状态 + 两个新增态
        let states: [(Kind, String)] = [
            (.complete, "complete"), (.normal, "normal"), (.uncovered, "gap"), (.rebuilding, "rebuilding"),
            (.allZero, "allZero"), (.stale, "refreshFailedStale"), (.offlineCache, "offlineCache"), (.refreshFailedCache, "refreshFailedCache"),
            (.loading, "loading"), (.failed, "failed"), (.disconnected, "disconnected"), (.empty, "empty"),
        ]
        theme.family = .standard
        for (kind, name) in states {
            let r = make(width: 1260, height: 1420, dark: false, kind: kind, segment: .today)
            await settle(r, kind: kind, segment: .today)
            if kind == .offlineCache { r.session.link = .offline("连接中断"); await idle(r) }
            if kind == .refreshFailedCache {
                r.session.usageOverride = { _ in throw URLError(.timedOut) }
                await r.session.loadUsage(UsageSegment.today.window)
                await idle(r)
            }
            if kind != .disconnected && kind != .loading && kind != .failed && kind != .empty { assertAllCards(r.frames.frames, name) }
            try write(r, name: name, dir: dir, frames: &store)
        }
        // 账户与主题：六个账户（暖橙、松绿），两账户清蓝深色，四账户，纯 API，低高度 680，浮层
        let extra: [(Kind, String, Bool, AccountsKind, CGFloat, Bool, UsageFamilyName)] = [
            (.complete, "accounts6-warmOrange", false, .six, 1420, false, .warmOrange),
            (.complete, "accounts6-qoderGreen", false, .six, 1420, false, .qoderGreen),
            (.complete, "accounts2-clearBlue-dark", true, .two, 1420, false, .clearBlue),
            (.complete, "accounts4", false, .four, 1420, false, .clearBlue),
            (.complete, "apiOnly", false, .apiOnly, 1420, false, .clearBlue),
            (.complete, "lowHeight680", false, .two, 680, false, .clearBlue),
            (.complete, "pricingPopover", false, .two, 1420, true, .clearBlue),
        ]
        for (kind, name, dark, accounts, height, popover, family) in extra {
            theme.family = family.family
            let r = make(width: 1260, height: height, dark: dark, kind: kind, segment: .today, accounts: accounts, popover: popover)
            await settle(r, kind: kind, segment: .today)
            assertAllCards(r.frames.frames, name)
            try write(r, name: name, dir: dir, frames: &store)
        }
        theme.family = .standard
        // 缓存切回：先有数据的今日页 → 切到近 7 天 → 清空卡位记录 → 切回今日，且刷新在途（不等成功）；缓存必须立即可见，卡位齐全
        let first = make(width: 1260, height: 1420, dark: false, kind: .cachedReturn, segment: .today)
        await settle(first, kind: .cachedReturn, segment: .today)
        let away = rehost(first, .last7d)
        await settle(away, kind: .cachedReturn, segment: .last7d)
        away.session.usageOverride = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000); throw URLError(.timedOut) }
        let back = rehost(away, .today)
        await idle(back)
        XCTAssertNotNil(back.session.visibleUsage, "刷新在途期间仍显示缓存的今日快照")
        assertAllCards(back.frames.frames, "cachedReturn-在途")
        try write(back, name: "cachedReturn-inFlight", dir: dir, frames: &store)

        // 零位移断言（宽窗 1260）：每个状态的每张网格卡都与「正常完整」同位同尺寸；缺失即失败
        guard let ref = store["complete"] else { return XCTFail("缺少正常完整的参照") }
        let compared = states.map { $0.1 }.filter { $0 != "complete" } + extra.map { $0.1 } + ["cachedReturn-inFlight"]
        for name in compared {
            guard let other = store[name] else { XCTFail("缺少 \(name)"); continue }
            for card in Self.requiredCards {
                guard let a = other[card], let b = ref[card] else { XCTFail("\(name) 缺少 \(card)"); continue }
                XCTAssertTrue(abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5,
                              "\(name) 的 \(card) 卡位与正常完整不一致：\(a) vs \(b)")
            }
        }
        // 820 窄宽：规格允许自然高度，不做零位移断言，只写出截图
        for (kind, name) in [(Kind.complete, "complete-820"), (Kind.loading, "loading-820")] {
            let r = make(width: 820, height: 2000, dark: false, kind: kind, segment: .today)
            await settle(r, kind: kind, segment: .today)
            try write(r, name: name, dir: dir, frames: &store)
        }
        try ("O1-372 证据矩阵（宽 1260；低高度 680；820 为自然高度，不做零位移）。\n" + store.keys.sorted().joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }
}

/// 测试用主题名（避免在矩阵里直接依赖枚举的全部成员）。
enum UsageFamilyName { case clearBlue, warmOrange, qoderGreen
    var family: PalmhelmThemeFamily {
        switch self { case .clearBlue: .clearBlue; case .warmOrange: .warmOrange; case .qoderGreen: .qoderGreen }
    }
}
