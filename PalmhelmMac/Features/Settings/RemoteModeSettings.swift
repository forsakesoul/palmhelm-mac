import SwiftUI
import PalmhelmKit

/// 连接方式的说明与确认文案（纯函数，便于测试）。
enum ConnectionModeCopy {
    static func explanation(_ mode: ConnectionMode) -> String {
        switch mode {
        case .local: String(localized: "这台 Mac 运行内置 Bridge，手机与刘海连接本机。")
        case .remote: String(localized: "连接并控制另一台 Mac 上的 Palmhelm 会话。本机不运行 Bridge。")
        }
    }

    /// 远程连接态的短文案（设置页用；与顶栏的 ConnectionPhase 文案口径一致）。
    static func linkText(_ link: MacSession.Link) -> String {
        switch link {
        case .notPaired: String(localized: "未连接远程 Mac")
        case .connecting: String(localized: "正在同步…")
        case .connected: String(localized: "在线")
        case .offline(let reason): String(localized: "离线：\(reason.text)")
        }
    }

    /// 切换前的确认：说明即将发生的副作用。
    static func confirmMessage(target: ConnectionMode) -> String {
        switch target {
        case .remote: String(localized: "会停止本机 Bridge。")
        case .local: String(localized: "会断开远程 Mac 并清空本机上的会话视图。")
        }
    }
}

/// 远程模式下的顶栏、侧栏说明：只描述远程 Mac 的地址与连接阶段，不读本机 Bridge 的端口文件。
enum RemoteLinePresentation {
    static func line(endpoint: BridgeEndpoint?, phase: String) -> String {
        guard let endpoint else { return String(localized: "远程 Mac 未配对") }
        return String(localized: "远程 Mac \(endpoint.host) · \(phase)")
    }

    static func help(endpoint: BridgeEndpoint?, phase: String) -> String {
        guard let endpoint else { return String(localized: "远程 Mac 未配对。点击打开设置") }
        return String(localized: "远程 Mac \(endpoint.host):\(String(endpoint.port)) · \(phase)。点击打开设置")
    }
}

/// 设置 › 连接与设备 顶部的连接方式：分段选择、确认框、结果提示。切换只经 ConnectionModeSwitcher。
struct ConnectionModeRows: View {
    @Environment(EngineSettings.self) private var settings
    @Environment(ConnectionModeSwitcher.self) private var switcher
    @State private var pending: ConnectionMode?
    @State private var message: (text: LText, isWarning: Bool)?

    var body: some View {
        Section("连接方式") {
            Picker(String(localized: "连接方式"), selection: Binding(get: { settings.connectionMode }, set: { pending = $0 })) {
                Text("本机 Bridge").tag(ConnectionMode.local)
                Text("远程 Mac").tag(ConnectionMode.remote)
            }
            .pickerStyle(.segmented)
            .disabled(switcher.switching)
            Text(ConnectionModeCopy.explanation(settings.connectionMode)).font(.caption).foregroundStyle(.secondary)
            if let message {
                Text(message.text.text).font(.caption).foregroundStyle(message.isWarning ? PalmhelmTheme.warn : PalmhelmTheme.bad)
            }
        }
        .confirmationDialog(String(localized: "切换连接方式？"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let target = pending {
                Button(String(localized: "切换"), role: .destructive) {
                    pending = nil
                    Task { await run(target) }
                }
            }
            Button(String(localized: "取消"), role: .cancel) { pending = nil }
        } message: {
            Text(pending.map(ConnectionModeCopy.confirmMessage(target:)) ?? "")
        }
    }

    private func run(_ target: ConnectionMode) async {
        switch await switcher.switchTo(target) {
        case .done: message = nil
        case .doneWithNote(let note): message = (note, true)
        case .failed(let reason): message = (reason, false)
        }
    }
}

/// 手动配对的证书短指纹确认：一次性、按尝试绑定。视图为每次配对 openAttempt 得到一个标识，
/// 只有该标识仍是当前尝试时 ask 才展示；dispose（宿主离开）作废当前尝试并以拒绝收束待答。
/// 没有 reactivate：重新出现的视图不会复活离开前的尝试，只有之后新开的尝试才会展示。
@MainActor
@Observable
final class FingerprintConfirmer {
    /// 待核对的短指纹（alert 据此展示；nil 即没有待答）。
    private(set) var pendingShort: String?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var currentAttempt: Int?
    @ObservationIgnored private var attemptSeq = 0

    /// 为一次新配对开启尝试，返回只属于它的标识（之前的尝试随之失效）。
    func openAttempt() -> Int {
        finish(false)
        attemptSeq += 1
        currentAttempt = attemptSeq
        return attemptSeq
    }

    /// 展示短指纹并等待回答；标识不是当前尝试时直接返回 false，不展示。
    func ask(short: String, attempt: Int) async -> Bool {
        guard attempt == currentAttempt else { return false }
        return await withCheckedContinuation { continuation in
            finish(false) // 同一时刻只有一个待答：旧的先以拒绝收束
            self.continuation = continuation
            pendingShort = short
        }
    }

    /// 唯一的回答入口：按钮、alert 关闭、取消都经这里；重复调用无效。
    func answer(_ accepted: Bool) { finish(accepted) }

    /// 宿主离开：作废当前尝试，待答以拒绝收束。
    func dispose() {
        currentAttempt = nil
        finish(false)
    }

    private func finish(_ accepted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        pendingShort = nil
        continuation.resume(returning: accepted)
    }
}

/// 已配对视图的权限说明（纯函数）：权限只来自设备帧或状态快照；只有在线且已知只读时才给升权指引。
enum RemotePermissionCopy {
    enum Level: Equatable { case control, readonly, unknown }

