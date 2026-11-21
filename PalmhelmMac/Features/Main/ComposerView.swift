import AppKit
import SwiftUI

// 线程输入区（B3）：多行草稿（Return 发送、Shift+Return 换行，最多约 8 行后内部滚动）与图片附件。
// 附件只以路径引用，图片字节不经 Bridge：拖入 / 粘贴的图片「文件」按原路径引用（不复制、不清理）；剪贴板里没有文件的位图转 PNG 写进本 App 的缓存目录（AttachmentCache）。

struct ComposerAttachment: Identifiable {
    let id = UUID()
    let path: String
    let thumbnail: NSImage
    var source: AttachmentSource = .userReference
}

/// 剪贴板 / 拖入的一项图片内容。
enum ComposerImageItem {
    case file(URL)       // 有 file URL：按原路径引用
    case bitmap(NSImage) // 没有文件的位图（截图等）：落缓存
}

/// 粘贴动作的归属：有图片文件优先按文件引用（Finder 里复制文件时剪贴板同时带文件名字符串）；没有文件且没有文本才当位图；其余走普通粘贴。
enum ComposerPasteDecision: Equatable { case text, files, bitmaps }

enum ComposerAttachments {
    static let fileTypes: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic"]

    static func pasteDecision(hasFiles: Bool, hasBitmaps: Bool, hasString: Bool) -> ComposerPasteDecision {
        if hasFiles { return .files }
        if hasBitmaps && !hasString { return .bitmaps }
        return .text
    }

    /// 移除只让附件脱离草稿：不碰任何文件（缓存位图统一按 7 天清理，不做引用计数；用户文件绝不删）。不可编辑时是 no-op。
    @discardableResult
    static func remove(_ a: ComposerAttachment, from list: inout [ComposerAttachment], editable: Bool) -> Bool {
        guard editable, let i = list.firstIndex(where: { $0.id == a.id }) else { return false }
        list.remove(at: i)
        return true
    }

    /// 加入列表。不可编辑时既不落盘也不改列表。文件缺失 / 不可读给错误并保留草稿；缓存失败给错误。返回面向用户的错误文案（成功为 nil）。
    @discardableResult
    static func add(_ items: [ComposerImageItem], to list: inout [ComposerAttachment], editable: Bool, cacheDir: URL = AttachmentCache.defaultDirectory) -> LText? {
        guard editable else { return nil }
        var failure: LText?
        for item in items {
            switch item {
            case .file(let url):
                guard FileManager.default.isReadableFile(atPath: url.path), let img = NSImage(contentsOf: url) else { failure = LText(String(localized: "文件不存在或读不了：\(url.lastPathComponent)")); continue }
                list.append(ComposerAttachment(path: url.path, thumbnail: img, source: .userReference))
            case .bitmap(let img):
                do { list.append(ComposerAttachment(path: try AttachmentCache.store(img, in: cacheDir), thumbnail: img, source: .cachedBitmap)) }
                catch let e as AttachmentCache.Failure { failure = e.message }
                catch { failure = LText(String(localized: "图片没能保存，请再试一次")) }
            }
        }
        return failure
    }

    /// 剪贴板或拖入内容里的图片：图片文件（png/jpg/jpeg/tif/tiff/heic）优先；没有文件时是位图对象（截图等）。
    static func items(from pb: NSPasteboard) -> [ComposerImageItem] {
        let files = imageFiles(pb)
        if !files.isEmpty { return files.map { .file($0) } }
        return (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []).map { .bitmap($0) }
    }

    static func decision(for pb: NSPasteboard) -> ComposerPasteDecision {
        pasteDecision(hasFiles: !imageFiles(pb).isEmpty, hasBitmaps: pb.canReadObject(forClasses: [NSImage.self], options: nil), hasString: pb.string(forType: .string) != nil)
    }

    /// 只看类型、不解码：拖动过程中反复调用，不能每次读图。
    static func hasImages(_ pb: NSPasteboard) -> Bool {
        !imageFiles(pb).isEmpty || pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func imageFiles(_ pb: NSPasteboard) -> [URL] {
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return files.filter { fileTypes.contains($0.pathExtension.lowercased()) }
    }
}

struct ComposerView: View {
    @Binding var draft: String
    @Binding var attachments: [ComposerAttachment]
    let enabled: Bool
    let placeholder: String
    let onSubmit: () -> Void
    let onError: (LText) -> Void
    /// ⌘↩：由调用方决定（工作中且支持则立即插入；不支持则拦下并说明，绝不排队）。
    var onSubmitCommand: (() -> Void)? = nil
    /// 草稿身份（连接身份 + 目标）：输入控件据此区分“同一草稿的普通重算”与“换了编辑对象”。
    let scope: String
    /// 发送入口的组字准入：组字中点发送只确认候选，不发送。
    let gate: ComposerCompositionGate
    @State private var height: CGFloat = 24

