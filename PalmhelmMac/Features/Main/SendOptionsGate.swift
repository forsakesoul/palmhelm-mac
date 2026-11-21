import Foundation
import PalmhelmKit

/// 打开发送方式浮层时的票据：线程、连接代次、直达 agent（路由）。选择时与「当前票据」比对，任一变化即旧浮层。
struct SendOptionsTicket: Equatable {
    let threadId: String?
    let epoch: Int
    let agent: String?
    let linkConnected: Bool
}

/// 选择复核（与 iOS 同一规则；Kit 不由本片改，故两端各一份）：票据未变、仍支持发送时机、当前菜单里该项仍可用，才放行；
/// 不满足零发送，不把旧的显式选择降级成普通发送（MacSession 会把不支持的 mode 去掉，所以必须在入口拦住）。
enum SendOptionsGate {
    static func permits<T: Equatable>(opened: T?, current: T, supportsSendTiming: Bool, items: [SendMenuItem], choice: SendMenuChoice) -> Bool {
        guard let opened, opened == current, supportsSendTiming else { return false }
        return items.first(where: { $0.choice == choice })?.enabled == true
    }
}

/// 当前路由 / 票据的纯派生（A1-002）：选择函数必须在选择当刻从当前 Session 重读这些事实，不能用渲染闭包里捕获的旧 agent。
enum SendOptionsRoute {
    /// 线程≠绑定且 agent 名可直达时返回该 agent 名（与 MainWindow.directAgent 同一规则）。
    static func directAgent(threadId: String?, bindingTargetId: String?, agentName: String?) -> String? {
        guard let threadId, bindingTargetId != threadId else { return nil }
        return OwnerCommand.canDirect(agentName: agentName) ? agentName : nil
    }

    static func ticket(threadId: String?, epoch: Int, linkConnected: Bool, bindingTargetId: String?, agentName: String?) -> SendOptionsTicket {
        SendOptionsTicket(threadId: threadId, epoch: epoch, agent: directAgent(threadId: threadId, bindingTargetId: bindingTargetId, agentName: agentName), linkConnected: linkConnected)
    }
}
