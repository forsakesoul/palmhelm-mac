import SwiftUI
import Charts
import PalmhelmKit

// 用量页（宽屏 C1）：这台 Mac 的本地记录，按参考 API 价估算，不是账单 / 订阅额度。
// 今日｜近 7 天各请求自己的窗口（24h / 7d），卡 / 表 / 图都来自同一份响应，不跨响应拼接。
// 旧版 Bridge（无 estimate）走旧口径并明说；estimate.version ≠ 1 提示暂不支持。用量与价格刷新的状态都在 MacSession（与设置页共用）。
struct MacStatsView: View {
    @Environment(MacSession.self) private var session
    @Environment(BridgeEngine.self) private var engine
    @Environment(EngineSettings.self) private var settings
    @State private var segment: UsageSegment
    /// 初始分段：生产默认「今日」；截图与测试可指定（如近 30 天）。
    init(initialSegment: UsageSegment = .today) { _segment = State(initialValue: initialSegment) }
    @State private var dayStamp = Calendar.current.startOfDay(for: Date())

    @State private var viewport: CGSize = CGSize(width: 1200, height: 800)

    var body: some View {
        // 外层 GeometryReader 取可视区（扣工具栏后的视口，不是 ScrollView 内容高）：柱图高度与两栏 / 单列判断都据此
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    content
                }
                .padding(20)
                .coordinateSpace(name: "usagePage")
            }
            .onAppear { viewport = g.size }
            .onChange(of: g.size) { _, v in viewport = v }
        }
        .palmhelmAnimation(session.visibleUsage == nil)
        // App 启动时 Bridge 还没起来，连上后再拉一次；换分段、换连接、跨日、回到前台都重拉
        .task(id: "\(segment.rawValue)|\(session.link == .connected)|\(session.connectionId)|\(dayStamp.timeIntervalSince1970)") { await session.loadUsage(segment.window) }
        .task(id: "accounts|\(session.link == .connected)|\(session.connectionId)") { await session.loadAccounts() }
        // 近 30 天能力发现：每个连接探测一次（与今日快照隔离）；能力消失或换连接时，选中的第三档退回「今日」
        .task(id: "last30d|\(session.link == .connected)|\(session.connectionId)") { await session.probeLast30d() }
        .onChange(of: session.last30dAvailable) { _, available in if !available, segment == .last30d { segment = .today } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dayStamp = Calendar.current.startOfDay(for: Date())
            Task { await session.loadUsage(segment.window) }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            let today = Calendar.current.startOfDay(for: Date())
            if today != dayStamp { dayStamp = today } // 跨日：task(id:) 随之重拉
        }
    }

    // 页头：左「用量」大标题 + 口径说明；右侧控件组（范围切换 + 刷新，同高同圆角同底色，紧挨）与大标题垂直居中。
    // 窄窗放不下一行时，控件组换到标题下方左对齐，不重叠、不截断。
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("用量").font(.largeTitle.bold())
            // 副标题位固定一行（18pt）：正常时是口径说明，加载 / 失败 / 离线 / 刷新时替换为对应状态（O1-368 追加）
            Text(subtitle).font(.caption).foregroundStyle(subtitleTint).lineLimit(1).truncationMode(.tail).help(subtitle)
                .frame(height: 18, alignment: .leading)
        }
    }

    /// 本范围的快照（只有当前范围的响应才参与显示）。
    private var matchingUsage: UsageResponse? {
        guard let u = session.visibleUsage, u.window == segment.window.rawValue else { return nil }
        return u
    }
    private var pageState: UsagePageState {
        UsagePageState.from(hasData: matchingUsage != nil, loading: session.usageLoading, settled: session.usageSettledWindow == segment.window.rawValue, error: session.usageError?.text, connected: session.link == .connected)
    }
    private var subtitle: String {
        let refreshing = session.usageLoading && matchingUsage != nil
        let t = session.usageFetchedAt.map { $0.shown(date: .omitted, time: .shortened) }
        return pageState.headline(defaultText: String(localized: "这台 Mac 的本地记录 · 按参考 API 价估算 · 不是账单 / 订阅额度"), lastUpdated: t, refreshing: refreshing, offline: session.link != .connected, failure: session.usageError?.text)
    }
    private var subtitleTint: Color {
        switch pageState { case .failed: PalmhelmTheme.bad; case .disconnected, .empty: .secondary; case .loading: .secondary; case .ready: session.usageError != nil || session.link != .connected ? PalmhelmTheme.warn : .secondary }
    }
    private var controls: some View {
        HStack(spacing: 8) {
            PalmhelmSegmented(options: UsageSegment.visible(last30dAvailable: session.last30dAvailable).map { ($0, $0.label) }, selection: $segment, segmentWidth: 88)
            RefreshButton(loading: session.usageLoading) { Task { await session.loadUsage(segment.window) } }
        }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { titleBlock; Spacer(minLength: 16); controls }
            VStack(alignment: .leading, spacing: 10) { titleBlock; controls }
        }
    }

    /// 页面主体（O1-368 追加）：网格始终是同一套卡位；有快照时填入数据，否则各卡内显示占位。旧口径（旧版 Bridge / 不支持的估价版本）仍走原来的说明。
    @ViewBuilder private var content: some View {
        // 账户额度独立于本地用量口径：旧口径 / 未知版本 / 缺范围时，只在用量说明处给出原因，账户卡仍然显示（A1-194 R5）
        if let u = matchingUsage, case .v1(let e) = UsageModel.mode(u), UsageModel.optionalWindow(e, segment) == nil {
            AccountsSection()
            Text("这个 Bridge 版本没有「\(segment.label)」的数据，请升级 Bridge。").font(.caption.weight(.semibold)).foregroundStyle(PalmhelmTheme.warn)
        } else if let u = matchingUsage, case .legacy = UsageModel.mode(u) {
            AccountsSection()
            Text("旧版 Bridge，仅提供旧版估算").font(.caption.weight(.semibold)).foregroundStyle(PalmhelmTheme.warn)
            LegacyUsage(u: u, showMoney: true)
        } else if let u = matchingUsage, case .unsupported = UsageModel.mode(u) {
            AccountsSection()
            Text("暂不支持该估价版本").font(.caption.weight(.semibold)).foregroundStyle(PalmhelmTheme.warn)
            LegacyUsage(u: u, showMoney: false)
        } else {
            V1Usage(grid: matchingUsage.flatMap { UsageGridData($0, segment: segment) }, state: pageState, segment: segment, viewport: viewport)
        }
    }
}

/// 刷新按钮：与范围切换同高（28）、同圆角（8）、同底色；进行中图标换成小号转圈，按钮尺寸不变不跳动。
struct RefreshButton: View {
    let loading: Bool
    var help = String(localized: "重新读取用量")   // 悬停说明与 AX 标签（账户卡传「刷新额度」）
    var label = String(localized: "刷新用量")
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(loading ? 0 : 1)
                if loading { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
            .frame(width: 28, height: 28)
            .background(PalmhelmTheme.card2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: 新口径（estimate v1）

/// 卡位上报（O1-368 追加）：测试与截图用，把每张网格卡在用量页坐标系里的 frame 记下来，用来证明各状态零位移。生产为 nil，不影响布局。
final class UsageCardFrames: @unchecked Sendable {
    var frames: [String: CGRect] = [:]
}
private struct UsageCardFramesKey: EnvironmentKey { static let defaultValue: UsageCardFrames? = nil }
extension EnvironmentValues {
    var usageCardFrames: UsageCardFrames? { get { self[UsageCardFramesKey.self] } set { self[UsageCardFramesKey.self] = newValue } }
}
private struct CardFrameReporter: ViewModifier {
    let id: String
    @Environment(\.usageCardFrames) private var sink
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("usagePage")) } action: { r in sink?.frames[id] = r }
    }
}
extension View {
    fileprivate func reportCardFrame(_ id: String) -> some View { modifier(CardFrameReporter(id: id)) }
}

