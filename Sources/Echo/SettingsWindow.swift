import SwiftUI
import AppKit

/// 设置窗口控制器。
///
/// Echo 设置页:历史上限、全局热键、自动粘贴开关、清空历史、AX 权限状态。
/// 所有配置经 AppSettings 持久化到 UserDefaults。
final class SettingsWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Echo 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 显示窗口。菜单栏 App(.accessory)需先激活否则窗口灰着无法聚焦。
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 设置页 SwiftUI 视图。
struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    // 配置(经 AppSettings 读写 UserDefaults)
    @State private var historyLimit: Int = AppSettings.shared.historyLimit
    @State private var hotkeyModifiers: UInt32 = AppSettings.shared.hotkeyModifiers
    @State private var hotkeyKeyCode: UInt32 = AppSettings.shared.hotkeyKeyCode
    @State private var autoPasteEnabled: Bool = AppSettings.shared.autoPasteEnabled
    @State private var hotkeyPresetIndex: Int = 0

    // AX 权限状态
    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var historyCount: Int = HistoryStore.shared.count

    private var palette: EchoTheme.Palette {
        EchoTheme.palette(for: colorScheme)
    }

    // 可选热键预设(避免复杂手势捕获,提供常用两键组合)
    private let hotkeyPresets: [(label: String, modifiers: UInt32, keycode: UInt32)] = [
        ("⌘ \\",  0x0100, 42),
        ("⌘ ⌥ V", 0x0100 | 0x0800, 9),
        ("⌘ ⇧ V", 0x0100 | 0x0200, 9),
        ("⌃ ⌘ V", 0x1000 | 0x0100, 9),
        ("⌘ B",   0x0100, 11),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsSection(title: "通用") {
                    settingRow(title: "历史上限") {
                        Stepper(value: $historyLimit, in: 10...200, step: 10) {
                            Text("\(historyLimit)")
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                        .onChange(of: historyLimit) { newValue in
                            AppSettings.shared.historyLimit = newValue
                        }
                    }

                    settingNote("文本/图片/文件共享名额。超出后最旧条目被淘汰,图片同步删盘。")
                }

                settingsSection(title: "全局热键") {
                    settingRow(title: "呼出快捷键") {
                        Picker("", selection: $hotkeyPresetIndex) {
                            ForEach(hotkeyPresets.indices, id: \.self) { idx in
                                Text(hotkeyPresets[idx].label).tag(idx)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: hotkeyPresetIndex) { newValue in
                            applyHotkey(index: newValue)
                        }
                    }

                    settingNote("在任意 App 中按此快捷键呼出历史选择面板。⌘\\ 为默认(两键、左手区、系统几乎不占用)。")
                }

                settingsSection(title: "粘贴") {
                    settingRow(title: "启用自动粘贴", subtitle: autoPasteEnabled ? "选中后自动模拟 ⌘V。需要辅助功能权限。" : "关闭后只写回剪贴板。") {
                        Toggle("", isOn: $autoPasteEnabled)
                            .labelsHidden()
                            .onChange(of: autoPasteEnabled) { newValue in
                                AppSettings.shared.autoPasteEnabled = newValue
                            }
                    }

                    if autoPasteEnabled {
                        permissionRow
                    }
                }

                settingsSection(title: "数据") {
                    settingRow(title: "当前历史") {
                        Text("\(historyCount) / \(historyLimit) 条")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                    }

                    settingRow(title: "清空所有历史", subtitle: "立即删除历史和图片缓存。") {
                        Button(role: .destructive) {
                            HistoryStore.shared.clearAll()
                            historyCount = 0
                        } label: {
                            Text("清空")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    settingRow(title: "重置使用成就", subtitle: "只删除勋章统计,不会影响当前或下次剪贴板历史。") {
                        Button(role: .destructive) {
                            AchievementStore.shared.reset()
                        } label: {
                            Text("重置")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Text("Echo · 剪贴板历史管理器 · 本地运行,数据不出本机")
                    .font(.caption2)
                    .foregroundStyle(palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
            .padding(18)
        }
        .frame(width: 520, height: 560)
        .background(palette.windowBackground)
        .onAppear {
            syncHotkeyPresetIndex()
            axGranted = AXIsProcessTrusted()
            historyCount = HistoryStore.shared.count
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChangeNotification)) { _ in
            historyCount = HistoryStore.shared.count
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axGranted = AXIsProcessTrusted()
            historyCount = HistoryStore.shared.count
            syncHotkeyPresetIndex()
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 12) {
            if axGranted {
                Label("辅助功能权限:已授予", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(palette.green)
            } else {
                Label("辅助功能权限:未授予(自动粘贴将降级)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.yellow)
                Button("打开设置") {
                    PermissionsManager.shared.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.controlBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.controlBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 设置页分组,贴近 design-plan.html 的 set-section 结构。
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.08)
                .foregroundStyle(palette.accent)

            content()
        }
    }

    /// 单行设置项:左侧标题/副标题,右侧控件。
    private func settingRow<Accessory: View>(title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            Spacer(minLength: 16)

            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(palette.rowBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func settingNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 根据当前配置同步热键预设索引。
    private func syncHotkeyPresetIndex() {
        hotkeyPresetIndex = hotkeyPresets.firstIndex {
            $0.modifiers == hotkeyModifiers && $0.keycode == hotkeyKeyCode
        } ?? 0
    }

    /// 把选中的预设应用到 AppSettings 并重新注册热键。
    private func applyHotkey(index: Int) {
        let clampedIndex = hotkeyPresets.indices.contains(index) ? index : 0
        let preset = hotkeyPresets[clampedIndex]
        hotkeyPresetIndex = clampedIndex
        hotkeyModifiers = preset.modifiers
        hotkeyKeyCode = preset.keycode
        AppSettings.shared.hotkeyModifiers = preset.modifiers
        AppSettings.shared.hotkeyKeyCode = preset.keycode
        GlobalHotkey.shared.reregister()
    }
}
