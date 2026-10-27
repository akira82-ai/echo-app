import SwiftUI
import AppKit
import QuartzCore
import MarkdownConversion
import Calculator

/// Menu-bar panels have no Edit menu to route standard editing shortcuts.
private final class QuickPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow, let editor = firstResponder as? NSTextView,
              (editor.isFieldEditor || editor is ModeSearchTextView), editor.isEditable else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command {
            switch key {
            case "a": editor.selectAll(nil); return true
            case "v": editor.pasteAsPlainText(nil); return true
            case "x": editor.cut(nil); return true
            case "c": editor.copy(nil); return true
            case "z":
                if let undo = editor.undoManager, undo.canUndo {
                    undo.undo(); return true
                }
            default: break
            }
        } else if modifiers == [.command, .shift], key == "z",
                  let undo = editor.undoManager, undo.canRedo {
            undo.redo(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// QuickPanel:Spotlight 风格的剪贴板历史选择浮层。
///
/// 设计依据(详见 design-plan.html 板块5、6):
/// - **NSPanel + nonactivating**:浮层不抢目标 App 焦点(关键:粘贴需要目标 App 仍是 key)
/// - **三种选择方式**:数字直达 / 关键词搜索 / 方向键导航(同一输入框智能识别)
/// - **失焦即关 / Esc 即关**:工具类产品零打扰
/// - 列表按"最近在前":第 1 条 = 最近复制的,数字直达语义自然
///
/// 交互逻辑(详见 design-plan.html 板块6):
/// - 输入 1–5 → 视为当前页编号,回车直达该条
/// - 输入 6 及以上或含非数字字符 → 视为搜索词,对文本/文件做子串过滤(图片不参与搜索)
/// - 不输入 → 方向键浏览,默认高亮第 1 条
/// - 按住 Command 点击或回车 → 将当前文本加入/移出批次;松开后回车合并批次并粘贴
///
/// 选中后通过 onSelected 回调把 entry 交给 Paster(Stage 4)。
final class QuickPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickPanelController()

    private enum Layout {
        static let panelWidth: CGFloat = 560
        static let panelHeight: CGFloat = 434
    }

    /// 选中某条历史项时调用(主线程)。
    var onSelected: ((ClipEntry, AchievementStore.SelectionContext, Paster.PasteFormat) -> Void)?
    /// 选中一批文本历史项时调用(主线程)。
    var onBatchSelected: (([ClipEntry], AchievementStore.SelectionContext) -> Void)?

    /// 承载 SwiftUI 内容的非激活式浮层
    private var panel: NSPanel?
    /// 当前显示的历史快照
    private var currentEntries: [ClipEntry] = []
    /// SwiftUI 视图模型(驱动列表与选中状态)
    private let viewModel = QuickPanelViewModel()
    /// 本地键盘事件监听器(面板显示期间接收方向键/回车/Esc/修饰键状态)
    private var keyMonitor: Any?
    private var conversionTask: Task<Void, Never>?
    private var conversionID: UUID?
    private var lastChatQuery: String?
    private var lastChatPage: [QuickPanelViewModel.DisplayItem] = []
    private var lastChatReference: QuickPanelViewModel.DisplayItem?

    private override init() {
        super.init()
    }

    // MARK: - 显示 / 隐藏

    /// 面板显示前的最前台 App(粘贴时需要激活它,让 ⌘V 送对地方)
    private(set) var frontmostAppAtShowTime: NSRunningApplication?

    /// 显示面板:读取历史快照、定位到屏幕中央、设为 key 窗口。
    func show() {
        let restoredChatQuery = viewModel.isChat ? viewModel.query : lastChatQuery
        let restoredPage = viewModel.isChat ? viewModel.chatPage : lastChatPage
        let restoredReference = viewModel.isChat ? viewModel.chatReference : lastChatReference
        Paster.shared.cancelPendingPaste()
        let entries = HistoryStore.shared.snapshot()
        currentEntries = entries
        AchievementStore.shared.recordPanelShown()

        // 先关闭旧面板(必须在 configure 之前,否则 hide 的 reset 会清空新数据)
        hide()

        // 记录当前最前台 App——选中条目粘贴时,要激活它让 ⌘V 送达
        frontmostAppAtShowTime = NSWorkspace.shared.frontmostApplication

        viewModel.configure(entries: entries)
        if let restoredChatQuery {
            viewModel.inputMode = .chat
            viewModel.restoreChat(page: restoredPage, reference: restoredReference, query: restoredChatQuery)
        }
        let viewModel = self.viewModel
        let hosting = NSHostingController(rootView: QuickPanelView(viewModel: viewModel) { [weak self] entry in
            self?.handleSelected(entry, source: .mouse, format: .original)
        })

        let panel = Self.makePanel(contentViewController: hosting)
        panel.delegate = self
        self.panel = panel

        // 装本地键盘监听器:方向键/回车/Esc/Command 修饰键状态
        installKeyMonitor()

        // 居中并显示
        // 面板需要 activate 才能接收键盘输入(TextField 聚焦 + NSEvent monitor)。
        // 选中条目后,Paster 会在粘贴前激活目标 App。
        NSApp.activate(ignoringOtherApps: true)
        panel.setContentSize(NSSize(width: Layout.panelWidth, height: Layout.panelHeight))
        centerOnScreen(panel)
        preparePanelEntrance(panel)
        panel.makeKeyAndOrderFront(nil)
        animatePanelEntrance(panel)
        DispatchQueue.main.async { [weak self] in self?.placeSearchCaretAtEnd() }
    }

    func placeSearchCaretAtEnd() {
        guard let field = panel?.firstResponder as? NSTextView,
              !field.hasMarkedText(), field.string == viewModel.query else { return }
        field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
    }

    func sendChatQuestion() {
        guard !viewModel.chat.busy else { return }
        viewModel.sendChat()
        guard viewModel.chat.busy else { return }
        if let editor = panel?.firstResponder as? ModeSearchTextView {
            editor.collapseIfExpanded()
        }
        placeSearchCaretAtEnd()
        // SwiftUI's submit handling can select the field after the key event returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewModel.chat.busy else { return }
            self.placeSearchCaretAtEnd()
        }
    }

    /// 隐藏面板。
    func hide() {
        lastChatQuery = viewModel.isChat ? viewModel.query : nil
        lastChatPage = viewModel.isChat ? viewModel.chatPage : []
        lastChatReference = viewModel.isChat ? viewModel.chatReference : nil
        viewModel.chat.reset()
        conversionID = nil
        conversionTask?.cancel()
        conversionTask = nil
        // 卸载键盘监听器
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        viewModel.reset()
    }

    // MARK: - 键盘监听

    /// 装本地键盘事件监听器,处理方向键导航 / 回车确认 / Esc 取消与 Command 状态。
    /// 用 NSEvent.addLocalMonitorForEvents(兼容 macOS 13,替代 SwiftUI onKeyPress 的 macOS 14 要求)。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
    }

    /// 处理一次按键。返回 nil 表示吞掉该事件,返回 event 表示放行。
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, panel?.isKeyWindow == true else { return event }
        if viewModel.isConverting {
            if event.type == .keyDown && event.keyCode == 53 { hide() }
            return nil
        }
        if event.type == .flagsChanged {
            viewModel.setCommandPressed(event.modifierFlags.contains(.command))
            return event
        }
        if let editor = panel?.firstResponder as? ModeSearchTextView {
            // IME owns composition keys, including Return, arrows and Escape.
            if editor.hasMarkedText() { return event }
            if event.keyCode == 53, editor.collapseIfExpanded() { return nil }
            if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.shift) { return event }
            if [123, 124].contains(event.keyCode), !editor.string.isEmpty { return event }
            if editor.isExpanded && [125, 126, 51].contains(event.keyCode) { return event }
        }
        if viewModel.isChat {
            if event.keyCode == 53 { hide(); return nil }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let field = panel?.firstResponder as? NSTextView, field.hasMarkedText() { return event }
                if !event.modifierFlags.contains(.command) {
                    sendChatQuestion()
                }
                return nil
            }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                // Let the native responder copy a selection in either the question or answer.
                if let field = panel?.firstResponder as? NSTextView {
                    if field.hasMarkedText() || field.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) {
                        return event
                    }
                }
                guard !viewModel.chat.busy, viewModel.chat.errorKey == nil, !viewModel.chat.answer.isEmpty else { return event }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.chat.answer, forType: .string)
                return nil
            }
            return event
        }
        if viewModel.isCalculator {
            if event.keyCode == 53 { hide(); return nil }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let result = viewModel.calculationResult {
                    let entry = ClipEntry(kind: .text(TextPayload(rawText: result, representations: [])))
                    let context = viewModel.selectionContext(source: .keyboard)
                    hide()
                    onSelected?(entry, context, .original)
                }
                return nil
            }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "c",
               let field = panel?.firstResponder as? ModeSearchTextView,
               field.selectedRange().length == 0,
               let result = viewModel.calculationResult {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                return nil
            }
            return event
        }
        if event.keyCode == 48 { // Tab
            guard !viewModel.showsAchievements else { return nil }
            viewModel.toggleShortcutGuide()
            return nil
        }
        if viewModel.showsShortcutGuide {
            if event.keyCode == 53 { // Esc
                hide()
            }
            return nil
        }
        if viewModel.showsAchievements {
            switch event.keyCode {
            case 53: // Esc
                hide()
                return nil
            default:
                return nil
            }
        }
        switch event.keyCode {
        case 126:  // ↑
            viewModel.moveUp()
            return nil
        case 125:  // ↓
            viewModel.moveDown()
            return nil
        case 123:  // ←
            viewModel.movePrevPage()
            return nil
        case 124:  // →
            viewModel.moveNextPage()
            return nil
        case 36, 76:  // Return / Enter
            if event.modifierFlags.contains(.control) {
                if let url = viewModel.selectedEntry()?.browserSource?.url {
                    hide()
                    NSWorkspace.shared.open(url)
                }
                return nil
            }
            if event.modifierFlags.contains(.command) {
                viewModel.toggleBatchSelection()
                return nil
            }
            if let entries = viewModel.batchEntries(), !entries.isEmpty {
                let context = viewModel.selectionContext(source: .keyboard)
                if event.modifierFlags.contains(.option) {
                    convertAndPaste(entries, context: context)
                    return nil
                }
                hide()
                onBatchSelected?(entries, context)
                return nil
            }
            if let entry = viewModel.selectedEntry() {
                let format: Paster.PasteFormat = event.modifierFlags.contains(.option)
                    ? .markdown
                    : .original
                handleSelected(entry, source: .keyboard, format: format)
            }
            return nil
        case 51:  // ⌫ Backspace
            // 仅当按住 ⌥ 时才视为「删除当前条目」,否则放行给搜索框删文字(避免冲突)
            if event.modifierFlags.contains(.option) {
                viewModel.deleteSelected { stillHasContent in
                    if !stillHasContent {
                        hide()  // 删空了,关闭面板
                    }
                }
                return nil  // 吞掉事件,防止 ⌥⌫ 冒泡
            }
            return event
        case 53:  // Esc
            hide()
            return nil
        default:
            return event
        }
    }

    // MARK: - 选中处理

    private func handleSelected(
        _ entry: ClipEntry,
        source: AchievementStore.SelectionSource,
        format: Paster.PasteFormat
    ) {
        guard !viewModel.isConverting else { return }
        let context = viewModel.selectionContext(source: source)
        if format == .markdown, case .text = entry.kind {
            convertAndPaste([entry], context: context)
            return
        }
        hide()
        onSelected?(entry, context, .original)
    }

    private func convertAndPaste(_ entries: [ClipEntry], context: AchievementStore.SelectionContext) {
        guard !viewModel.isConverting else { return }
        let id = UUID()
        conversionID = id
        let target = frontmostAppAtShowTime
        let changeCount = NSPasteboard.general.changeCount
        viewModel.isConverting = true
        viewModel.conversionNotice = nil
        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var results: [String] = []
                for entry in entries {
                    try Task.checkCancellation()
                    results.append(try await MarkdownCache.shared.value(for: entry.id))
                }
                try Task.checkCancellation()
                guard self.conversionID == id else { return }
                guard NSPasteboard.general.changeCount == changeCount else {
                    throw ProbeError.message(L10n.text("quick.markdown.clipboardChanged"))
                }
                let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard foreground == ProcessInfo.processInfo.processIdentifier || foreground == target?.processIdentifier else {
                    self.hide(); return
                }
                self.hide()
                Paster.shared.pasteMarkdown(results.joined(separator: "\n\n"), context: context, targetApp: target, expectedChangeCount: changeCount)
            } catch {
                guard self.conversionID == id, !Task.isCancelled else { return }
                self.viewModel.isConverting = false
                self.viewModel.conversionNotice = L10n.text("quick.markdown.failed") + " " + error.localizedDescription
                self.conversionTask = nil
            }
        }
    }

    // MARK: - NSWindowDelegate

    /// 失焦即关:面板失去 key 状态时自动关闭(零打扰)。
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Panel 工厂

    /// 构造一个非激活式、毛玻璃浮层,使用系统原生标题栏。
    ///
    /// 取舍说明:.nonactivatingPanel(为保证粘贴时目标 App 仍是 key 窗口)下系统不渲染交通灯,
    /// 多种强制显示手段均无效,故放弃交通灯——标题栏只显示 "Echo" 文字(左上角留空)。
    /// 这是「不抢焦点」与「显示交通灯」之间的取舍,前者对粘贴功能是硬需求。
    private static func makePanel(contentViewController: NSViewController) -> NSPanel {
        let styleMask: NSWindow.StyleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]
        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = contentViewController
        // 显式设置内容尺寸,防止 SwiftUI 视图 intrinsic size 没撑开导致面板为 0
        panel.contentViewController?.view.frame = NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight)
        panel.setContentSize(NSSize(width: Layout.panelWidth, height: Layout.panelHeight))
        panel.setFrame(NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight), display: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        // 系统原生标题栏:显示 Echo 标题 + 真实交通灯(保持系统默认外观)
        panel.title = "Echo"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        return panel
    }

    /// 把面板居中显示在鼠标所在的屏幕(贴近用户视线焦点)。
    ///
    /// 垂直定位说明:面板**视觉中心**落在屏幕可见区中线**偏上**一点点。
    /// Cocoa 坐标系原点在左下角,setFrameOrigin 设的是面板左下角,
    /// 所以左下角 y = 期望中心 y − 面板高度 / 2。
    private func centerOnScreen(_ panel: NSPanel) {
        // 找鼠标所在屏幕;无则回退主屏
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        // 面板视觉中心目标:水平居中,垂直 = 屏幕中线偏上约 8% 屏高
        let desiredCenterX = screenFrame.midX
        let desiredCenterY = screenFrame.midY + screenFrame.height * 0.08
        // 反推左下角坐标
        let x = desiredCenterX - panelSize.width / 2
        let y = desiredCenterY - panelSize.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Prepares and plays the short drop-in used when the panel appears.
    private func preparePanelEntrance(_ panel: NSPanel) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            return
        }

        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + 8))
    }

    private func animatePanelEntrance(_ panel: NSPanel) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let finalOrigin = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y - 8)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(finalOrigin)
            panel.animator().alphaValue = 1
        }
    }
}