/// 一次成功快照派生出的全部数据（网格各卡共用，保证不同卡之间不会用不同响应）。
struct UsageGridData {
    let u: UsageResponse
    let e: UsageEstimate
    let w: UsageEstimateWindow
    let data: UsageChartData
    init?(_ u: UsageResponse, segment: UsageSegment) {
        guard case .v1(let e) = UsageModel.mode(u), UsageModel.optionalWindow(e, segment) != nil else { return nil }
        self.u = u; self.e = e; self.w = UsageModel.window(e, segment); self.data = UsageModel.chartData(u, self.w, segment)
    }
}

/// 柱图区的占位（O1-368 追加）：加载中用骨架条，其余用说明；高度与真实绘图区（含标签带）相同。
private struct ChartPlaceholder: View {
    let state: UsagePageState
    let height: CGFloat
    var body: some View {
        ZStack {
            if case .loading = state { SkeletonBlock(height: height, cornerRadius: 8) }
            else { RoundedRectangle(cornerRadius: 8).fill(PalmhelmTheme.card2.opacity(0.5)).overlay(Text(TrendCard.placeholderLine(state)).font(.caption).foregroundStyle(.secondary)) }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .accessibilityLabel(TrendCard.placeholderLine(state))
    }
}

/// 固定网格（O1-368 追加）：加载 / 首次无数据 / 失败 / 未连接 / 有数据，全部走同一套卡位与尺寸；
/// 没有数据时只在各卡内部原位显示占位（骨架或说明），外层布局不变。
private struct V1Usage: View {
    @Environment(\.usageNow) private var usageNow
    @Environment(MacSession.self) private var session
    let grid: UsageGridData?
    let state: UsagePageState
    let segment: UsageSegment
    let viewport: CGSize

    /// 每张卡在宽窗与窄窗下的尺寸：宽窗固定（不随状态、数量或内容变化），窄窗自然高度。
    @ViewBuilder private func card(_ c: UsageLayout.Card, wide: Bool) -> some View {
        switch c {
        case .trend: TimelineView(.periodic(from: .now, by: 30)) { ctx in
            TrendCard(grid: grid, state: state, segment: segment, wide: wide, now: usageNow ?? UsageModel.nowMs(ctx.date))
        }
        .reportCardFrame("trend")
        case .account: AccountsSection(fixedHeight: wide ? UsageLayout.accountHeight : nil).reportCardFrame("account")
        case .working: WorkingCard(fixedHeight: wide ? UsageLayout.workingHeight : nil).reportCardFrame("working")
        case .activity: ActivityCard(u: grid?.u, state: state, fixedHeight: wide ? UsageLayout.activityHeight : nil, cellHeight: UsageLayout.heatCellHeight(wide: wide)).reportCardFrame("activity")
        case .sources: SourcesCard(e: grid?.e, state: state, fixedHeight: wide ? UsageLayout.sourcesHeight : nil).reportCardFrame("sources")
        case .modelTable: ModelTable(w: grid?.w, e: grid?.e, series: grid?.data.series ?? [], state: state, fixedHeight: wide ? UsageLayout.modelHeight : nil).reportCardFrame("modelTable")
        }
    }

    var body: some View {
        let wide = UsageLayout.isWide(contentWidth: viewport.width - 40)
        Group {
            if wide {
                // 两行配对：行内两栏顶对齐；右栏固定宽 332；卡高固定（624 = 416 + 16 + 192；336 = 336）。
                VStack(alignment: .leading, spacing: UsageLayout.rowGap) {
                    HStack(alignment: .top, spacing: UsageLayout.columnSpacing) {
                        card(.trend, wide: true).frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(spacing: UsageLayout.rowGap) {
                            card(.account, wide: true)
                            card(.working, wide: true)
                        }
                        .frame(width: UsageLayout.rightWidth, alignment: .topLeading)
                    }
                    HStack(alignment: .top, spacing: UsageLayout.columnSpacing) {
                        card(.activity, wide: true).frame(maxWidth: .infinity, alignment: .topLeading)
                        card(.sources, wide: true).frame(width: UsageLayout.rightWidth, alignment: .topLeading)
                    }
                    card(UsageLayout.fullWidthRow, wide: true)
                }
            } else {
                VStack(spacing: 14) { ForEach(UsageLayout.singleColumn, id: \.self) { card($0, wide: false) } }
            }
        }
        .environment(\.cardPadding, 16) // V1：只在用量页把卡片内边距落实为 16pt
    }
}

/// 趋势卡（O1-368 左 1）：顶部 Token 总计 / 估算金额两项大数；其下数据状态一行；柱图（嵌入，不另起卡片）。
/// 宽窗固定 624pt（wide），窄窗自然高度。没有数据时：大数显示 —，柱图区显示占位（骨架或说明），卡位不变。
private struct TrendCard: View {
    @Environment(MacSession.self) private var session
    let grid: UsageGridData?
    let state: UsagePageState
    let segment: UsageSegment
    let wide: Bool
    let now: Int
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let g = grid {
                let t = g.w.totals
                HStack(alignment: .top, spacing: 28) {
                    summary(title: String(localized: "Token 总计"), value: t.tokens.total.shown, caption: String(localized: "\(segment.label) · 含缓存"))
                        .accessibilityLabel("\(segment.label)，token 总计 \(t.tokens.total.shown)，含缓存")
                    summary(title: String(localized: "≈ 估算金额"), value: UsageModel.usd(t.costUsd), caption: t.costUsd == nil ? String(localized: "没有可估价的部分") : t.hasUnpriced ? String(localized: "可估价部分 · 另有未报价") : String(localized: "可估价部分 · 参考 API 价"))
                        .accessibilityLabel(t.hasUnpriced ? String(localized: "估算 \(UsageModel.usd(t.costUsd))，可估价部分，另有未报价") : String(localized: "估算 \(UsageModel.usd(t.costUsd))，可估价部分，参考 API 价"))
                    Spacer(minLength: 0)
                }
                statusRow(g)
                ChartCard(u: g.u, w: g.w, segment: segment, data: g.data, plotHeight: UsageLayout.chartHeight(wide: wide), now: now)
                Text("悬停或用 ← → 查看单个时段；点按「详情」看缺口原因。").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(UsageModel.timesLine(generatedT: g.u.generatedT, asOfT: g.e.pricing.asOfT, tz: UsageModel.timeZone(g.u)))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    summary(title: String(localized: "Token 总计"), value: "—", caption: String(localized: "\(segment.label) · 含缓存"))
                    summary(title: String(localized: "≈ 估算金额"), value: "—", caption: String(localized: "参考 API 价"))
                    Spacer(minLength: 0)
                }
                Text(Self.placeholderLine(state)).font(.caption).foregroundStyle(.secondary)
                ChartPlaceholder(state: state, height: UsageLayout.chartHeight(wide: wide) + UsageChartLayout.labelBand(scale: 1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil, alignment: .topLeading)
        .card()
        .frame(height: wide ? UsageLayout.trendHeight : nil)
    }

    /// 没有数据时的一行说明（卡内，不改卡位）。
    static func placeholderLine(_ state: UsagePageState) -> String {
        switch state {
        case .loading: String(localized: "正在加载这个范围的用量…")
        case .empty: String(localized: "这个范围还没有用量记录。")
        case .failed(let e): String(localized: "加载失败 · \(e)")
        case .disconnected: String(localized: "未连接这台 Mac，连上后自动加载。")
        case .ready: ""
        }
    }