    var body: some View {
        let _ = MacRenderCounter.bump("composer") // 测试：输入区 body 求值次数（发布版为空操作）
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { a in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: a.thumbnail).resizable().scaledToFill()
                                    .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
                                Button { ComposerAttachments.remove(a, from: &attachments, editable: enabled) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.5))
                                }
                                .buttonStyle(.plain).offset(x: 6, y: -6).disabled(!enabled)
                                .accessibilityLabel("删除图片")
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            ZStack(alignment: .topLeading) {
                ComposerTextField(text: $draft, height: $height, enabled: enabled, scope: scope, gate: gate, onSubmit: onSubmit, onSubmitCommand: onSubmitCommand, onImages: { items in
                    if let err = ComposerAttachments.add(items, to: &attachments, editable: enabled) { onError(err) }
                })
                    .frame(height: height)
                if draft.isEmpty {
                    Text(placeholder).foregroundStyle(.secondary).padding(.leading, 5).padding(.top, 4).allowsHitTesting(false)
                }
            }
        }
    }
}

/// 输入区的状态转换（纯规则，便于测试）：编辑守卫、业务拒绝后的恢复、发送收尾。
/// 发送期间（busy）整个输入区冻结：恢复与编辑都不得改动草稿或附件。
enum ComposerRules {
    /// 输入框自适应的上限行数（超过后内部滚动，#57）。
    static let inputMaxLines = 14
    static func canEdit(canControl: Bool, busy: Bool) -> Bool { canControl && !busy }

    /// 路径里已不存在 / 读不了的文件名（用于发送前与恢复前的完整验证）。
    static func missingFiles(paths: [String]) -> [String] {
        paths.filter { !FileManager.default.isReadableFile(atPath: $0) }.map { ($0 as NSString).lastPathComponent }
    }

    /// 把一条被拒的发送恢复到输入框；不可编辑时 no-op 并返回 false（调用方据此不标记已恢复）。
    /// 先完整验证：任何附件缺失 / 解不开都整个不恢复（草稿与附件原样不动、返回 false），不会恢复一半。
    @discardableResult
    static func restore(_ m: MacSession.Sent, canEdit: Bool, draft: inout String, attachments: inout [ComposerAttachment]) -> Bool {
        guard canEdit else { return false }
        // 来源随快照保留：旧快照没有来源记录时按用户引用处理（宁可不清理）
        let restored: [ComposerAttachment] = m.attachmentPaths.enumerated().compactMap { i, p in
            NSImage(contentsOfFile: p).map { ComposerAttachment(path: p, thumbnail: $0, source: m.attachmentSources.indices.contains(i) ? m.attachmentSources[i] : .userReference) }
        }
        guard restored.count == m.attachmentPaths.count else { return false }
        draft = m.draft
        attachments = restored
        return true
    }

    /// 发送收尾：只要本次已入账（有发送记录，成功或失败）就清掉快照里的附件；草稿仅在期间未被改动时清空。守卫拦下（没有记录）保留全部。
    /// 发送结束后清掉本次快照：`recorded` 表示这次发送已入账（成功或失败都有记录）。没有记录（守卫拦下）时不动草稿（#57）。
    static func settle(recorded: Bool, draftSnap: String, attachSnap: [ComposerAttachment], draft: inout String, attachments: inout [ComposerAttachment]) {
        guard recorded else { return }
        let sentIds = Set(attachSnap.map(\.id))
        attachments.removeAll { sentIds.contains($0.id) }
        if draft == draftSnap { draft = "" }
    }
}

/// 发送入口的组字准入（按钮、时机菜单、Return、⌘↩ 共用）：输入法正在组字时，发送一律是无操作——
/// 不发送、不结束组字、不改组字内容。App 无法替输入法选出候选（结束组字只会留下拼音），所以确认候选完全交给输入法；
/// 用户确认之后的第一次操作才正常发送，快照里是输入法确认后的文字。没有“下一次放行”之类的状态。
@MainActor
final class ComposerCompositionGate {
    private weak var textView: NSTextView?

    func attach(_ tv: NSTextView) { textView = tv }

    var isComposing: Bool { textView?.hasMarkedText() == true }

    /// 返回 true 表示可以发送；组字中返回 false（本次什么都不做）。
    func admitsSend() -> Bool { !isComposing }
}