// MARK: - 视图模型

/// 驱动 QuickPanel 列表与选中状态的视图模型。
final class QuickPanelViewModel: ObservableObject {
    @Published var isConverting = false
    @Published var conversionNotice: String?
    /// 全部历史(最近在前)
    @Published private(set) var allEntries: [ClipEntry] = []

    /// 每页显示条数(分页后每页固定 5 条)。
    /// 设为 internal 以便 View 据此渲染固定数量的行槽位(含空槽)。
    let pageSize = 5

    /// 当前页码(0-based,0 = 第 1 页)
    @Published private(set) var currentPage = 0

    /// 搜索/编号输入框文本
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            refreshInput()
        }
    }

    @Published var inputMode: QuickInputMode = .search {
        didSet {
            guard inputMode != oldValue else { return }
            if inputMode == .chat { chatPage = pageItems }
            chatReference = nil
            chatReferenceNotice = nil
            refreshInput()
        }
    }

    private func refreshInput() {
        guard !isConfiguring else { return }
        chat.reset()
        chatReferenceNotice = nil
        calculation = isCalculator ? Calculator.evaluate(query) : .empty
        if isChat || isCalculator {
            batchSelectionIDs = []
            batchNotice = nil
        } else {
            applyFilter()
        }
    }

    var isCalculator: Bool { inputMode == .calculator }
    var isChat: Bool { inputMode == .chat }
    let chat = ChatState()
    @Published private(set) var chatPage: [DisplayItem] = []
    @Published private(set) var chatReference: DisplayItem?
    @Published private(set) var chatReferenceNotice: String?

    var showsChatChoices: Bool { chatReference == nil && query.isEmpty }

    func selectChatReference(_ number: Int) {
        guard isChat, chatReference == nil, query.isEmpty else { return }
        guard let item = chatPage.first(where: { $0.displayNumber == number }) else {
            chatReferenceNotice = "chat.reference.missing"; return
        }
        guard case .text = item.entry.kind else {
            chatReferenceNotice = "chat.reference.unsupported"; return
        }
        chat.reset()
        chatReferenceNotice = nil
        chatReference = item
    }

    @discardableResult
    func cancelChatReference() -> Bool {
        guard chatReference != nil else { return false }
        chatReference = nil
        query = ""
        chatReferenceNotice = nil
        chat.reset()
        return true
    }

    func restoreChat(page: [DisplayItem], reference: DisplayItem?, query: String) {
        chatPage = page
        chatReference = reference
        self.query = query
    }

    func sendChat() {
        guard chatReferenceNotice == nil else { return }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if chatReference != nil { chatReferenceNotice = "chat.reference.instruction" }
            return
        }
        let context: String?
        if let reference = chatReference, case .text(let payload) = reference.entry.kind {
            context = payload.rawText
        } else { context = nil }
        chat.send(query, reference: context)
    }

    @Published private(set) var calculation: Calculation = .empty
    var calculationResult: String? {
        if case .result(let value) = calculation { return value }
        return nil
    }

    /// 过滤后的全量条目(搜索后),带原始全局序号(1-based)。
    /// 分页只取其中当前页的切片。
    @Published private(set) var displayed: [DisplayItem] = []

    /// 当前页内选中的序号(1-based,范围 1...pageSize)。
    /// 与 currentPage 配合定位最终条目:selectedEntry = 当前页第 selectedDisplayIndex 条。
    @Published var selectedDisplayIndex: Int = 1

    /// 正文显示模式:历史列表或勋章墙。
    @Published var showsAchievements = false

    /// 正文显示模式:快捷键说明页。与历史列表共用同一正文槽位。
    @Published var showsShortcutGuide = false

    /// 勋章墙快照。统计变化时由视图刷新。
    @Published private(set) var medals: [AchievementStore.Medal] = AchievementStore.shared.medals()

    /// 当前面板内待合并粘贴的文本条目,按加入顺序保存。
    @Published private(set) var batchSelectionIDs: [UUID] = []

    /// 最近一次批次操作提示。
    @Published private(set) var batchNotice: String?

    /// 文本批次最多允许选择的条数。
    let batchSelectionLimit = 5

    /// Command 是否处于按下状态,仅用于即时界面反馈。
    @Published private(set) var isCommandPressed = false

    /// Command 按下后是否已经通过方向键移动过,用于恢复当前行高亮。
    @Published private(set) var hasNavigatedWhileCommandPressed = false

    /// configure 进行中标志(禁止 query didSet 干扰)
    private var isConfiguring = false

    struct DisplayItem: Identifiable {
        let id: UUID           // 来自 ClipEntry.id
        let displayNumber: Int // 全局原始序号(1-based,搜索结果中的位次)
        let entry: ClipEntry
    }

    // MARK: - 分页

    /// 总页数(至少 1,空列表也是 1 页占位)
    var pageCount: Int {
        max(1, (displayed.count + pageSize - 1) / pageSize)
    }

    /// 当前页应渲染的条目(已重算为页内编号 1...pageSize)。
    /// 页内编号独立于全局序号:每页都从 1 开始,数字直达只对当前页生效。
    var pageItems: [DisplayItem] {
        guard !displayed.isEmpty else { return [] }
        let start = currentPage * pageSize
        let end = min(start + pageSize, displayed.count)
        guard start < end else { return [] }
        return displayed[start..<end].enumerated().map { localIndex, item in
            DisplayItem(id: item.id, displayNumber: localIndex + 1, entry: item.entry)
        }
    }

    /// 把 currentPage 钳制到合法范围,并重置页内选中到第 1 条。
    private func clampPageAndSelection() {
        if currentPage >= pageCount { currentPage = max(0, pageCount - 1) }
        if currentPage < 0 { currentPage = 0 }
        selectedDisplayIndex = pageItems.isEmpty ? 0 : 1
    }

    func configure(entries: [ClipEntry]) {
        isConfiguring = true
        allEntries = entries
        chatPage = []
        chatReference = nil
        chatReferenceNotice = nil
        inputMode = .search
        query = ""
        currentPage = 0
        applyFilter()
        isConfiguring = false
    }

    func refreshBrowserSources() {
        let sources = Dictionary(uniqueKeysWithValues: HistoryStore.shared.snapshot().map { ($0.id, $0) })
        allEntries = allEntries.map { sources[$0.id] ?? $0 }
        displayed = displayed.map { item in
            var entry = item.entry
            entry.browserSource = sources[item.id]?.browserSource
            entry.sourceAppName = sources[item.id]?.sourceAppName
            return DisplayItem(id: item.id, displayNumber: item.displayNumber, entry: entry)
        }
    }

    func reset() {
        isConverting = false
        conversionNotice = nil
        allEntries = []
        chatPage = []
        chatReference = nil
        chatReferenceNotice = nil
        inputMode = .search
        query = ""
        displayed = []
        currentPage = 0
        selectedDisplayIndex = 1
        showsAchievements = false
        showsShortcutGuide = false
        batchSelectionIDs = []
        batchNotice = nil
        isCommandPressed = false
        hasNavigatedWhileCommandPressed = false
    }

    func toggleAchievements() {
        showsAchievements.toggle()
        showsShortcutGuide = false
        if showsAchievements {
            inputMode = .search
            query = ""
        }
        refreshMedals()
    }

    func toggleShortcutGuide() {
        guard !showsAchievements else { return }
        showsShortcutGuide.toggle()
    }

    func refreshMedals() {
        medals = AchievementStore.shared.medals()
    }

    func setCommandPressed(_ pressed: Bool) {
        guard isCommandPressed != pressed else { return }
        isCommandPressed = pressed
        if pressed {
            hasNavigatedWhileCommandPressed = false
        }
    }

    private func markCommandNavigation() {
        if isCommandPressed {
            hasNavigatedWhileCommandPressed = true
        }
    }

    /// 将指定文本加入批次,再次执行则移出批次。
    /// 批次只允许文本,并保持用户加入时的顺序。
    func toggleBatchSelection() {
        guard let entry = selectedEntry() else { return }
        toggleBatchSelection(for: entry)
    }

    func toggleBatchSelection(for entry: ClipEntry) {
        guard case .text = entry.kind else {
            batchNotice = L10n.text("quick.batch.textOnly")
            return
        }

        batchNotice = nil
        if let index = batchSelectionIDs.firstIndex(of: entry.id) {
            batchSelectionIDs.remove(at: index)
        } else if batchSelectionIDs.count < batchSelectionLimit {
            batchSelectionIDs.append(entry.id)
        } else {
            batchNotice = L10n.format("quick.batch.limit", batchSelectionLimit)
        }
    }

    /// 返回当前批次中的文本条目,顺序与加入顺序一致。
    func batchEntries() -> [ClipEntry]? {
        let entriesByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        let entries = batchSelectionIDs.compactMap { entriesByID[$0] }
        return entries.isEmpty ? nil : entries
    }

    /// 返回条目在批次中的顺序编号,用于列表反馈。
    func batchOrder(for id: UUID) -> Int? {
        guard let index = batchSelectionIDs.firstIndex(of: id) else { return nil }
        return index + 1
    }

    /// 应用过滤:1...pageSize→当前页页内编号定位;其余非空输入→子串搜索;空→全部。
    ///
    /// 注意:数字直达只对**当前页**生效(输 1–5 选当前页第 1–5 条),
    /// 超出页内范围的数字无效——这是分页方案下「页内重新编号」的取舍。
    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            displayed = allEntries.enumerated().map { idx, e in
                DisplayItem(id: e.id, displayNumber: idx + 1, entry: e)
            }
            clampPageAndSelection()
            return
        }
        if let n = directPageIndex {
            // 数字直达:不缩小列表,只在当前页内定位第 n 条
            displayed = allEntries.enumerated().map { idx, e in
                DisplayItem(id: e.id, displayNumber: idx + 1, entry: e)
            }
            clampPageAndSelection()
            let localCount = pageItems.count
            selectedDisplayIndex = (n >= 1 && n <= localCount) ? n : selectedDisplayIndex
            return
        }
        // 关键词搜索:文本/文件做子串匹配,图片不参与(无法文字搜)
        let needle = q.lowercased()
        displayed = allEntries.enumerated().compactMap { idx, e in
            switch e.kind {
            case .text(let payload):
                return payload.normalizedText.lowercased().contains(needle)
                    ? DisplayItem(id: e.id, displayNumber: idx + 1, entry: e) : nil
            case .files(let urls):
                let names = urls.map { $0.lastPathComponent }.joined(separator: " ").lowercased()
                return names.contains(needle)
                    ? DisplayItem(id: e.id, displayNumber: idx + 1, entry: e) : nil
            case .image:
                return nil
            }
        }
        // 搜索结果可能变少,回到第 1 页重新展示
        currentPage = 0
        clampPageAndSelection()
    }

    /// 仅 1...pageSize 作为当前页编号,更大的数字进入搜索态。
    private var directPageIndex: Int? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let n = Int(q), (1...pageSize).contains(n) else { return nil }
        return n
    }

    // MARK: - 删除

    /// 删除当前选中的条目(用户按 ⌥⌫ 触发)。
    ///
    /// 删除后停在原页内位置(手感连贯,连续按 ⌥⌫ 可逐条下删);
    /// 若当前页删空了则回退到上一页;删空全部则通知调用方关闭面板。
    ///
    /// - Parameter completion: 删除后是否仍有内容(true=还有条目可继续操作;
    ///   false=已删空,调用方应关闭面板)。
    func deleteSelected(completion: (Bool) -> Void) {
        guard let entry = selectedEntry() else { completion(false); return }
        let deletedLocalIndex = selectedDisplayIndex

        // 1. 从本地快照移除(立即刷新 UI,不等 HistoryStore 的异步回调)
        batchSelectionIDs.removeAll { $0 == entry.id }
        allEntries.removeAll { $0.id == entry.id }
        // 2. 通知存储层删盘(图片)/ 清去重锚点
        HistoryStore.shared.remove(id: entry.id)
        // 3. 重新过滤。注意:applyFilter 会在 query 为空时走默认分支并 clampPage,
        //    但当前若处于「搜索结果」态,直接 applyFilter 会因 query 非空再次过滤。
        //    删除不应改变搜索条件,所以这里只重算 displayed(沿用原 query 逻辑)后手动 clamp。
        reapplyFilterPreservingPage()
        if displayed.isEmpty {
            selectedDisplayIndex = 0
            completion(false)  // 删空了 → 调用方关闭面板
            return
        }
        // 若删除导致当前页变空(如删掉本页唯一一条),回退到上一页
        if currentPage >= pageCount { currentPage = max(0, pageCount - 1) }
        let localCount = pageItems.count
        selectedDisplayIndex = max(1, min(deletedLocalIndex, localCount))
        completion(true)
    }

    /// 重算 displayed 但不重置 currentPage(删除场景:保持翻页位置)。
    private func reapplyFilterPreservingPage() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            displayed = allEntries.enumerated().map { idx, e in
                DisplayItem(id: e.id, displayNumber: idx + 1, entry: e)
            }
            return
        }
        if Int(q) != nil {
            // 数字态:列表仍是全量,无需重算过滤
            displayed = allEntries.enumerated().map { idx, e in
                DisplayItem(id: e.id, displayNumber: idx + 1, entry: e)
            }
            return
        }
        let needle = q.lowercased()
        displayed = allEntries.enumerated().compactMap { idx, e in
            switch e.kind {
            case .text(let payload):
                return payload.normalizedText.lowercased().contains(needle)
                    ? DisplayItem(id: e.id, displayNumber: idx + 1, entry: e) : nil
            case .files(let urls):
                let names = urls.map { $0.lastPathComponent }.joined(separator: " ").lowercased()
                return names.contains(needle)
                    ? DisplayItem(id: e.id, displayNumber: idx + 1, entry: e) : nil
            case .image:
                return nil
            }
        }
    }

    // MARK: - 键盘导航

    /// ↑:页内上移,到顶循环到底(不跨页)。
    func moveUp() {
        guard !pageItems.isEmpty else { return }
        let count = pageItems.count
        selectedDisplayIndex = selectedDisplayIndex > 1 ? selectedDisplayIndex - 1 : count
        markCommandNavigation()
    }
    /// ↓:页内下移,到底循环到顶(不跨页)。
    func moveDown() {
        guard !pageItems.isEmpty else { return }
        let count = pageItems.count
        selectedDisplayIndex = selectedDisplayIndex < count ? selectedDisplayIndex + 1 : 1
        markCommandNavigation()
    }
    /// ←:上一页(已在第 1 页则不动,不循环)。翻页后高亮重置到该页第 1 条。
    func movePrevPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        selectedDisplayIndex = pageItems.isEmpty ? 0 : 1
        markCommandNavigation()
    }
    /// →:下一页(已在最后一页则不动,不循环)。翻页后高亮重置到该页第 1 条。
    func moveNextPage() {
        guard currentPage < pageCount - 1 else { return }
        currentPage += 1
        selectedDisplayIndex = pageItems.isEmpty ? 0 : 1
        markCommandNavigation()
    }

    /// 当前选中的 ClipEntry(数字直达或方向键选中),无则 nil。
    ///
    /// 数字直达:输 1–5 选当前页内第 N 条(超出页内范围无效)。
    /// 6+ 和文本搜索都取当前搜索结果页的 selectedDisplayIndex 条。
    func selectedEntry() -> ClipEntry? {
        if let n = directPageIndex {
            // 数字直达只认当前页
            let items = pageItems
            guard n >= 1, n <= items.count else { return nil }
            return items[n - 1].entry
        }
        let items = pageItems
        guard selectedDisplayIndex >= 1, selectedDisplayIndex <= items.count else { return nil }
        return items[selectedDisplayIndex - 1].entry
    }

    func selectionContext(source: AchievementStore.SelectionSource) -> AchievementStore.SelectionContext {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let mode: AchievementStore.PasteMode
        if directPageIndex != nil {
            mode = .direct
        } else if trimmed.isEmpty {
            mode = .browse
        } else {
            mode = .search
        }
        return AchievementStore.SelectionContext(
            mode: mode,
            source: source,
            paged: currentPage > 0
        )
    }
}