    private func summary(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// 数据状态（S1）：覆盖 / 完整 / 缺口、更新失败、离线旧值、重建中直接显示；价格不确定、未报价、价格过期也直接写出。
    private func statusRow(_ g: UsageGridData) -> some View {
        let u = g.u, t = g.w.totals, e = g.e
        let cov = UsageAccuracy.coverageLine(u.coverage)
        let offline = session.link != .connected ? session.usageFetchedAt.map { String(localized: "离线 · 显示 \($0.shown(date: .omitted, time: .shortened)) 的上次数据") } : nil
        let failure = session.usageError.map { String(localized: "更新失败 · \($0.text)，下面是上次结果") }
        let headline = u.partial ? String(localized: "扫描有缺口") : (cov == nil ? String(localized: "已完整") : String(localized: "覆盖进度"))
        let facts = UsageModel.dataStatusFacts(u, totals: t, offline: offline, failure: failure)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("数据状态：\(headline)").font(.caption.weight(.semibold)).foregroundStyle(u.partial ? PalmhelmTheme.warn : .primary)
                Text(UsageModel.confirmedText(u, tz: UsageModel.timeZone(u))).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("详情") { showDetail = true }.controlSize(.small).buttonStyle(.borderless)
                    .popover(isPresented: $showDetail, arrowEdge: .bottom) { detail(g) }
            }
            if let cov { Text(cov).font(.caption2).foregroundStyle(PalmhelmTheme.warn).lineLimit(1) }
            if let offline { Text(offline).font(.caption2).foregroundStyle(PalmhelmTheme.warn).lineLimit(1) }
            if let failure { Text(failure).font(.caption2).foregroundStyle(PalmhelmTheme.bad).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("数据状态：\(headline)" + facts.map { "，\($0)" }.joined())
    }

    @ViewBuilder private func detail(_ g: UsageGridData) -> some View {
        let u = g.u, t = g.w.totals, e = g.e
        VStack(alignment: .leading, spacing: 8) {
            Text("缺口原因").font(.headline)
            if u.partial, !u.reasons.isEmpty { Text(u.reasons.map(UsageCopy.reason).joined(separator: "；")).font(.caption) }
            else { Text("本次没有扫描缺口。").font(.caption).foregroundStyle(.secondary) }
            if (t.ttlUnknownTokens ?? 0) > 0 { Text(UsageCopy.reason("cache_ttl_unknown")).font(.caption).foregroundStyle(.secondary) }
            ForEach(UsageModel.truncationNotes(e), id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            Text(UsageModel.timesLine(generatedT: u.generatedT, asOfT: e.pricing.asOfT, tz: UsageModel.timeZone(u))).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 300, alignment: .leading)
    }
}

/// 当前时段（纯函数，便于类型检查与测试）。
fileprivate func currentSlot(_ slots: [UsageModel.Slot], now: Int) -> UsageModel.Slot? {
    slots.first { $0.start <= now && now < $0.end }
}
fileprivate func nowFraction(_ cur: UsageModel.Slot, now: Int) -> Double {
    Double(now - cur.start) / Double(max(1, cur.end - cur.start))
}

struct ChartCard: View {
    let u: UsageResponse
    let w: UsageEstimateWindow
    let segment: UsageSegment
    /// 统一的当前时间（毫秒）：现在线、未到 / 当前 / 过去的分类、图例都只用它；由外层 TimelineView 按分钟刷新，截图可固定。
    let now: Int
    let data: UsageChartData
    let plotHeight: CGFloat
    var probe: ChartProbe? = nil // 测试接缝（生产为 nil）
    var axisLabelMeasured: ((String) -> Void)? = nil // 测试接缝：实际最大标签宽度估计；生产为 nil。
    @State private var rawSelectedKey: String?   // 悬停的类目键（桶起点 epoch ms 的字符串）；分类轴，柱子居中于类目
    @State private var selectedKey: String?  // 悬停或键盘选中的类目键（含占位时段）；离开 / 切范围 / 响应更新时清除
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorScheme) private var colorScheme
    /// 系列填充：颜色（当前家族）；系统「区分时不仅依赖颜色」开启时为纹理（O1-359 R2）。图与图例共用。
    private func seriesFill(_ index: Int?) -> AnyShapeStyle {
        UsageSeriesTexture.fill(index, family: PalmhelmThemeStore.shared.family, dark: colorScheme == .dark, differentiate: differentiateWithoutColor)
    }

    init(u: UsageResponse, w: UsageEstimateWindow, segment: UsageSegment, data: UsageChartData, plotHeight: CGFloat, probe: ChartProbe? = nil, initialSelection: Int? = nil, now: Int? = nil, axisLabelMeasured: ((String) -> Void)? = nil) {
        self.u = u; self.w = w; self.segment = segment; self.data = data; self.plotHeight = plotHeight; self.probe = probe
        self.now = now ?? UsageModel.nowMs()
        self.axisLabelMeasured = axisLabelMeasured
        _selectedKey = State(initialValue: initialSelection.map(String.init))
    }
    @FocusState private var focused: Bool
    @Environment(\.plotReporter) private var plotReporter

    private var bars: [UsageChartData.Bar] { data.bars }
    private var selectedBar: UsageChartData.Bar? { selectedKey.flatMap { k in data.bar(key: k) } }
    private var hasOther: Bool { bars.contains { $0.parts.contains { $0.model == nil } } }
    /// 标签步长：按绘图区宽度与最长标签估计宽度自适应（UsageChartLayout，Mac 字号固定）。
    private func labelStep(_ plotWidth: CGFloat, count: Int, labelWidth: CGFloat) -> Int {
        UsageChartLayout.labelStride(count: count, plotWidth: plotWidth, labelWidth: labelWidth)
    }
    /// 类目轴：今日 = 全部小时时段（含占位），近 7 天 = 响应里的日桶。标签与类目域共用这一份，不会错位。
    struct AxisItem: Equatable { let key: String; let start: Date }

    var body: some View {
        let c = UsageModel.chart(u, segment, window: w)
        let tz = data.timeZone
        let confirmed = UsageModel.confirmedUntil(u)
        let slots = c.daily ? [] : UsageModel.todaySlots(u, w, coversAll: c.coversAll, now: now, confirmed: confirmed)
        // Audio Graph：正值时段 + 已确认的真零桶；未到 / 覆盖不足 / 未覆盖 不进入数据点（服务端补出的 0 不是确认为零）
        let audioKeys: Set<String>? = c.daily ? nil : Set(slots.filter { $0.state == .present || $0.state == .zero }.map(\.key))
        let axis: [AxisItem] = slots.isEmpty
            ? bars.map { AxisItem(key: UsageChartData.key($0), start: $0.start) }
            : slots.map { AxisItem(key: $0.key, start: Date(timeIntervalSince1970: Double($0.start) / 1000)) }
        let format = UsageModel.axisFormat(daily: c.daily, tz: tz)
        let labels = axis.map { $0.start.formatted(format) }
        let longestText = labels.max { $0.count < $1.count } ?? ""
        let labelWidth = UsageModel.labelEstimate(longestText, pointSize: 11)
        let _ = axisLabelMeasured?(longestText)
        let selIdx = selectedKey.flatMap { k in axis.firstIndex { $0.key == k } }
        let selSlot = selectedKey.flatMap { k in slots.first { $0.key == k } }
        let maxTotal = max(1, bars.map(\.total).max() ?? 1)
        let gap = Double(maxTotal) * 0.004
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token").font(.headline)
                Spacer()
                Text(String(localized: "\(c.daily ? String(localized: "按日") : String(localized: "按小时")) · 时区 \(tz.identifier)")).font(.caption).foregroundStyle(.secondary)
            }
            do {
                Chart {
                    // 今日的未到 / 覆盖不足时段：只画淡色占位（不是用量）
                    ForEach(slots.filter { $0.state == .future || $0.state == .gap }) { sl in
                        RectangleMark(x: .value(String(localized: "时段"), sl.key), yStart: .value(String(localized: "下"), 0), yEnd: .value(String(localized: "上"), UsageModel.yDomain(data).upperBound), width: .ratio(UsageModel.macBarRatio))
                            .foregroundStyle(Self.placeholderFill(sl.state))
                            .accessibilityHidden(true)
                    }
                    ForEach(bars) { bar in
                        ForEach(UsageModel.stack(bar)) { seg in
                            let p = seg.part
                            // 段间留细分隔：每段上沿让出一条极细的缝（只在段足够高时），颜色取固定系列色
                            BarMark(x: .value(String(localized: "时段"), UsageChartData.key(bar)), yStart: .value(String(localized: "起"), seg.start), yEnd: .value(String(localized: "止"), Double(p.tokens) > gap * 3 ? seg.end - gap : seg.end), width: .ratio(UsageModel.macBarRatio))
                                .cornerRadius(3)
                                .foregroundStyle(seriesFill(UsageModel.seriesIndex(p.model, series: data.series)))
                                .accessibilityLabel(bar.title)
                                .accessibilityValue(String(localized: "\(p.model ?? String(localized: "其他")) \(UsageModel.tokens(p.tokens))，\(p.percent)%"))
                        }
                    }
                    if let k = selectedKey {
                        RectangleMark(x: .value(String(localized: "选中"), k), yStart: .value(String(localized: "下"), 0), yEnd: .value(String(localized: "上"), UsageModel.yDomain(data).upperBound), width: .ratio(1))
                            .foregroundStyle(Color.primary.opacity(0.10)) // 选中时段的轮廓 / 高亮底（柱子或占位）
                            .accessibilityHidden(true)
                        RuleMark(x: .value(String(localized: "选中"), k))
                            .foregroundStyle(Color.primary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .accessibilityHidden(true)
                            // 浮层放在图内（.overlay，贴顶）：选中在左半边时放在竖线右侧，反之放左侧
                            .annotation(position: .overlay, alignment: (selectedBar.map { UsageModel.tipOnTrailingSide(selected: $0.id, in: data) } ?? ((selIdx ?? 0) < axis.count / 2)) ? .topLeading : .topTrailing, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                // 选中说明由 slot 状态决定（不因原始桶存在而显示「确认为零」）
                                switch Self.selectionTip(slot: selSlot, bar: selectedBar) {
                                case .slot: SlotTipView(title: Self.slotTitle(selSlot!, tz: tz), text: Self.slotText(selSlot!)).padding(.horizontal, 14)
                                case .bar: TipView(tip: UsageModel.tip(selectedBar!, series: data.series)).padding(.horizontal, 14)
                                case .none: EmptyView()
                                }
                            }
                    }
                }
                .chartXSelection(value: $rawSelectedKey)
                // 类目域显式给出全部桶的键：零桶（没有 mark）也占有自己的类目；键盘选中零桶时不会临时追加类别、其他柱子不移动
                .chartXScale(domain: axis.map(\.key))
                // 内置 x 轴隐藏：分类轴上 AxisMarks 的标签位置不可靠（小时图会错位一个类目）。标签与网格线改由 chartBackground / chartOverlay 按柱子中心摆放（proxy.position）。
                .chartXAxis(.hidden)
                .chartPlotStyle { $0.padding(.bottom, UsageChartLayout.labelBand(scale: 1)) } // 底部留出标签的位置
                .chartBackground { proxy in
                    GeometryReader { g in
                        if let plot = proxy.plotFrame {
                            let st = labelStep(g[plot].width, count: axis.count, labelWidth: labelWidth)
                            ForEach(Array(axis.enumerated()).filter { $0.offset % st == 0 }, id: \.offset) { item in
                                if let x = proxy.position(forX: item.element.key) {
                                    Path { p in
                                        p.move(to: CGPoint(x: g[plot].minX + x, y: g[plot].minY))
                                        p.addLine(to: CGPoint(x: g[plot].minX + x, y: g[plot].maxY))
                                    }
                                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                }
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { g in
                        let _ = probe?.attach(proxy) // 测试接缝：真实 ChartProxy 坐标（生产为 nil）
                        if let plot = proxy.plotFrame {
                            Color.clear.frame(width: 0, height: 0)
                                .onAppear { plotReporter?.report(g[plot].height) }
                                .onChange(of: g[plot].height) { _, h in plotReporter?.report(h) }
                        }
                        if let plot = proxy.plotFrame, let cur = currentSlot(slots, now: now),
                           let cx = proxy.position(forX: cur.key), !slots.isEmpty {
                            // 「现在」：按真实当前时间画在当前小时的类目内（不画在整点上）
                            let cat: CGFloat = g[plot].width / CGFloat(slots.count)
                            let frac: Double = nowFraction(cur, now: now)
                            let x = g[plot].minX + cx - cat / 2 + cat * CGFloat(frac)
                            Path { p in
                                p.move(to: CGPoint(x: x, y: g[plot].minY))
                                p.addLine(to: CGPoint(x: x, y: g[plot].maxY))
                            }
                            .stroke(PalmhelmTheme.card, lineWidth: 4) // 底衬：叠在柱子上也能辨认（O1-356）
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            Path { p in
                                p.move(to: CGPoint(x: x, y: g[plot].minY))
                                p.addLine(to: CGPoint(x: x, y: g[plot].maxY))
                            }
                            .stroke(PalmhelmTheme.accent, lineWidth: 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            Text("现在 " + Self.clock(now, tz)).font(.caption2.weight(.semibold)).foregroundStyle(PalmhelmTheme.accent)
                                .fixedSize()
                                .position(x: min(max(x, g[plot].minX + 36), g[plot].maxX - 36), y: g[plot].minY + 7)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        if let plot = proxy.plotFrame, slots.count > 0 {
                            let cat = g[plot].width / CGFloat(slots.count)
                            ForEach(slots.filter { $0.state == .uncovered }) { sl in
                                if let x = proxy.position(forX: sl.key) {
                                    HatchFill().frame(width: cat, height: g[plot].height).clipped()
                                        .position(x: g[plot].minX + x, y: g[plot].midY)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                        }
                        if let plot = proxy.plotFrame {
                            let st = labelStep(g[plot].width, count: axis.count, labelWidth: labelWidth)
                            ForEach(Array(axis.enumerated()).filter { $0.offset % st == 0 }, id: \.offset) { item in
                                if let x = proxy.position(forX: item.element.key) {
                                    Text(labels[item.offset])
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                        .position(x: g[plot].minX + x, y: g[plot].maxY + UsageChartLayout.labelBand(scale: 1) / 2)
                                }
                            }
                        }
                    }
                    .allowsHitTesting(false) // 标签不挡悬停选择
                }
                .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18)); AxisValueLabel { if let n = v.as(Int.self) { Text(UsageModel.tokens(n)) } } } }
                .chartYScale(domain: UsageModel.yDomain(data)) // 下界严格为 0：柱底落在 0 线上；上界留 8% 空白，最高柱不贴顶
                .environment(\.calendar, UsageModel.calendar(tz))
                .environment(\.timeZone, tz)
                .frame(height: plotHeight + UsageChartLayout.labelBand(scale: 1)) // 绘图区固定高度（O1-368）：不随视口或状态伸缩
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(PalmhelmTheme.accent, lineWidth: focused ? 2 : 0))
                .onKeyPress(.leftArrow) { selectedKey = Self.stepKey(axis, selectedKey, -1); return .handled } // 键盘覆盖全部类目（含占位）
                .onKeyPress(.rightArrow) { selectedKey = Self.stepKey(axis, selectedKey, 1); return .handled }
                .onKeyPress(.escape) { selectedKey = nil; rawSelectedKey = nil; return .handled }
                .onChange(of: rawSelectedKey) { _, k in selectedKey = k } // 悬停 → 类目；离开（nil）清除
                .accessibilityLabel("\(segment.label)用量柱图，按模型堆叠")
                .accessibilityChartDescriptor(UsageAudioGraph(data: data, keys: audioKeys)) // Audio Graph 概览；鼠标移动不播报
                if bars.allSatisfy({ $0.total == 0 }) { Text("本次没有用量：已确认时段内为零，占位与交互照常可用。").font(.caption).foregroundStyle(.secondary) }
                if !slots.isEmpty { slotLegend(slots) }
                legend
                if !c.coversAll { Text("小时数据未覆盖今日全部时段").font(.caption2).foregroundStyle(.secondary) } // 不补 0、不用差值捏造
            }
        }
        .onChange(of: data) { _, _ in selectedKey = nil; rawSelectedKey = nil } // 响应更新 / 切范围：清除选中
    }

    /// 键盘步进：沿完整类目数组（含占位）移动，两端不回绕；没有选中时从对应端开始。
    static func stepKey(_ axis: [AxisItem], _ key: String?, _ d: Int) -> String? {
        guard !axis.isEmpty else { return nil }
        guard let k = key, let i = axis.firstIndex(where: { $0.key == k }) else { return d > 0 ? axis.first?.key : axis.last?.key }
        return axis[min(max(i + d, 0), axis.count - 1)].key
    }
    /// 占位时段的标题与说明（只读状态，不写数值）。
    static func slotTitle(_ sl: UsageModel.Slot, tz: TimeZone) -> String {
        let f = KitL10n.displayStyle(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz))
        return Date(timeIntervalSince1970: Double(sl.start) / 1000).formatted(f) + "–" + Date(timeIntervalSince1970: Double(sl.end) / 1000).formatted(f)
    }
    static func slotText(_ sl: UsageModel.Slot) -> String {
        switch sl.state {
        case .future: String(localized: "还没到")
        case .gap: String(localized: "数据没覆盖到")
        case .uncovered: String(localized: "未覆盖：确认截止之后，这一时段还没有确认")
        case .zero: UsageModel.Tip.emptyText
        case .current: String(localized: "当前小时，还没有记录")
        case .present: ""
        }
    }

    /// 今日占位的含义：灰 = 还没到，琥珀 = 覆盖不足，空白 = 已过但为零；竖线 = 现在；数据截止时间单独写出。
    private func slotLegend(_ slots: [UsageModel.Slot]) -> some View {
        let f = KitL10n.displayStyle(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: data.timeZone))
        let confirmed = UsageModel.confirmedText(u, tz: data.timeZone)
        let nowText = Date(timeIntervalSince1970: Double(now) / 1000).formatted(f)
        let has = Set(slots.map(\.state))
        var parts: [String] = []
        if has.contains(.future) { parts.append(String(localized: "灰 = 还没到")) }
        if has.contains(.gap) { parts.append(String(localized: "琥珀 = 覆盖不足")) }
        if has.contains(.uncovered) { parts.append(String(localized: "浅灰斜纹 = 未覆盖")) }
        parts.append(String(localized: "空白 = 已确认为零"))
        // 只有 now 落在所展示日期内、存在当前时段时，才写「竖线 = 现在」
        if slots.contains(where: { $0.start <= now && now < $0.end }) { parts.append(String(localized: "竖线 = 现在 \(nowText)")) }
        return Text(parts.joined(separator: " · ") + "；" + confirmed)
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("占位说明：" + parts.joined(separator: "，") + "，" + confirmed)
    }

