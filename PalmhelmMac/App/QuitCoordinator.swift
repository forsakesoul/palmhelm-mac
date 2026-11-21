import AppKit

// 退出决策（issue #54）：只有用户主动退出才确认（⌘Q、菜单「退出 Palmhelm」、Dock 退出）。
// 系统注销 / 重启 / 关机与脚本 quit（osascript）不弹，避免阻塞关机和部署。
// 确认后：Bridge 是后台运行的（启动时没有 BRIDGE_PARENT_PID）就直接退出、不停它；否则照旧先停 Bridge 再退出。

enum QuitRequest: Equatable {
    /// 没有 AppleEvent（⌘Q、菜单、Dock 退出）或 Dock 发来的 quit：用户主动退出。
    case user
    /// 带 why? 属性的 quit：系统注销 / 重启 / 关机。
    case system
    /// 其他 AppleEvent（osascript quit、其他进程发来的事件）。
    case scripted
}

/// 退出请求上的 AppleEvent 信息（读取自 NSAppleEventManager.currentAppleEvent，测试里直接构造）。
struct QuitEventInfo: Equatable {
    /// 事件类别 aevt、事件号 quit。
    let isQuit: Bool
    /// 带 why? 属性（系统注销 / 重启 / 关机才会带）。
    let hasReason: Bool
    /// 发送者是 Dock。
    let senderIsDock: Bool

    /// 当前正在处理的 AppleEvent；没有则为 nil（⌘Q / 菜单 / 程序内 terminate）。
    @MainActor
    static func current(probe: BridgeProcessProbing) -> QuitEventInfo? {
        NSAppleEventManager.shared().currentAppleEvent.map { from($0, probe: probe) }
    }

    /// 从一个真实的 AppleEvent 描述符取出退出信息。why? 是 kAEQuitApplication 的**参数**（paramDescriptor），不是属性。
    /// senderPID：发送者进程号；默认从 'spid' 属性读取（系统投递时填入，构造的事件里无法伪造，测试里显式传入）。
    static func from(_ ev: NSAppleEventDescriptor, probe: BridgeProcessProbing, senderPID explicitPID: Int32? = nil) -> QuitEventInfo {
        let isQuit = ev.eventClass == 0x6165_7674 && ev.eventID == 0x7175_6974 // 'aevt' 'quit'
        let hasReason = ev.paramDescriptor(forKeyword: 0x7768_793F) != nil // 'why?'
        let senderPID = explicitPID ?? ev.attributeDescriptor(forKeyword: 0x7370_6964)?.int32Value // 'spid'（发送者进程号是属性）
        let senderPath = senderPID.flatMap { probe.snapshot(pid: $0)?.executable } ?? ""
        return QuitEventInfo(isQuit: isQuit, hasReason: hasReason, senderIsDock: senderPath.hasSuffix("/CoreServices/Dock.app/Contents/MacOS/Dock"))
    }
}

enum QuitPolicy {
    static func request(_ event: QuitEventInfo?) -> QuitRequest {
        guard let event else { return .user }
        if !event.isQuit { return .scripted }
        if event.hasReason { return .system }
        return event.senderIsDock ? .user : .scripted
    }

    /// 只有用户主动退出、且没有关闭「退出前确认」时才弹窗。
    static func shouldConfirm(_ request: QuitRequest, confirmEnabled: Bool) -> Bool {
        request == .user && confirmEnabled
    }

    static func alertText(keepsAfterQuit: Bool) -> (title: String, text: String) {
        (
            String(localized: "退出 Palmhelm？"),
            keepsAfterQuit ? String(localized: "Bridge 会继续在后台运行，手机仍可连接。") : String(localized: "Bridge 会一起停止，手机将连不上这台 Mac。")
        )
    }
}

struct QuitAnswer: Equatable {
    let quit: Bool
    /// 勾选了「不再询问」。
    let suppress: Bool
}

/// 确认弹窗的接缝：生产用原生 NSAlert，测试注入假回答。
@MainActor
protocol QuitConfirming {
    func confirm(keepsAfterQuit: Bool) -> QuitAnswer
}

@MainActor
struct QuitAlertConfirmer: QuitConfirming {
    func confirm(keepsAfterQuit: Bool) -> QuitAnswer {
        let copy = QuitPolicy.alertText(keepsAfterQuit: keepsAfterQuit)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.text
        alert.addButton(withTitle: String(localized: "退出"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r" // 回车默认取消：误按回车不会退出
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "不再询问")
        let answer = alert.runModal()
        return QuitAnswer(quit: answer == .alertFirstButtonReturn, suppress: alert.suppressionButton?.state == .on)
    }
}

enum QuitOutcome: Equatable {
    case cancel
    /// 直接退出（没有 Bridge，或 Bridge 是后台运行的）。
    case quitNow
    /// 先停止 Bridge（SIGTERM，超时强杀），再退出。
    case stopBridgeThenQuit
    /// 后台 Bridge 正在重启（旧的已停、新的还没起）：等这次事务完成后再决定，绝不在零个 Bridge 的时刻退出（R5）。
    case deferUntilRestartDone
}

@MainActor
struct QuitCoordinator {
    let settings: EngineSettings
    let engine: BridgeEngine
    let confirmer: any QuitConfirming

    func decide(event: QuitEventInfo?) -> QuitOutcome {
        if QuitPolicy.shouldConfirm(QuitPolicy.request(event), confirmEnabled: settings.confirmQuit) {
            let answer = confirmer.confirm(keepsAfterQuit: engine.keepsAfterQuit)
            // 「不再询问」跟随所选动作：只有点了「退出」才保存；取消时不保存，下次 ⌘Q 照常询问
            if answer.quit && answer.suppress { settings.confirmQuit = false }
            if !answer.quit { return .cancel }
        }
        if engine.backgroundRestartInFlight { return .deferUntilRestartDone }
        return afterConfirmation()
    }

    /// 确认之后（或等待重启结束之后）的退出方式：不再弹窗。
    func afterConfirmation() -> QuitOutcome {
        guard engine.childRunning else { return .quitNow }
        return engine.isBackground ? .quitNow : .stopBridgeThenQuit
    }
}
