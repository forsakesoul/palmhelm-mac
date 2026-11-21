import SwiftUI
import PalmhelmKit

// 设置 › 连接与设备 › 这台设备：改名走 Bridge 的自改名接口（O1-364 ④）。失败留在本区并给出原因，本地不改。
struct ThisDeviceNameRows: View {
    @Environment(MacSession.self) private var session
    @State private var text = ""
    @State private var message: LText?
    @State private var saving = false

    private var canSave: Bool { !saving && DeviceNameRules.clean(text) != nil && DeviceNameRules.clean(text) != session.deviceName }

    var body: some View {
        LabeledContent("当前名字", value: session.deviceName)
        TextField("新的名字", text: $text, prompt: Text("最多 32 个字，一行"))
            .onSubmit { if canSave { save() } }
        HStack {
            Button("保存名字") { save() }.disabled(!canSave)
            if saving { ProgressView().controlSize(.small) }
        }
        if let message { Text(message.text).font(.caption).foregroundStyle(PalmhelmTheme.warn) }
        Text("名字显示在手机的消息来源里，不影响连接与权限。").font(.caption).foregroundStyle(.secondary)
    }

    private func save() {
        saving = true
        Task {
            message = await session.renameThisDevice(text)
            saving = false
            if message == nil { text = "" }
        }
    }
}