    /// 占位配色（只用于未到 / 覆盖不足 / 未覆盖；不是用量）。
    static func placeholderFill(_ st: UsageModel.SlotState) -> Color {
        switch st {
        case .future: Color.primary.opacity(0.05)
        case .gap: PalmhelmTheme.warn.opacity(0.14)
        case .uncovered: Color.secondary.opacity(0.10)
        default: .clear
        }
    }

    /// 图例：色块 · 模型名（可换行，长名中间截断，悬停看全名）；有「其他」才列「其他」。
    private var legend: some View {
        WrapLayout(spacing: 12, lineSpacing: 4) {
            ForEach(Array(data.series.enumerated()), id: \.offset) { i, name in legendItem(name, fill: seriesFill(i)) }
            if hasOther { legendItem(String(localized: "其他"), fill: seriesFill(nil)) }
        }
        .accessibilityElement(children: .contain)
    }
    private func legendItem(_ name: String, fill: AnyShapeStyle) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(fill).frame(width: 10, height: 10)
            Text(name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
        }
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }
}

/// 绘图区高度报告对象（测试 / 截图接缝；生产为 nil）。只在主线程使用。
final class PlotReporter: @unchecked Sendable {
    private(set) var heights: [CGFloat] = []
    func report(_ h: CGFloat) { heights.append(h) }
}
private struct PlotReporterKey: EnvironmentKey { static let defaultValue: PlotReporter? = nil }
extension EnvironmentValues {
    var plotReporter: PlotReporter? { get { self[PlotReporterKey.self] } set { self[PlotReporterKey.self] = newValue } }
}

