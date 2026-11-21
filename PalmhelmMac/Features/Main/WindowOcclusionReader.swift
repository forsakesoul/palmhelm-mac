import AppKit
import SwiftUI

/// 把所在窗口的可见性（NSWindow.occlusionState 是否含 visible）报给 SwiftUI：隐藏、最小化或被完全遮挡时为 false。
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> OcclusionView {
        let view = OcclusionView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: OcclusionView, context: Context) {
        view.onChange = onChange
    }
}

final class OcclusionView: NSView {
    var onChange: ((Bool) -> Void)?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else {
            onChange?(false)
            return
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] note in
            guard let w = note.object as? NSWindow else { return }
            let visible = w.occlusionState.contains(.visible)
            MainActor.assumeIsolated { self?.onChange?(visible) }
        }
        onChange?(window.occlusionState.contains(.visible))
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
