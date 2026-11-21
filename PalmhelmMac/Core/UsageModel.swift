import Foundation
import PalmhelmKit

/// 用量页的纯逻辑（宽屏 C1）：窗口选择、日桶 / 小时桶、金额与服务商文案、质量标记。不含 UI，便于测试。
enum UsageSegment: Int, CaseIterable, Equatable {
    case today, last7d, last30d
    var label: String { switch self { case .today: String(localized: "今日"); case .last7d: String(localized: "近 7 天"); case .last30d: String(localized: "近 30 天") } }
    /// 每个分段只请求自己的窗口：今日 = 24h，近 7 天 = 7d，近 30 天 = 30d；卡 / 表 / 图都用同一份响应，不跨响应拼接。
    var window: UsageWindow { switch self { case .today: .h24; case .last7d: .d7; case .last30d: .d30 } }
    /// 近 30 天只在能力发现确认支持时出现（O1-244）；其余分段总是出现。
    static func visible(last30dAvailable: Bool) -> [UsageSegment] { last30dAvailable ? allCases : allCases.filter { $0 != .last30d } }
}

enum UsageModel {
    /// 这份响应的估价区块：nil = 旧版 Bridge（无 estimate）；version ≠ 1 = 暂不支持。
    enum Mode: Equatable { case v1(UsageEstimate), legacy, unsupported }

    static func mode(_ u: UsageResponse) -> Mode {
        if u.estimateUnsupported { return .unsupported }
        if let e = u.estimateV1 { return .v1(e) }
        return .legacy
    }

    static func window(_ e: UsageEstimate, _ seg: UsageSegment) -> UsageEstimateWindow { optionalWindow(e, seg) ?? e.windows.today }
    /// 分段对应的估价窗口；近 30 天在响应里缺失（旧 Bridge）时为 nil，界面明说而不是借用别的窗口。
    static func optionalWindow(_ e: UsageEstimate, _ seg: UsageSegment) -> UsageEstimateWindow? {
        switch seg { case .today: e.windows.today; case .last7d: e.windows.last7d; case .last30d: e.windows.last30d }
    }

    /// 图：今日 = 同一响应里落在 today.from–to（按响应 timeZone 的日历日）的小时桶；近 7 天 = last7d.from–to 的日桶。
    /// coversAll=false：24h 桶覆盖不了今日全部小时（DST 回拨 / 数据缺口等），图下注明，不补 0、不用差值捏造。
    struct Chart: Equatable {
        struct Bar: Equatable, Identifiable { let id: Int; let t: Int; let tokens: Int } // 桶按 epoch ms 标识（回拨日的重复小时不并成一根）
        var bars: [Bar]
        var coversAll: Bool
        var daily: Bool
    }

    /// 一律用响应里的 timeZone（Bridge 本机时区）：日 / 小时归组、轴标签、VoiceOver 时间都不依赖这台机器的时区。
    static func timeZone(_ u: UsageResponse) -> TimeZone { TimeZone(identifier: u.timeZone) ?? .current }
    static func calendar(_ tz: TimeZone) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    /// 轴标签格式：小时只显示小时，日显示 月/日；时区显式设为响应时区。
    static func axisFormat(daily: Bool, tz: TimeZone) -> Date.FormatStyle {
        let base = KitL10n.displayStyle(Date.FormatStyle(timeZone: tz))
        return daily ? base.month(.defaultDigits).day() : base.hour()
    }
    static func axisLabel(_ t: Int, daily: Bool, tz: TimeZone) -> String { ms(t).formatted(axisFormat(daily: daily, tz: tz)) }