/// Offscreen integration checks without showing a panel or sending model requests.
func runQuickPanelInputChecks() -> Bool {
    let model = QuickPanelViewModel()
    model.configure(entries: [ClipEntry(kind: .text(TextPayload(rawText: "hello", representations: [])))])
    model.query = "hello"
    let host = NSHostingView(rootView: QuickPanelView(viewModel: model, onSelected: { _ in }))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 434),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    func settle(_ turns: Int = 8) {
        for _ in 0..<turns {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }
    func findInput(_ view: NSView) -> ModeSearchContainer? {
        if let input = view as? ModeSearchContainer { return input }
        for child in view.subviews { if let input = findInput(child) { return input } }
        return nil
    }
    func capturePreview(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ECHO_INPUT_PREVIEW_DIR"],
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        } catch {
            print("FAIL panel preview: \(error)")
        }
    }
    settle()
    capturePreview("input-collapsed")
    guard let input = findInput(host) else { print("FAIL panel: missing native input"); return false }
    let before = input.convert(input.bounds, to: host)
    let selection = NSRange(location: 1, length: 2)
    input.editor.setSelectedRange(selection)
    input.toggle.performClick(nil)
    settle()
    let after = input.convert(input.bounds, to: host)
    let sameTop = abs((host.isFlipped ? before.minY : before.maxY) - (host.isFlipped ? after.minY : after.maxY)) < 1
    // NSHostingView routes native events via SwiftUI's event graph; its offscreen
    // hitTest returns the host itself. Check the expanded native subtree directly.
    let point = input.convert(NSPoint(x: 10, y: input.bounds.height - 5), to: input.superview)
    let hit = input.hitTest(point)
    let overlayOwnsHit = hit.map { $0 === input || $0.isDescendant(of: input) } ?? false
    let passed = input.editor.isExpanded && after.height > before.height && sameTop
        && host.frame.size == NSSize(width: 560, height: 434)
        && input.editor.selectedRange() == selection && overlayOwnsHit
    print("\(passed ? "PASS" : "FAIL") panel input: fixed frame, anchored top, native hit region, preserved selection")
    if !passed {
        print("panel diagnostics: before=\(before), after=\(after), host=\(host.frame), expanded=\(input.editor.isExpanded), selection=\(input.editor.selectedRange()), hit=\(String(describing: hit)), ownsHit=\(overlayOwnsHit)")
    }
    input.editor.collapseIfExpanded()
    settle()
    model.query = String(repeating: "hello 世界 ", count: 70)
    settle()
    let automaticPassed = input.editor.isExpanded && input.bounds.height > 48 && input.bounds.height < 160
        && input.editor.string == model.query && host.frame.size == NSSize(width: 560, height: 434)
    print("\(automaticPassed ? "PASS" : "FAIL") panel input: binding-driven automatic expansion and six-line limit")
    let plainWidth = input.bounds.width
    model.inputMode = .chat
    model.query = "帮我整理下面的发布要点：\n1. 搜索框支持自动展开\n2. 多行内容完整保留\n3. 浮层覆盖列表，不挤压布局\n\n输出一段简短、自然的更新说明。"
    settle()
    let modePassed = findInput(host) === input && abs(input.bounds.width - plainWidth) < 1
        && input.editor.mode == .chat && input.editor.string == model.query
    print("\(modePassed ? "PASS" : "FAIL") panel input: mode changes preserve editor identity and width")
    capturePreview("input-expanded")
    host.appearance = NSAppearance(named: .darkAqua)
    settle()
    capturePreview("input-expanded-dark")
    model.query = ""
    model.inputMode = .search
    settle()
    let origin = input.convert(NSPoint.zero, to: host)
    input.editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
    settle()
    let triggerPassed = model.isCalculator && model.query.isEmpty && input.editor.string.isEmpty
        && input.convert(NSPoint.zero, to: host) == origin && findInput(host) === input
    print("\(triggerPassed ? "PASS" : "FAIL") panel mode: typed trigger, empty body, fixed input origin")
    model.query = "1+2"
    settle()
    host.appearance = NSAppearance(named: .aqua)
    settle()
    capturePreview("input-calculator")
    let calculationPassed = model.calculationResult == "3" && input.editor.string == "1+2"
    print("\(calculationPassed ? "PASS" : "FAIL") panel mode: calculation uses complete body")
    model.query = ""
    settle()
    input.editor.deleteBackward(nil)
    settle()
    let exitPassed = model.inputMode == .search && model.query.isEmpty && !model.isCalculator
    model.query = "@ literal search"
    settle()
    let literalPassed = !model.isChat && input.editor.string == model.query
    print("\(exitPassed && literalPassed ? "PASS" : "FAIL") panel mode: Backspace exit and literal search prefix")
    var referencePassed = true
    func checkReference(_ condition: Bool, _ name: String) {
        if !condition { referencePassed = false }
        print("\(condition ? "PASS" : "FAIL") reference: \(name)")
    }
    let entries = (1...7).map { ClipEntry(kind: .text(TextPayload(rawText: "Reference text \($0)", representations: []))) }
    model.configure(entries: entries)
    model.moveNextPage()
    let originalPage = model.pageItems.map(\.id)
    model.inputMode = .chat
    model.query = ""
    settle()
    capturePreview("reference-choices")
    checkReference(model.chatPage.map(\.id) == originalPage && model.chatPage.first?.entry.id == entries[5].id,
                   "captures current page and local numbering")
    input.editor.insertText("2", replacementRange: NSRange(location: 0, length: 0))
    // Another key before SwiftUI updates must be instruction text, not a new reference.
    input.editor.insertText("2", replacementRange: NSRange(location: 0, length: 0))
    settle()
    checkReference(model.chatReference?.entry.id == entries[6].id && model.query == "2" && input.editor.string == "2",
                   "first digit locks reference; next digit is instruction without a space")
    let identity = model.chatReference?.id
    model.query = "Translate"
    settle()
    checkReference(model.chatReference?.id == identity, "editing instruction preserves selected content")
    input.editor.setSelectedRange(NSRange(location: 0, length: 0))
    input.editor.deleteBackward(nil)
    settle()
    checkReference(model.chatReference == nil && model.isChat && model.query.isEmpty && model.chatPage.map(\.id) == originalPage,
                   "Backspace returns to the same frozen page")
    model.selectChatReference(5)
    checkReference(model.chatReference == nil && model.chatReferenceNotice == "chat.reference.missing", "missing index reports error")
    model.configure(entries: [ClipEntry(kind: .files([URL(fileURLWithPath: "/tmp/example.txt")]))])
    model.inputMode = .chat
    model.selectChatReference(1)
    checkReference(model.chatReference == nil && model.chatReferenceNotice == "chat.reference.unsupported", "file references are rejected")
    model.configure(entries: entries)
    model.query = "Reference text 3"
    model.inputMode = .chat
    model.query = ""
    checkReference(model.chatPage.count == 1 && model.chatPage.first?.id == entries[2].id, "search results freeze before entering chat")
    model.configure(entries: entries)
    model.inputMode = .chat
    model.selectChatReference(3)
    model.sendChat()
    checkReference(!model.chat.busy && model.chatReferenceNotice == "chat.reference.instruction", "empty instruction cannot send")
    model.query = "解释这个报错"
    settle()
    settle(40)
    capturePreview("reference-selected")
    host.appearance = NSAppearance(named: .darkAqua)
    settle(40)
    capturePreview("reference-selected-dark")
    checkReference(model.chatReference?.id == entries[2].id && input.editor.hasReference && input.editor.string == model.query,
                   "native editor and reference remain in sync")
    let draftPage = model.chatPage
    let draftReference = model.chatReference
    model.configure(entries: [])
    model.inputMode = .chat
    model.restoreChat(page: draftPage, reference: draftReference, query: "restored instruction")
    checkReference(model.chatReference?.id == entries[2].id && model.chatPage.map(\.id) == draftPage.map(\.id),
                   "reopening a draft restores its original reference and page")
    model.cancelChatReference()
    model.query = "ordinary question"
    checkReference(model.chatReference == nil && !model.showsChatChoices, "ordinary question carries no reference")
    return referencePassed && passed && automaticPassed && modePassed && triggerPassed && calculationPassed && exitPassed && literalPassed
}