/// 选中说明的种类：由 slot 状态决定。未到 / 未覆盖 / 覆盖不足 / 当前 / 确认为零 → slot；有正值数据 → bar。
enum ChartTipKind: Equatable { case bar, slot, none }
extension ChartCard {
    static func selectionTip(slot: UsageModel.Slot?, bar: UsageChartData.Bar?) -> ChartTipKind {
        if let slot, slot.state != .present { return .slot }
        return bar == nil ? .none : .bar
    }
    /// 时刻的时分（用于现在线标签与图例），按响应时区。
    static func clock(_ ms: Int, _ tz: TimeZone) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(KitL10n.displayStyle(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz)))
    }
}

/// 未覆盖的装饰纹理：稀疏斜纹（hidden，不拦鼠标；图例写的是「斜纹」）。
private struct HatchFill: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6
            }
            ctx.stroke(p, with: .color(Color.secondary.opacity(0.45)), lineWidth: 0.8)
        }
    }
}

/// 截图 / 测试接缝：固定的当前时间（毫秒）。生产为 nil，由 TimelineView 提供。
private struct UsageNowKey: EnvironmentKey { static let defaultValue: Int? = nil }
extension EnvironmentValues {
    var usageNow: Int? { get { self[UsageNowKey.self] } set { self[UsageNowKey.self] = newValue } }
}

