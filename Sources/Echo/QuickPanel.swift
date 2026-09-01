import SwiftUI
import AppKit
import QuartzCore

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
        static let panelHeight: CGFloat = 425
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

    private override init() {
        super.init()
    }

    // MARK: - 显示 / 隐藏

    /// 面板显示前的最前台 App(粘贴时需要激活它,让 ⌘V 送对地方)
    private(set) var frontmostAppAtShowTime: NSRunningApplication?

    /// 显示面板:读取历史快照、定位到屏幕中央、设为 key 窗口。
    func show() {
        let entries = HistoryStore.shared.snapshot()
        currentEntries = entries
        AchievementStore.shared.recordPanelShown()

        // 先关闭旧面板(必须在 configure 之前,否则 hide 的 reset 会清空新数据)
        hide()

        // 记录当前最前台 App——选中条目粘贴时,要激活它让 ⌘V 送达
        frontmostAppAtShowTime = NSWorkspace.shared.frontmostApplication

        viewModel.configure(entries: entries)
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
    }

    /// 隐藏面板。
    func hide() {
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
        if event.type == .flagsChanged {
            viewModel.setCommandPressed(event.modifierFlags.contains(.command))
            return event
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
            if event.modifierFlags.contains(.command) {
                viewModel.toggleBatchSelection()
                return nil
            }
            if let entries = viewModel.batchEntries(), !entries.isEmpty {
                let context = viewModel.selectionContext(source: .keyboard)
                hide()
                onBatchSelected?(entries, context)
                return nil
            }
            if let entry = viewModel.selectedEntry() {
                let format: Paster.PasteFormat = event.modifierFlags.contains(.option)
                    ? .plainText
                    : .original
                handleSelected(entry, source: .keyboard, format: format)
            }
            return nil
        case 51:  // ⌫ Backspace
            // 仅当按住 ⌘ 时才视为「删除当前条目」,否则放行给搜索框删文字(避免冲突)
            if event.modifierFlags.contains(.command) {
                viewModel.deleteSelected { stillHasContent in
                    if !stillHasContent {
                        hide()  // 删空了,关闭面板
                    }
                }
                return nil  // 吞掉事件,防止 ⌘⌫ 冒泡
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
        let context = viewModel.selectionContext(source: source)
        hide()
        onSelected?(entry, context, format)
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
        let panel = NSPanel(
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
        panel.titleVisibility = .visible
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
            // configure 期间禁止 didSet 触发 applyFilter(避免 query="" 清空还没配好的数据)
            guard !isConfiguring else { return }
            applyFilter()
        }
    }

    /// 过滤后的全量条目(搜索后),带原始全局序号(1-based)。
    /// 分页只取其中当前页的切片。
    @Published private(set) var displayed: [DisplayItem] = []

    /// 当前页内选中的序号(1-based,范围 1...pageSize)。
    /// 与 currentPage 配合定位最终条目:selectedEntry = 当前页第 selectedDisplayIndex 条。
    @Published var selectedDisplayIndex: Int = 1

    /// 正文显示模式:历史列表或勋章墙。
    @Published var showsAchievements = false

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
        query = ""
        currentPage = 0
        applyFilter()
        isConfiguring = false
    }

    func reset() {
        allEntries = []
        query = ""
        displayed = []
        currentPage = 0
        selectedDisplayIndex = 1
        showsAchievements = false
        batchSelectionIDs = []
        batchNotice = nil
        isCommandPressed = false
        hasNavigatedWhileCommandPressed = false
    }

    func toggleAchievements() {
        showsAchievements.toggle()
        if showsAchievements {
            query = ""
        }
        refreshMedals()
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
            batchNotice = "批量粘贴仅支持文本"
            return
        }

        batchNotice = nil
        if let index = batchSelectionIDs.firstIndex(of: entry.id) {
            batchSelectionIDs.remove(at: index)
        } else if batchSelectionIDs.count < batchSelectionLimit {
            batchSelectionIDs.append(entry.id)
        } else {
            batchNotice = "最多选择 \(batchSelectionLimit) 条文本"
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

    /// 删除当前选中的条目(用户按 ⌘⌫ 触发)。
    ///
    /// 删除后停在原页内位置(手感连贯,连续按 ⌘⌫ 可逐条下删);
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

// MARK: - SwiftUI 视图

struct QuickPanelView: View {
    @ObservedObject var viewModel: QuickPanelViewModel
    let onSelected: (ClipEntry) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    @State private var hasAppeared = false

    private enum Layout {
        static let panelWidth: CGFloat = 560
        static let panelHeight: CGFloat = 425
        static let searchHeight: CGFloat = 72
        static let rowHeight: CGFloat = 56
        static let listVerticalPadding: CGFloat = 8
        static let listHeight: CGFloat = 304
        // HTML .qp-achievement: height 296 + padding 12px 14px + 8px grid gaps.
        static let achievementHeight: CGFloat = 296
        static let achievementHorizontalPadding: CGFloat = 14
        static let achievementVerticalPadding: CGFloat = 12
        static let achievementGridSpacing: CGFloat = 8
        static let medalRowHeight: CGFloat = 85.333333
        static let footerHeight: CGFloat = 48
        static let footerContentHeight: CGFloat = 28
        static let keyCapHeight: CGFloat = 22
    }

    private var palette: EchoTheme.Palette {
        EchoTheme.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().foregroundStyle(palette.border)
            if viewModel.showsAchievements {
                achievementArea
            } else {
                listArea
            }
            footer
        }
        .frame(width: Layout.panelWidth, height: Layout.panelHeight)
        // 设计稿:单一深色面板 + 毛玻璃底,避免重复叠背景导致发灰
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(palette.windowTint)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AchievementStore.didChangeNotification)) { _ in
            viewModel.refreshMedals()
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

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.isCommandPressed ? "checkmark.circle.fill" : "magnifyingglass")
                .foregroundStyle(viewModel.isCommandPressed ? palette.accent : palette.textTertiary)
                .font(.system(size: 16))
            TextField("输入 1-5 直达本页 / 关键词搜索", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($fieldFocused)
                .disabled(viewModel.showsAchievements)
            if viewModel.isCommandPressed && !viewModel.showsAchievements {
                HStack(spacing: 4) {
                    Image(systemName: "command")
                    Text("多选")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.accentSoft)
                .clipShape(Capsule())
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        // 设计稿:.qp-search padding:14px 18px + border-bottom
        .padding(.horizontal, 18)
        .frame(height: Layout.searchHeight)
        .background(viewModel.isCommandPressed ? palette.accentSoft.opacity(0.42) : .clear)
        .overlay(
            Rectangle()
                .fill(viewModel.isCommandPressed ? palette.accent.opacity(0.42) : palette.border)
                .frame(height: 1),
            alignment: .bottom
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: viewModel.isCommandPressed)
        .onAppear { fieldFocused = !viewModel.showsAchievements }
        .onChange(of: viewModel.showsAchievements) { showsAchievements in
            fieldFocused = !showsAchievements
        }
    }

    @FocusState private var fieldFocused: Bool

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
        VStack(spacing: 2) {
            ForEach(0..<viewModel.pageSize, id: \.self) { slot in
                if slot < viewModel.pageItems.count {
                    let item = viewModel.pageItems[slot]
                    // Command 多选期间不显示普通当前行高亮,避免第一条看起来被自动选中。
                    let isSelected = (!viewModel.isCommandPressed || viewModel.hasNavigatedWhileCommandPressed)
                        && viewModel.selectedDisplayIndex == item.displayNumber
                    let batchOrder = viewModel.batchOrder(for: item.id)
                    itemRow(item, batchOrder: batchOrder)
                        // 设计稿:.qp-item.selected = accent-soft(0.14) + 1px border rgba(accent,0.3)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(palette.accentSoft)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(palette.accent.opacity(0.3), lineWidth: 1)
                                    )
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

            Text("还没有剪贴板记录")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text("Echo 已准备好。复制一段文字、图片或文件，再按下快捷键，就能在这里找到它。")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 330)
                .padding(.top, 8)
                .padding(.bottom, 14)

            kbdHint("⌘\\", "呼出面板 · 复制内容后即可开始")

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
                Text(viewModel.query.isEmpty ? "暂无历史" : "无匹配结果")
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
                .foregroundStyle(colorScheme == .dark ? .white : palette.textTertiary)
                .frame(width: 28, alignment: .trailing)
            previewContent(for: item.entry.kind)
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
                .font(.system(size: 13.5))
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
                    Text("[ 图片 ]").foregroundStyle(palette.textSecondary).font(.system(size: 13))
                    Text(ref.sizeText).font(.system(size: 10.5)).foregroundStyle(palette.textTertiary)
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
                        .font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(palette.textPrimary)
                    Text(filesLocation(urls))
                        .font(.system(size: 10.5)).foregroundStyle(palette.textTertiary)
                }
            }
        }
    }

    /// 类型标签。设计稿:font10 weight600 padding 2/7 圆角5 + soft 底(0.14)。
    private func typeTag(for kind: ClipEntry.Kind) -> some View {
        let (text, color, soft): (String, Color, Color) = {
            switch kind {
            case .text: return ("文本", palette.accent, palette.accentSoft)
            case .image: return ("图片", palette.purple, palette.purpleSoft)
            case .files: return ("文件", palette.green, palette.greenSoft)
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)   // 设计稿 letter-spacing:0.04em
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(soft)
            .foregroundStyle(color)
            .cornerRadius(5)
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
            statusSummary
            Spacer()
            shortcutHints
            .font(.system(size: 10.5))
            .foregroundStyle(palette.textTertiary)
            .frame(height: Layout.footerContentHeight, alignment: .center)
        }
        .padding(.horizontal, 18)
        .frame(height: Layout.footerHeight, alignment: .center)
        .background(palette.footerBackground)
        // 设计稿:.qp-footer border-top:1px solid var(--border)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(palette.border), alignment: .top)
    }

    /// 左侧状态拆开渲染,避免 emoji 影响整行文字基线。
    private var statusSummary: some View {
        HStack(spacing: 7) {
            Button {
                viewModel.toggleAchievements()
            } label: {
                Text("🏅")
                    .font(.system(size: 14))
                    .frame(width: 18, height: Layout.footerContentHeight, alignment: .center)
            }
            .buttonStyle(.plain)
            .help(viewModel.showsAchievements ? "返回历史" : "查看使用成就")
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(colorScheme == .dark ? .white : palette.textTertiary)
                .lineLimit(1)
        }
        .frame(height: Layout.footerContentHeight, alignment: .center)
    }

    private var statusText: String {
        if let notice = viewModel.batchNotice {
            return notice
        }
        if viewModel.isCommandPressed {
            return "⌘ 多选模式"
        }
        if !viewModel.batchSelectionIDs.isEmpty {
            return "已选 \(viewModel.batchSelectionIDs.count) 条文本 · 按 ↵ 合并粘贴"
        }
        return "已记录 \(viewModel.allEntries.count) / \(AppSettings.shared.historyLimit) 条"
    }

    @ViewBuilder
    private var shortcutHints: some View {
        if viewModel.isCommandPressed {
            HStack(spacing: 8) {
                kbdHint("↑↓", "选择")
                kbdHint("←→", "翻页")
                kbdHint("⌘↵ / ⌘点击", "加入批次")
            }
        } else if viewModel.batchSelectionIDs.isEmpty {
            HStack(spacing: 8) {
                kbdHint("↑↓", "选择")
                kbdHint("←→", "翻页")
                kbdHint("↵ / ⌥↵", "粘贴")
                kbdHint("esc", "关闭")
            }
        } else {
            HStack(spacing: 8) {
                kbdHint("↑↓", "选择")
                kbdHint("←→", "翻页")
                kbdHint("⌘↵ / ⌘点击", "加入/移出")
                kbdHint("↵", "合并粘贴")
                kbdHint("⌘⌫", "删除")
                kbdHint("esc", "关闭")
            }
        }
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
                .foregroundStyle(colorScheme == .dark ? .white : palette.textTertiary)
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
        return urls[0].lastPathComponent + " 等 \(urls.count) 个文件"
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