// MARK: - SwiftUI 视图

struct QuickPanelView: View {
    @ObservedObject var viewModel: QuickPanelViewModel
    let onSelected: (ClipEntry) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    @State private var hasAppeared = false
    @State private var inputHeight: CGFloat = 25

    private enum Layout {
        static let panelWidth: CGFloat = 560
        static let panelHeight: CGFloat = 434
        // HTML: 36pt brand bar + 59pt input anchor (47pt editor + 12pt gap).
        static let searchHeight: CGFloat = 95
        static let rowHeight: CGFloat = 56
        static let listVerticalPadding: CGFloat = 11
        static let listHeight: CGFloat = 302
        // HTML .qp-achievement: height 296 + padding 12px 14px + 8px grid gaps.
        static let achievementHeight: CGFloat = 296
        static let achievementHorizontalPadding: CGFloat = 14
        static let achievementVerticalPadding: CGFloat = 12
        static let achievementGridSpacing: CGFloat = 8
        static let medalRowHeight: CGFloat = 85.333333
        static let footerHeight: CGFloat = 36
        static let footerContentHeight: CGFloat = 28
        static let keyCapHeight: CGFloat = 22
        // The guide occupies the same outer content slot as the five-row list.
        // Its inner content remains padded within this fixed 304pt area.
        static let shortcutGuideHeight: CGFloat = 302
        static let shortcutGuideHorizontalPadding: CGFloat = 22
        static let shortcutGuideVerticalPadding: CGFloat = 14
        static let shortcutGuideColumnGap: CGFloat = 18
    }

