import SwiftUI
import AppKit

/// QuickPanel:Spotlight 风格的剪贴板历史选择浮层。
///
/// 设计依据(详见 design-plan.html 板块5、6):
/// - **NSPanel + nonactivating**:浮层不抢目标 App 焦点(关键:粘贴需要目标 App 仍是 key)
/// - **三种选择方式**:数字直达 / 关键词搜索 / 方向键导航(同一输入框智能识别)
/// - **失焦即关 / Esc 即关**:工具类产品零打扰
/// - 列表按"最近在前":第 1 条 = 最近复制的,数字直达语义自然
///
/// 交互逻辑(详见 design-plan.html 板块6):
/// - 输入纯数字且 ≤ 列表长度 → 视为编号,回车直达该条
/// - 输入含非数字字符 → 视为搜索词,对文本/文件做子串过滤(图片不参与搜索)
/// - 不输入 → 方向键浏览,默认高亮第 1 条
///
/// 选中后通过 onSelected 回调把 entry 交给 Paster(Stage 4)。
final class QuickPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickPanelController()

    /// 选中某条历史项时调用(主线程)。
    var onSelected: ((ClipEntry) -> Void)?

    /// 承载 SwiftUI 内容的非激活式浮层
    private var panel: NSPanel?
    /// 当前显示的历史快照
    private var currentEntries: [ClipEntry] = []
    /// SwiftUI 视图模型(驱动列表与选中状态)
    private let viewModel = QuickPanelViewModel()
    /// 本地键盘事件监听器(面板显示期间接收方向键/回车/Esc)
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

        // 先关闭旧面板(必须在 configure 之前,否则 hide 的 reset 会清空新数据)
        hide()

        // 记录当前最前台 App——选中条目粘贴时,要激活它让 ⌘V 送达
        frontmostAppAtShowTime = NSWorkspace.shared.frontmostApplication

        // 无历史则不弹(避免空面板)
        if entries.isEmpty {
            NSSound.beep()
            return
        }

        viewModel.configure(entries: entries)
        let viewModel = self.viewModel
        let hosting = NSHostingController(rootView: QuickPanelView(viewModel: viewModel) { [weak self] entry in
            self?.handleSelected(entry)
        })

        let panel = Self.makePanel(contentViewController: hosting)
        panel.delegate = self
        self.panel = panel

        // 装本地键盘监听器:方向键/回车/Esc
        installKeyMonitor()

        // 居中并显示
        // 面板需要 activate 才能接收键盘输入(TextField 聚焦 + NSEvent monitor)。
        // 选中条目后,Paster 会在粘贴前激活目标 App。
        NSApp.activate(ignoringOtherApps: true)
        panel.setContentSize(NSSize(width: 560, height: 420))
        centerOnScreen(panel)
        panel.makeKeyAndOrderFront(nil)
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

    /// 装本地键盘事件监听器,处理方向键导航 / 回车确认 / Esc 取消。
    /// 用 NSEvent.addLocalMonitorForEvents(兼容 macOS 13,替代 SwiftUI onKeyPress 的 macOS 14 要求)。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
    }

    /// 处理一次按键。返回 nil 表示吞掉该事件,返回 event 表示放行。
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 126:  // ↑
            viewModel.moveUp()
            return nil
        case 125:  // ↓
            viewModel.moveDown()
            return nil
        case 36, 76:  // Return / Enter
            if let entry = viewModel.selectedEntry() {
                handleSelected(entry)
            }
            return nil
        case 53:  // Esc
            hide()
            return nil
        default:
            return event
        }
    }

    // MARK: - 选中处理

    private func handleSelected(_ entry: ClipEntry) {
        hide()
        onSelected?(entry)
    }

    // MARK: - NSWindowDelegate

    /// 失焦即关:面板失去 key 状态时自动关闭(零打扰)。
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Panel 工厂

    /// 构造一个非激活式、无边框、毛玻璃浮层。
    private static func makePanel(contentViewController: NSViewController) -> NSPanel {
        let styleMask: NSWindow.StyleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = contentViewController
        // 显式设置内容尺寸,防止 SwiftUI 视图 intrinsic size 没撑开导致面板为 0
        panel.contentViewController?.view.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        panel.setContentSize(NSSize(width: 560, height: 420))
        panel.setFrame(NSRect(x: 0, y: 0, width: 560, height: 420), display: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        return panel
    }

    /// 把面板居中显示在鼠标所在的屏幕(贴近用户视线焦点)。
    private func centerOnScreen(_ panel: NSPanel) {
        // 找鼠标所在屏幕;无则回退主屏
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        // 水平居中,垂直略偏上(贴近 Spotlight 习惯位置)
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY + screenFrame.height * 0.1
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 视图模型

/// 驱动 QuickPanel 列表与选中状态的视图模型。
final class QuickPanelViewModel: ObservableObject {
    /// 全部历史(最近在前)
    @Published private(set) var allEntries: [ClipEntry] = []

    /// 搜索/编号输入框文本
    @Published var query: String = "" {
        didSet {
            // configure 期间禁止 didSet 触发 applyFilter(避免 query="" 清空还没配好的数据)
            guard !isConfiguring else { return }
            applyFilter()
        }
    }

    /// 当前显示(过滤后)的条目,带显示编号(1-based)
    @Published private(set) var displayed: [DisplayItem] = []

    /// 当前选中的显示编号
    @Published var selectedDisplayIndex: Int = 1

    /// configure 进行中标志(禁止 query didSet 干扰)
    private var isConfiguring = false

    struct DisplayItem: Identifiable {
        let id: UUID           // 来自 ClipEntry.id
        let displayNumber: Int // 1-based 显示编号
        let entry: ClipEntry
    }

    func configure(entries: [ClipEntry]) {
        isConfiguring = true
        allEntries = entries
        query = ""
        applyFilter()
        selectedDisplayIndex = 1
        isConfiguring = false
    }

    func reset() {
        allEntries = []
        query = ""
        displayed = []
    }

    /// 应用过滤:纯数字→编号定位;否则→子串搜索;空→全部。
    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            displayed = allEntries.enumerated().map { idx, e in
                DisplayItem(id: e.id, displayNumber: idx + 1, entry: e)
            }
            clampSelection()
            return
        }
        if let n = Int(q), n > 0 {
            // 数字直达:不缩小列表,只把选中移到第 n 条(若存在)
            displayed = allEntries.enumerated().map { idx, e in
                DisplayItem(id: e.id, displayNumber: idx + 1, entry: e)
            }
            selectedDisplayIndex = min(n, displayed.count)
            return
        }
        // 关键词搜索:文本/文件做子串匹配,图片不参与(无法文字搜)
        let needle = q.lowercased()
        displayed = allEntries.enumerated().compactMap { idx, e in
            switch e.kind {
            case .text(let body):
                return body.lowercased().contains(needle)
                    ? DisplayItem(id: e.id, displayNumber: idx + 1, entry: e) : nil
            case .files(let urls):
                let names = urls.map { $0.lastPathComponent }.joined(separator: " ").lowercased()
                return names.contains(needle)
                    ? DisplayItem(id: e.id, displayNumber: idx + 1, entry: e) : nil
            case .image:
                return nil
            }
        }
        clampSelection()
    }

    /// 确保选中编号在合法范围内
    private func clampSelection() {
        if displayed.isEmpty {
            selectedDisplayIndex = 0
        } else {
            selectedDisplayIndex = max(1, min(selectedDisplayIndex, displayed.count))
        }
    }

    // MARK: - 键盘导航

    func moveUp() {
        guard !displayed.isEmpty else { return }
        selectedDisplayIndex = selectedDisplayIndex > 1 ? selectedDisplayIndex - 1 : displayed.count
    }
    func moveDown() {
        guard !displayed.isEmpty else { return }
        selectedDisplayIndex = selectedDisplayIndex < displayed.count ? selectedDisplayIndex + 1 : 1
    }

    /// 当前选中的 ClipEntry(数字直达或方向键选中),无则 nil。
    func selectedEntry() -> ClipEntry? {
        // 若输入是纯数字且指向某条,直接返回那条(数字直达优先)
        if let n = Int(query.trimmingCharacters(in: .whitespaces)), n > 0 {
            return allEntries.indices.contains(n - 1) ? allEntries[n - 1] : nil
        }
        // 否则用方向键选中的显示项
        guard selectedDisplayIndex >= 1, selectedDisplayIndex <= displayed.count else { return nil }
        return displayed[selectedDisplayIndex - 1].entry
    }
}

