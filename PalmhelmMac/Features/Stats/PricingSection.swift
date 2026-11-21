import SwiftUI
import PalmhelmKit

/// 测试 / 截图用：价格细节默认展开（用户操作仍优先）。
private struct PricingInitiallyExpandedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var pricingInitiallyExpanded: Bool { get { self[PricingInitiallyExpandedKey.self] } set { self[PricingInitiallyExpandedKey.self] = newValue } }
}

/// 参考价格（models.dev）：状态、更新入口、自动检查开关。用量页（compact 卡片）与设置「用量与隐私」共用，状态与单飞都在 MacSession。
/// 旧版 Bridge（无 estimate）与不支持的估价版本不显示价格入口。
struct PricingSection: View {
    @Environment(MacSession.self) private var session
    @Environment(EngineSettings.self) private var settings
    @Environment(BridgeEngine.self) private var engine
    var compact = false
    /// 紧凑卡的两个部分：摘要（来源 / 新鲜度 / 浮层入口）放在可滚动主体，更新操作放在卡底固定区（A1-194 R4）。
    enum CompactPart { case summary, refresh }
    var part: CompactPart = .summary

    var body: some View {
        if compact {
            if part == .summary { if let p = pricing { CompactPricing(p: p) } }
            else { refreshRow }
        } else {
            Group {
                if let p = pricing { status(p); refreshRow } else {
                    Text("价格状态需要连接到较新的 Bridge 才能显示。").font(.caption).foregroundStyle(.secondary)
                }
                autoUpdateRow
                Text("只下载公开价格表，不上传会话；普通网络请求会暴露出口 IP。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pricing: UsagePricingInfo? {
        guard let u = session.visibleUsage, case .v1(let e) = UsageModel.mode(u) else { return nil }
        return e.pricing
    }

    @ViewBuilder private func status(_ p: UsagePricingInfo) -> some View { PricingDetails(p: p) }
}

/// 用量页「数据与价格」卡的价格小节（O1-368）：来源 · 新鲜度 · 获取日期一行；「价格细节」为原生 popover（不推挤正文）；「立即更新价格」在卡底。
private struct CompactPricing: View {
    let p: UsagePricingInfo
    @State private var showDetails = false
    @Environment(\.pricingInitiallyExpanded) private var initiallyExpanded
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("参考价格").font(.subheadline.weight(.semibold))
            Text("models.dev · \(Self.freshShort(p.freshness)) · \(UsageModel.ms(p.asOfT).formatted(KitL10n.displayStyle(Date.FormatStyle().month().day()))) 获取")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("价格细节") { showDetails = true }
                .controlSize(.small).buttonStyle(.borderless)
                .popover(isPresented: $showDetails, arrowEdge: .leading) { PricingPopoverContent(p: p) }
        }
        .onAppear { if initiallyExpanded { showDetails = true } } // 截图 / 测试：开关打开时直接展开浮层
    }
    static func freshShort(_ f: String) -> String {
        switch f { case "current": String(localized: "较新"); case "stale": String(localized: "较旧"); case "excluded": String(localized: "过旧，未用于估价"); default: f }
    }
}

/// 价格明细（8 行键值 + 推导规则说明）：用量页的折叠展开与设置页共用。
/// 价格细节浮层的内容：宽 420，最大高 360，超出在浮层内滚动，不影响页面布局（A1-194 R4 / A1-195 R4a）。
struct PricingPopoverContent: View {
    let p: UsagePricingInfo
    var body: some View {
        ScrollView {
            PricingDetails(p: p).padding(14).frame(width: 420, alignment: .leading)
        }
        .frame(width: 420)
        .frame(maxHeight: 360)
    }
}

struct PricingDetails: View {
    let p: UsagePricingInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row(String(localized: "来源"), "models.dev · \(UsageModel.originText(p.origin))")
            row(String(localized: "状态"), UsageModel.freshnessText(p.freshness)) // 新鲜度只用服务器给的 freshness
            row(String(localized: "价格表获取"), UsageModel.ms(p.asOfT).shown(date: .abbreviated, time: .omitted))
            row(String(localized: "上次确认有效"), UsageModel.ms(p.lastValidatedT).shown(date: .abbreviated, time: .shortened))
            row(String(localized: "上次检查"), p.lastCheckT.map { UsageModel.ms($0).shown(date: .abbreviated, time: .shortened) } ?? String(localized: "尚未检查")) // 检查可能失败，与「确认有效」分开
            row(String(localized: "更新时机"), UsageModel.updatePolicyText(p.updatePolicy))
            row(String(localized: "自动检查（运行中）"), p.autoUpdate ? String(localized: "开") : String(localized: "关"))
            ForEach(p.cacheLongRules ?? [], id: \.rule) { r in
                GridRow(alignment: .firstTextBaseline) {
                    Text("1h 缓存写价").foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
                    HStack(spacing: 6) {
                        Text("\(r.multiplier.shown)× 输入价")
                        // 来源：短链接（可点），不显示裸 URL（A1-194 R4）
                        if let url = Self.sourceURL(r.source) {
                            Link("\(Self.sourceName(url)) · \(r.asOf)", destination: url).font(.caption)
                        } else {
                            Text("· \(r.source)，\(r.asOf)").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
          }
          // 地域脚注（规格）：日志标明 US 时所有价格 1.1 倍；读不到地域按全球价。
          Text("地域：日志标明 US 时所有价格按 1.1 倍计算；读不到地域时按全球价。").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          ForEach(p.notes ?? [], id: \.self) { n in if let t = UsageAccuracy.pricingNote(n) { Text(t).font(.caption2).foregroundStyle(.secondary) } }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    /// 规则来源是一个定价页地址：短链接用的站点名（如「Claude 定价页」），完整地址只在可点的链接里。
    static func sourceURL(_ source: String) -> URL? {
        let raw = source.contains("://") ? source : "https://" + source
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    static func sourceName(_ url: URL) -> String {
        let host = url.host ?? ""
        return host.contains("claude") || host.contains("anthropic") ? String(localized: "Claude 定价页") : host
    }

    /// 两列：标签固定 108pt（左），值左对齐、可多行（右）。
    private func row(_ k: String, _ v: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            Text(v).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PricingSection {

    var refreshRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let blocker = session.priceRefreshBlocker(now: ctx.date)
                HStack(spacing: 8) {
                    Button("立即更新价格") { Task { await session.refreshPrices() } }.controlSize(.small).disabled(blocker != nil)
                    if session.priceRefreshBusy { ProgressView().controlSize(.small) }
                    if let blocker { Text(blocker).font(.caption2).foregroundStyle(.secondary) } // 同步给原因，不是默默禁用
                }
                if let n = session.visiblePriceNote, let text = Self.noteText(n, now: ctx.date) { Text(text).font(.caption2).foregroundStyle(Self.noteTint(n)) }
            }
        }
    }

    /// 结果文案：429 显示截止倒计时（不自动重试）；重拉用量失败也要说清。
    static func noteText(_ n: MacSession.PriceNote, now: Date) -> String? {
        switch n {
        case .current: return String(localized: "价格已是最新")
        case .updated: return String(localized: "价格已更新")
        case .failed(let code): return UsageCopy.refreshFailure(code)
        case .rateLimited(let until):
            let left = Int(until.timeIntervalSince(now).rounded(.up))
            return left > 0 ? String(localized: "更新太频繁，\(left) 秒后可再试") : nil
        case .usageNotRefreshed: return String(localized: "价格已更新，用量暂未刷新")
        }
    }
    static func noteTint(_ n: MacSession.PriceNote) -> Color {
        switch n { case .failed: PalmhelmTheme.bad; case .rateLimited, .usageNotRefreshed: PalmhelmTheme.warn; default: PalmhelmTheme.ok }
    }

    @ViewBuilder private var autoUpdateRow: some View {
        @Bindable var settings = settings
        Toggle("自动检查价格（Bridge 启动时，缓存超过 3 天才查）", isOn: $settings.pricingAutoUpdate)
        if let p = pricing, p.autoUpdate != settings.pricingAutoUpdate {
            Text("已保存，重启 Bridge 后生效").font(.caption).foregroundStyle(PalmhelmTheme.warn) // 运行中的生效值看上面「自动检查（运行中）」
        } else if pricing == nil, engine.pendingRestart {
            Text("已保存，重启 Bridge 后生效").font(.caption).foregroundStyle(PalmhelmTheme.warn)
        }
        Text("关闭后仍可手动更新。").font(.caption).foregroundStyle(.secondary)
    }
}
