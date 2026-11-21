import XCTest
import SwiftUI
import AppKit
import PalmhelmKit
@testable import PalmhelmMac

/// 用量页的合成数据（非隔离，供 @Sendable 的 override 直接调用）。固定：2026-10-24 Asia/Shanghai，生成时刻 14:30。
enum UsageShotVariant: String { case normal, longNames, stale, uncovered, allZero, complete, rebuilding }

enum UsageShotFixture {
    static let midnight = 1_792_771_200_000     // 2026-10-24 00:00 Asia/Shanghai
    static let hour = 3_600_000
    static let generatedT = midnight + 14 * 3_600_000 + 1_800_000 // 14:30（确认截止）
    /// 截图固定的当前时间：2026-10-24 18:25 Asia/Shanghai（在所展示日期内）。
    static let fixedNow = midnight + 18 * 3_600_000 + 25 * 60_000

    static func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    static func tokens(_ i: Int) -> String {
        #"{"input":\#(i),"output":\#(i / 5),"cacheRead":\#(i * 3),"cacheWrite":\#(i / 9),"activity":\#(max(1, i / 6))}"#
    }
    static func bucket(_ t: Int, date: String? = nil, a: Int, b: Int, v: UsageShotVariant) -> String {
        let d = date.map { #""date":"\#($0)","# } ?? ""
        let names = v == .longNames
            ? ["claude-opus-5-5-extended-experimental-long-name-for-legend-check-xxxxxxxxxxxxx", "claude-sonnet-5-5", "gpt-6.1-sol"]
            : ["claude-opus-5-5", "claude-sonnet-5-5", "gpt-6.1-sol"]
        let z = v == .allZero ? 0 : 1
        return #"{"t":\#(t),\#(d)"byModel":{"\#(names[0])":\#(tokens(a * z)),"\#(names[1])":\#(tokens(b * z)),"\#(names[2])":\#(tokens((a / 2 + 3) * z))}}"#
    }
    static func win(_ from: String, _ to: String, rows: String = "[]", cost: String = "2.84") -> String {
        #"{"from":"\#(from)","to":"\#(to)","rows":\#(rows),"totals":{"tokens":{"input":41200,"output":8300,"cacheRead":512000,"cacheWrite":18200},"costUsd":\#(cost),"hasUnpriced":true,"partial":true,"priceStale":false,"ttlUnknownTokens":900}}"#
    }
    static func row(_ model: String, _ prov: String, _ src: String, _ cost: String) -> String {
        #"{"source":"\#(src)","model":"\#(model)","provider":"\#(prov)","tokens":{"input":16000,"output":3100,"cacheRead":181000,"cacheWrite":6200},"costUsd":\#(cost),"unpricedTokens":0,"reasons":[],"usedBands":[]}"#
    }
    static func coverage(_ v: UsageShotVariant) -> String {
        switch v {
        case .stale: #","coverage":{"enumeration":"complete","filesTotal":3,"filesIndexed":3,"bytesTotal":10,"bytesIndexed":10,"percent":100,"updatedT":\#(generatedT),"backfilling":false,"rebuilding":false,"refresh":"failed","lastSuccessT":\#(midnight + 11 * hour)}"#
        case .uncovered: #","coverage":{"enumeration":"in_progress","filesTotal":40,"filesIndexed":16,"bytesTotal":10,"bytesIndexed":4,"percent":40,"updatedT":\#(generatedT),"backfilling":true,"rebuilding":false,"refresh":"ok","lastSuccessT":\#(generatedT)}"#
        case .complete: #","coverage":{"enumeration":"complete","filesTotal":3,"filesIndexed":3,"bytesTotal":10,"bytesIndexed":10,"percent":100,"updatedT":\#(generatedT),"backfilling":false,"rebuilding":false,"refresh":"ok","lastSuccessT":\#(generatedT)}"#
        case .rebuilding: #","coverage":{"enumeration":"in_progress","filesTotal":40,"filesIndexed":12,"bytesTotal":10,"bytesIndexed":3,"percent":30,"updatedT":\#(generatedT),"backfilling":false,"rebuilding":true,"refresh":"ok","lastSuccessT":\#(generatedT)}"#
        default: ""
        }
    }
    /// 上海时区的 yyyy-MM-dd（补零），与产品解析的日期格式一致。
    static func isoDay(_ t: Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
    }
    /// 合成的用量响应。v 控制变体：长模型名、旧快照、未覆盖、全零。
    static func usage(_ w: UsageWindow, _ v: UsageShotVariant = .normal) -> UsageResponse {
        let rows = "[" + [row("claude-opus-5-5", "anthropic", "claude", "1.84"), row("claude-sonnet-5-5", "anthropic", "claude", "0.61"), row("gpt-6.1-sol", "openai", "codex", "0.39")].joined(separator: ",") + "]"
        let estimate = #"{"version":1,"windows":{"today":\#(win("2026-10-24", "2026-10-24", rows: rows)),"last7d":\#(win("2026-10-18", "2026-10-24")),"last30d":\#(win("2026-09-25", "2026-10-24", cost: "21.90"))},"pricing":{"source":"models.dev","origin":"downloaded","freshness":"current","versionHash":"abcdef123456","asOfT":1761270000000,"lastValidatedT":1761273600000,"lastCheckT":null,"autoUpdate":true,"updatePolicy":"startup_if_older_than_3d","cacheLongRules":[]},"sources":[{"source":"claude","status":"collected","reasons":[]},{"source":"codex","status":"partial","reasons":["sqlite_not_opened"]},{"source":"pi","status":"found_unusable","reasons":[]}],"truncated":[]}"#
        var buckets: [String] = []
        switch w {
        case .h24:
            for h in 0...14 { buckets.append(bucket(midnight + h * hour, a: 30 + h * 9, b: 12 + (h % 4) * 7, v: v)) }
        case .d7:
            for d in 0..<7 { buckets.append(bucket(midnight - (6 - d) * 86_400_000, date: "2026-10-\(18 + d)", a: 400 + d * 60, b: 200, v: v)) }
        default:
            for d in 0..<30 {
                let t = midnight - (29 - d) * 86_400_000
                buckets.append(bucket(t, date: isoDay(t), a: 300 + d * 25, b: 120, v: v))
            }
        }
        let heat = (0..<7).map { _ in (0..<24).map { h in (h >= 8 && h <= 18) ? (h * 3 + 4) : (h % 5) } }
        let days = (0..<7).map { "2026-10-\(18 + $0)" }
        let heatJSON = #"{"days":["\#(days.joined(separator: "\",\""))"],"activity":[\#(heat.map { "[" + $0.map(String.init).joined(separator: ",") + "]" }.joined(separator: ","))]}"#
        let r = #"{"from":"2026-10-24","to":"2026-10-24","byModel":{}}"#
        let json = #"""
        {"window":"\#(w.rawValue)","timeZone":"Asia/Shanghai","generatedT":\#(generatedT),"partial":\#(v == .complete ? "false" : "true"),"reasons":\#(v == .complete ? "[]" : #"["sqlite_not_opened"]"#),"quality":{},"bucketMs":\#(w == .h24 ? 3_600_000 : 86_400_000),"buckets":[\#(buckets.joined(separator: ","))]\#(coverage(v)),
         "recent":{"today":\#(r),"d7":\#(r),"d30":\#(r)},"heatmap":\#(heatJSON),"prices":{},
         "agents":{"claude":{"candidates":3,"parsed":3,"complete":3},"codex":{"candidates":2,"parsed":2,"complete":1},"pi":{"candidates":0,"parsed":0,"complete":0}},
         "estimate":\#(estimate)}
        """#
        return decode(json)
    }
    /// O1-368 典型夹具：Codex Pro 100（5h / 7d）+ Claude Max 5x（5h / 7d / Fable）。
    static func accounts() -> AccountsResponse {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return decode(#"""
        {"accounts":[
          {"provider":"codex","accountId":"acct_0123456789abcdef","billingMode":"subscription","plan":"prolite","source":"codex_app_server","observedAt":\#(now - 120_000),"status":"ok","windows":[{"id":"bucket0:primary","label":null,"usedPercent":42,"windowMins":300,"resetAt":\#(now + 3_540_000)},{"id":"bucket1:primary","label":null,"usedPercent":12,"windowMins":10080,"resetAt":\#(now + 82_800_000)}]},
          {"provider":"claude","accountId":"acct_fedcba9876543210","billingMode":"subscription","plan":"max_5x","source":"claude_statusline","observedAt":\#(now - 180_000),"status":"ok","windows":[{"id":"five_hour:primary","usedPercent":18,"windowMins":300,"resetAt":\#(now + 7_200_000)},{"id":"seven_day:primary","usedPercent":35,"windowMins":10080,"resetAt":\#(now + 259_200_000)},{"id":"seven_day:fable","label":"Fable","usedPercent":61,"windowMins":10080,"resetAt":\#(now + 259_200_000)}]}
        ]}
        """#)
    }
    static func state() -> BridgeState {
        decode(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[{"id":"t1","projectName":"remote-herdr-bridge","agentName":"design","online":true,"status":"working","kind":"claude","location":{"workspace":"Palmhelm","pane":"w1:p1"}},{"id":"t2","projectName":"example-app","agentName":"execute","online":true,"status":"working","kind":"codex","location":{"workspace":"Palmhelm","pane":"w1:p2"}},{"id":"t3","projectName":"ops","agentName":"idle","online":true,"status":"idle","kind":"pi"}],"history":{"highWater":0,"items":[]}}"#)
    }
}

/// 离屏渲染 harness：窗口不显示；容器视图画底色（背景进图），内容为用量页；宽高即用量页的视口。
@MainActor
enum UsageShotHarness {
    struct Rendered { let window: NSWindow; let host: NSHostingView<AnyView>; let session: MacSession }

    static func make(width: CGFloat, height: CGFloat, dark: Bool, variant: UsageShotVariant = .normal,
                     segment: UsageSegment = .today, expandedPricing: Bool = false, reporter: PlotReporter? = nil) -> Rendered {
        let session = MacSession()
        session.link = .connected
        session.device = UsageShotFixture.decode(#"{"id":"d","name":"mac","paused":false}"#)
        session.state = UsageShotFixture.state()
        session.usageOverride = { w in UsageShotFixture.usage(w, variant) }
        session.accountsOverride = { _ in UsageShotFixture.accounts() }
        let defaults = UserDefaults(suiteName: "palmhelm.usage.shots.\(Int(width)).\(dark).\(variant.rawValue).\(segment.rawValue).\(expandedPricing)")!
        let settings = EngineSettings(defaults: defaults)
        let engine = BridgeEngine(settings: settings)
        var root = AnyView(MacStatsView(initialSegment: segment).environment(session).environment(engine).environment(settings)
            .environment(\.pricingInitiallyExpanded, expandedPricing)
            .environment(\.usageNow, UsageShotFixture.fixedNow))
        if let reporter { root = AnyView(root.environment(\.plotReporter, reporter)) }
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
        return Rendered(window: window, host: host, session: session)
    }

    /// 等待数据与布局稳定，然后把容器（含底色）画成位图。
    static func settle(_ r: Rendered, segment: UsageSegment) async {
        await r.session.loadUsage(segment.window)
        await r.session.loadAccounts()
        await r.session.probeLast30d()
        for _ in 0..<6 { try? await Task.sleep(nanoseconds: 200_000_000); r.host.layoutSubtreeIfNeeded() }
    }

    /// 局部图：只放今日图表卡片，固定 now；用于看清过去未覆盖 / 当前 / 未来三段。
    static func chartOnlyPNG(dark: Bool) async -> Data? {
        let u = UsageShotFixture.usage(.h24, .normal)
        guard case .v1(let e) = UsageModel.mode(u) else { return nil }
        let w = UsageModel.window(e, .today)
        let data = UsageModel.chartData(u, w, .today)
        let view = ChartCard(u: u, w: w, segment: .today, data: data, plotHeight: 240, now: UsageShotFixture.fixedNow)
            .frame(width: 980).padding(14)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1008, height: 360)
        let container = NSView(frame: host.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)).cgColor
        container.addSubview(host)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        for _ in 0..<6 { try? await Task.sleep(nanoseconds: 200_000_000); host.layoutSubtreeIfNeeded() }
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        window.contentView = nil
        return rep.representation(using: .png, properties: [:])
    }

    static func png(_ r: Rendered) -> Data? {
        guard let container = r.window.contentView, let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

@MainActor
final class UsageScreenshotTests: XCTestCase {
    /// 30 天夹具（E1）：30 个桶、日期补零且连续，截图前先确认。
    func testThirtyDayFixtureHasContinuousZeroPaddedDates() throws {
        let u = UsageShotFixture.usage(.d30)
        guard case .v1(let e) = UsageModel.mode(u) else { return XCTFail("应为 v1 估算") }
        let w = UsageModel.window(e, .last30d)
        let data = UsageModel.chartData(u, w, .last30d)
        XCTAssertEqual(data.bars.count, 30)
        XCTAssertEqual(u.buckets.count, 30)
        let dates = u.buckets.compactMap(\.date)
        XCTAssertEqual(dates.count, 30, "每个桶都带日期")
        XCTAssertEqual(dates.first, "2026-09-25")
        XCTAssertEqual(dates.last, "2026-10-24")
        XCTAssertTrue(dates.allSatisfy { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }, "日期补零")
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        for (a, b) in zip(dates, dates.dropFirst()) {
            let da = f.date(from: a)!, db = f.date(from: b)!
            XCTAssertEqual(db.timeIntervalSince(da), 86_400, accuracy: 1, "\(a) 与 \(b) 相邻")
        }
    }

    /// 默认跳过。TEST_RUNNER_REINS_USAGE_SHOTS=1 时渲染到 /tmp/w1-usage-shots/。
    func testRenderUsageShots() async throws {
        guard ProcessInfo.processInfo.environment["REINS_USAGE_SHOTS"] == "1" else { throw XCTSkip("set REINS_USAGE_SHOTS=1 to render usage shots") }
        let dir = URL(fileURLWithPath: "/tmp/w1-usage-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 补充：整页（高度 2400）用于看到折叠线以下的价格卡（价格展开）；其余为正常视口 820。
        let plan: [(name: String, width: CGFloat, height: CGFloat, dark: Bool, variant: UsageShotVariant, segment: UsageSegment, expanded: Bool)] = [
            ("default-820-light", 820, 820, false, .normal, .today, false),
            ("default-820-dark", 820, 820, true, .normal, .today, false),
            ("default-1440-light", 1440, 820, false, .normal, .today, false),
            ("default-1440-dark", 1440, 820, true, .normal, .today, false),
            ("pricing-expanded-820-light", 820, 820, false, .normal, .today, true),
            ("pricing-expanded-820-fullpage-light", 820, 2400, false, .normal, .today, true),
            ("long-legend-820-fullpage-light", 820, 2400, false, .longNames, .today, false),
            ("last30d-1440-fullpage-light", 1440, 2400, false, .normal, .last30d, false),
            ("last30d-820-light", 820, 820, false, .normal, .last30d, false),
            ("stale-820-light", 820, 820, false, .stale, .today, false),
            ("uncovered-820-light", 820, 820, false, .uncovered, .today, false),
            ("allzero-820-light", 820, 820, false, .allZero, .today, false),
        ]
        var written: [String] = []
        for dark in [false, true] {
            if let png = await UsageShotHarness.chartOnlyPNG(dark: dark) {
                let name = "chart-local-\(dark ? "dark" : "light").png"
                try png.write(to: dir.appendingPathComponent(name))
                written.append(name)
            }
        }
        for p in plan {
            let r = UsageShotHarness.make(width: p.width, height: p.height, dark: p.dark, variant: p.variant, segment: p.segment, expandedPricing: p.expanded)
            await UsageShotHarness.settle(r, segment: p.segment)
            guard let png = UsageShotHarness.png(r) else { XCTFail("no png for \(p.name)"); continue }
            try png.write(to: dir.appendingPathComponent("usage-\(p.name).png"))
            written.append(p.name)
        }
        try ("默认主题的浅色与深色已采（820 与 1440 宽）。其余主题未采。\n"
            + "视口高度 820（用量页可滚动）；宽度为用量页内容宽度（不含侧栏）；容器底色已画入图中。\n"
            + "数据为固定合成数据（2026-10-24，Asia/Shanghai，生成时刻 14:30）。\n"
            + "变体：" + written.joined(separator: "、") + "\n").write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }
}