    static func chart(_ u: UsageResponse, _ seg: UsageSegment, window w: UsageEstimateWindow) -> Chart {
        let tz = TimeZone(identifier: u.timeZone) ?? .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let df = DateFormatter(); df.calendar = cal; df.timeZone = tz; df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        func day(_ ms: Int) -> String { df.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
        let all = TokenKind.allCases.reduce(into: Set<TokenKind>()) { $0.insert($1) }
        let inRange = u.buckets.filter { b in
            let d = seg != .today ? (b.date ?? day(b.t)) : day(b.t)
            return d >= w.from && d <= w.to
        }
        let bars = inRange.map { Chart.Bar(id: $0.t, t: $0.t, tokens: $0.byModel.values.reduce(0) { $0 + $1.total(all) }) }.sorted { $0.t < $1.t }
        var covers = true
        if seg == .today, let start = df.date(from: w.from).map({ cal.startOfDay(for: $0) }) {
            // 响应生成时刻之前的整点小时桶应当都在：第一根桶不晚于今日 0 点，且相邻桶没有缺口
            let first = bars.first?.t ?? Int.max
            covers = first <= Int(start.timeIntervalSince1970 * 1000)
            if covers, u.bucketMs > 0 { for (a, b) in zip(bars, bars.dropFirst()) where b.t - a.t > u.bucketMs { covers = false } }
        }
        return Chart(bars: bars, coversAll: covers, daily: seg != .today)
    }

    /// 卡 / 列表下的截断说明（用 Kit 文案；未知码原样）。
    static func truncationNotes(_ e: UsageEstimate) -> [String] { e.truncated.map(UsageCopy.reason) }

    /// 质量标记：扫描缺口（响应级 partial）与价格不确定（totals）分开显示，平和文案。
    static func qualityBadges(_ t: UsageEstimateTotals, scanPartial: Bool) -> [String] {
        UsageAccuracy.badges(t, scanPartial: scanPartial)
    }

    // MARK: 图表坐标轴

    /// token 数的人类可读短格式（坐标轴 / 表格共用）：1.5M、150M、12K、980；不出现科学计数法。
    static func tokens(_ n: Int) -> String {
        func trim(_ v: Double, _ unit: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        let a = abs(n)
        if a >= 1_000_000_000 { return trim(Double(n) / 1_000_000_000, "B") }
        if a >= 1_000_000 { return trim(Double(n) / 1_000_000, "M") }
        if a >= 1_000 { return trim(Double(n) / 1_000, "K") }
        return String(n)
    }

    /// 今日小时图 X 轴的刻度间隔（小时）：按柱数取 1 / 2 / 3，避免标签挤在一起或被自动刻度切成半小时而重复。
    static func hourStride(barCount: Int) -> Int { barCount > 18 ? 3 : barCount > 10 ? 2 : 1 }

    /// 模型明细：token 总数为 0 的行不显示（既无用量，又会出现「≈$0.00」与「没有价格」自相矛盾）；返回隐藏了几行，表头据此注明。
    static func visibleRows(_ rows: [UsageEstimateRow]) -> (rows: [UsageEstimateRow], hidden: Int) {
        let shown = rows.filter { $0.tokens.total > 0 }
        return (shown, rows.count - shown.count)
    }

    // MARK: 金额与行文案

    static func usd(_ v: Double?) -> String { v.map { "≈$" + String(format: "%.2f", $0) } ?? "—" }

    /// 估算列：costUsd 为空 = 未报价（带原因）；有金额但 unpricedTokens>0 = 可估部分，另有未报价。
    static func costText(_ r: UsageEstimateRow) -> String {
        guard let c = r.costUsd else { return String(localized: "未报价") }
        return r.unpricedTokens > 0 ? String(localized: "\(usd(c)) · 可估部分，另有未报价") : usd(c)
    }

    /// 服务商列：有实际服务商直接写；未知时写「服务商未知 · 按 X 参考价」，没有参考渠道只写服务商未知。
    static func providerText(_ r: UsageEstimateRow) -> String {
        if let p = r.provider { return p }
        if let ref = r.referenceProvider { return String(localized: "服务商未知 · 按 \(ref) 参考价") }
        return String(localized: "服务商未知")
    }

    static func reasonsText(_ r: UsageEstimateRow) -> String? { r.reasons.isEmpty ? nil : r.reasons.map(UsageCopy.reason).joined(separator: "；") }

    /// 旧版 Bridge 路径：金额只计有价部分，全不可估显示「—」（不是 ≈$0）。
    static func legacyCost(_ r: (usd: Double, hasUnpriced: Bool)) -> String {
        if r.usd == 0 && r.hasUnpriced { return "—" }
        return usd(r.usd) + (r.hasUnpriced ? " · " + String(localized: "含未报价部分") : "")
    }

    // MARK: 时间（四种分开）

    static func ms(_ t: Int) -> Date { Date(timeIntervalSince1970: Double(t) / 1000) }
    /// 数据 HH:mm（generatedT）· 价格 日期 HH:mm（asOfT）。其余两个时间（lastValidatedT / lastCheckT）只在设置页的价格区。
    static func timesLine(generatedT: Int, asOfT: Int?, tz: TimeZone = .current) -> String {
        // 每段是整句参数化 key，分隔符放在代码里：Catalog 值首尾空白不可靠（英文曾黏成“22:13· PriceNov 14”）。
        let time = ms(generatedT).formatted(KitL10n.displayStyle(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz)))
        var parts = [String(localized: "响应生成 \(time)")]
        if let asOfT {
            let day = ms(asOfT).formatted(KitL10n.displayStyle(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: tz)))
            parts.append(String(localized: "价格 \(day)"))
        }
        return parts.joined(separator: " · ")
    }