    private var palette: EchoTheme.Palette {
        EchoTheme.panelPalette(for: colorScheme, mode: viewModel.inputMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The editor is overlaid below; this slot never changes size.
            Color.clear.frame(height: Layout.searchHeight)
            Divider().foregroundStyle(palette.border)
            if viewModel.isChat {
                chatReferenceArea
                    .frame(height: Layout.listHeight)
            } else if viewModel.isCalculator {
                calculatorArea
            } else if viewModel.showsAchievements {
                achievementArea
            } else if viewModel.showsShortcutGuide {
                shortcutGuideArea
            } else {
                listArea
            }
            footer
        }
        .frame(width: Layout.panelWidth, height: Layout.panelHeight)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                HStack {
                    Text("echo").tracking(2)
                    Spacer()
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text("v" + version)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(palette.textTertiary)
                .padding(.horizontal, 21)
                .frame(height: 36)
                searchBar
            }
        }
        .allowsHitTesting(!viewModel.isConverting)
        // 设计稿:单一深色面板 + 毛玻璃底,避免重复叠背景导致发灰
        .background(palette.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderStrong, lineWidth: 1))
        .onReceive(NotificationCenter.default.publisher(for: AchievementStore.didChangeNotification)) { _ in
            viewModel.refreshMedals()
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChangeNotification)) { _ in
            viewModel.refreshBrowserSources()
        }
        .onAppear {
            if reduceMotion {
                hasAppeared = true
            } else {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.22)) {
                        hasAppeared = true
                    }
                }
            }
        }
        // 不在 body 上做 clipShape/overlay/shadow:
        // 系统标题栏(.titled)由 NSPanel 管理,若这里再裁圆角会把标题栏和交通灯一起裁掉。
        // 圆角、边框、阴影交给 NSPanel 本身(NSWindow 在 .titled 下自带圆角和阴影)。
    }

    // MARK: 搜索栏

    private var calculatorArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(viewModel.calculationResult == nil ? "calc.title" : "calc.result"))
                .font(.system(size: 12)).foregroundStyle(palette.accent)
            if let result = viewModel.calculationResult {
                ScrollView {
                    Text(result).font(.system(size: 40, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(L10n.text(calculationMessageKey))
                    .font(.system(size: 18)).foregroundStyle(palette.textPrimary)
            }
            Text(L10n.text("calc.help"))
                .font(.system(size: 11)).foregroundStyle(palette.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Layout.listHeight)
    }

    private var chatReferenceArea: some View {
        ZStack(alignment: .topLeading) {
            ForEach(viewModel.chatPage) { item in
                let selected = viewModel.chatReference?.id == item.id
                itemRow(item, batchOrder: nil)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selected { viewModel.cancelChatReference() }
                        else { viewModel.selectChatReference(item.displayNumber) }
                    }
                    .padding(.horizontal, 6)
                    .offset(y: CGFloat(selected ? 0 : item.displayNumber - 1) * Layout.rowHeight + Layout.listVerticalPadding)
                    // On cancellation, let the instruction area disappear before moving the row back.
                    .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
                        .delay(viewModel.showsChatChoices ? 0.16 : 0), value: viewModel.chatReference?.id)
                    .opacity(viewModel.showsChatChoices || selected ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16)
                        .delay(viewModel.showsChatChoices ? 0.16 : 0), value: viewModel.showsChatChoices)
                    .allowsHitTesting(viewModel.showsChatChoices || selected)
                    .accessibilityHidden(!(viewModel.showsChatChoices || selected))
            }
            if !viewModel.showsChatChoices {
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.chatReference != nil {
                        Text(L10n.text("chat.reference.privacy"))
                            .font(.caption).foregroundStyle(palette.textTertiary)
                            .padding(.horizontal, 22)
                    }
                    ChatArea(state: viewModel.chat, accent: palette.accent,
                             hasReference: viewModel.chatReference != nil)
                }
                .padding(.top, viewModel.chatReference == nil ? 0 : 78)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            if let notice = viewModel.chatReferenceNotice {
                Text(L10n.text(notice)).font(.caption).foregroundStyle(palette.accent)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .background(alignment: .bottom) { palette.windowBackground.frame(height: 40) }
            } else if viewModel.showsChatChoices && viewModel.chatPage.isEmpty {
                Text(L10n.text("chat.reference.noHistory"))
                    .font(.caption).foregroundStyle(palette.textTertiary).padding(22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: viewModel.showsChatChoices ? 0.16 : 0.2)
            .delay(viewModel.showsChatChoices ? 0 : 0.22), value: viewModel.showsChatChoices)
    }

    private var calculationMessageKey: String {
        switch viewModel.calculation {
        case .empty: return "calc.empty"
        case .incomplete: return "calc.incomplete"
        case .invalid: return "calc.invalid"
        case .nonFinite: return "calc.nonFinite"
        case .tooLong: return "calc.tooLong"
        case .result: return "calc.result"
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if viewModel.isCalculator {
                    Text("!").font(.system(size: 20, weight: .medium))
                } else if viewModel.isChat {
                    HStack(spacing: 0) {
                        Text("@")
                        if let reference = viewModel.chatReference {
                            Text("\(reference.displayNumber)")
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }.font(.system(size: 19, weight: .medium))
                } else {
                    Image(systemName: showsMultiSelectFeedback ? "checkmark.circle.fill" : "magnifyingglass")
                        .font(.system(size: 16))
                }
            }
                .foregroundStyle(palette.accent)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.inputMode)
                .frame(width: viewModel.isChat && viewModel.chatReference != nil ? 32 : 17, height: 25)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: viewModel.chatReference?.id)
                .accessibilityLabel(L10n.text(viewModel.inputMode.labelKey))
            ModeSearchField(text: $viewModel.query, mode: $viewModel.inputMode,
                            placeholder: L10n.text(viewModel.isChat
                                ? (viewModel.chatReference == nil ? "chat.reference.placeholder" : "chat.reference.commandPlaceholder")
                                : viewModel.inputMode.placeholderKey),
                            focused: fieldFocused,
                            enabled: !viewModel.showsAchievements && !viewModel.showsShortcutGuide && !viewModel.isConverting,
                            onHeightChange: { height in
                                if inputHeight != height { inputHeight = height }
                            }, hasReference: viewModel.chatReference != nil,
                            onReference: { viewModel.selectChatReference($0); return viewModel.chatReference != nil },
                            onCancelReference: { viewModel.cancelChatReference() }) {
                    // Input methods may consume Return before the event monitor can send.
                    if viewModel.isChat {
                        QuickPanelController.shared.sendChatQuestion()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: inputHeight)
        }
        if inputHeight > 25 {
            VStack(spacing: 8) {
                Rectangle().fill(palette.border).frame(height: 1)
                HStack(spacing: 8) {
                    Text(L10n.text("quick.input.keys"))
                    if viewModel.isChat {
                        Text(L10n.text("chat.title"))
                    } else if viewModel.isCalculator {
                        Text(L10n.text("calc.title"))
                    } else if showsMultiSelectFeedback {
                        Text("⌘ " + L10n.text("quick.multiSelect"))
                    }
                    Spacer(minLength: 0)
                    Text(L10n.format("quick.input.count", viewModel.query.count))
                }
                .font(.system(size: 10))
                .foregroundStyle(palette.textTertiary)
            }
            .padding(.leading, 27)
            .padding(.top, 9)
        }
        }
        .padding(.horizontal, 12)
        // CSS borders occupy layout space; SwiftUI strokes do not.
        .padding(.top, 13)
        .padding(.bottom, 9)
        .background {
            (colorScheme == .dark ? Color(nsColor: NSColor(calibratedWhite: 0.19, alpha: 1)) : .white)
                .overlay(showsMultiSelectFeedback ? palette.accentSoft.opacity(0.42) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(palette.accent.opacity(inputHeight > 25 ? 0.65 : 0.35), lineWidth: 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.inputMode))
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(inputHeight > 25 ? 0.16 : 0), radius: 14, y: 10)
        .padding(.horizontal, 9)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: viewModel.isCommandPressed)
        .onAppear { fieldFocused = !viewModel.showsAchievements && !viewModel.showsShortcutGuide }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { notification in
            guard let editor = notification.object as? NSTextView,
                  editor.window === NSApp.keyWindow, editor.string == viewModel.query else { return }
            DispatchQueue.main.async {
                QuickPanelController.shared.placeSearchCaretAtEnd()
            }
        }
        .onChange(of: viewModel.showsAchievements) { showsAchievements in
            fieldFocused = !showsAchievements && !viewModel.showsShortcutGuide
        }
        .onChange(of: viewModel.showsShortcutGuide) { showsShortcutGuide in
            fieldFocused = !showsShortcutGuide && !viewModel.showsAchievements
        }
    }

    @FocusState private var fieldFocused: Bool

    private var showsMultiSelectFeedback: Bool {
        viewModel.isCommandPressed && !viewModel.isChat && !viewModel.isCalculator && !viewModel.showsAchievements && !viewModel.showsShortcutGuide
    }

    // MARK: 列表

    /// 列表区:**固定 5 个行槽位常驻**,严禁自适应高低。
    /// - 有内容的槽位:渲染条目 + 选中高亮 + 可点击
    /// - 空槽位:渲染与有内容行**等高**的透明占位(不响应点击、不参与高亮、不可被 ↑↓ 选中)
    ///
    /// 这样即使整页只有 1 条内容,下方 4 个空槽位也始终在,框架尺寸纹丝不动。
    @ViewBuilder
    private var listArea: some View {
        if viewModel.allEntries.isEmpty && viewModel.query.isEmpty {
            emptyState
        } else {
            populatedList
        }
    }

    /// 勋章墙:外层与历史列表共用 304pt 正文槽位,内部沿用 HTML 的 296pt 网格。
    private var achievementArea: some View {
        ZStack {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Layout.achievementGridSpacing), count: 4),
                spacing: Layout.achievementGridSpacing
            ) {
                ForEach(viewModel.medals) { medal in
                    medalView(medal)
                }
            }
            .padding(.horizontal, Layout.achievementHorizontalPadding)
            .padding(.vertical, Layout.achievementVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Layout.achievementHeight, maxHeight: Layout.achievementHeight)
            .background {
                RadialGradient(
                    colors: [palette.purpleSoft, .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 210
                )
                .opacity(0.7)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Layout.listHeight, maxHeight: Layout.listHeight)
    }

    /// 快捷键说明页:与历史列表共用正文槽位,不改变面板尺寸。
    private var shortcutGuideArea: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L10n.text("quick.guideTitle"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            HStack(alignment: .top, spacing: 23) {
                shortcutColumn(title: L10n.text("quick.shortcut.general"), items: [
                    (L10n.text("quick.shortcut.move"), "↑ ↓"),
                    (L10n.text("quick.shortcut.page"), "← →"),
                    (L10n.text("quick.shortcut.search"), L10n.text("quick.shortcut.type")),
                    (L10n.text("quick.shortcut.direct"), "1–5"),
                    (L10n.text("quick.shortcut.delete"), "⌥⌫"),
                    (L10n.text("quick.shortcut.close"), "esc")
                ])
                VStack(alignment: .leading, spacing: 14) {
                    shortcutColumn(title: L10n.text("quick.pasteSource"), items: [
                        (L10n.text("quick.shortcut.formattedPaste"), "↵"),
                        (L10n.text("quick.shortcut.markdownPaste"), "⌥↵"),
                        (L10n.text("quick.openSource"), "⌃↵")
                    ], note: L10n.text("quick.sourceAvailableNote"))
                    shortcutColumn(title: L10n.text("quick.shortcut.multiMode"), items: [
                        (L10n.text("quick.shortcut.enterMulti"), L10n.text("quick.shortcut.holdCommand")),
                        (L10n.text("quick.shortcut.addRemove"), L10n.text("quick.shortcut.click")),
                        (L10n.text("quick.shortcut.mergePaste"), L10n.text("quick.shortcut.releaseCommand"))
                    ], note: L10n.text("quick.shortcut.textOnly"))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, minHeight: Layout.shortcutGuideHeight, maxHeight: Layout.shortcutGuideHeight, alignment: .topLeading)
    }

    private func shortcutColumn(
        title: String,
        items: [(String, String)],
        note: String? = nil,
        usesModePrefix: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if usesModePrefix {
                    Text("/ ")
                }
                Text(title)
            }
            .font(.system(size: 10, weight: .medium))
            .tracking(0)
            .foregroundStyle(palette.accent)
            .padding(.bottom, 6)
            .lineLimit(1)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.border)
                    .frame(height: 1)
            }

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                shortcutRow(label: item.0, keys: item.1)
            }

            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func shortcutRow(label: String, keys: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            shortcutKeycap(keys)
        }
        .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
        }
    }

    private func shortcutKeycap(_ keys: String) -> some View {
        Text(keys)
            .font(.system(size: 9))
            .foregroundStyle(palette.textSecondary)
            .fixedSize()
    }

    private func medalView(_ medal: AchievementStore.Medal) -> some View {
        let tone = medalTone(medal.tone)
        return VStack(spacing: 4) {
            Text(medal.icon)
                .font(.system(size: medal.icon.count > 2 ? 12 : 16, weight: .semibold, design: .rounded))
                .foregroundStyle(medal.unlocked ? tone.primary : palette.textTertiary)
                .frame(width: 34, height: 34)
                .background(medal.unlocked ? tone.soft : palette.achievementLockedIconBackground)
                .overlay(Circle().stroke(medal.unlocked ? tone.primary.opacity(0.36) : palette.border, lineWidth: 1))
                .clipShape(Circle())

            Text(medal.name)
                .font(.system(size: 10.5))
                .foregroundStyle(medal.unlocked ? palette.textPrimary : palette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: Layout.medalRowHeight, maxHeight: Layout.medalRowHeight)
        .background(medal.unlocked ? palette.rowBackground : palette.achievementLockedBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(medal.unlocked ? 1 : 0.40)
        .help(medal.progress ?? medal.name)
    }

    private func medalTone(_ tone: AchievementStore.Medal.Tone) -> (primary: Color, soft: Color) {
        switch tone {
        case .accent: return (palette.accent, palette.accentSoft)
        case .green: return (palette.green, palette.greenSoft)
        case .yellow: return (palette.yellow, palette.yellowSoft)
        case .purple: return (palette.purple, palette.purpleSoft)
        }
    }

    /// 有内容时的固定 5 行列表。
    private var populatedList: some View {
        VStack(spacing: 0) {
            ForEach(0..<viewModel.pageSize, id: \.self) { slot in
                if slot < viewModel.pageItems.count {
                    let item = viewModel.pageItems[slot]
                    // Command 多选期间不显示普通当前行高亮,避免第一条看起来被自动选中。
                    let isSelected = (!viewModel.isCommandPressed || viewModel.hasNavigatedWhileCommandPressed)
                        && viewModel.selectedDisplayIndex == item.displayNumber
                    let batchOrder = viewModel.batchOrder(for: item.id)
                    itemRow(item, batchOrder: batchOrder)
                        .contextMenu {
                            if let source = item.entry.browserSource {
                                Button(L10n.text("quick.openSource")) {
                                    NSWorkspace.shared.open(source.url)
                                }
                            }
                        }
                        // 设计稿:.qp-item.selected = accent-soft(0.14) + 1px border rgba(accent,0.3)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(palette.accentSoft)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(palette.accent.opacity(0.25), lineWidth: 1)
                                    )
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(palette.accent)
                                            .frame(width: 3, height: 26)
                                    }
                                    .matchedGeometryEffect(id: "selected-row-background", in: selectionNamespace)
                            } else if let batchOrder {
                                let tone = batchTone(for: batchOrder)
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(tone.soft.opacity(0.55))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(tone.primary.opacity(0.18), lineWidth: 1)
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                viewModel.toggleBatchSelection(for: item.entry)
                            } else {
                                onSelected(item.entry)
                            }
                        }
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.12),
                            value: viewModel.selectedDisplayIndex
                        )
                        .opacity(reduceMotion || hasAppeared ? 1 : 0)
                        .offset(x: reduceMotion || hasAppeared ? 0 : -8)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.22).delay(Double(slot) * 0.025),
                            value: hasAppeared
                        )
                } else {
                    emptySlot(slot: slot)
                }
            }
        }
        // 设计稿:.qp-list padding:6px
        .padding(.horizontal, 6)
        .padding(.vertical, Layout.listVerticalPadding)
    }

    /// 剪贴板为空时的引导状态:保留列表区域高度,避免窗口跳动。
    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(palette.accentSoft)
                Image(systemName: "command")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 58, height: 58)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(palette.accent.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 15, y: 8)
            .padding(.bottom, 16)

            Text(L10n.text("quick.empty.title"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text(L10n.text("quick.empty.body"))
                .font(.system(size: 12.5))
                .foregroundStyle(palette.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 330)
                .padding(.top, 8)
                .padding(.bottom, 14)

            kbdHint("⌘\\", L10n.text("quick.empty.hint"))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Layout.listHeight)
        .background {
            RadialGradient(
                colors: [palette.accentSoft, .clear],
                center: .center,
                startRadius: 0,
                endRadius: 210
            )
            .opacity(0.65)
        }
    }

    /// 空槽位:与 itemRow 等高的纯透明占位。
    /// - 固定 56pt 高,与有内容行严格一致(设计稿 .qp-item height:56px)
    /// - 不挂 contentShape / onTapGesture → 不响应任何点击
    /// - 第 1 个空槽位(即整页全空时)显示一句轻提示,其余空槽纯留白
    @ViewBuilder
    private func emptySlot(slot: Int) -> some View {
        HStack(spacing: 14) {
            if slot == 0 {
                Text(L10n.text(viewModel.query.isEmpty ? "quick.noHistory" : "quick.noMatches"))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: Layout.rowHeight, maxHeight: Layout.rowHeight, alignment: .leading)
    }

    /// 单行:编号 + 内容预览 + 类型标签。
    /// 设计稿 .qp-item:height:56px + box-sizing:border-box + padding:11px 14px + gap:14px。
    @ViewBuilder
    private func itemRow(_ item: QuickPanelViewModel.DisplayItem, batchOrder: Int?) -> some View {
        HStack(spacing: 14) {
            Text("\(item.displayNumber)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                previewContent(for: item.entry.kind)
                if let source = item.entry.browserSource {
                    Text("\(source.browserName) · \(source.url.absoluteString)")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                        .help("\(source.title)\n\(source.url.absoluteString)\n\(L10n.text("quick.sourceHint"))")
                } else if let name = item.entry.sourceAppName {
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let batchOrder {
                let tone = batchTone(for: batchOrder)
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("# \(batchOrder)")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tone.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tone.soft)
                .cornerRadius(5)
            } else {
                typeTag(for: item.entry.kind)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: Layout.rowHeight, maxHeight: Layout.rowHeight, alignment: .leading)
    }

    /// 根据类型渲染预览:文本/图片缩略图/文件图标。
    /// 设计稿:缩略图 32×32 圆角6 + 深色底;文件图标 32×32 圆角7 + green-soft 色底框。
    @ViewBuilder
    private func previewContent(for kind: ClipEntry.Kind) -> some View {
        switch kind {
        case .text(let payload):
            Text(payload.normalizedText.previewString(maxLines: 1))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(palette.textPrimary)
        case .image(let ref):
            HStack(spacing: 14) {
                // 缩略图:32×32 圆角6 + 深色底 #2a2f3d + 边框
                Image(nsImage: ref.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .background(palette.thumbnailBackground)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("quick.imagePreview"))
                        .foregroundStyle(colorScheme == .dark ? palette.textPrimary : palette.textSecondary)
                        .font(.system(size: 13))
                    Text(ref.sizeText).font(.system(size: 10.5))
                        .foregroundStyle(colorScheme == .dark ? Color(red: 0.71, green: 0.75, blue: 0.81) : palette.textTertiary)
                }
            }
        case .files(let urls):
            HStack(spacing: 14) {
                // 文件图标:32×32 圆角7 + green-soft 色底框(图标居中)
                Image(systemName: fileIconName(for: urls.first))
                    .font(.system(size: 16))
                    .foregroundStyle(palette.green)
                    .frame(width: 32, height: 32)
                    .background(palette.greenSoft)
                    .cornerRadius(7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filesPreview(urls))
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(palette.textPrimary)
                    Text(filesLocation(urls))
                        .font(.system(size: 10.5)).foregroundStyle(palette.textTertiary)
                }
            }
        }
    }

    /// 类型标签。设计稿:font10 weight600 padding 2/7 圆角5 + soft 底(0.14)。
    private func typeTag(for kind: ClipEntry.Kind) -> some View {
        let text: String
        switch kind {
        case .text: text = L10n.text("quick.type.text")
        case .image: text = L10n.text("quick.type.image")
        case .files: text = L10n.text("quick.type.file")
        }
        return Text(text)
            .font(.system(size: 9))
            .foregroundStyle(palette.textTertiary)
    }

    private func batchTone(for order: Int) -> (primary: Color, soft: Color) {
        switch order {
        case 1: return (palette.accent, palette.accentSoft)
        case 2: return (palette.purple, palette.purpleSoft)
        case 3: return (palette.yellow, palette.yellowSoft)
        case 4: return (palette.green, palette.greenSoft)
        default: return (palette.red, palette.redSoft)
        }
    }

    // MARK: 底部

    /// 底部状态栏。设计稿 .qp-footer:48pt 高 + 内容 28pt 垂直居中。
    private var footer: some View {
        HStack(alignment: .center) {
            if viewModel.isChat {
                Text(L10n.text("chat.shortcuts"))
                    .font(.system(size: 10)).foregroundStyle(palette.textTertiary)
                Spacer()
            } else if viewModel.isCalculator {
                Text(L10n.text("calc.shortcuts"))
                    .font(.system(size: 10.5)).foregroundStyle(palette.textTertiary)
                Link(L10n.text("quick.help"), destination: URL(string: "https://github.com/nicklockwood/Expression#math-symbols")!)
                    .font(.system(size: 10.5)).foregroundStyle(palette.accent)
                Spacer()
                Text("esc " + L10n.text("calc.close"))
                    .font(.system(size: 10.5)).foregroundStyle(palette.textTertiary)
            } else {
            statusSummary
            Spacer()
            shortcutHints
            .font(.system(size: 10.5))
            .foregroundStyle(palette.textTertiary)
            .frame(height: Layout.footerContentHeight, alignment: .center)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Layout.footerHeight, alignment: .center)
        .background(Color.clear)
        // 设计稿:.qp-footer border-top:1px solid var(--border)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(palette.border), alignment: .top)
    }

    /// 左侧状态拆开渲染,避免 emoji 影响整行文字基线。
    private var statusSummary: some View {
        Text(statusText)
            .help(statusText)
            .font(.system(size: 9))
            .foregroundStyle(palette.textTertiary)
            .lineLimit(1)
    }

    private var statusText: String {
        if viewModel.isConverting { return L10n.text("quick.markdown.converting") }
        if let notice = viewModel.conversionNotice { return notice }
        if let notice = viewModel.batchNotice {
            return notice
        }
        if viewModel.isCommandPressed && !viewModel.showsShortcutGuide {
            return L10n.text("quick.status.multiMode")
        }
        if !viewModel.batchSelectionIDs.isEmpty {
            return L10n.format("quick.status.selected", viewModel.batchSelectionIDs.count)
        }
        return L10n.format("quick.status.page", viewModel.allEntries.count, viewModel.currentPage + 1)
    }

    private var shortcutHints: some View {
        HStack(spacing: 14) {
            if !viewModel.showsShortcutGuide {
                Text(L10n.text("quick.pasteHints"))
                    .foregroundStyle(palette.textSecondary)
            }
            Button {
                viewModel.toggleShortcutGuide()
            } label: {
                Text("Tab " + L10n.text(viewModel.showsShortcutGuide ? "quick.backToHistory" : "quick.help"))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 9))
    }

    /// 按键提示。设计稿 .kbd:panel-solid 深色实底 + border-strong + 圆角4 + text-dim 亮字。
    private func kbdHint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                // 设计稿:panel-solid(#1c202a)实心深底 + 文字 text-dim(比 tertiary 亮一档)
                .background(palette.keycapBackground)
                .foregroundStyle(palette.keycapText)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.borderStrong, lineWidth: 1))
                .cornerRadius(4)
                .frame(minHeight: Layout.keyCapHeight, alignment: .center)
            Text(label)
                .lineLimit(1)
                .foregroundStyle(palette.textTertiary)
        }
        .frame(height: Layout.footerContentHeight, alignment: .center)
    }

    // MARK: - 文件预览辅助

    private func fileIconName(for url: URL?) -> String {
        guard let url else { return "doc" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z": return "doc.zipper"
        case "mp4", "mov": return "film"
        case "mp3", "wav": return "music.note"
        default: return "doc"
        }
    }

    private func filesPreview(_ urls: [URL]) -> String {
        if urls.count == 1 { return urls[0].lastPathComponent }
        return L10n.format("quick.files.multiple", urls[0].lastPathComponent, urls.count)
    }

    private func filesLocation(_ urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        let dir = first.deletingLastPathComponent()
        return dir.pathabbreviated()
    }
}

// MARK: - String 预览辅助

extension String {
    /// 去掉换行,返回单行预览。
    func previewString(maxLines: Int) -> String {
        let collapsed = self.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        return trimmed
    }
}

extension URL {
    /// 把路径缩写显示,如 ~/Documents/... 替换 home。
    func pathabbreviated() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = self.path
        if p.hasPrefix(home) {
            p = "~" + p.dropFirst(home.count)
        }
        return p
    }
}