/// 占位时段的浮层（没有柱子）：时间段 + 一句说明。
private struct SlotTipView: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(PalmhelmTheme.card2, in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 悬停浮层：时间标题 / 总 token（大号）/ 各部分（色块 · 名称 · 紧凑 token · %）。不放金额；零总量写「本次记录无用量」。辅助字号下允许换行。
private struct TipView: View {
    let tip: UsageModel.Tip
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tip.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if tip.isEmpty {
                Text(UsageModel.Tip.emptyText).font(.callout)
            } else {
                Text(tip.totalText + " token").font(.title3.weight(.bold)).monospacedDigit()
                ForEach(tip.rows) { r in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(UsageSeriesColor.color(r.colorIndex, family: PalmhelmThemeStore.shared.family)).frame(width: 9, height: 9)
                        // 模型名单行 + 中间省略（辅助字号很大时才允许换行，不固定高度裁字）；token 与 % 两列右对齐等宽数字
                        Text(r.name).font(.caption).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.middle).help(r.name)
                        Spacer(minLength: 8)
                        Text(r.tokensText).font(.caption).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                        Text("\(r.percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 36, alignment: .trailing)
                    }
                }
            }
        }
        .padding(10)
        .frame(minWidth: 260, idealWidth: 280, maxWidth: 320, alignment: .leading) // 放得下常见模型名（如 claude-sonnet-5-5），不折行
        .background(PalmhelmTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .allowsHitTesting(false) // 浮层不抢鼠标：悬停不抖动
        .accessibilityHidden(true) // 逐桶朗读走图表元素与 Audio Graph，不对鼠标移动播报
    }
}

/// Audio Graph 概览：每根桶一个点（总 token）。make 与 update 共用同一套构造，同一 Chart 切范围 / 响应刷新后描述器随之改写（默认的 update 不会重建）。
struct UsageAudioGraph: AXChartDescriptorRepresentable {
    let data: UsageChartData
    /// 允许进入 Audio Graph 的类目键（今日 = 已观测正值的时段）；nil = 全部桶（近 7 / 30 天）。
    var keys: Set<String>? = nil

    /// 描述器各部分（make 新建、update 原地改写都用它）。
    static func parts(_ data: UsageChartData, keys: Set<String>? = nil) -> (title: String, summary: String, x: AXCategoricalDataAxisDescriptor, y: AXNumericDataAxisDescriptor, series: [AXDataSeriesDescriptor]) {
        let bars = keys.map { k in data.bars.filter { k.contains(UsageChartData.key($0)) } } ?? data.bars
        let maxV = Double(max(1, bars.map(\.total).max() ?? 1))
        return (String(localized: "用量柱图"), String(localized: "共 \(bars.count) 个时段，各时段 token 总量"),
                AXCategoricalDataAxisDescriptor(title: String(localized: "时段"), categoryOrder: bars.map(\.title)),
                AXNumericDataAxisDescriptor(title: "token", range: 0...maxV, gridlinePositions: [], valueDescriptionProvider: { UsageModel.tokens(Int($0)) + " token" }),
                [AXDataSeriesDescriptor(name: String(localized: "总 token"), isContinuous: false, dataPoints: bars.map { AXDataPoint(x: $0.title, y: Double($0.total)) })])
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let p = Self.parts(data, keys: keys)
        return AXChartDescriptor(title: p.title, summary: p.summary, xAxis: p.x, yAxis: p.y, additionalAxes: [], series: p.series)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let p = Self.parts(data, keys: keys)
        descriptor.title = p.title
        descriptor.summary = p.summary
        descriptor.xAxis = p.x
        descriptor.yAxis = p.y
        descriptor.series = p.series
    }
}

/// 简单的自动换行布局（图例用）。
private struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height); width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

/// 正在工作（O1-368 右 2 / A1-194 R2）：每个工作中的会话一行——状态点、agent 与 topic、工作时长；整行可点进会话。
/// 只来自实时 targets；列表在固定 192pt 视口内滚动（不只显示前两条），脚注在底。
private struct WorkingCard: View {
    @Environment(MacSession.self) private var session
    var fixedHeight: CGFloat? = nil
    var body: some View {
        let connected = session.link == .connected
        let n = UsageModel.workingCount(targets: session.state?.targets, connected: connected)
        let working: [TargetSummary] = connected ? (session.state?.targets ?? []).filter { ThreadIdentity.status($0) == .working } : []
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("正在工作").font(.headline)
                Spacer()
                Text(n.map(String.init) ?? "—").font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit() // 断线不写 0
                Text("个会话").font(.caption).foregroundStyle(.secondary)
            }
            if working.isEmpty {
                Text(connected ? String(localized: "没有正在工作的会话。") : String(localized: "未连接，无法得知正在工作的会话。")).font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(working) { t in
                            WorkingRow(target: t) { session.openThread(t.id) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                HStack {
                    Text("共 \(working.count) 个 · 列表可滚动").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("点按一行进入会话").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fixedHeight == nil ? nil : .infinity, alignment: .topLeading)
        .card()
        .frame(height: fixedHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(n.map { String(localized: "正在工作 \($0) 个会话") } ?? String(localized: "正在工作数量未知，未连接"))
    }
}

/// 工作会话的一行（可点进会话）：状态点 + 「agent · topic」+ 工作时长。缺 topic 时省略，不虚构任务摘要。
private struct WorkingRow: View {
    @Environment(MacSession.self) private var session
    let target: TargetSummary
    let action: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Button(action: action) {
                HStack(alignment: .top, spacing: 8) {
                    ActivityDot(kind: session.activityKind(target), size: 7, accent: PalmhelmTheme.accent, ok: PalmhelmTheme.ok, warn: PalmhelmTheme.warn)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.agentName ?? target.projectName).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        if let topic = target.statsTopic, !topic.isEmpty {
                            Text(topic).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(session.activityText(target, at: ctx.date)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开这个会话")
            .accessibilityLabel("\(target.agentName ?? target.projectName)\(target.statsTopic.map { "，\($0)" } ?? "")，\(session.activityText(target, at: ctx.date))")
        }
    }
}

/// 数据与价格（O1-368 右 3）：记录来源与参考价格在可滚动主体内；价格细节为 popover，立即更新在卡底。宽窗固定 336pt。
private struct SourcesCard: View {
    let e: UsageEstimate?
    var state: UsagePageState = .ready
    var fixedHeight: CGFloat? = nil
    @Environment(MacSession.self) private var session
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("数据与价格").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let e {
                        sourceList(e)
                        Divider()
                        PricingSection(compact: true, part: .summary)
                    } else {
                        Text("记录来源").font(.subheadline.weight(.semibold))
                        if case .loading = state { SkeletonLines(count: 3) } else { Text(TrendCard.placeholderLine(state)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // 卡底固定区：更新操作与说明始终在底部，不随正文滚动（A1-194 R4）
            if e != nil { PricingSection(compact: true, part: .refresh) }
            Text("只下载公开价格表，不上传会话；普通网络请求会暴露出口 IP。").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: fixedHeight == nil ? nil : .infinity, alignment: .topLeading)
        .card()
        .frame(height: fixedHeight)
    }
    private func sourceList(_ e: UsageEstimate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("记录来源").font(.subheadline.weight(.semibold))
            ForEach(e.sources) { s in
                let why = s.reasons.isEmpty ? nil : s.reasons.map(UsageCopy.reason).joined(separator: "；")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(UsageCopy.sourceName(s.source)).font(.callout.weight(.medium))
                        Spacer(minLength: 8)
                        // 状态胶囊：已采集绿、部分采集琥珀、暂不可用 / 未发现灰；状态色只在胶囊上
                        Text(UsageCopy.status(s.status))
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Self.tint(s.status).opacity(0.16), in: Capsule())
                            .foregroundStyle(Self.tint(s.status))
                    }
                    // 原因最多两行；完整原因放进悬停提示（不截断丢失）
                    if let why { Text(why).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(why).fixedSize(horizontal: false, vertical: true) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(UsageCopy.sourceName(s.source))，\(UsageCopy.status(s.status))\(why.map { "，\($0)" } ?? "")")
            }
        }
    }
    static func tint(_ status: String) -> Color {
        switch status { case "collected": PalmhelmTheme.ok; case "partial": PalmhelmTheme.warn; default: .secondary }
    }
}

/// 活动时段 · 近 7 天：7×24 热力图内联（活动记录数，不是 token），标明周期与时区。
/// 活动时段（O1-368 左 2）：7 行热力格固定高度（宽窗 28、间距 4，总高 220）；宽窗固定 336pt。
private struct ActivityCard: View {
    let u: UsageResponse?
    var state: UsagePageState = .ready
    var fixedHeight: CGFloat? = nil
    var cellHeight: CGFloat? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("活动时段 · 近 7 天").font(.headline); Spacer(); Text(u.map { String(localized: "时区 \(UsageModel.timeZone($0).identifier) · 用量活动记录数") } ?? String(localized: "用量活动记录数")).font(.caption).foregroundStyle(.secondary) }
            if let u {
                HeatmapView(u: u, showsHeader: false, cellHeight: cellHeight) // 卡头已标明周期 / 时区 / 口径，不再重复二级标题
            } else {
                // 占位：与热力图同高（7 行 × 格高 + 间距），加载中用骨架，其余用说明
                ChartPlaceholder(state: state, height: 7 * (cellHeight ?? UsageLayout.heatCellWide) + 6 * UsageLayout.heatGap)
            }
            Spacer(minLength: 0)
            Text("每格是活动记录数，不是 token；独立于上方的范围。").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: fixedHeight == nil ? nil : .infinity, alignment: .topLeading)
        .card()
        .frame(height: fixedHeight)
    }
}