    /// 「正在工作 N · 现在」：取实时 targets 的 working；断线 / 没有 state 时是 nil（显示「—」），不写 0。
    static func workingCount(targets: [TargetSummary]?, connected: Bool) -> Int? {
        guard connected, let targets else { return nil }
        return targets.filter { ThreadIdentity.status($0) == .working }.count
    }

    /// 参考价格新鲜度（只用服务器的 freshness）。
    static func freshnessText(_ f: String) -> String {
        switch f { case "current": String(localized: "价格表较新"); case "stale": String(localized: "价格表较旧"); case "excluded": String(localized: "价格表过旧，未用于估价"); default: f }
    }
    static func originText(_ o: String) -> String { o == "downloaded" ? String(localized: "已下载") : o == "bundled" ? String(localized: "随 App 内置") : o }
    static func updatePolicyText(_ p: String) -> String {
        switch p { case "startup_if_older_than_3d": String(localized: "Bridge 启动时，缓存超过 3 天才检查"); case "manual_only": String(localized: "仅手动更新"); default: p }
    }
}

// MARK: h11c 柱图堆叠 / 悬停浮层 / 铺满布局（纯逻辑）

extension UsageModel {
    /// 柱图数据：同一响应里筛到当前窗口的桶，整图前 3 个具名模型 + 其他（Kit UsageChartData，不在这里重算）。
    static func chartData(_ u: UsageResponse, _ w: UsageEstimateWindow, _ seg: UsageSegment) -> UsageChartData {
        UsageChartData.make(u, from: w.from, to: w.to, daily: seg != .today)
    }

    /// 模型 → 系列序号（0..<3）；不在前 3（含「其他」nil）→ nil（灰）。图 / 图例 / 浮层 / 模型表共用这一个映射。
    static func seriesIndex(_ model: String?, series: [String]) -> Int? { model.flatMap { series.firstIndex(of: $0) } }

    /// 悬停浮层的文字（固定最多 6 项：时间标题 / 总 token / 模型 A·B·C / 其他）；零总量写「本次记录无用量」；不放金额。
    struct Tip: Equatable {
        struct Row: Equatable, Identifiable {
            let name: String          // 模型名；其他写「其他」（不写「+N 个」）
            let colorIndex: Int?      // 系列色序号；nil = 其他灰
            let tokensText: String    // 紧凑 token
            let percent: Int
            var id: String { name + "|\(colorIndex.map(String.init) ?? "o")" }
        }
        let title: String
        let totalText: String
        let rows: [Row]
        let isEmpty: Bool
        static var emptyText: String { String(localized: "本次记录无用量") }
    }

    static func tip(_ bar: UsageChartData.Bar, series: [String]) -> Tip {
        let rows = bar.parts.map { p in Tip.Row(name: p.model ?? String(localized: "其他"), colorIndex: seriesIndex(p.model, series: series), tokensText: tokens(p.tokens), percent: p.percent) }
        return Tip(title: bar.title, totalText: tokens(bar.total), rows: rows, isEmpty: bar.total == 0)
    }

    /// 堆叠：一根柱的各部分按系列顺序（前 3 + 其他）累加出 [start, end)；各段合计恰为柱总量。
    struct Segment: Identifiable, Equatable {
        let part: UsageChartData.Part
        let start: Double
        let end: Double
        var id: String { part.id }
    }
    static func stack(_ bar: UsageChartData.Bar) -> [Segment] {
        var cum = 0.0
        return bar.parts.map { p in
            let seg = Segment(part: p, start: cum, end: cum + Double(p.tokens))
            cum = seg.end
            return seg
        }
    }

    /// Y 轴 domain：下界严格为 0（柱底落在 0 线上），上界 = 最高柱 × 1.08（顶部留白，最高柱不贴顶）；无数据仍是 0…1。图、选中高亮底共用，不随浮层 / 预留变化。
    static let yHeadroom = 1.08
    static func yDomain(_ data: UsageChartData) -> ClosedRange<Double> {
        let top = data.bars.map(\.total).max() ?? 0
        return top > 0 ? 0...(Double(top) * yHeadroom) : 0...1
    }

