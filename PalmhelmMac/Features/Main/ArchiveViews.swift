import SwiftUI
import PalmhelmKit

// 历史会话整理（#97，S3）的界面：目标栏里的历史行、已归档窗口（列表 + 只读分页历史）。
// 动作全部经 MacSession 调用 Kit 判定；这里不做任何规则判断。

/// 目标栏里的历史目标（已不在登记表中）：只能展示标题，右键可归档/删除。
/// 只消费一份展示值（HistoricalRailRow）：不再逐行回读整份目标栏投影。
struct HistoricalRowView: View, Equatable {
    @Environment(MacSession.self) private var session
    let row: HistoricalRailRow
    @State private var confirmDelete = false

    nonisolated static func == (l: Self, r: Self) -> Bool { l.row == r.row }

    var body: some View {
        let _ = { RailProbe.rowBodies += 1 }()
        let id = row.id, title = row.title
        Button { session.selectTarget(id) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                Text("历史 · 不在线").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 6)
        .contextMenu {
            if row.canArchive {
                Button("归档", systemImage: "archivebox") { session.archiveThread(id) }
                Button("删除…", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("删除这个历史会话？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { session.deleteThread(id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅从这台 Mac 的列表移除并清理本地缓存，Bridge 上的历史记录不受影响。")
        }
    }
}

/// 已归档窗口：左边是归档列表（右键恢复或删除，删除需确认），右边是所选线程的只读历史（按游标分页）。
struct ArchivedThreadsWindow: View {
    @Environment(MacSession.self) private var session
    @State private var selected: String?
    @State private var pendingDelete: String?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                if session.archivedThreads.isEmpty {
                    Text("没有已归档的会话").foregroundStyle(.secondary)
                }
                ForEach(session.archivedThreads) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title).font(.body.weight(.semibold)).lineLimit(1)
                        Text(a.reason == .auto ? String(localized: "离线满 7 天，已自动归档") : String(localized: "已手动归档")).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(a.id)
                    .contextMenu {
                        Button("恢复到目标栏", systemImage: "arrow.uturn.backward") { session.restoreThread(a.id) }
                        Button("删除…", systemImage: "trash", role: .destructive) { pendingDelete = a.id }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260)
            Group {
                if let id = selected, let a = session.archivedThreads.first(where: { $0.id == id }) {
                    ArchivedHistoryPane(targetId: id, title: a.title)
                } else {
                    Text("选择一个已归档的会话").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 440)
        .confirmationDialog("删除这个历史会话？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let id = pendingDelete { session.deleteThread(id); if selected == id { selected = nil } }; pendingDelete = nil }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("仅从这台 Mac 的列表移除并清理本地缓存，Bridge 上的历史记录不受影响。")
        }
    }
}

/// 目标账本历史的只读内容（归档窗口与活目标的消息账本共用）：不含恢复 / 删除 / 绑定 / 发送，只有加载与重试。
/// 行状态由 `status` 给出（会话的 ledgerMessageStatus：有当前指令时与对话页同一事实，没有时只对账本缓存独立求值）。
struct TargetHistoryContent: View {
    let page: TargetHistoryPaging
    let connected: Bool
    let note: LocalizedStringKey
    let load: () -> Void
    /// 入口打开时捕获的内容 scope、当前 scope 与当前页条目查找：复制 / 阅读 / 翻页前按它复核（LedgerRowGuard）。没有默认值。
    let opened: LedgerScope?
    let currentScope: () -> LedgerScope?
    let currentRow: (String) -> TargetHistoryRow?
    let status: (TargetHistoryRow) -> MessageStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note).font(.caption).foregroundStyle(.secondary)
            if !connected {
                Text("未连接，连接后加载历史消息。").font(.footnote).foregroundStyle(.secondary)
            }
            if page.failed {
                Text("加载失败，请稍后再试。").font(.footnote).foregroundStyle(PalmhelmTheme.warn)
            }
            if (page.canLoadInitial || page.canLoadMore) && connected {
                // 首载失败时显示“重试”；首载完成后才显示“加载更早的消息”（R1）。
                let title = page.loading ? String(localized: "正在加载…") : (page.canLoadInitial ? (page.failed ? String(localized: "重试") : String(localized: "加载历史")) : String(localized: "加载更早的消息"))
                Button(title, action: load).disabled(page.loading)
            }
            if page.items.isEmpty && page.exhausted {
                Text("没有可显示的历史消息。").font(.footnote).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(page.items) { item in TargetHistoryRowView(item: item, status: status(item), isCurrent: { LedgerRowGuard.permits(opened: opened, now: currentScope(), captured: $0, current: currentRow($0.id)) }) }
                }
            }
        }
    }
}