private struct ModelTable: View {
    /// 行高统一：每行至少这么高（TTL 拆分在 token 单元格的第二行，小字）。
    static let rowMinHeight: CGFloat = 34
    let w: UsageEstimateWindow?
    let e: UsageEstimate?
    let series: [String] // 图的前 3 个模型：行首色块与图 / 图例 / 浮层同一映射，其余用「其他」灰
    var state: UsagePageState = .ready
    var fixedHeight: CGFloat? = nil // 宽窗通栏固定 288pt；表格超量时卡内纵向滚动（O1-368）

    var body: some View {
        if let w, let e { table(w, e) } else { placeholder }
    }

    /// 没有数据：表头与一组骨架行（同一卡位、同一高度）；说明在卡内。
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("模型明细").font(.headline); Spacer() }
            if case .loading = state { SkeletonLines(count: 3) } else { Text(TrendCard.placeholderLine(state)).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: fixedHeight == nil ? nil : .infinity, alignment: .topLeading)
        .card()
        .frame(height: fixedHeight)
    }

    /// 列（规格 mockup）：模型 | 输入 | 输出 | 缓存读取 | 缓存写入 | TTL 未知 | 总 Token | 可估价金额；末行合计。
    private func table(_ w: UsageEstimateWindow, _ e: UsageEstimate) -> some View {
        let vis = UsageModel.visibleRows(w.rows)
        let rows = vis.rows.sorted { (a, b) in a.tokens.total != b.tokens.total ? a.tokens.total > b.tokens.total : a.id < b.id }
        let t = w.totals
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("模型明细").font(.headline); Spacer()
                Text(vis.hidden > 0 ? String(localized: "已隐藏无用量的行") : String(localized: "同一模型不同来源分行")).font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty { Text("该时段没有模型记录。").font(.caption).foregroundStyle(.secondary) }
            else {
                // 表视口：Grid 的最小宽度 = 视口宽（宽时填满、模型列吃掉剩余空间，金额列贴右）；窄时内部横向滚动（A1-194 R6 / A1-195 R6a）
                GeometryReader { vp in
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("模型").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                            ForEach([String(localized: "输入"), String(localized: "输出"), String(localized: "缓存读取"), String(localized: "缓存写入"), String(localized: "TTL 未知"), String(localized: "总 Token"), String(localized: "可估价金额")], id: \.self) { Text($0).frame(minWidth: 56, alignment: .trailing) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(rows) { r in
                            GridRow(alignment: .firstTextBaseline) {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 2).fill(UsageSeriesColor.color(UsageModel.seriesIndex(r.model, series: series), family: PalmhelmThemeStore.shared.family)).frame(width: 9, height: 9)
                                    Text(r.model).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(r.model)
                                }
                                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                                Text(UsageModel.tokens(r.tokens.input)).frame(minWidth: 56, alignment: .trailing)
                                Text(UsageModel.tokens(r.tokens.output)).frame(minWidth: 56, alignment: .trailing)
                                Text(UsageModel.tokens(r.tokens.cacheRead)).frame(minWidth: 56, alignment: .trailing)
                                Text(UsageModel.tokens(r.tokens.cacheWrite)).frame(minWidth: 56, alignment: .trailing)
                                Text(UsageAccuracy.hasUnknownTTL(r) ? String(localized: "有") : String(localized: "无")).frame(minWidth: 56, alignment: .trailing)
                                Text(UsageModel.tokens(r.tokens.total)).frame(minWidth: 56, alignment: .trailing)
                                Text(UsageModel.costText(r)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                                    .foregroundStyle(r.costUsd == nil ? .secondary : .primary)
                                    .help(UsageAccuracy.priceDetail(r, rules: e.pricing.cacheLongRules))
                            }
                            .font(.caption.monospacedDigit())
                            .frame(minHeight: 30)
                            .accessibilityElement(children: .combine)
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("合计").font(.callout.weight(.semibold)).frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                            Text(UsageModel.tokens(t.tokens.input)).frame(minWidth: 56, alignment: .trailing)
                            Text(UsageModel.tokens(t.tokens.output)).frame(minWidth: 56, alignment: .trailing)
                            Text(UsageModel.tokens(t.tokens.cacheRead)).frame(minWidth: 56, alignment: .trailing)
                            Text(UsageModel.tokens(t.tokens.cacheWrite)).frame(minWidth: 56, alignment: .trailing)
                            Text((t.ttlUnknownTokens ?? 0) > 0 ? UsageModel.tokens(t.ttlUnknownTokens ?? 0) : String(localized: "无")).frame(minWidth: 56, alignment: .trailing)
                            Text(UsageModel.tokens(t.tokens.total)).frame(minWidth: 56, alignment: .trailing)
                            Text(UsageModel.usd(t.costUsd)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                        }
                        .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .frame(minWidth: vp.size.width, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                }
                // 窄宽卡高自然：无固定高时 GeometryReader 会塌成 0，表体被裁掉，按行数给出视口高
                .frame(height: fixedHeight == nil ? CGFloat(rows.count + 3) * 34 : nil)
            }
            // 脚注贴底：TTL 未知与未报价的口径说明（不隐藏故障）
            Spacer(minLength: 0)
            if (t.ttlUnknownTokens ?? 0) > 0 {
                Text("有 \(UsageModel.tokens(t.ttlUnknownTokens ?? 0)) token 的缓存 TTL 未知，未计入金额；估算不是实际账单。").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(UsageModel.truncationNotes(e), id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: fixedHeight == nil ? nil : .infinity, alignment: .topLeading)
        .card()
        .frame(height: fixedHeight)
    }
}

struct HeatmapView: View {
    let u: UsageResponse
    var showsHeader = true
    /// 固定格高（宽窗 28、窄窗 18）；nil 保持原来的近方形比例。
    var cellHeight: CGFloat? = nil
    var body: some View {
        let maxV = max(1, u.heatmap.activity.flatMap { $0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { HStack { Text("7 天活动").font(.subheadline.weight(.semibold)); Spacer(); Text("用量活动记录数").font(.caption).foregroundStyle(.secondary) } }
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                // 小时刻度：每 3 小时一个，标在对应的列上方
                GridRow {
                    Color.clear.frame(width: 34, height: 1)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 3 == 0 ? "\(h)" : "").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .fixedSize()
                    }
                }
                ForEach(Array(u.heatmap.days.enumerated()), id: \.offset) { i, day in
                    let row = i < u.heatmap.activity.count ? u.heatmap.activity[i] : []
                    GridRow {
                        Text(String(day.suffix(5))).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                        ForEach(0..<24, id: \.self) { h in
                            let v = h < row.count ? row[h] : 0
                            HeatCell(fill: UsageSeriesColor.heatColor(level: UsageSeriesColor.heatLevel(value: v, maxValue: maxV), family: PalmhelmThemeStore.shared.family), cellHeight: cellHeight,
                                     help: String(localized: "\(String(day.suffix(5))) \(String(format: "%02d", h)):00–\(String(format: "%02d", (h + 1) % 24)):00 · \(v) 条活动记录"))
                        }
                    }
                    // 按行读：每天一行，读出当天最忙的时段与总记录数，不逐格读
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.rowLabel(day: day, row: row))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("7 天活动热图，按天逐行")
        }
    }

    /// 一行的无障碍文字：当天最忙的时段（同值取较早）与总记录数；当天没有活动时明说。
    static func rowLabel(day: String, row: [Int]) -> String {
        let total = row.reduce(0, +)
        guard total > 0, let peak = row.indices.max(by: { row[$0] != row[$1] ? row[$0] < row[$1] : $0 > $1 }) else { return String(localized: "\(day)，没有活动记录") }
        return String(localized: "\(day)，最忙在 \(String(format: "%02d", peak)):00–\(String(format: "%02d", (peak + 1) % 24)):00，共 \(total) 条活动记录")
    }
}

/// 热力格：接近 1 : 1.3（宽:高），悬停时描边高亮并显示原生 .help 提示。
private struct HeatSize: ViewModifier {
    let cellHeight: CGFloat?
    func body(content: Content) -> some View {
        if let cellHeight { content.frame(height: cellHeight) } else { content.aspectRatio(1.0 / 1.3, contentMode: .fit) }
    }
}

private struct HeatCell: View {
    let fill: Color
    var cellHeight: CGFloat? = nil
    let help: String
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fill)
            .modifier(HeatSize(cellHeight: cellHeight))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(PalmhelmTheme.accent, lineWidth: hovering ? 1.5 : 0))
            .onHover { hovering = $0 }
            .help(help)
    }
}