    /// 刻度步长：今日按 `hourStride`，近 7 天每天一个。分类轴上刻度由闭包按序号决定是否显示。
    static func isLabeledBar(_ data: UsageChartData, _ bar: UsageChartData.Bar, daily: Bool) -> Bool {
        guard let i = data.bars.firstIndex(where: { $0.id == bar.id }) else { return false }
        return i % (daily ? 1 : hourStride(barCount: data.bars.count)) == 0
    }

    /// 浮层相对选中竖线的摆放：选中柱在左半边时浮层放右侧，在右半边放左侧（留出 14pt 空隙），不盖住被选柱。
    static func tipOnTrailingSide(selected id: Int, in data: UsageChartData) -> Bool {
        guard let i = data.bars.firstIndex(where: { $0.id == id }) else { return true }
        return i < (data.bars.count + 1) / 2
    }

    /// 键盘逐桶移动：从当前选中桶（id = epoch ms）向左 / 右一根；没有选中时左键取最后一根、右键取第一根；到头停住。
    static func step(_ data: UsageChartData, from id: Int?, by delta: Int) -> Int? {
        guard !data.bars.isEmpty else { return nil }
        guard let id, let i = data.bars.firstIndex(where: { $0.id == id }) else { return delta < 0 ? data.bars.last?.id : data.bars.first?.id }
        return data.bars[min(max(i + delta, 0), data.bars.count - 1)].id
    }

    /// VoiceOver 逐桶朗读：时段、总 token、各模型占比。不对鼠标移动播报（只作为元素标签）。
    static func spokenSummary(_ bar: UsageChartData.Bar, series: [String]) -> String {
        let t = tip(bar, series: series)
        if t.isEmpty { return DisplayList.join([t.title, Tip.emptyText]) }
        return DisplayList.join([t.title, String(localized: "共 \(t.totalText) token")] + t.rows.map { String(localized: "\($0.name) \($0.tokensText)，\($0.percent)%") })
    }
}

/// 用量页卡片的纵向分栏与尺寸规则（D3）。
enum UsageLayout {
    /// O1-368：趋势（摘要 + 柱图）、账户额度、正在工作、活动时段、数据与价格、模型明细。
    enum Card: Hashable { case trend, account, working, activity, sources, modelTable }
    /// 宽窗两行配对（规格 3d1e685）：第 1 行 左「趋势」624 | 右「账户额度」416 + 16 + 「正在工作」192；
    /// 第 2 行 左「活动时段」336 | 右「数据与价格」336；第 3 行 模型明细通栏 288。
    struct Row: Equatable { let left: [Card]; let right: [Card] }
    static let rows: [Row] = [
        Row(left: [.trend], right: [.account, .working]),
        Row(left: [.activity], right: [.sources]),
    ]
    static let fullWidthRow: Card = .modelTable
    /// 窄窗单列顺序（规格）：摘要趋势 → 账户 → 活动 → 正在工作 → 模型明细 → 数据与价格。
    static let singleColumn: [Card] = [.trend, .account, .activity, .working, .modelTable, .sources]

    // 固定尺寸（宽窗，pt，含卡片内边距与边框）。验证等式：624 = 416 + 16 + 192；336 = 336。
    static let trendHeight: CGFloat = 624
    static let accountHeight: CGFloat = 416
    static let workingHeight: CGFloat = 192
    static let activityHeight: CGFloat = 336
    static let sourcesHeight: CGFloat = 336
    static let modelHeight: CGFloat = 288
    static let rowGap: CGFloat = 16
    static let rightWidth: CGFloat = 332
    static let columnSpacing: CGFloat = 16
    /// 宽窗断点按用量页的实际可用内容宽度（已扣侧栏与内边距）：内容宽 ≥ 960 双栏，否则单列自然高度。
    static let wideMinWidth: CGFloat = 960
    static func isWide(contentWidth: CGFloat) -> Bool { contentWidth >= wideMinWidth }

    /// 柱图绘图区：宽窗固定 320，窄窗 240（不随视口或状态变化）。
    static let chartWide: CGFloat = 320
    static let chartNarrow: CGFloat = 240
    static func chartHeight(wide: Bool) -> CGFloat { wide ? chartWide : chartNarrow }
    /// 热力格高度：宽窗 28（7 行总高 220），窄窗 18。
    static let heatCellWide: CGFloat = 28
    static let heatCellNarrow: CGFloat = 18
    static let heatGap: CGFloat = 4
    static func heatCellHeight(wide: Bool) -> CGFloat { wide ? heatCellWide : heatCellNarrow }
}

// MARK: #32 柱图：柱宽与今日时段占位（Mac 专用；iPhone 仍用 Kit 的 UsageChartData.barRatio）