    static func level(permission: String?) -> Level {
        switch permission {
        case DevicePermission.control.rawValue: .control
        case DevicePermission.readonly.rawValue: .readonly
        default: .unknown
        }
    }

    static func label(_ level: Level) -> String {
        switch level {
        case .control: String(localized: "可控")
        case .readonly: String(localized: "只读")
        case .unknown: String(localized: "未知")
        }
    }

    static func guide(level: Level, link: MacSession.Link) -> String? {
        guard level == .readonly, link == .connected else { return nil }
        return String(localized: "在远程 Mac 的「配对新设备」窗口把本机设为可控后，才能发送和审批。")
    }
}

/// 断开 / 切换的结果到设置页提示的映射（纯函数）：成功不提示，未确认自撤为警示，失败为错误。
enum RemoteNotice {
    struct Message: Equatable {
        let text: String
        let isWarning: Bool
    }

    static func message(for outcome: ModeSwitchOutcome) -> Message? {
        switch outcome {
        case .done: nil
        case .doneWithNote(let note): Message(text: note.text, isWarning: true)
        case .failed(let reason): Message(text: reason.text, isWarning: false)
        }
    }
}

/// 远程 Mac 区：未配对时填写配对链接或手动信息；已配对时显示地址、连接状态、权限与断开。
/// 确认与配对任务的生命周期都挂在本视图上：离开（切换模式、离开设置区、关窗）即取消配对并拒绝待答。
struct RemoteMacRows: View {
    @Environment(MacSession.self) private var session
    @Environment(ConnectionModeSwitcher.self) private var switcher
    @State private var link = ""
    @State private var host = ""
    @State private var port = String(BridgeAPI.defaultPort)
    @State private var code = ""
    @State private var confirmer = FingerprintConfirmer()
    @State private var pairTask: Task<Void, Never>?
    /// 断开 / 切换的结果：跨已配对与未配对两种视图都可见。
    @State private var notice: RemoteNotice.Message?

    var body: some View {
        Group {
            if let notice {
                Text(notice.text).font(.caption).foregroundStyle(notice.isWarning ? PalmhelmTheme.warn : PalmhelmTheme.bad)
            }
            if session.isPaired { pairedView } else { unpairedView }
        }
        .onDisappear { leave() }
        .alert(String(localized: "确认远程 Mac 的证书指纹"), isPresented: Binding(get: { confirmer.pendingShort != nil }, set: { if !$0 { confirmer.answer(false) } })) {
            Button(String(localized: "一致，继续")) { confirmer.answer(true) }
            Button(String(localized: "取消"), role: .cancel) { confirmer.answer(false) }
        } message: {
            Text(String(localized: "请与远程 Mac 设置 › 连接与设备 中的证书短指纹核对：\(confirmer.pendingShort ?? "")"))
        }
    }

    private var pairedView: some View {
        let level = RemotePermissionCopy.level(permission: (session.device ?? session.state?.device)?.permission)
        return Group {
            if let ep = session.endpoint {
                LabeledContent(String(localized: "远程 Mac"), value: "\(ep.host):\(ep.port)")
            }
            LabeledContent(String(localized: "连接状态"), value: ConnectionModeCopy.linkText(session.link))
            LabeledContent(String(localized: "权限"), value: RemotePermissionCopy.label(level))
            if let guide = RemotePermissionCopy.guide(level: level, link: session.link) {
                Text(guide).font(.caption).foregroundStyle(PalmhelmTheme.warn)
            }
            Button(String(localized: "断开")) {
                Task { notice = RemoteNotice.message(for: await switcher.disconnectRemote()) }
            }
            .disabled(switcher.switching)
        }
    }

    private var unpairedView: some View {
        Group {
            TextField(String(localized: "配对链接"), text: $link, prompt: Text("palmhelm://pair?…"))
            Button(String(localized: "使用配对链接")) {
                guard let url = URL(string: link), let parsed = PairLink.parse(url) else {
                    session.link = .offline(LText(String(localized: "配对链接格式不正确")))
                    return
                }
                startPairing { confirm in await session.pairRemote(link: parsed, confirm: confirm) }
            }
            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || session.pairing || switcher.switching)
            TextField(String(localized: "远程 Mac 地址"), text: $host)
            TextField(String(localized: "端口"), text: $port, prompt: Text(String(BridgeAPI.defaultPort)))
            TextField(String(localized: "6 位配对码"), text: $code)
            Button(String(localized: "配对")) {
                startPairing { confirm in await session.pairRemote(host: host, port: Int(port) ?? 0, code: code, expectedSpki: nil, confirm: confirm) }
            }
            .disabled(host.isEmpty || code.isEmpty || session.pairing || switcher.switching)
            if case .offline(let reason) = session.link { Text(reason.text).font(.caption).foregroundStyle(PalmhelmTheme.bad) }
            if session.pairing { Text("正在连接远程 Mac…").font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// 配对任务挂在视图上：每次配对开启一个确认尝试；视图离开时取消任务并作废尝试。
    private func startPairing(_ operation: @escaping @Sendable (@escaping @Sendable (String) async -> Bool) async -> Bool) {
        notice = nil
        cancelPairTask()
        let confirmer = confirmer
        let attempt = confirmer.openAttempt()
        let confirm: @Sendable (String) async -> Bool = { short in await confirmer.ask(short: short, attempt: attempt) }
        pairTask = Task { _ = await operation(confirm) }
    }

    /// 视图离开（切换模式、离开设置区、关窗）：取消配对、拒绝待答，之后的结果不再写入。
    private func leave() {
        cancelPairTask()
        confirmer.dispose()
    }

    /// 唯一的取消出口：任务取消与会话侧作废同一次尝试一起发生。
    private func cancelPairTask() {
        pairTask?.cancel()
        pairTask = nil
        session.cancelRemotePairing()
    }
}