// MARK: 旧口径（旧版 Bridge / 估价版本不支持）

private struct LegacyUsage: View {
    @Environment(MacSession.self) private var session
    let u: UsageResponse
    let showMoney: Bool
    @State private var kinds: Set<TokenKind> = [.input, .output, .cacheWrite]
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorScheme) private var colorScheme
    private var all: Set<TokenKind> { Set(TokenKind.allCases) }
    private func seriesFill(_ index: Int?) -> AnyShapeStyle {
        UsageSeriesTexture.fill(index, family: PalmhelmThemeStore.shared.family, dark: colorScheme == .dark, differentiate: differentiateWithoutColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Token 类型").font(.caption).foregroundStyle(.secondary)
                ForEach(TokenKind.allCases, id: \.self) { k in
                    let on = kinds.contains(k)
                    Button(k.label) { if on { if kinds.count > 1 { kinds.remove(k) } } else { kinds.insert(k) } }
                        .buttonStyle(.bordered).tint(on ? PalmhelmTheme.accent : .secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                chart.frame(maxWidth: .infinity)
                VStack(spacing: 14) { recent; VStack(alignment: .leading) { HeatmapView(u: u) }.card() }.frame(width: 340)
            }
        }
    }

    private func money(_ byModel: [String: UsageTokens], _ ks: Set<TokenKind>) -> String? {
        guard showMoney else { return nil }
        return UsageModel.legacyCost(u.estimate(byModel, kinds: ks))
    }

    /// 旧口径图：数据全部来自 UsageLegacyStacks（与测试同一 seam）。身份是系列序号，不是显示名（O1-359 R1）。
    private var chart: some View {
        let plan = UsageLegacyStacks.plan(u.buckets, kinds: kinds)
        let stacks = UsageLegacyStacks.stacks(u.buckets, plan: plan, kinds: kinds)
        let models = UsageLegacyStacks.modelTotals(u.buckets, plan: plan, kinds: kinds)
        let total = stacks.reduce(0) { $0 + $1.tokens }
        let allModels = u.buckets.reduce(into: [String: UsageTokens]()) { acc, b in for (m, t) in b.byModel { acc[m] = (acc[m] ?? UsageTokens()) + t } }
        let legendIndices = (0..<plan.named.count).map { $0 } + (plan.hasAggregate ? [UsageLegacyStacks.aggregateIndex] : [])
        let daily = u.bucketMs >= 86_400_000
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Token").font(.headline); Spacer(); Text(daily ? "按模型堆叠 · 1 天" : "按模型堆叠 · 1 小时").font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Text(total.shown).font(.system(.title3, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6) }
            if let m = money(allModels, kinds) { Text("所选 \(m)").font(.caption).foregroundStyle(.secondary) }
            if total == 0 { Text("该时段没有用量。").font(.caption).foregroundStyle(.secondary).frame(height: 200) }
            else {
                Chart(stacks) { st in
                    BarMark(x: .value(String(localized: "时段"), Date(timeIntervalSince1970: Double(st.t) / 1000), unit: daily ? .day : .hour), y: .value("token", st.tokens))
                        .foregroundStyle(by: .value(String(localized: "系列"), st.index))
                }
                .chartForegroundStyleScale(domain: legendIndices, range: legendIndices.map { seriesFill($0) })
                .chartLegend(.hidden)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) { _ in AxisGridLine(); AxisValueLabel(format: KitL10n.displayStyle(daily ? Date.FormatStyle().month(.defaultDigits).day() : Date.FormatStyle().hour(.twoDigits(amPM: .omitted)))) } }
                .frame(height: 200)
                // 图例：与图同一填充；具名模型与「其他」
                WrapLayout(spacing: 12, lineSpacing: 4) {
                    ForEach(legendIndices, id: \.self) { i in
                        legendRow(i == UsageLegacyStacks.aggregateIndex ? String(localized: "其他") : plan.named[i], fill: seriesFill(i))
                    }
                }
                // 明细：所有模型都在（不因图表合并而丢失），与图同色；聚合键显示为「其他」
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(models) { m in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(seriesFill(m.index)).frame(width: 10, height: 10)
                            Text(m.isAggregateKey ? String(localized: "其他（服务端合并）") : m.model).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(m.total.shown).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .card()
    }

    private func legendRow(_ name: String, fill: AnyShapeStyle) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(fill).frame(width: 10, height: 10)
            Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近用量").font(.headline)
            ForEach([(String(localized: "今天"), u.recent.today), (String(localized: "最近 7 天"), u.recent.d7), (String(localized: "最近 30 天"), u.recent.d30)], id: \.0) { title, r in
                let total = r.byModel.values.reduce(0) { $0 + $1.total(kinds) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(title); Spacer(); Text(total.shown).font(.system(.body, design: .monospaced)) }
                    if let m = money(r.byModel, kinds) { Text("所选 \(m)").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 3)
            }
        }
        .card()
    }
}

fileprivate extension TargetSummary {
    /// 统计行的第二行：自定义名（#134）优先，其次会话主题；空白视为没有。
    var statsTopic: String? {
        let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let topic = self.topic?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return topic.isEmpty ? nil : topic
    }
}