extension UsageModel {
    static let macBarRatio = 0.55

    /// 时段的状态（R1 / R3）。事实口径只有这一处：
    /// present = 有正值数据；current = 当前小时还没有数据；future = 还没到（真实当前时间之后）；
    /// zero = 已确认截止之内且没有用量（确认为零）；gap = 已确认但响应没有覆盖全部小时；uncovered = 截止之后未确认（不能当成零）。
    enum SlotState: Equatable {
        case present, current, future, zero, gap, uncovered
    }
    struct Slot: Identifiable, Equatable {
        let key: String   // 与 UsageChartData.key 同格式：桶起点 epoch ms 的字符串
        let start: Int    // epoch ms
        let end: Int      // epoch ms（当天最后一个小时的终点截到次日 0 点）
        let state: SlotState
        var id: String { key }
    }

    /// 确认截止时间（单一来源）：扫描失败 → coverage.lastSuccessT（缺失即 nil = 未知）；否则有效快照 → generatedT。
    static func confirmedUntil(_ u: UsageResponse) -> Int? {
        if let c = u.coverage, c.refresh == "failed" { return c.lastSuccessT }
        return u.generatedT
    }
    static func nowMs(_ date: Date = Date()) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    /// 确认截止的文字（数据卡 / 图例共用）：未知时明说，不写一个假时间。
    static func confirmedText(_ u: UsageResponse, tz: TimeZone) -> String {
        guard let t = confirmedUntil(u) else { return String(localized: "确认截止未知") }
        return String(localized: "确认截止 \(ms(t).formatted(KitL10n.displayStyle(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz))))")
    }

    /// 今日的小时时段（响应时区的本机日历日，DST 当天 23 或 25 个）。时间语义只用 now 与 confirmed 两个输入。
    static func todaySlots(_ u: UsageResponse, _ w: UsageEstimateWindow, coversAll: Bool, now: Int, confirmed: Int?) -> [Slot] {
        let tz = timeZone(u)
        let cal = calendar(tz)
        let df = DateFormatter()
        df.calendar = cal; df.timeZone = tz; df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        guard let dayStart = df.date(from: w.from).map({ cal.startOfDay(for: $0) }),
              let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let dayEndMs = Int(dayEnd.timeIntervalSince1970 * 1000)
        let all = TokenKind.allCases.reduce(into: Set<TokenKind>()) { $0.insert($1) }
        var positive = Set<Int>()
        for b in u.buckets where b.byModel.values.reduce(0, { $0 + $1.total(all) }) > 0 { positive.insert(b.t) }
        var out: [Slot] = []
        var t = dayStart
        while t < dayEnd, out.count < 26 {
            guard let next = cal.date(byAdding: .hour, value: 1, to: t) else { break }
            let s = Int(t.timeIntervalSince1970 * 1000)
            let e = min(Int(next.timeIntervalSince1970 * 1000), dayEndMs)
            let state: SlotState
            if positive.contains(s) { state = .present }
            else if s > now { state = .future }
            else if now < e { state = .current }
            else if let c = confirmed, e <= c { state = coversAll ? .zero : .gap }
            else { state = .uncovered }
            out.append(Slot(key: String(s), start: s, end: e, state: state))
            t = next
        }
        return out
    }
}

// MARK: #32 标签宽度估计（Mac）：中文字符约一个字号宽，ASCII 约 0.6 个字号；比 Kit 的通用估计更保守，避免标签挤在一起。
extension UsageModel {
    static func labelEstimate(_ text: String, pointSize: CGFloat) -> CGFloat {
        let w = text.reduce(CGFloat(0)) { acc, ch in acc + (ch.isASCII ? 0.6 : 1.0) }
        return max(w, 1) * pointSize + 4
    }
}

// MARK: #32 数据状态卡的事实口径（可见文字与无障碍朗读共用）
extension UsageModel {
    /// 数据状态的全部事实：覆盖 / 重建中 / 离线旧值 / 更新失败、价格不确定、未报价、价格过期、确认截止。
    static func dataStatusFacts(_ u: UsageResponse, totals t: UsageEstimateTotals, offline: String?, failure: String?) -> [String] {
        var out: [String] = []
        if let cov = UsageAccuracy.coverageLine(u.coverage) { out.append(cov) }
        if let offline { out.append(offline) }
        if let failure { out.append(failure) }
        out += qualityBadges(t, scanPartial: false) // 扫描缺口已在上面的标题里说过；按参数排除，不比较译文
        out.append(confirmedText(u, tz: timeZone(u)))
        return out
    }
}
