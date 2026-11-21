import Foundation

/// 线程会话读取的前台门禁（Mac）：线程可见、窗口为 key、窗口未被遮挡（隐藏、最小化或被完全遮挡时 occlusionState 不含 visible）、且显示对话（非终端页）。
/// 只有四者同时成立时才发起会话读取，否则停止激活（#88 S4）。
enum ThreadActivityGate {
    static func isActive(threadVisible: Bool, keyWindow: Bool, windowVisible: Bool, mode: Int) -> Bool {
        threadVisible && keyWindow && windowVisible && mode == 0
    }
}
