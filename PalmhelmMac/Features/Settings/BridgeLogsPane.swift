import AppKit
import SwiftUI

/// 设置页的 Bridge 日志（A1-081 片 2）：上方是持久文件 logs/bridge.log 的最近 500 行，只在本页可见时每 2 秒重读（离开页面即取消，轮转后自然读到新文件）；
/// 下方是本次 App 的内存记录（含 App 自己的诊断）。持久行只展示，不驱动 Bridge 的状态。
struct BridgeLogsPane: View {
    let engine: BridgeEngine
    @State private var persisted: [String] = []
    @State private var note: LText?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bridge 日志（持久，最近 500 行）").font(.headline)
                Spacer()
                Button("复制全部") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(persisted.joined(separator: "\n"), forType: .string) }
            }
            ScrollView {
                Text(persisted.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(PalmhelmTheme.card2, in: RoundedRectangle(cornerRadius: 8))
            if let note { Text(note.text).font(.caption).foregroundStyle(.secondary) }
            Text("本次 App 记录（内存）").font(.subheadline.weight(.semibold))
            ScrollView {
                Text(engine.logs.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .background(PalmhelmTheme.card2, in: RoundedRectangle(cornerRadius: 8))
            Text("日志只含结构化字段，不含消息正文与凭据。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 活动数据目录：本次启动（或接管）冻结的目录；从未启动时用设置里的目录。
    private var dataDir: String { engine.activeDataDir.isEmpty ? engine.settings.dataDir : engine.activeDataDir }

    private func reload() async {
        let dir = dataDir
        let result = await Task.detached(priority: .utility) { BridgeLogFile.tail(dataDir: dir) }.value
        switch result {
        case .lines(let lines):
            persisted = lines
            note = nil
        case .absent:
            persisted = []
            note = LText(String(localized: "还没有持久日志（Bridge 启动后写入；旧版 Bridge 替换后才开始写）"))
        case .unsafe(let reason):
            persisted = []
            note = LText(String(localized: "日志文件不可读取（\(reason)），不影响服务"))
        }
    }
}