/// 一条归档线程的只读历史：按游标向更旧翻页。未连接时说明，已缓存的页仍可看。
struct ArchivedHistoryPane: View {
    @Environment(MacSession.self) private var session
    let targetId: String
    let title: String
    /// 打开归档历史时捕获的内容 scope（账户 / Bridge / 连接代次 / 目标；不要求目标仍在线）。
    @State private var openedScope: LedgerScope?
    /// 回到前台或窗口重新成为 key 的次数：变化时重启刷新任务（离页即取消；同一时刻的多次触发在会话里合并为一次尾随刷新）。
    @State private var activations = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActive

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            TargetHistoryContent(page: session.archivedPage(targetId), connected: session.link == .connected, note: "历史离线会话（只读）。内容来自 Bridge 账本。", load: {
                Task { await session.loadArchivedHistory(targetId, older: true) }
            }, opened: openedScope, currentScope: { session.ledgerScope(targetId) }, currentRow: { id in session.archivedPage(targetId).items.first { $0.id == id } },
                               status: { session.ledgerMessageStatus($0, scope: openedScope) })
        }
        .padding(14)
        // 进入即首载（已加载过则刷新已加载范围）；回到前台 / 窗口重新成为 key 再刷新；不自动翻页。
        .task(id: "\(targetId)#\(activations)") { if openedScope == nil || openedScope?.targetId != targetId { openedScope = session.ledgerScope(targetId) }; await session.refreshArchivedHistory(targetId) }
        .onChange(of: scenePhase) { _, now in if now == .active { activations += 1 } }
        .onChange(of: controlActive) { _, now in if now == .key { activations += 1 } }
    }
}

/// 活目标的消息账本（只读 sheet）：只有读取与翻页，没有归档恢复 / 删除 / 绑定 / 发送。只读设备也可进入。
/// 路由捕获 scope；每次首载 / 重试 / 续页真正提交前复核，失效零请求并关闭。
struct ThreadLedgerSheet: View {
    let scope: LedgerScope
    let title: String
    let onClose: () -> Void
    @Environment(MacSession.self) private var session
    @State private var activations = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActive

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            TargetHistoryContent(page: session.archivedPage(scope.targetId), connected: session.link == .connected, note: "消息账本是保存在 Bridge 上、按目标查看的消息与回执记录，用来核对哪些消息已排队、已送达或已停止；它不是终端的完整对话记录。这里只能查看和复制，不会改动任何消息。", load: {
                Task { await load(older: true) }
            }, opened: scope, currentScope: { session.ledgerScope(scope.targetId) }, currentRow: { id in session.archivedPage(scope.targetId).items.first { $0.id == id } },
                               status: { session.ledgerMessageStatus($0, scope: scope) })
        }
        .padding(14)
        .frame(minWidth: 460, minHeight: 360)
        // 账本出现时：首载，或刷新已加载范围；账本仍展示时回到前台 / 窗口重新成为 key 再刷新（同次合并为一轮，离页即取消）。
        .task(id: activations) { await refresh() }
        .onChange(of: scenePhase) { _, now in if now == .active { activations += 1 } }
        .onChange(of: controlActive) { _, now in if now == .key { activations += 1 } }
        .onChange(of: session.ledgerScope(scope.targetId)) { _, now in if now != scope { onClose() } }
    }

    private func load(older: Bool) async {
        guard session.ledgerScope(scope.targetId) == scope else { onClose(); return }
        await session.loadArchivedHistory(scope.targetId, older: older, scope: scope)
    }

    private func refresh() async {
        guard session.ledgerScope(scope.targetId) == scope else { onClose(); return }
        await session.refreshArchivedHistory(scope.targetId, scope: scope)
    }
}
