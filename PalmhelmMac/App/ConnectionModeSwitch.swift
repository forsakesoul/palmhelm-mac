import Foundation
import Observation
import PalmhelmKit

/// 切换结果：done 成功；doneWithNote 切换已完成但需要用户注意（远程自撤未确认）；failed 未切换。
enum ModeSwitchOutcome {
    case done
    case doneWithNote(LText)
    case failed(LText)
}

// 本机 ↔ 远程模式切换与远程断开的唯一入口：先作废旧连接并停掉旧进程，成功后才落盘新模式。
// 停机未确认时保持原模式与凭据不动（I3）。
@MainActor
@Observable
final class ConnectionModeSwitcher {
    private let settings: EngineSettings
    private let engine: BridgeEngine
    private let session: MacSession
    @ObservationIgnored private let notch: NotchController?
    /// 远程自撤的替身（测试用；生产为 BridgeClient.deleteSelf，期限只由 BridgeClient 的 timeout 决定）。
    @ObservationIgnored var deleteSelfOverride: (@Sendable (BridgeClient) async throws -> Void)?
    /// AppBoot 完成启动与接管（engine.bootOnLaunch）后置真。之前一律拒绝切换：否则接管窗口内的后台 Bridge 会被遗留（R5）。
    var bootReady = false
    private(set) var switching = false

    init(settings: EngineSettings, engine: BridgeEngine, session: MacSession, notch: NotchController?) {
        self.settings = settings
        self.engine = engine
        self.session = session
        self.notch = notch
    }

    func switchTo(_ mode: ConnectionMode) async -> ModeSwitchOutcome {
        guard !switching else { return .failed(LText(String(localized: "正在切换连接模式，请稍候"))) }
        guard bootReady else { return .failed(LText(String(localized: "正在启动，稍后再切换"))) }
        guard settings.connectionMode != mode else { return .done }
        guard session.credentialsLoaded else { return .failed(LText(String(localized: "正在读取凭据，稍后再切换"))) }
        begin()
        defer { end() }
        switch mode {
        case .remote: return await switchToRemote()
        case .local: return await switchToLocal()
        }
    }

    /// 远程 Mac 断开：清掉本机在它那边的注册与本地连接，模式保持远程（与切换共用单飞）。
    func disconnectRemote() async -> ModeSwitchOutcome {
        guard !switching else { return .failed(LText(String(localized: "正在切换连接模式，请稍候"))) }
        guard settings.connectionMode == .remote else { return .failed(LText(String(localized: "当前不是远程模式"))) }
        guard session.credentialsLoaded else { return .failed(LText(String(localized: "正在读取凭据，稍后再断开"))) }
        begin()
        defer { end() }
        let confirmed = await leaveRemote()
        return confirmed ? .done : .doneWithNote(removalNote)
    }

    /// 切回本机与断开共用：只陈述自撤是否确认，不声称切换方向。
    private var removalNote: LText {
        LText(String(localized: "未能确认已从远程 Mac 移除本机，请在那台 Mac 的设备列表核对"))
    }

    private func begin() {
        switching = true
        session.modeSwitchInProgress = true
    }

    private func end() {
        switching = false
        session.modeSwitchInProgress = false
    }

    private func switchToRemote() async -> ModeSwitchOutcome {
        engine.startBlocked = true
        session.stopStream() // 代次 +1：在途的配对、Hook、同步结果从此作废
        guard await engine.stopForModeSwitch() else {
            engine.startBlocked = false
            await session.refresh() // 原模式与凭据保留：把连接接回去
            return .failed(LText(String(localized: "本机 Bridge 未能停止，已保留本机模式")))
        }
        session.forget()
        notch?.resetConnection()
        settings.connectionMode = .remote
        engine.startBlocked = false // 此后由模式守卫拦截所有启动
        return .done
    }

    private func switchToLocal() async -> ModeSwitchOutcome {
        let confirmed = await leaveRemote()
        settings.connectionMode = .local
        if settings.autoStart && settings.secretsLoaded { engine.start() }
        return confirmed ? .done : .doneWithNote(removalNote)
    }

    /// 离开远程连接：先固定旧客户端，再作废会话代次，尽力自撤，最后清会话。返回自撤是否确认成功（无远程凭据时为 true）。
    private func leaveRemote() async -> Bool {
        let old = session.currentClient(timeout: 5) // 固定旧 Mac 的客户端，之后会话被清空也不影响自撤
        session.stopStream()
        var confirmed = true
        if let old { confirmed = await deleteSelf(old) }
        session.forget()
        notch?.resetConnection()
        return confirmed
    }

    /// 自撤：期限只由 BridgeClient 的 timeout 决定（Kit 的绝对期限），失败与超时都按未确认处理。
    private func deleteSelf(_ client: BridgeClient) async -> Bool {
        do {
            if let deleteSelfOverride { try await deleteSelfOverride(client) } else { try await client.deleteSelf() }
            return true
        } catch {
            return false
        }
    }
}