// MARK: - SwiftUI 视图

struct QuickPanelView: View {
    @ObservedObject var viewModel: QuickPanelViewModel
    let onSelected: (ClipEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().background(Color.white.opacity(0.1))
            listArea
            footer
        }
        .frame(width: 560, height: 420)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    // MARK: 搜索栏

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
            TextField("输入编号直达 / 关键词搜索", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($fieldFocused)
            if !viewModel.query.isEmpty {
                Text(directHint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .onAppear { fieldFocused = true }
    }

    @FocusState private var fieldFocused: Bool

    /// 输入纯数字时显示"→ 直达第 N 条"提示。
    private var directHint: String {
        let q = viewModel.query.trimmingCharacters(in: .whitespaces)
        if let n = Int(q), n > 0 {
            return "→ 直达第 \(n) 条"
        }
        return "搜索中"
    }

    // MARK: 列表

    private var listArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.displayed) { item in
                        itemRow(item)
                            .id(item.id)
                            .background(
                                viewModel.selectedDisplayIndex == item.displayNumber
                                ? Color.accentColor.opacity(0.25)
                                : Color.clear
                            )
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelected(item.entry)
                            }
                    }
                    if viewModel.displayed.isEmpty {
                        Text(viewModel.query.isEmpty ? "暂无历史" : "无匹配结果")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 40)
                    }
                }
                .padding(6)
            }
            .onChange(of: viewModel.selectedDisplayIndex) { _ in
                // 选中变化时滚动到该条
                if let id = viewModel.selectedEntry()?.id {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    /// 单行:编号 + 内容预览 + 类型标签
    @ViewBuilder
    private func itemRow(_ item: QuickPanelViewModel.DisplayItem) -> some View {
        HStack(spacing: 12) {
            Text("\(item.displayNumber)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            previewContent(for: item.entry.kind)
            Spacer(minLength: 0)
            typeTag(for: item.entry.kind)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    /// 根据类型渲染预览:文本/图片缩略图/文件图标
    @ViewBuilder
    private func previewContent(for kind: ClipEntry.Kind) -> some View {
        switch kind {
        case .text(let body):
            Text(body.previewString(maxLines: 1))
                .font(.system(size: 13.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
        case .image(let ref):
            HStack(spacing: 10) {
                Image(nsImage: ref.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("[ 图片 ]").foregroundStyle(.secondary).font(.system(size: 13))
                    Text(ref.sizeText).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        case .files(let urls):
            HStack(spacing: 10) {
                Image(systemName: fileIconName(for: urls.first))
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filesPreview(urls))
                        .font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.primary)
                    Text(filesLocation(urls))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func typeTag(for kind: ClipEntry.Kind) -> some View {
        let (text, color): (String, Color) = {
            switch kind {
            case .text: return ("文本", .blue)
            case .image: return ("图片", .purple)
            case .files: return ("文件", .green)
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(5)
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Text("已记录 \(viewModel.allEntries.count) / \(AppSettings.shared.historyLimit) 条")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 14) {
                kbdHint("↑↓", "选择")
                kbdHint("↵", "粘贴")
                kbdHint("esc", "关闭")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.black.opacity(0.15))
    }

    private func kbdHint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.white.opacity(0.1)).cornerRadius(4)
            Text(label)
        }
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
