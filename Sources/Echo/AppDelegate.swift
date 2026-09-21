import AppKit

/// Echo 应用主控制器:负责菜单栏图标、菜单项、权限引导与各组件生命周期。
///
/// Stage 1 骨架:仅装配菜单栏 UI 与权限检查;
/// 后续 Stage 会逐步接入:
/// - Stage 2: ClipboardWatcher + HistoryStore(采集链路)
/// - Stage 3: GlobalHotkey + QuickPanel(呼出面板)
/// - Stage 4: Paster(粘贴 + 降级)
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - UI Elements

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var countMenuItem: NSMenuItem!

    /// 设置窗口控制器(懒加载)
    private lazy var settingsWindowController = SettingsWindowController()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动即清空图片缓存(符合"每次启动即初始化"约束:
        // 历史纯内存归零,遗留图片盘文件是上次运行的残留,清掉避免膨胀)
        ImageCache.shared.purgeAll()

        setupStatusItem()
        setupHistoryObserver()
        setupGlobalHotkey()

        // 启动剪贴板监听(零权限,覆盖所有复制来源)
        ClipboardWatcher.shared.start()
        updateStatusMenuItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Echo"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = L10n.text("app.tagline")
        }

        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 显示历史:Stage 3 接入 QuickPanel 后会呼出面板
        let showHistory = NSMenuItem(
            title: L10n.text("menu.showHistory"),
            action: #selector(showHistory),
            keyEquivalent: "\\"
        )
        showHistory.target = self
        menu.addItem(showHistory)

        // 清空历史:Stage 2 接入 HistoryStore 后生效
        let clearHistory = NSMenuItem(
            title: L10n.text("menu.clearHistory"),
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clearHistory.target = self
        menu.addItem(clearHistory)

        countMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        countMenuItem.isEnabled = false
        countMenuItem.isHidden = true
        menu.addItem(countMenuItem)

        menu.addItem(NSMenuItem.separator())

        let openSettings = NSMenuItem(
            title: L10n.text("menu.settings"),
            action: #selector(openSettingsWindow),
            keyEquivalent: ","
        )
        openSettings.target = self
        menu.addItem(openSettings)

        let openAccessibility = NSMenuItem(
            title: L10n.text("menu.openAccessibility"),
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        openAccessibility.target = self
        menu.addItem(openAccessibility)

        let quit = NSMenuItem(
            title: L10n.text("menu.quit"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusMenuItem()
    }

    // MARK: - 全局热键

    /// 注册全局热键(⌘\),触发时显示 QuickPanel。
    private func setupGlobalHotkey() {
        GlobalHotkey.shared.onTriggered = { [weak self] in
            AchievementStore.shared.recordHotkeyShow()
            self?.showHistoryPanel()
        }
        GlobalHotkey.shared.register()
    }

    // MARK: - Actions

    @objc private func showHistory() {
        showHistoryPanel()
    }

    /// 显示历史选择面板(菜单点击与热键共用入口)。
    private func showHistoryPanel() {
        QuickPanelController.shared.onSelected = { entry, context, format in
            Paster.shared.paste(
                entry,
                format: format,
                context: context,
                targetApp: QuickPanelController.shared.frontmostAppAtShowTime
            )
        }
        QuickPanelController.shared.onBatchSelected = { entries, context in
            Paster.shared.pasteTextBatch(
                entries,
                context: context,
                targetApp: QuickPanelController.shared.frontmostAppAtShowTime
            )
        }
        QuickPanelController.shared.show()
    }

    @objc private func clearHistory() {
        HistoryStore.shared.clearAll()
    }

    @objc private func openSettingsWindow() {
        settingsWindowController.show()
    }

    @objc private func openAccessibilitySettings() {
        PermissionsManager.shared.openSystemSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 历史变化订阅

    /// 订阅 HistoryStore 变化通知,刷新菜单栏计数。
    private func setupHistoryObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyDidChange),
            name: HistoryStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func historyDidChange() {
        updateStatusMenuItem()
    }

    // MARK: - UI Updates

    /// 刷新菜单栏状态行与计数行。
    private func updateStatusMenuItem() {
        statusMenuItem.title = L10n.text("menu.monitoring")
        let count = HistoryStore.shared.count
        countMenuItem.title = L10n.format("menu.collected", count)
        countMenuItem.isHidden = (count == 0)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// 菜单即将打开时刷新状态
    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenuItem()
    }
}