/// 基于 NSTextView 的输入框：SwiftUI 的 TextField 无法稳定区分 Return 与 Shift+Return，也拿不到粘贴图片。
@MainActor
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let enabled: Bool
    let scope: String
    let gate: ComposerCompositionGate?
    let onSubmit: () -> Void
    let onSubmitCommand: (() -> Void)?
    let onImages: ([ComposerImageItem]) -> Void
    static let maxLines = ComposerRules.inputMaxLines

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerNSTextView()
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.registerForDraggedTypes([.fileURL, .tiff, .png])
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        gate?.attach(tv)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? ComposerNSTextView else { return }
        gate?.attach(tv)
        context.coordinator.sync(self, to: tv)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextField
        /// 当前编辑的草稿身份：变化即换了编辑对象，旧组字必须作废，不能写进新草稿。
        private(set) var scope: String
        init(_ parent: ComposerTextField) { self.parent = parent; self.scope = parent.scope }

        /// updateNSView 的全部同步：先处理编辑对象变化（作废旧组字、采纳新草稿），再换 parent，最后才改可编辑状态。
        /// 顺序很重要：停用输入会让 AppKit 立即结束组字并回调 delegate，那时 parent 必须已经是新草稿且组字已被清掉。
        func sync(_ field: ComposerTextField, to tv: ComposerNSTextView) {
            if field.scope != scope { rebind(to: field, tv) }
            parent = field
            tv.onSubmit = field.onSubmit
            tv.onSubmitCommand = field.onSubmitCommand
            tv.onImages = field.onImages
            tv.isEditable = field.enabled
            applyExternal(field.text, to: tv)
            updateHeight(tv)
        }

        /// 换了草稿：旧草稿的组字与待应用的外部改写一并作废；写入期间抑制 delegate，旧回调不会写新 parent。
        private func rebind(to field: ComposerTextField, _ tv: NSTextView) {
            isSynchronizing = true
            tv.inputContext?.discardMarkedText()
            tv.unmarkText()
            tv.string = field.text
            tv.setSelectedRange(NSRange(location: (field.text as NSString).length, length: 0))
            isSynchronizing = false
            scope = field.scope
            synced = field.text
            pendingExternal = nil
            parent = field
        }

        /// 与视图内容一致的最近文本。组字期间视图含未提交的候选，binding 不含，所以不能用“视图与 binding 不同”判断外部改写。
        private(set) var synced = ""  // 新视图为空，与 binding 的初始值一致
        /// 组字期间到达的外部改写（如发送后清空）：等组字提交后再应用，并覆盖提交得到的文本，外部改写优先。
        private(set) var pendingExternal: String?
        /// 程序化写入视图期间不把 textDidChange 当作用户输入回写 binding。
        private var isSynchronizing = false

        /// 把 binding 的外部值同步到视图。组字中只记录，不触碰视图（否则 AppKit 会取消组字）。
        func applyExternal(_ text: String, to tv: NSTextView) {
            if tv.hasMarkedText() {
                if text != synced { pendingExternal = text; synced = text }
                return
            }
            pendingExternal = nil
            synced = text
            if tv.string != text { write(text, to: tv) }
        }

        private func write(_ text: String, to tv: NSTextView) {
            isSynchronizing = true
            tv.string = text
            isSynchronizing = false
        }

        func textDidChange(_ n: Notification) {
            guard !isSynchronizing, let tv = n.object as? NSTextView else { return }
            if !tv.hasMarkedText(), let external = pendingExternal {
                pendingExternal = nil
                write(external, to: tv)
                synced = external
                parent.text = external
                updateHeight(tv)
                return
            }
            parent.text = tv.string
            synced = tv.string
            updateHeight(tv)
        }

        // 行数随内容增长，超过上限后由 NSScrollView 内部滚动。
        func updateHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = lm.defaultLineHeight(for: tv.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let h = min(max(used, line + 8), line * CGFloat(ComposerTextField.maxLines) + 8)
            guard abs(parent.height - h) > 0.5 else { return }
            let binding = parent.$height
            DispatchQueue.main.async { binding.wrappedValue = h } // 不在视图更新期间改写状态
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onSubmitCommand: (() -> Void)?
    var onImages: (([ComposerImageItem]) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // 输入法组合中的回车只确认候选词，不发送
        if isReturn, !event.modifierFlags.contains(.shift), !hasMarkedText() {
            if event.modifierFlags.contains(.command), let onSubmitCommand { onSubmitCommand(); return }
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pb = NSPasteboard.general
        if ComposerAttachments.decision(for: pb) != .text {
            let items = ComposerAttachments.items(from: pb)
            if !items.isEmpty { onImages?(items); return }
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return ComposerAttachments.hasImages(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        let items = ComposerAttachments.items(from: sender.draggingPasteboard)
        if !items.isEmpty { onImages?(items); return true }
        return super.performDragOperation(sender)
    }
}
