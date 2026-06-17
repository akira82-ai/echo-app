import AppKit

/// 应用主控制器：负责菜单栏图标、菜单项、权限引导与监听生命周期。
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - UI Elements

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var todayCountMenuItem: NSMenuItem!

    /// 今日已记录条数（用于菜单显示）
    private var todayCount: Int = 0

    /// 热键监听器
    private let monitor = HotkeyMonitor()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupCallbacks()

        // 启动权限检查 → 通过后自动启动监听
        PermissionsManager.shared.requestIfNeeded()
        if PermissionsManager.shared.isGranted {
            startMonitoring()
        } else {
            updateStatusMenuItem()
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Lark Assistant"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Lark Assistant - 三连 ⌘+C 收集剪贴内容"
        }

        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(
            title: "暂停监听",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        todayCountMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(todayCountMenuItem)

        menu.addItem(NSMenuItem.separator())

        let openToday = NSMenuItem(
            title: "打开今日文件",
            action: #selector(openTodayFile),
            keyEquivalent: "o"
        )
        openToday.target = self
        menu.addItem(openToday)

        let openFolder = NSMenuItem(
            title: "在 Finder 中显示",
            action: #selector(revealInFinder),
            keyEquivalent: ""
        )
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(NSMenuItem.separator())

        let openSettings = NSMenuItem(
            title: "打开辅助功能设置…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        openSettings.target = self
        menu.addItem(openSettings)

        let quit = NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusMenuItem()
    }

    private func setupCallbacks() {
        monitor.onTriggered = { [weak self] in
            self?.todayCount += 1
            self?.flashStatusItem()
        }
        monitor.onPermissionDenied = { [weak self] in
            self?.updateStatusMenuItem()
        }
        PermissionsManager.shared.onStatusChange = { [weak self] granted in
            if granted {
                self?.startMonitoring()
            }
            self?.updateStatusMenuItem()
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        if monitor.start() {
            monitor.isPaused = false
            updateStatusMenuItem()
        }
    }

    // MARK: - Actions

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        updateStatusMenuItem()
    }

    @objc private func openTodayFile() {
        let url = StorageManager.shared.fileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            showAlert(title: "今日暂无记录",
                      message: "文件还未创建：\(url.lastPathComponent)\n三连 ⌘+C 复制内容后即会生成。")
        }
    }

    @objc private func revealInFinder() {
        let url = StorageManager.shared.fileURL()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openAccessibilitySettings() {
        PermissionsManager.shared.openSystemSettings()
    }

    @objc private func quit() {
        monitor.stop()
        NSApp.terminate(nil)
    }

    // MARK: - UI Updates

    private func updateStatusMenuItem() {
        let granted = PermissionsManager.shared.isGranted
        let paused = monitor.isPaused

        if !granted {
            statusMenuItem.title = "⚠️ 未授权辅助功能权限"
            statusMenuItem.toolTip = "请在系统设置中授权"
            toggleMenuItem.isHidden = true
        } else if paused {
            statusMenuItem.title = "⏸ 监听已暂停"
            toggleMenuItem.title = "继续监听"
            toggleMenuItem.isHidden = false
        } else {
            statusMenuItem.title = "✅ 监听中 · 三连 ⌘+C 收集"
            toggleMenuItem.title = "暂停监听"
            toggleMenuItem.isHidden = false
        }

        if granted {
            todayCountMenuItem.title = "今日已收集：\(todayCount) 条"
            todayCountMenuItem.isHidden = false
        } else {
            todayCountMenuItem.isHidden = true
        }
    }

    /// 触发时短暂高亮菜单栏图标，给用户反馈
    private func flashStatusItem() {
        guard let button = statusItem.button else { return }
        let original = button.image
        let flash = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "已保存"
        )
        flash?.isTemplate = true
        button.image = flash
        updateStatusMenuItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            button.image = original
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// 菜单即将打开时刷新状态显示
    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenuItem()
    }
}
